import AppKit

/// Carries out actions the way a person would, with the buddy as the visible hand: it travels to the Dock
/// to open an app, to the address bar to go somewhere, types at a human rhythm, and hovers before it clicks.
/// Your real mouse is left where you put it.
@MainActor
final class Hand {
    private let buddy: Buddy
    /// Extra time to stay put at the end (e.g. while pointing something out).
    var lingerBeforeHome: TimeInterval = 0
    /// The run's request, so session-ending chords are pressed only when it asked for them.
    var request = ""
    /// Set when switching apps was the point of the task ("open Spotify"): the run's end then leaves it in front.
    var keepFrontApp = false
    /// Why Hand last refused to act (password field, sensitive app, blocked chord, stale target), for the step's message.
    private(set) var refusal: String?

    private var runCursor: CGPoint?
    private var runFrontApp: NSRunningApplication?
    /// Where Clinqy last left the real pointer without putting it back (scrolling moves it).
    private var cursorLeftAt: CGPoint?

    init(buddy: Buddy) { self.buddy = buddy }

    private func trace(_ s: String) {
        if ProcessInfo.processInfo.environment["CB_TRACE"] != nil { print("    · \(s)"); fflush(stdout) }
    }

    private func refuse(_ why: String) -> String {
        refusal = why
        trace("refused: \(why)")
        return why
    }

    // MARK: - Run

    /// Notes the pointer and frontmost app so `endRun` can put things back the way the user had them.
    func beginRun(request: String) {
        self.request = request
        keepFrontApp = false
        refusal = nil
        cursorLeftAt = nil
        runCursor = Buddy.mouse()
        let front = NSWorkspace.shared.frontmostApplication
        runFrontApp = front?.processIdentifier == getpid() ? nil : front
    }

    /// Releases any button left down, puts the pointer back if Clinqy moved it and the user hasn't since, and
    /// brings back the app the user was in (unless `keepFrontApp`). Safe to call on cancel and failure.
    func endRun() {
        // A background run never touched the user's pointer, buttons or front app: nothing to put back.
        if Background.active {
            runCursor = nil
            runFrontApp = nil
            cursorLeftAt = nil
            return
        }
        Self.releaseButtons()
        if let start = runCursor, let left = cursorLeftAt, Self.near(Buddy.mouse(), left, 2) {
            CGWarpMouseCursorPosition(start)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        if !keepFrontApp, let app = runFrontApp, !app.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            // Plain activate() is ignored while Clinqy isn't frontmost; bringToFront opens it, which always works.
            Task { await Launcher.bringToFront(app) }
        }
        runCursor = nil
        runFrontApp = nil
        cursorLeftAt = nil
    }

    // MARK: - Pointer

    /// How a click at a point is delivered.
    enum ClickMode: Sendable {
        /// Moves the real pointer, clicks, and puts it back. The default: web pages and many apps trust only real events.
        case real
        /// Posted straight to the app (postToPid): the pointer never moves, and the window needn't be frontmost.
        case pid
        /// Private SkyLight path for Chromium/Electron windows in the background. Every click of a background run
        /// goes this way; other runs only with BACKGROUND_CLICKS=1.
        case background
    }

    /// How the last element click went through: "axpress" or "real" (for the click log).
    private(set) var lastMethod = ""
    private(set) var lastClickUncertain = false

    /// Submit one input delivery. A successful AX request must not be followed by another click merely
    /// because its visible acknowledgement is slow; the caller owns effect verification.
    @discardableResult
    func click(_ el: UIElementInfo, in app: NSRunningApplication, fingerprint: Int, window requested: WindowSnapshot? = nil) async -> String? {
        lastClickUncertain = false
        guard let window = requested ?? WindowSnapshot.capture(app), window.pid == app.processIdentifier,
              el.windowID == nil || el.windowID == window.windowID else { return refuse("the element's window cannot be verified; look again") }
        if let requested, el.observationID != requested.id { return refuse("the element belongs to another observation; look again") }
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        guard window.frame.contains(el.center) else { return refuse("the element is outside the observed window; look again") }
        lastMethod = "axpress"
        await buddy.travel(to: el.center, framing: el.frame)
        guard !Task.isCancelled else { return "Stopped" }
        if Efficiency.humanMotion { try? await Task.sleep(for: .milliseconds(80)) }
        guard !Task.isCancelled else { return "Stopped" }
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        buddy.click()
        let element = el.element
        guard !Task.isCancelled else { return "Stopped" }
        switch await Task.detached(operation: { AXEngine.axPressDelivery(element) }).value {
        case .delivered: return nil
        case .uncertain:
            lastClickUncertain = true
            return nil // Observe the effect; never issue a second input after an ambiguous AX reply.
        case .unsupported: break
        }
        guard !Task.isCancelled else { return "Stopped" }
        // An explicitly unsupported AX action permits one checked pixel input.
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        if let why = hitCheck(el.center, pid: app.processIdentifier, window: window.element) { return refuse(why) }
        if Background.active {
            lastMethod = "background"
            return backgroundClick(at: el.center, pid: app.processIdentifier)
        }
        lastMethod = "real"
        realClick(at: el.center)
        return nil
    }

