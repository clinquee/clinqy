import AppKit
import QuartzCore

/// The companion: a small glowing triangle that rides just below-right of your mouse, pointing at it.
/// When Clinqy acts it leaves your side, flies an arc to each target the way a hand would travel,
/// points, clicks, types — then flies home. It draws on a click-through overlay on every screen.
@MainActor
final class Buddy {
    enum Mood { case idle, listening, thinking, acting, success, failure }

    var mood: Mood = .idle {
        didSet {
            guard mood != oldValue else { return }
            let now = CACurrentMediaTime()
            if mood == .failure { shakeStart = now }
            if mood == .success { pop = now }
            wake()
        }
    }

    /// Microphone level 0…1 while listening.
    var level: CGFloat = 0

    /// Off: the companion stays hidden while Clinqy is idle and only appears when it listens, thinks or acts.
    var followsMouse = UserDefaults.standard.object(forKey: "buddyFollowsMouse") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followsMouse, forKey: "buddyFollowsMouse"); wake() }
    }

    /// QA mode: the companion becomes an amber targeting reticle with a "QA" tag.
    var qaMode = false { didSet { wake() } }
    /// A background run nobody is watching: the buddy doesn't fly to clicks in windows the user can't see.
    var quiet = false
    var suppressed = false { didSet { stages.forEach { $0.window.alphaValue = suppressed ? 0 : 1 } } }
    var tint: NSColor?
    var parkingSlot: Int?
    private var disposed = false
    /// A background run on Clinqy's hidden screen: the buddy only goes, points and frames things there.
    var confine: CGRect?
    /// Parked at the screen's edge, off doing a background run (see `goAway`).
    private(set) var away = false

    /// A check result: green flash + pop when it held, red flash + shake when it didn't.
    func signal(_ ok: Bool) {
        let now = CACurrentMediaTime()
        flash = (ok, now)
        if ok { pop = now } else { shakeStart = now }
        wake()
    }
    private var flash: (Bool, CFTimeInterval)?

    private enum Mode { case following, flying, parked, returning }
    private var mode: Mode = .following

    private var stages: [Stage] = []
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    /// Motion follows the display's refresh rate (up to 120 Hz), decorative animation 30 Hz; a parked companion has no idle timer.
    private var fast = false
    private var stillSince: CFTimeInterval?
    private var mouseMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    // Motion, in global top-left coordinates (CGEvent space). `pos` is the triangle's tip.
    private var pos = CGPoint(x: 400, y: 400)
    private var vel = CGVector.zero
    private var angle: CGFloat = Buddy.restAngle
    private var scale: CGFloat = 1
    private var flight: Flight?
    private var returnStartMouse = CGPoint.zero

    // Effects.
    private var shakeStart: CFTimeInterval = 0
    private var pop: CFTimeInterval = 0
    private var pressStart: CFTimeInterval = 0
    private var ripples: [(CGPoint, CFTimeInterval)] = []
    private var highlight: CGRect?
    private var highlightAlpha: CGFloat = 0
    private var typing = false
    private var bubbleText: String?
    private var bubbleShown = 0
    private var bubbleAppeared: CFTimeInterval = 0
    private var bubbleWidth: CGFloat = 0
    private var bubbleTimer: Timer?
    private var mark: Mark?
    /// 0 = beside the mouse, 1 = floated up off-stage (the mouse went idle or the user is typing).
    private var offstage: CGFloat = 0

    /// A hand-drawn circle around something, with an arrow drawn in from where the buddy parks.
    struct Mark {
        let rect: CGRect
        let tail: CGPoint
        let began: CFTimeInterval
        let seed: CGFloat
        let mouse: CGPoint
        /// When it started fading out (time's up, or the user moved on).
        var fading: CFTimeInterval?
    }

    /// Upright like the system cursor; it only leans a little into fast motion.
    static let restAngle: CGFloat = 0
    /// Where it rides relative to the mouse.
    static let offset = CGVector(dx: 14, dy: 16)

    private struct Flight {
        let start: CGPoint
        let control: CGPoint
        let end: CGPoint
        let began: CFTimeInterval
        let duration: CFTimeInterval
        var done: CheckedContinuation<Void, Never>?
    }

    init() {
        Efficiency.start()
        rebuildStages()
        let m = Self.mouse()
        pos = CGPoint(x: m.x + Self.offset.dx, y: m.y + Self.offset.dy)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildStages() }
        }
        setRate(fast: true)
    }

    private func watchMouse() {
        guard mouseMonitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { mouseMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) { mouseMonitors.append(monitor) }
    }

    deinit {
        timer?.invalidate()
        bubbleTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
    }

    private func mouseMoved() {
        // Already animating: no new task, simulation step or timer allocation per mouse event.
        if !fast, mode == .following { wake() }
    }

    private func setRate(fast: Bool) {
        self.fast = fast
        if fast || mode != .following {
            for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
            mouseMonitors.removeAll()
        } else { watchMouse() }
        if !fast, mode != .following {
            timer?.invalidate(); timer = nil
            return
        }
        let moving = flight != nil || (mode == .following && hypot(vel.dx, vel.dy) > 1)
        let interval = fast ? Efficiency.animationInterval(moving: moving) : 0.25
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            onMainRunLoop { self?.tick() }
        }
        timer.tolerance = fast ? interval * 0.1 : 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Back to full frame rate (something changed that has to animate).
    private func wake() {
        guard !disposed else { return }
        stillSince = nil
        setRate(fast: true)
    }

    // MARK: - API

    /// Flies along an arc so the tip lands just below-right of `point`, pointing at it. Frames `rect` if given.
    func travel(to point: CGPoint, framing rect: CGRect? = nil) async {
        if quiet { return }
        if let confine, !confine.contains(point) { return }
        highlight = rect.map { $0.insetBy(dx: -5, dy: -5) }
        typing = false
        let end = CGPoint(x: point.x + 3, y: point.y + 3)
        let start = pos
        let distance = hypot(end.x - start.x, end.y - start.y)
        if distance < 4 { mode = .parked; wake(); return }
        // A person's hand: quick for short hops, never instant, never sluggish.
        let duration = min(0.8, max(0.3, 0.24 + Double(distance) / 1900))
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let lift = min(distance * 0.22, 90)
        let control = CGPoint(x: mid.x, y: mid.y - lift)
        finishFlight()
        mode = .flying
        wake()
        if !Efficiency.humanMotion {
            flight = Flight(start: start, control: control, end: end, began: CACurrentMediaTime(), duration: min(0.18, duration), done: nil)
            return
        }
        await withCheckedContinuation { continuation in
            flight = Flight(start: start, control: control, end: end, began: CACurrentMediaTime(),
                            duration: duration, done: continuation)
        }
    }

    /// Press-in squash with a ripple at the tip.
    func click() {
        if quiet { return }
        pressStart = CACurrentMediaTime()
        ripples.append((flight?.end ?? pos, pressStart))
        if ripples.count > 4 { ripples.removeFirst() }
        wake()
    }

    /// Gentle bob while text goes in.
    func setTyping(_ on: Bool) { typing = on; wake() }

    /// Off to work somewhere else, until the run is done or needs the user (`goHome` brings it back): onto Clinqy's
    /// hidden screen when there is one (`to`; it leaves through the corner that screen touches), else to the right
    /// edge of the user's screen, half out of view.
    func goAway(to elsewhere: CGRect? = nil) {
        highlight = nil
        typing = false
        let m = Self.mouse()
        let screen = NSScreen.screens.map { AXEngine.flipped($0.frame) }.first { $0.contains(m) }
            ?? AXEngine.flipped(NSScreen.main?.frame ?? .zero)
        let end = parkingSlot.map { CGPoint(x: screen.maxX - 26, y: screen.maxY - 55 - CGFloat($0) * 58) }
            ?? elsewhere.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: screen.maxX - 10, y: screen.minY + screen.height * 0.22)
        away = true
        let start = pos
        let distance = hypot(end.x - start.x, end.y - start.y)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        finishFlight()
        mode = .flying
        flight = Flight(start: start, control: CGPoint(x: mid.x, y: mid.y - min(distance * 0.25, 120)), end: end,
                        began: CACurrentMediaTime(), duration: min(1.1, max(0.5, 0.3 + Double(distance) / 1600)), done: nil)
        wake()
    }

    /// Clears the target frame, then flies back to the mouse and resumes following.
    func goHome() {
        away = false
        highlight = nil
        typing = false
        guard mode != .following else { return }
        let m = Self.mouse()
        returnStartMouse = m
        mode = .returning
        let start = pos
        let end = CGPoint(x: m.x + Self.offset.dx, y: m.y + Self.offset.dy)
        let distance = hypot(end.x - start.x, end.y - start.y)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        finishFlight()
        flight = Flight(start: start, control: CGPoint(x: mid.x, y: mid.y - min(distance * 0.2, 70)), end: end,
                        began: CACurrentMediaTime(), duration: min(0.9, max(0.35, 0.25 + Double(distance) / 1800)), done: nil)
        wake()
    }

    /// A small speech bubble beside the triangle, streamed in character by character.
    func bubble(_ text: String?, for seconds: TimeInterval = 3.5) {
        bubbleTimer?.invalidate()
        guard let text, !text.isEmpty else { bubbleText = nil; return }
        bubbleText = String(text.replacingOccurrences(of: "\n", with: " ").prefix(90))
        bubbleShown = 0
        bubbleAppeared = CACurrentMediaTime()
        wake()
        bubbleTimer = Timer.scheduledTimer(withTimeInterval: 0.028, repeats: true) { [weak self] t in
            onMainRunLoop {
                guard let self, let full = self.bubbleText else { t.invalidate(); return }
                self.bubbleShown += 1
                if self.bubbleShown >= full.count {
                    t.invalidate()
                    let shownText = full
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                        if self?.bubbleText == shownText { self?.bubbleText = nil }
                    }
                }
            }
        }
    }

    /// Marks something on screen: flies beside it, draws a circle around it and an arrow to it, shows `label`.
    /// Stays until `clearMark()` or the next mark; the buddy stays parked next to it meanwhile.
    func mark(_ rect: CGRect, label: String?) async {
        if quiet { return }
        if let confine, !confine.contains(CGPoint(x: rect.midX, y: rect.midY)) { return }
        highlight = nil
        let screen = NSScreen.screens.map { AXEngine.flipped($0.frame) }.first { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }
            ?? AXEngine.flipped(NSScreen.main?.frame ?? .zero)
        // The arrow comes in from whichever side has room, a little above.
        let dx: CGFloat = rect.midX > screen.midX ? -150 : 150
        let dy: CGFloat = rect.midY > screen.minY + 160 ? -90 : 90
        var tail = CGPoint(x: rect.midX + dx, y: rect.midY + dy)
        tail.x = min(max(tail.x, screen.minX + 30), screen.maxX - 220)
        tail.y = min(max(tail.y, screen.minY + 40), screen.maxY - 60)
        await travel(to: tail)
        mark = Mark(rect: rect, tail: tail, began: CACurrentMediaTime(), seed: CGFloat.random(in: 0...(2 * .pi)),
                    mouse: Self.mouse())
        wake()
        try? await Task.sleep(for: .milliseconds(900))
        if let label, !label.isEmpty { bubble(label, for: 3) }
    }

    func clearMark() { mark = nil; wake() }

    /// Fades out the frame around the element just used (the UI has usually moved on).
    func clearHighlight() { highlight = nil; wake() }

    /// Recent positions (global), for the short streak drawn behind the buddy as it moves.
    private var trail: [(CGPoint, CFTimeInterval)] = []

    private func finishFlight() {
        flight?.done?.resume()
        flight = nil
    }

    // MARK: - Simulation

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(1.0 / 30.0, now - lastTick))
        lastTick = now
        let mouse = Self.mouse()
        var targetAngle = Self.restAngle

        if var f = flight {
            // Moving the mouse a lot during the flight home hands control back immediately.
            if mode == .returning, hypot(mouse.x - returnStartMouse.x, mouse.y - returnStartMouse.y) > 100 {
                flight = nil
                mode = .following
            } else {
                let raw = min(1, (now - f.began) / f.duration)
                let t = CGFloat(raw * raw * (3 - 2 * raw))   // smoothstep
                let u = 1 - t
                let next = CGPoint(x: u * u * f.start.x + 2 * u * t * f.control.x + t * t * f.end.x,
                                   y: u * u * f.start.y + 2 * u * t * f.control.y + t * t * f.end.y)
                let tangent = CGVector(dx: 2 * u * (f.control.x - f.start.x) + 2 * t * (f.end.x - f.control.x),
                                       dy: 2 * u * (f.control.y - f.start.y) + 2 * t * (f.end.y - f.control.y))
                vel = CGVector(dx: (next.x - pos.x) / max(dt, 0.001), dy: (next.y - pos.y) / max(dt, 0.001))
                pos = next
                _ = tangent
                scale = 1 + 0.28 * CGFloat(sin(raw * .pi))
                if raw >= 1 {
                    let done = f.done
                    f.done = nil
                    flight = nil
                    vel = .zero
                    mode = mode == .returning ? .following : .parked
                    done?.resume()
                }
            }
        }

        if flight == nil, mode == .following {
            // Stiff, slightly bouncy spring: sticks to the mouse like it's attached by a short elastic.
            let goal = CGPoint(x: mouse.x + Self.offset.dx, y: mouse.y + Self.offset.dy)
            let omega: CGFloat = 2 * .pi / 0.16
            let k = omega * omega, c = 2 * 1.0 * omega
            // Small fixed substeps keep the stiff spring stable even when a frame arrives late.
            let steps = max(1, Int(ceil(dt / (1.0 / 480.0))))
            let h = dt / CGFloat(steps)
            for _ in 0..<steps {
                vel.dx += (k * (goal.x - pos.x) - c * vel.dx) * h
                vel.dy += (k * (goal.y - pos.y) - c * vel.dy) * h
                pos.x += vel.dx * h
                pos.y += vel.dy * h
            }
            if !pos.x.isFinite || !pos.y.isFinite || !vel.dx.isFinite || !vel.dy.isFinite {
                pos = goal
                vel = .zero
            }
            scale += (1 - scale) * min(1, dt * 12)
        } else if flight == nil {
            scale += (1 - scale) * min(1, dt * 12)
        }

        // Lean into horizontal motion (like a hand dragging it), settle upright when still.
        targetAngle = max(-0.3, min(0.3, vel.dx / 3000))
        // Ease the heading, the short way round.
        var delta = targetAngle - angle
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        angle += delta * min(1, dt * (flight != nil ? 22 : 10))

        highlightAlpha += ((highlight == nil ? 0 : 1) - highlightAlpha) * min(1, dt * 12)
        ripples.removeAll { now - $0.1 > 0.55 }

        // A mark lasts ~4 s, or fades as soon as the user moves the mouse once it's drawn.
        if var m = mark {
            let age = now - m.began
            if m.fading == nil, age > 4 || (age > 1.2 && hypot(mouse.x - m.mouse.x, mouse.y - m.mouse.y) > 60) {
                m.fading = now
                if bubbleText != nil { bubbleText = nil }
            }
            if let f = m.fading, now - f > 0.4 { mark = nil } else { mark = m }
        }
        // Off-stage when the real pointer would be hidden: idle mouse, or typing (macOS hides it then).
        let mouseIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let keyIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let resting = mode == .following && flight == nil && mood == .idle && bubbleText == nil && mark == nil
        let leave = resting && (!followsMouse || mouseIdle > 3 || (mouseIdle > 0.6 && keyIdle < 1.0))
        // Exit slowly (floating up), come back quickly (dropping in).
        offstage += ((leave ? 1 : 0) - offstage) * min(1, dt * (leave ? 3.2 : 14))
        // Only when Clinqy moves it itself (not while it's just following the user's mouse).
        if flight != nil, mode != .returning { trail.append((pos, now)) }
        trail.removeAll { now - $0.1 > 0.1 }

        // Nothing moving, fading or pulsing: after a second of that, stop drawing until something changes.
        let goal = CGPoint(x: mouse.x + Self.offset.dx, y: mouse.y + Self.offset.dy)
        let still = flight == nil && mode != .returning && trail.isEmpty && ripples.isEmpty && mark == nil
            && bubbleText == nil && !typing && mood != .thinking && mood != .listening
            && hypot(vel.dx, vel.dy) < 1 && (mode != .following || hypot(goal.x - pos.x, goal.y - pos.y) < 0.5)
            && abs(offstage - (leave ? 1 : 0)) < 0.005 && abs(highlightAlpha - (highlight == nil ? 0 : 1)) < 0.005
            && abs(scale - 1) < 0.002 && abs(angle - targetAngle) < 0.002
            && now - shakeStart > 0.45 && now - pressStart > 0.26 && now - pop > 0.5
            && (flash.map { now - $0.1 > 0.7 } ?? true)
        if !still {
            wake()
        } else if let since = stillSince {
            if now - since > 1 {
                setRate(fast: false)
                return
            }
        } else {
            stillSince = now
        }
        let frame = Frame(
            now: now, pos: pos, trail: trail.map(\.0), angle: angle, scale: scale, speed: hypot(vel.dx, vel.dy), mood: mood,
            shake: now - shakeStart < 0.45 ? now - shakeStart : nil,
            press: now - pressStart < 0.26 ? now - pressStart : nil,
            pop: now - pop < 0.5 ? now - pop : nil,
            typing: typing,
            ripples: ripples.map { ($0.0, now - $0.1) },
            highlight: highlight, highlightAlpha: highlightAlpha,
            bubble: bubbleText.map { String($0.prefix(bubbleShown)) },
            bubbleAge: now - bubbleAppeared,
            level: level,
            mark: mark.map { ($0, now - $0.began) },
            tint: tint?.usingColorSpace(.deviceRGB).map { ($0.redComponent, $0.greenComponent, $0.blueComponent) },
            qa: qaMode,
            flash: flash.flatMap { now - $0.1 < 0.7 ? ($0.0, now - $0.1) : nil },
            offstage: offstage)
        for stage in stages { stage.render(frame, bubbleWidth: &bubbleWidth, dt: dt) }
    }

    func dismiss() {
        disposed = true
        timer?.invalidate(); timer = nil
        bubbleTimer?.invalidate(); bubbleTimer = nil
        mouseMonitors.forEach(NSEvent.removeMonitor); mouseMonitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        finishFlight()
        stages.forEach { $0.window.orderOut(nil) }
    }

    private func rebuildStages() {
        stages.forEach { $0.window.orderOut(nil) }
        stages = NSScreen.screens.map(Stage.init)
        stages.forEach { $0.window.alphaValue = suppressed ? 0 : 1 }
        wake()
    }

    static func mouse() -> CGPoint {
        let m = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: m.x, y: primaryHeight - m.y)
    }
}