    /// Clicks a screen point, with the buddy travelling there first. Given the target `pid` (and the `window` as
    /// scanned), first checks the window is unchanged and the point still shows that app, so a moved window or a
    /// popup that slid in isn't clicked by mistake. Returns why it didn't click (re-scan and retry), or nil.
    @discardableResult
    func click(at point: CGPoint, pid: pid_t? = nil, window: WindowSnapshot? = nil, mode: ClickMode = .real) async -> String? {
        let mode = Background.active ? .background : mode
        if let window {
            guard pid == window.pid, window.frame.contains(point) else { return refuse("the point is outside the observed target window; look again") }
            if let why = window.staleness(includeContent: true) { return refuse(why) }
        }
        if let pid, let why = hitCheck(point, pid: pid, window: window?.element) { return refuse(why) }
        await buddy.travel(to: point)
        guard !Task.isCancelled else { return "Stopped" }
        if Efficiency.humanMotion { try? await Task.sleep(for: .milliseconds(80)) }
        guard !Task.isCancelled else { return "Stopped" }
        // Cursor animation is asynchronous: verify again immediately before input delivery.
        if let why = window?.staleness(includeContent: true) { return refuse(why) }
        if let pid, let why = hitCheck(point, pid: pid, window: window?.element) { return refuse(why) }
        buddy.click()
        switch mode {
        case .real:
            realClick(at: point)
        case .pid:
            guard let pid else { return refuse("a click sent to an app needs its pid") }
            Self.postClick(at: point, pid: pid)
        case .background:
            guard let pid else { return refuse("a background click needs the app's pid") }
            if !Background.active, !SkyLight.isEnabled { return refuse("background clicks are off (BACKGROUND_CLICKS=1 enables them)") }
            return backgroundClick(at: point, pid: pid)
        }
        return nil
    }

    /// A click on `pid`'s window at `point` that leaves the pointer and the front app alone: SkyLight where this macOS
    /// has it (Chromium and Electron windows take nothing else), else posted to the app.
    private func backgroundClick(at point: CGPoint, pid: pid_t) -> String? {
        guard SkyLight.isAvailable else {
            Self.postClick(at: point, pid: pid)
            return nil
        }
        // On Clinqy's hidden screen whatever window is at the spot is the run's, even one a helper process owns
        // (the file picker panel belongs to a macOS service, not the app).
        let target = Self.windowInfo(pid: pid, containing: point).map { (pid, $0.id, $0.frame) }
            ?? (AgentScreen.bounds?.contains(point) == true ? Self.topWindow(at: point) : nil)
        guard let (owner, id, frame) = target else {
            return refuse("no window of the target app at that point for a background click")
        }
        if let why = SkyLight.click(at: point, pid: owner, window: id, frame: frame) { return refuse(why) }
        return nil
    }