// MARK: - Rendering

private struct Frame {
    let now: CFTimeInterval
    let pos: CGPoint
    /// Oldest to newest, the last ~0.1 s.
    let trail: [CGPoint]
    let angle: CGFloat
    let scale: CGFloat
    let speed: CGFloat
    let mood: Buddy.Mood
    let shake: CFTimeInterval?
    let press: CFTimeInterval?
    let pop: CFTimeInterval?
    let typing: Bool
    let ripples: [(CGPoint, CFTimeInterval)]
    let highlight: CGRect?
    let highlightAlpha: CGFloat
    let bubble: String?
    let bubbleAge: CFTimeInterval
    let level: CGFloat
    let mark: (Buddy.Mark, CFTimeInterval)?
    let tint: (CGFloat, CGFloat, CGFloat)?
    let qa: Bool
    let flash: (Bool, CFTimeInterval)?
    let offstage: CGFloat
}

enum Palette {
    static let accent = NSColor(red: 0.23, green: 0.51, blue: 1.0, alpha: 1)
    /// QA mode accent (amber).
    static let qa: (r: CGFloat, g: CGFloat, b: CGFloat) = (1.0, 0.62, 0.04)

    static func rgba(for mood: Buddy.Mood) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch mood {
        case .failure: return (1.0, 0.33, 0.30)
        case .success: return (0.2, 0.8, 0.45)
        default: return (0.23, 0.51, 1.0)
        }
    }

    static func color(for mood: Buddy.Mood) -> NSColor {
        let c = rgba(for: mood)
        return NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}

/// One transparent overlay window per screen; renders the shared frame translated into its own space.
@MainActor
private final class Stage {
    let window: NSWindow
    private let origin: CGPoint
    private let root = CALayer()
    private let body = CALayer()          // positioned at the tip, rotated to the heading
    private let streak = CAShapeLayer()   // short tapered trail while moving
    private let triangle = CAShapeLayer()
    private let reticle = CAShapeLayer()
    private let qaTag = CALayer()
    private let qaText = CATextLayer()
    private var qaAlpha: CGFloat = 0
    private let spinner = CAShapeLayer()
    private let bars = (0..<5).map { _ in CALayer() }
    private let rippleLayers = (0..<4).map { _ in CAShapeLayer() }
    private let focusRing = CAShapeLayer()
    private let circle = CAShapeLayer()
    private let arrow = CAShapeLayer()
    private let arrowHead = CAShapeLayer()
    private let bubble = CALayer()
    private let text = CATextLayer()
    private let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private var color = Palette.rgba(for: .idle)
    private var shapeAlpha: CGFloat = 1
    private var spinnerAlpha: CGFloat = 0
    private var barsAlpha: CGFloat = 0
    private var bubbleAlpha: CGFloat = 0
    private var measuredLabel = ""
    private var measuredWidth: CGFloat = 0