    /// The frontmost normal-level window at `point`, whoever owns it.
    nonisolated static func topWindow(at point: CGPoint) -> (pid: pid_t, id: CGWindowID, frame: CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list where info[kCGWindowLayer as String] as? Int == 0 {
            guard let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), pid != getpid(),
                  let id = info[kCGWindowNumber as String] as? Int, let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point) else { continue }
            return (pid, CGWindowID(id), frame)
        }
        return nil
    }

    /// Puts the caret in a text box: travel, click, focus. Returns why it didn't, or nil.
    @discardableResult
    func focus(_ el: UIElementInfo, in app: NSRunningApplication, window requested: WindowSnapshot? = nil) async -> String? {
        guard Self.isTextRole(el.role) else { return refuse("the requested element is not a text input; look again before typing") }
        guard let window = requested ?? WindowSnapshot.capture(app), window.pid == app.processIdentifier,
              el.windowID == nil || el.windowID == window.windowID,
              requested.map { el.observationID == $0.id } ?? true else { return refuse("the field belongs to another observation; look again") }
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        await buddy.travel(to: el.center, framing: el.frame)
        guard !Task.isCancelled else { return "Stopped" }
        if Efficiency.humanMotion { try? await Task.sleep(for: .milliseconds(90)) }
        guard !Task.isCancelled else { return "Stopped" }
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        buddy.click()
        var settable = DarwinBoolean(false)
        let canFocus = AXUIElementIsAttributeSettable(el.element, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
        if canFocus {
            _ = AXEngine.focus(el.element)
        } else {
            if let why = hitCheck(el.center, pid: app.processIdentifier, window: window.element) { return refuse(why) }
            if Background.active {
                if let why = backgroundClick(at: el.center, pid: app.processIdentifier) { return refuse(why) }
            } else { realClick(at: el.center) }
        }
        try? await Task.sleep(for: .milliseconds(120))
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        guard AXEngine.focusedWithin(el.element, in: app) else {
            return refuse("the requested field did not acquire verifiable focus; look again before typing")
        }
        return nil
    }

    static func isTextRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea"].contains(role)
    }

    /// A real click, with the user's pointer put back afterwards.
    /// Foreground gestures use the same window provenance and hit checks as clicks. Always release a
    /// possibly delivered down event, including cancellation and failure during a drag.
    func gesture(_ plan: PointerGesture, in app: NSRunningApplication, window: WindowSnapshot) async -> String? {
        guard !Background.active else { return refuse("Native pointer gestures require foreground mode") }
        let start = CGPoint(x: plan.start.x, y: plan.start.y), end = CGPoint(x: plan.end.x, y: plan.end.y)
        guard app.processIdentifier == window.pid, window.frame.contains(start), window.frame.contains(end) else {
            return refuse("gesture endpoints must belong to the observed window")
        }
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        for point in [start, end] {
            if let why = hitCheck(point, pid: app.processIdentifier, window: window.element) { return refuse(why) }
        }
        await buddy.travel(to: start)
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        for point in [start, end] {
            if let why = hitCheck(point, pid: app.processIdentifier, window: window.element) { return refuse(why) }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        var held = false, last = start
        defer {
            if held {
                CGEvent(mouseEventSource: source, mouseType: plan.kind == .right_click ? .rightMouseUp : .leftMouseUp,
                        mouseCursorPosition: last, mouseButton: plan.kind == .right_click ? .right : .left)?.post(tap: .cghidEventTap)
            }
            cursorLeftAt = last
        }
        for step in plan.events {
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                return refuse("gesture interrupted; inspect the result before repeating input")
            }
            let point = CGPoint(x: step.point.x, y: step.point.y)
            let type: CGEventType = step.phase == .move ? (held ? .leftMouseDragged : .mouseMoved)
                : step.phase == .down ? (step.right ? .rightMouseDown : .leftMouseDown) : (step.right ? .rightMouseUp : .leftMouseUp)
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                      mouseButton: step.right ? .right : .left) else { return refuse("couldn't construct pointer event") }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(step.count))
            // Treat delivery as possible before posting; cancellation must still release the button.
            if step.phase == .down { held = true }
            last = point
            event.post(tap: .cghidEventTap)
            if step.phase == .up { held = false }
            try? await Task.sleep(for: .milliseconds(plan.kind == .drag ? 20 : 35))
        }
        return nil
    }

    private func realClick(at point: CGPoint) {
        let saved = Buddy.mouse()
        Self.postRealClick(at: point)
        usleep(25_000)
        CGWarpMouseCursorPosition(saved)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Down and up through the HID stream; the up is posted however the down went, so the button is never left held.
    nonisolated private static func postRealClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        defer {
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        usleep(15_000)
    }

    /// A click posted to the app itself: the real pointer stays put. The window number fields let AppKit route it
    /// to the right window even when it isn't frontmost.
    nonisolated private static func postClick(at point: CGPoint, pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let window = windowInfo(pid: pid, containing: point)?.id
        func post(_ type: CGEventType) {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            if let window {
                e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
                e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
            }
            e.postToPid(pid)
        }
        post(.leftMouseDown)
        defer { post(.leftMouseUp) }
        usleep(15_000)
    }

    /// Lets go of any mouse button still down (a click interrupted by a crash, cancel or error).
    nonisolated static func releaseButtons() {
        let point = CGEvent(source: nil)?.location ?? .zero
        for (button, type) in [(CGMouseButton.left, CGEventType.leftMouseUp), (.right, .rightMouseUp)]
        where CGEventSource.buttonState(.combinedSessionState, button: button) {
            CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                    mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Pre-click checks

    /// What's under `point` must belong to `pid` (and to the element's window, when known), or the click would
    /// land on something else: another app's popup, a window that moved.
    private func hitCheck(_ point: CGPoint, pid: pid_t, windowOf element: AXUIElement) async -> String? {
        let window: AXUIElement? = Self.axAttr(element, kAXWindowAttribute)
        return hitCheck(point, pid: pid, window: window)
    }

    private func hitCheck(_ point: CGPoint, pid: pid_t, window: AXUIElement?) -> String? {
        Background.active ? Self.hitMismatchInApp(at: point, pid: pid, window: window) : Self.hitMismatch(at: point, pid: pid, window: window)
    }

    /// hitMismatch for a background run, whose window is expected to sit under the user's: only the app's own
    /// windows are hit-tested, so another of its windows (a popup that slid in, a moved window) still stops the click.
    static func hitMismatchInApp(at point: CGPoint, pid: pid_t, window: AXUIElement?) -> String? {
        var hit: AXUIElement?
        guard let window, AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &hit) == .success,
              let hit, let hitWindow: AXUIElement = axAttr(hit, kAXWindowAttribute), !CFEqual(hitWindow, window) else { return nil }
        return "a different \(NSRunningApplication(processIdentifier: pid)?.cleanName ?? "app") window is at that spot now; look again"
    }

    /// Why the element at `point` isn't the target app's (or target window's), or nil. Inconclusive answers
    /// (no element, Clinqy's own overlay) pass: this guards against clicking the wrong thing, not against clicking.
    /// Main thread only: a hit test that lands on one of Clinqy's own windows is answered in this process on the calling
    /// thread, and off the main thread AppKit throws inside SwiftUI's update and leaves its lock held, freezing the app.
    static func hitMismatch(at point: CGPoint, pid: pid_t, window: AXUIElement?) -> String? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(hit, &owner) == .success, owner != getpid() else { return nil }
        // Web content can answer from the browser's own helper process (Safari's WebContent, Chromium helpers).
        let helper = NSRunningApplication(processIdentifier: owner).map { app in
            let id = app.bundleIdentifier?.lowercased() ?? ""
            return id.hasPrefix("com.apple.webkit") || id.contains(".helper") || id.contains("framework")
        } ?? true
        if owner != pid, !helper {
            let other = NSRunningApplication(processIdentifier: owner)?.cleanName ?? "another app"
            let target = NSRunningApplication(processIdentifier: pid)?.cleanName ?? "the target app"
            return "\(other) is on top at that spot, not \(target); look again before clicking"
        }
        if let window, let hitWindow: AXUIElement = axAttr(hit, kAXWindowAttribute), !CFEqual(hitWindow, window) {
            return "a different \(NSRunningApplication(processIdentifier: pid)?.cleanName ?? "app") window is at that spot now; look again"
        }
        return nil
    }

    /// Kept as an alias for input callers; observation, capture and execution share one immutable identity.
    typealias WindowSnapshot = NativeWindowObservation

    /// Numbers of `pid`'s normal-level windows, wherever they are.
    nonisolated static func windowIDs(pid: pid_t) -> Set<CGWindowID> {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid, info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? Int else { return nil }
            return CGWindowID(id)
        })
    }

    /// The on-screen normal-level window of `pid` containing `point`: its number and bounds.
    nonisolated static func windowInfo(pid: pid_t, containing point: CGPoint) -> (id: CGWindowID, frame: CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list where (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid
            && info[kCGWindowLayer as String] as? Int == 0 {
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point) else { continue }
            return (CGWindowID(id), frame)
        }
        return nil
    }

    nonisolated private static func axAttr<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    nonisolated private static func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    /// Presses a combo. Refuses (false, with `refusal` set) a lock/log-out/force-quit chord the request didn't ask for.
    @discardableResult
    func press(_ keys: String) -> Bool {
        refusal = nil
        if let why = Safety.blockedChord(keys, request: request) { _ = refuse(why); return false }
        if let why = AXEngine.chordProblem(keys) { _ = refuse(why); return false }
        buddy.click()
        return AXEngine.press(combo: keys)
    }

    func scroll(up: Bool, in app: NSRunningApplication) async {
        await scroll(ScrollPlan(direction: up ? .up : .down, unit: .lines, amount: 12, isDefault: true), in: app, window: nil)
    }

    /// Scrolls as asked: direction, unit and amount are all honoured. With `anchor` the wheel is aimed at that point
    /// (which must lie inside the observed `window`); otherwise at the window's middle.
    /// Returns why it did not scroll, or nil.
    @discardableResult
    func scroll(_ plan: ScrollPlan, in app: NSRunningApplication, window: WindowSnapshot?, anchor: CGPoint? = nil) async -> String? {
        refusal = nil
        if let window {
            guard window.pid == app.processIdentifier else { return refuse("the scroll target belongs to another application; look again") }
            if let why = window.staleness() { return refuse(why) }
            if let anchor, !window.frame.contains(anchor) { return refuse("the scroll anchor is outside the observed window; look again") }
        }
        let frame = window?.frame ?? AXEngine.windowFrame(of: app)
        if let anchor, window == nil, let frame, !frame.contains(anchor) { return refuse("the scroll anchor is outside the window") }
        let target = anchor ?? frame.map { CGPoint(x: $0.midX, y: $0.midY) }
        if let target { await buddy.travel(to: target) }
        let (pixels, steps) = plan.chunks(viewport: frame?.size ?? CGSize(width: 800, height: 600))
        for step in steps {
            if Task.isCancelled { return refuse("scroll interrupted; inspect the result before repeating input") }
            AXEngine.scroll(dy: step.dy, dx: step.dx, pixels: pixels, at: target, in: app)
            try? await Task.sleep(for: .milliseconds(70))
        }
        // Scrolling moves the real pointer to the aimed point; the run's end puts it back if the user doesn't.
        if !Background.active { cursorLeftAt = Buddy.mouse() }
        try? await Task.sleep(for: .milliseconds(200))
        return nil
    }

    // MARK: - Click options

    /// A pixel click with the requested button, count, modifiers and hold, after the same window and hit checks as
    /// every other click. AXPress cannot express any of these, so it is never used here.
    @discardableResult
    func click(at point: CGPoint, options: ClickOptions, pid: pid_t, window: WindowSnapshot) async -> String? {
        guard !Background.active else { return refuse("button, count, modifier and hold options need foreground mode") }
        guard pid == window.pid, window.frame.contains(point) else { return refuse("the point is outside the observed target window; look again") }
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        if let why = hitCheck(point, pid: pid, window: window.element) { return refuse(why) }
        await buddy.travel(to: point)
        try? await Task.sleep(for: .milliseconds(80))
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        if let why = hitCheck(point, pid: pid, window: window.element) { return refuse(why) }
        buddy.click()
        let saved = Buddy.mouse()
        let source = CGEventSource(stateID: .hidSystemState)
        var flags: CGEventFlags = []
        if options.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if options.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if options.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if options.modifiers.contains(.control) { flags.insert(.maskControl) }
        let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) = {
            switch options.button {
            case .left: return (.leftMouseDown, .leftMouseUp, .left)
            case .right: return (.rightMouseDown, .rightMouseUp, .right)
            case .middle: return (.otherMouseDown, .otherMouseUp, .center)
            }
        }()
        func post(_ type: CGEventType, state: Int) {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
            e.flags = flags
            e.setIntegerValueField(.mouseEventClickState, value: Int64(state))
            e.post(tap: .cghidEventTap)
        }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        var held = false
        defer {
            if held { post(upType, state: 1) }
            // Make sure no modifier stays latched, then give the pointer back.
            CGWarpMouseCursorPosition(saved)
            CGAssociateMouseAndMouseCursorPosition(1)
            cursorLeftAt = nil
        }
        for step in options.steps {
            if step.down {
                held = true
                post(downType, state: step.clickState)
                if options.holdMilliseconds > 0 {
                    try? await Task.sleep(for: .milliseconds(options.holdMilliseconds))
                    if Task.isCancelled { return refuse("click interrupted; inspect the result before repeating input") }
                } else { usleep(15_000) }
            } else {
                post(upType, state: step.clickState)
                held = false
                usleep(30_000)
            }
        }
        lastMethod = "options"
        return nil
    }

    // MARK: - Screenshot insertion

    struct SnapPasteReport {
        /// Indices (into the items given) whose caption and picture were both delivered without interruption.
        var inserted: [Int] = []
        /// An item whose caption went in but whose picture did not (so the document holds a lone caption).
        var partial: Int?
        var stopped: String?
    }

    /// Pastes each caption and then its picture at the caret, counting only items delivered start to finish. Delivery is
    /// keystrokes plus the clipboard: apps like Google Docs do not let Clinqy read the result back, so "inserted"
    /// means delivered while the target stayed frontmost and the clipboard stayed ours, not independently seen.
    func pasteSnaps(_ items: [(caption: String, png: Data)], in app: NSRunningApplication) async -> SnapPasteReport {
        var report = SnapPasteReport()
        let board = NSPasteboard.general
        let saved = PasteboardSnapshot(board)
        var owned = board.changeCount
        AXEngine.targetPid = app.processIdentifier
        defer {
            AXEngine.targetPid = nil
            saved.restore(to: board, ifUnchangedSince: owned)
        }
        func ready() -> String? {
            if Task.isCancelled { return "the run was cancelled" }
            if !Background.active, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                return "\(app.cleanName ?? "the target app") is no longer in front"
            }
            if board.changeCount != owned { return "the clipboard changed while pasting (the user may have copied something)" }
            return nil
        }
        func load(_ write: (NSPasteboard) -> Void) {
            board.clearContents()
            write(board)
            owned = board.changeCount
        }
        for (i, item) in items.enumerated() {
            if let why = ready() { report.stopped = why; return report }
            load { $0.setString(item.caption, forType: .string) }
            AXEngine.pressPaste()
            try? await Task.sleep(for: .milliseconds(250))
            AXEngine.pressReturn()
            if let why = ready() { report.partial = i; report.stopped = why; return report }
            load { $0.setData(item.png, forType: .png) }
            AXEngine.pressPaste()
            try? await Task.sleep(for: .milliseconds(1800))   // Google Docs uploads the image
            AXEngine.pressReturn()
            AXEngine.pressReturn()
            try? await Task.sleep(for: .milliseconds(150))
            report.inserted.append(i)
        }
        return report
    }

    // MARK: - Control state

    /// Sets a checkbox, radio button or range control to the requested state, confirming it by reading it back.
    func setState(_ el: UIElementInfo, to desired: DesiredState, in app: NSRunningApplication, window requested: WindowSnapshot? = nil) async -> AXEngine.StateOutcome {
        guard let window = requested ?? WindowSnapshot.capture(app), window.pid == app.processIdentifier,
              el.windowID == nil || el.windowID == window.windowID,
              requested.map({ el.observationID == $0.id }) ?? true else { return .refused("the control belongs to another observation; look again") }
        if let why = window.staleness(includeContent: true) { return .refused(why) }
        await buddy.travel(to: el.center, framing: el.frame)
        if let why = window.staleness(includeContent: true) { return .refused(why) }
        buddy.click()
        let element = el.element
        return await Task.detached { AXEngine.setState(element, to: desired) }.value
    }

    // MARK: - Text placement

    /// Inserts or appends text at the real caret instead of replacing the field. Where the field gives Accessibility
    /// no caret or settable text, says so rather than falling back to select-all-and-replace.
    func place(_ text: String, mode: TextEditMode, in app: NSRunningApplication) -> AXEngine.EditOutcome {
        refusal = nil
        guard mode != .replaceAll else { return .unsupported("replace is what type already does") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let field = focused, CFGetTypeID(field) == AXUIElementGetTypeID() else { return .refused("no focused field") }
        if let why = Safety.secureInputBlock() { _ = refuse(why); return .refused(why) }
        let outcome = AXEngine.edit(text, mode: mode, field: field as! AXUIElement)
        if case .refused(let why) = outcome { _ = refuse(why) }
        return outcome
    }

    // MARK: - Keyboard

    /// Replaces the focused field's text, typed at a human rhythm, and confirms it landed.
    /// Falls back to pasting once; never leaves half a message behind for a Return to send.
    func type(_ text: String, in app: NSRunningApplication) async -> Bool {
        refusal = nil
        buddy.setTyping(true)
        defer { buddy.setTyping(false) }
        // Browser editors whose text Accessibility can't see (Google Docs shows only zero-width spaces): typing
        // can't be checked, and the check-then-clear fallback would wipe the document. Paste it once, fast.
        let invisible = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}"))
        if Launcher.isBrowser(app), (AXEngine.focusedValue(of: app) ?? "").trimmingCharacters(in: invisible).isEmpty {
            AXEngine.targetPid = app.processIdentifier
            defer { AXEngine.targetPid = nil }
            AXEngine.paste(text)
            return true
        }
        // In a background run, long or multi-line text goes straight into the field: pasting would borrow the
        // user's clipboard. Fields that don't take a set value (or don't show it) fall through to the usual ways.
        if Background.active, text.count > 80 || text.contains("\n"), !Self.codeEditorIDs.contains(app.bundleIdentifier ?? ""),
           AXEngine.setFocusedValue(text, in: app), await landed(text, in: app) {
            return true
        }
        // Long text (an answer list, a write-up) is pasted: typing 2,000 characters takes minutes and trips the
        // watchdog halfway, leaving half a message behind. Pasted line breaks don't send in chat apps.
        if text.count > 300, !Self.codeEditorIDs.contains(app.bundleIdentifier ?? "") {
            AXEngine.targetPid = app.processIdentifier
            defer { AXEngine.targetPid = nil }
            if !(AXEngine.focusedValue(of: app) ?? "").isEmpty {
                AXEngine.selectAll()
                try? await Task.sleep(for: .milliseconds(60))
            }
            AXEngine.paste(text)
            return await landed(text, in: app)
        }
        // Multi-line text is still typed (that's the point of watching it), with Shift+Return for line breaks.
        if text.contains("\n") {
            AXEngine.targetPid = app.processIdentifier
            defer { AXEngine.targetPid = nil }
            AXEngine.selectAll()
            try? await Task.sleep(for: .milliseconds(80))
            let code = Self.codeEditorIDs.contains(app.bundleIdentifier ?? "")
            await enterText(text, codeEditor: code)
            return await landed(text, in: app)
        }
        // Replace existing text only when there is some: ⌘A where there's nothing to select just beeps.
        if let existing = AXEngine.focusedValue(of: app), !existing.isEmpty {
            AXEngine.selectAll()
            try? await Task.sleep(for: .milliseconds(60))
        }

        // Keys go only to the target app, never to whatever else might grab focus meanwhile.
        AXEngine.targetPid = app.processIdentifier
        defer { AXEngine.targetPid = nil }
        await keystrokes(text)
        if Task.isCancelled || refusal != nil { return false }
        if await landed(text, in: app) { return true }

        // Some apps only accept keys through the system stream: retry by pasting that way,
        // replacing (never appending to) what's there.
        AXEngine.targetPid = nil
        AXEngine.selectAll()
        try? await Task.sleep(for: .milliseconds(60))
        AXEngine.paste(text)
        if await landed(text, in: app) { return true }
        AXEngine.selectAll()
        AXEngine.press(0x33)
        return false
    }

    /// Apps whose editors auto-indent what's typed.
    static let codeEditorIDs: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.sublimetext.4", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.google.android.studio",
    ]

    /// Enters text into the focused field, always typed so it can be watched.
    /// Line breaks are Shift+Return (a new line without sending in chat apps). In code editors, which re-indent
    /// typed code, each line is typed without its leading spaces and the exact code is swapped in at the end.
    func enterText(_ text: String, codeEditor: Bool = false) async {
        // A long program typed key by key takes half a minute (and trips the watchdog), only to be replaced by the
        // exact paste at the end anyway: paste it straight in.
        if codeEditor, text.count > 300 {
            AXEngine.selectAll()
            try? await Task.sleep(for: .milliseconds(60))
            AXEngine.paste(text)
            try? await Task.sleep(for: .milliseconds(250))
            return
        }
        guard text.contains("\n") else { return await keystrokes(text) }
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if Task.isCancelled { return }
            if i > 0 {
                AXEngine.press(combo: "shift+return")
                try? await Task.sleep(for: .milliseconds(60))
            }
            await keystrokes(codeEditor ? line.trimmingCharacters(in: .whitespaces) : line)
        }
        if codeEditor {
            // The editor's auto-indent and auto-closing brackets have had their say; now make it exactly right.
            try? await Task.sleep(for: .milliseconds(200))
            AXEngine.selectAll()
            try? await Task.sleep(for: .milliseconds(60))
            AXEngine.paste(text)
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Types at a human rhythm (keys go wherever AXEngine.targetPid points). Stops, with `refusal` set, the moment
    /// a password field takes secure input: focus can move mid-word.
    func keystrokes(_ text: String) async {
        let base = text.count > 80 ? 10.0 : text.count > 30 ? 20.0 : 32.0
        refusal = nil
        for ch in text {
            if Task.isCancelled { return }
            AXEngine.type(String(ch))
            var ms = base + Double.random(in: 0...(base * 0.9))
            if ch == " " { ms += base * 0.5 }
            if ".,!?".contains(ch) { ms += 70 }
            try? await Task.sleep(for: .milliseconds(Int(ms)))
        }
    }

    private func landed(_ text: String, in app: NSRunningApplication) async -> Bool {
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(70))
            if AXEngine.fieldHolds(text, in: app) { return true }
        }
        return false
    }

    // MARK: - Apps

    /// Opens an app like a person: click its Dock icon, or use Spotlight if it isn't in the Dock.
    func openApp(named name: String) async -> NSRunningApplication? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let running = Launcher.running(named: wanted)
        let url = running?.bundleURL ?? Launcher.find(named: wanted)
        guard let url else { return nil }
        let appName = url.deletingPathExtension().lastPathComponent

        if let running, NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier,
           AXEngine.windowFrame(of: running) != nil {
            return running
        }
        // In a background run the app opens behind the user's (no Dock click, no Spotlight).
        if Background.active { return await Launcher.launch(url) }
        if !Efficiency.humanMotion { return await Launcher.launch(url) }

        trace("openApp \(appName) dock=\(AXEngine.dockItem(named: appName) != nil)")
        if let dock = AXEngine.dockItem(named: appName) {
            await buddy.travel(to: CGPoint(x: dock.frame.midX, y: dock.frame.midY), framing: dock.frame)
            try? await Task.sleep(for: .milliseconds(140))
            buddy.click()
            let item = dock.element
            _ = await Task.detached { AXEngine.axPress(item) }.value
        } else {
            await spotlight(appName)
        }
        if let app = await waitForFront(bundleURL: url, seconds: 5) { return app }
        return await Launcher.launch(url)
    }

    private func spotlight(_ query: String) async {
        // Typing blind into a password prompt is worse than launching the app directly (the caller falls back).
        guard Safety.secureInputBlock() == nil else { return }
        let screen = NSScreen.main?.frame ?? .zero
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let spot = CGPoint(x: screen.midX - 180, y: primaryHeight - screen.maxY + screen.height * 0.3)
        await buddy.travel(to: spot)
        press("cmd+space")
        try? await Task.sleep(for: .milliseconds(450))
        buddy.setTyping(true)
        for ch in query {
            AXEngine.type(String(ch))
            try? await Task.sleep(for: .milliseconds(Int.random(in: 45...95)))
        }
        buddy.setTyping(false)
        try? await Task.sleep(for: .milliseconds(550))
        press("return")
    }

    private func waitForFront(bundleURL: URL, seconds: Double) async -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleURL == bundleURL {
                // Give it a moment to put a window up.
                for _ in 0..<20 where AXEngine.windowFrame(of: front) == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if AXEngine.windowFrame(of: front) == nil { return nil }
                return front
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }

    // MARK: - Web

    /// Goes to a website like a person: bring up the browser, open a tab, type the address, press Return.
    func openURL(_ url: URL, current: NSRunningApplication?, newTab: Bool = true) async -> NSRunningApplication? {
        // A background run without the extension: hand the address to the browser, which opens it without coming
        // forward. Typing it would send ⌘T and the address to whichever of its windows the user has.
        if Background.active {
            await Launcher.openURL(url)
            let id = NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
            return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id && id != nil }
        }
        var browser: NSRunningApplication?
        if let current, Launcher.isBrowser(current) {
            await Launcher.bringToFront(current)
            browser = current
        } else if let name = Launcher.defaultBrowserName {
            browser = await openApp(named: name)
        }
        guard let browser else {
            await Launcher.openURL(url)
            return NSWorkspace.shared.frontmostApplication
        }

        if !Efficiency.humanMotion {
            let bridge = BrowserBridge.shared
            if bridge.isConnected(browser), let tab = await bridge.activeTab(in: browser),
               await bridge.tabCommand(newTab ? "newTab" : "navigate", on: tab, ["url": url.absoluteString]) != nil {
                return browser
            }
            if newTab, let bundle = browser.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                if let opened = try? await NSWorkspace.shared.open([url], withApplicationAt: bundle, configuration: configuration) { return opened }
            }
        }

        trace("browser \(browser.cleanName ?? "?") front=\(NSWorkspace.shared.frontmostApplication?.cleanName ?? "-")")
        // A new tab for a fresh destination; otherwise edit the current tab's address like a person would.
        press(newTab ? "cmd+t" : "cmd+l")
        try? await Task.sleep(for: .milliseconds(420))
        trace("after cmd+t focused=\(AXEngine.focusedFrame(of: browser).map { "\($0)" } ?? "nil")")
        // Go to where the address goes: the focused field if it's plausibly the address bar (top of the
        // window), otherwise Arc's command bar in the upper middle, or the usual toolbar spot.
        let window = AXEngine.windowFrame(of: browser)
        if let field = AXEngine.focusedFrame(of: browser), field.width > 40,
           let window, field.midY < window.minY + window.height * 0.4 {
            await buddy.travel(to: CGPoint(x: field.minX + min(80, field.width / 2), y: field.midY), framing: field)
        } else if let window {
            let arc = browser.bundleIdentifier == "company.thebrowser.Browser"
            await buddy.travel(to: CGPoint(x: window.midX - (arc ? 200 : 0), y: window.minY + (arc ? window.height * 0.3 : 44)))
        }

        trace("traveled; front=\(NSWorkspace.shared.frontmostApplication?.cleanName ?? "-")")
        var address = url.absoluteString
        for prefix in ["https://www.", "https://", "http://"] where address.hasPrefix(prefix) {
            address = String(address.dropFirst(prefix.count))
            break
        }
        if address.hasSuffix("/") { address.removeLast() }
        if Safety.secureInputBlock() != nil {
            press("esc")
            await Launcher.openURL(url)
            return browser
        }
        buddy.setTyping(true)
        // Deliver keys straight to the browser so they can't land in some other window.
        AXEngine.targetPid = browser.processIdentifier
        if Efficiency.humanMotion {
            for ch in address {
                guard !Task.isCancelled else { break }
                AXEngine.type(String(ch))
                try? await Task.sleep(for: .milliseconds(Int.random(in: 22...60)))
            }
        } else { AXEngine.type(address) }
        AXEngine.targetPid = nil
        buddy.setTyping(false)
        try? await Task.sleep(for: .milliseconds(150))
        let value = AXEngine.focusedValue(of: browser) ?? ""
        trace("typed; focused value=\(value.debugDescription)")

        // If the keys went astray, fill the field directly; failing that, open the tab through the browser.
        // Arc's command bar reports an empty value even when the text is there, so only a readable
        // mismatch counts as a miss.
        if !value.isEmpty, !value.lowercased().contains(address.prefix(6).lowercased()) {
            if AXEngine.setFocusedValue(address, in: browser),
               (AXEngine.focusedValue(of: browser) ?? "").lowercased().contains(address.prefix(6).lowercased()) {
                trace("filled field via accessibility")
            } else {
                trace("falling back to opening the URL directly")
                AXEngine.press(combo: "esc")
                try? await Task.sleep(for: .milliseconds(150))
                await Launcher.openURL(url)
                try? await Task.sleep(for: .milliseconds(900))
                return browser
            }
        }
        try? await Task.sleep(for: .milliseconds(200))
        press("return")
        // Wait for the page to start loading rather than a fixed pause.
        let startURL = Launcher.frontURLHint
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(100))
            if Launcher.frontURLHint != startURL { break }
        }
        try? await Task.sleep(for: .milliseconds(250))
        trace("returned")
        return browser
    }
}