    init(screen: NSScreen) {
        let frame = screen.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        origin = CGPoint(x: frame.minX, y: primaryHeight - frame.maxY)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        // Keep the companion out of Clinqy's own screenshots (and other capture), so the model never
        // mistakes the ring/arrow/bubble for part of the app it's looking at.
        window.sharingType = .none
        window.setFrame(frame, display: false)

        // AppKit owns the view's own layer (and resets its flip), so everything lives on a child
        // canvas whose y grows downward, matching the top-left global coordinates we track.
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.addSublayer(root)
        root.frame = view.bounds
        root.isGeometryFlipped = true
        window.contentView = view
        root.insertSublayer(streak, at: 0)
        let scale = screen.backingScaleFactor
        root.contentsScale = scale

        focusRing.fillColor = nil
        focusRing.lineWidth = 2
        focusRing.shadowOpacity = 0.8
        focusRing.shadowRadius = 8
        focusRing.shadowOffset = .zero
        focusRing.opacity = 0
        root.addSublayer(focusRing)
        for layer in [circle, arrow, arrowHead] {
            layer.fillColor = nil
            layer.lineWidth = 3.2
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.shadowOffset = .zero
            layer.shadowOpacity = 0.9
            layer.shadowRadius = 7
            layer.strokeEnd = 0
            layer.opacity = 0
            root.addSublayer(layer)
        }

        for r in rippleLayers {
            r.fillColor = nil
            r.lineWidth = 2
            r.opacity = 0
            root.addSublayer(r)
        }

        body.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        body.anchorPoint = .zero
        root.addSublayer(body)

        // Arrow with its tip at the origin, shaped like the system cursor; rounded joins keep it soft.
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: 19))
        path.addLine(to: CGPoint(x: 5.2, y: 14.2))
        path.addLine(to: CGPoint(x: 13.6, y: 14.2))
        path.closeSubpath()
        triangle.path = path
        triangle.lineJoin = .round
        triangle.lineWidth = 2
        triangle.shadowOffset = .zero
        triangle.shadowOpacity = 0.85
        body.addSublayer(triangle)

        // QA reticle: a ring with four ticks and a centre dot, centred on the target.
        let ret = CGMutablePath()
        ret.addEllipse(in: CGRect(x: -9, y: -9, width: 18, height: 18))
        for (dx, dy) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)] as [(CGFloat, CGFloat)] {
            ret.move(to: CGPoint(x: dx * 5, y: dy * 5))
            ret.addLine(to: CGPoint(x: dx * 13, y: dy * 13))
        }
        ret.addEllipse(in: CGRect(x: -1.6, y: -1.6, width: 3.2, height: 3.2))
        reticle.path = ret
        reticle.fillColor = nil
        reticle.lineWidth = 2
        reticle.lineCap = .round
        reticle.shadowOffset = .zero
        reticle.shadowOpacity = 0.9
        reticle.shadowRadius = 6
        reticle.opacity = 0
        body.addSublayer(reticle)

        qaTag.bounds = CGRect(x: 0, y: 0, width: 24, height: 14)
        qaTag.cornerRadius = 4
        qaTag.opacity = 0
        qaText.string = "QA"
        qaText.fontSize = 9
        qaText.font = NSFont.systemFont(ofSize: 9, weight: .heavy)
        qaText.alignmentMode = .center
        qaText.foregroundColor = NSColor.black.cgColor
        qaText.frame = CGRect(x: 0, y: 1, width: 24, height: 12)
        qaText.contentsScale = scale
        qaTag.addSublayer(qaText)
        root.addSublayer(qaTag)

        // Thinking: a comet arc spinning where the triangle was.
        spinner.path = CGPath(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18), transform: nil)
        spinner.fillColor = nil
        spinner.lineWidth = 2.6
        spinner.lineCap = .round
        spinner.strokeEnd = 0.3
        spinner.shadowOffset = .zero
        spinner.shadowOpacity = 0.8
        spinner.shadowRadius = 5
        spinner.bounds = CGRect(x: -9, y: -9, width: 18, height: 18)
        spinner.opacity = 0
        root.addSublayer(spinner)

        // Listening: five bars that dance with your voice.
        for bar in bars {
            bar.cornerRadius = 1.5
            bar.opacity = 0
            bar.shadowOffset = .zero
            bar.shadowOpacity = 0.7
            bar.shadowRadius = 4
            root.addSublayer(bar)
        }

        bubble.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        bubble.borderWidth = 0.5
        bubble.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        bubble.opacity = 0
        root.addSublayer(bubble)
        text.contentsScale = scale
        text.font = font
        text.fontSize = font.pointSize
        text.foregroundColor = NSColor.white.cgColor
        text.truncationMode = .end
        bubble.addSublayer(text)

        window.orderFrontRegardless()
    }

    func render(_ f: Frame, bubbleWidth: inout CGFloat, dt: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var want = f.qa && f.mood != .success && f.mood != .failure ? Palette.qa : Palette.rgba(for: f.mood)
        if let tint = f.tint, f.mood != .success, f.mood != .failure { want = (r: tint.0, g: tint.1, b: tint.2) }
        if let (ok, age) = f.flash, age < 0.7 { want = Palette.rgba(for: ok ? .success : .failure) }
        let k = min(1, dt * 8)
        color = (color.r + (want.r - color.r) * k, color.g + (want.g - color.g) * k, color.b + (want.b - color.b) * k)
        let accent = CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - origin.x, y: p.y - origin.y) }
        func ease(_ v: inout CGFloat, _ target: CGFloat, _ rate: CGFloat) { v += (target - v) * min(1, dt * rate) }

        var p = local(f.pos)
        // Floating off-stage: rise and shrink as it fades.
        let o = f.offstage
        p.y -= 42 * o * o
        body.opacity = Float(1 - o)
        spinner.isHidden = o > 0.99
        if let s = f.shake { p.x += CGFloat(sin(s * 55) * 6 * (1 - s / 0.45)) }
        if f.typing { p.y += CGFloat(sin(f.now * 14)) * 1.5 }

        // Which face shows: triangle, spinner (thinking) or bars (listening).
        ease(&shapeAlpha, f.mood == .thinking || f.mood == .listening ? 0 : 1, 12)
        ease(&spinnerAlpha, f.mood == .thinking ? 1 : 0, 12)
        ease(&barsAlpha, f.mood == .listening ? 1 : 0, 12)

        var s = f.scale
        if let pr = f.press { s *= 1 - 0.25 * CGFloat(sin(pr / 0.26 * .pi)) }
        if let pp = f.pop { s *= 1 + 0.3 * CGFloat(sin(min(1, pp / 0.5) * .pi)) }
        body.position = p
        let shrink = 1 - 0.35 * o
        body.transform = CATransform3DScale(CATransform3DMakeRotation(f.angle, 0, 0, 1),
                                            s * (0.7 + 0.3 * shapeAlpha) * shrink, s * (0.7 + 0.3 * shapeAlpha) * shrink, 1)
        triangle.fillColor = accent
        triangle.strokeColor = accent
        triangle.shadowColor = accent
        triangle.shadowRadius = 6 + (f.scale - 1) * 26
        ease(&qaAlpha, f.qa ? 1 : 0, 10)
        triangle.opacity = Float(shapeAlpha * (1 - qaAlpha))
        reticle.opacity = Float(shapeAlpha * qaAlpha)
        reticle.strokeColor = accent
        reticle.fillColor = nil
        reticle.shadowColor = accent
        // The reticle doesn't lean like an arrow; it sits square on its target.
        reticle.transform = CATransform3DMakeRotation(-f.angle, 0, 0, 1)
        qaTag.position = CGPoint(x: p.x + 24, y: p.y - 14)
        qaTag.backgroundColor = accent
        qaTag.opacity = Float(qaAlpha * (1 - CGFloat(0)))

        // The spinner and bars sit where the triangle's body is, not its tip.
        let center = CGPoint(x: p.x + 9, y: p.y + 9)
        spinner.position = center
        spinner.strokeColor = accent
        spinner.shadowColor = accent
        spinner.transform = CATransform3DMakeRotation(CGFloat(f.now * 9).truncatingRemainder(dividingBy: 2 * .pi), 0, 0, 1)
        spinner.strokeEnd = 0.22 + 0.14 * CGFloat(sin(f.now * 4) + 1)
        spinner.opacity = Float(spinnerAlpha)
        for (i, bar) in bars.enumerated() {
            let wave = (sin(f.now * 11 + Double(i) * 1.3) + 1) / 2
            let h = 4 + (3 + f.level * 16) * CGFloat(wave) * (i == 2 ? 1 : i == 1 || i == 3 ? 0.8 : 0.55)
            bar.frame = CGRect(x: center.x - 12 + CGFloat(i) * 5, y: center.y - h / 2, width: 3, height: h)
            bar.backgroundColor = accent
            bar.shadowColor = accent
            bar.opacity = Float(barsAlpha)
        }

        for (i, layer) in rippleLayers.enumerated() {
            guard i < f.ripples.count else { layer.opacity = 0; continue }
            let (c0, age) = f.ripples[i]
            let t = CGFloat(age / 0.55)
            let r = 3 + (1 - pow(1 - t, 3)) * 22
            let c = local(c0)
            layer.path = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
            layer.strokeColor = accent
            layer.opacity = Float(0.9 * (1 - t))
        }

        if let h = f.highlight {
            let r = CGRect(origin: local(h.origin), size: h.size)
            let corner = min(9, r.height / 2)
            focusRing.path = CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil)
        }
        focusRing.strokeColor = accent.copy(alpha: 0.9)
        focusRing.shadowColor = accent
        focusRing.fillColor = accent.copy(alpha: 0.06)
        focusRing.opacity = Float(f.highlightAlpha)

        // Bubble: pops in with a little overshoot, text streams in.
        let label = f.bubble ?? ""
        ease(&bubbleAlpha, label.isEmpty ? 0 : 1, 14)
        if label != measuredLabel {
            measuredLabel = label
            measuredWidth = label.isEmpty ? 0 : ceil(NSAttributedString(string: label, attributes: [.font: font]).size().width) + 24
            text.string = label
        }
        let width = label.isEmpty ? bubbleWidth : measuredWidth
        ease(&bubbleWidth, width, 20)
        let height: CGFloat = 28
        let age = min(1, f.bubbleAge / 0.35)
        let popScale = label.isEmpty ? 1 : 0.6 + 0.4 * CGFloat(1 - pow(1 - age, 3)) + 0.06 * CGFloat(sin(age * .pi))
        bubble.bounds = CGRect(x: 0, y: 0, width: max(height, bubbleWidth), height: height)
        bubble.anchorPoint = .zero
        bubble.position = CGPoint(x: p.x + 16, y: p.y + 18)
        bubble.transform = CATransform3DMakeScale(popScale, popScale, 1)
        bubble.cornerRadius = height / 2
        bubble.opacity = Float(bubbleAlpha)
        bubble.borderColor = accent.copy(alpha: 0.45)
        text.frame = CGRect(x: 12, y: 6, width: max(0, bubbleWidth - 20), height: 18)
        renderStreak(f, accent: accent, local: local)
        renderMark(f, accent: accent, local: local)
        CATransaction.commit()
    }

    /// A thin ribbon along the last few positions: widest at the buddy, tapering to nothing. Only shows while moving.
    private func renderStreak(_ f: Frame, accent: CGColor, local: (CGPoint) -> CGPoint) {
        // From the arrow's body rather than its very tip, so it reads as trailing behind.
        let pts = f.trail.map { local(CGPoint(x: $0.x + 5, y: $0.y + 6)) }
        var length: CGFloat = 0
        for i in pts.indices.dropFirst() { length += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
        guard pts.count > 2, length > 6, f.offstage < 0.95 else { streak.opacity = 0; return }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in pts.indices {
            let a = pts[max(0, i - 1)], b = pts[min(pts.count - 1, i + 1)]
            let d = max(0.001, hypot(b.x - a.x, b.y - a.y))
            let w = 1.6 * CGFloat(i) / CGFloat(pts.count - 1)   // half-width: 0 at the tail, 1.6 at the head
            let n = CGPoint(x: -(b.y - a.y) / d * w, y: (b.x - a.x) / d * w)
            left.append(CGPoint(x: pts[i].x + n.x, y: pts[i].y + n.y))
            right.append(CGPoint(x: pts[i].x - n.x, y: pts[i].y - n.y))
        }
        let path = CGMutablePath()
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        streak.path = path
        streak.fillColor = accent
        streak.shadowColor = accent
        streak.shadowRadius = 3
        streak.shadowOpacity = 0.6
        streak.shadowOffset = .zero
        // Fainter on slow drifts, a touch stronger on quick moves.
        streak.opacity = Float((1 - f.offstage) * min(0.55, 0.15 + length / 300))
    }

    /// The marker: a slightly wobbly, overlapping loop drawn like a pen stroke, then a curved arrow.
    private func renderMark(_ f: Frame, accent: CGColor, local: (CGPoint) -> CGPoint) {
        guard let (m, age) = f.mark else {
            for l in [circle, arrow, arrowHead] { l.opacity = 0 }
            return
        }
        let r = CGRect(origin: local(m.rect.origin), size: m.rect.size)
        let c = CGPoint(x: r.midX, y: r.midY)
        let rx = max(26, r.width / 2 + 16), ry = max(20, r.height / 2 + 12)
        let loop = CGMutablePath()
        let steps = 90
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let a = m.seed + t * 1.12 * 2 * .pi
            let wobble = 1 + 0.035 * sin(3 * a + m.seed) + 0.05 * t
            let p = CGPoint(x: c.x + cos(a) * rx * wobble, y: c.y + sin(a) * ry * wobble)
            if i == 0 { loop.move(to: p) } else { loop.addLine(to: p) }
        }
        circle.path = loop

        // Arrow from the parked buddy to the circle's edge, bowed like a hand-drawn stroke.
        let tail = local(m.tail)
        let dir = CGVector(dx: tail.x - c.x, dy: tail.y - c.y)
        let len = max(0.001, hypot(dir.dx / rx, dir.dy / ry))
        let tip = CGPoint(x: c.x + dir.dx / len * 1.12, y: c.y + dir.dy / len * 1.12)
        let start = CGPoint(x: tail.x + (tip.x - tail.x) * 0.12, y: tail.y + (tip.y - tail.y) * 0.12)
        let mid = CGPoint(x: (start.x + tip.x) / 2, y: (start.y + tip.y) / 2)
        let n = CGVector(dx: -(tip.y - start.y), dy: tip.x - start.x)
        let nl = max(1, hypot(n.dx, n.dy))
        let control = CGPoint(x: mid.x + n.dx / nl * 28, y: mid.y + n.dy / nl * 28)
        let shaft = CGMutablePath()
        shaft.move(to: start)
        shaft.addQuadCurve(to: tip, control: control)
        arrow.path = shaft
        let heading = atan2(tip.y - control.y, tip.x - control.x)
        let head = CGMutablePath()
        for side in [-1.0, 1.0] as [CGFloat] {
            let a = heading + .pi - side * 0.5
            head.move(to: CGPoint(x: tip.x + cos(a) * 13, y: tip.y + sin(a) * 13))
            head.addLine(to: tip)
        }
        arrowHead.path = head

        let ease = { (x: Double) -> CGFloat in let t = min(1, max(0, x)); return CGFloat(1 - pow(1 - t, 3)) }
        circle.strokeEnd = ease(age / 0.6)
        arrow.strokeEnd = ease((age - 0.5) / 0.35)
        arrowHead.strokeEnd = ease((age - 0.82) / 0.15)
        let fade: Float = m.fading.map { Float(max(0, 1 - (f.now - $0) / 0.4)) } ?? 1
        for l in [circle, arrow, arrowHead] {
            l.strokeColor = accent
            l.shadowColor = accent
            l.opacity = fade
        }
    }
}

/// Runs `body` from a main-run-loop timer without `MainActor.assumeIsolated`'s runtime executor check,
/// which intermittently segfaults (swift_task_isMainExecutorImpl) when hit at frame rate on macOS 27.
/// Only for callbacks that are guaranteed to fire on the main thread.
private func onMainRunLoop(_ body: @MainActor () -> Void) {
    withoutActuallyEscaping(body) { body in
        unsafeBitCast(body, to: (() -> Void).self)()
    }
}
