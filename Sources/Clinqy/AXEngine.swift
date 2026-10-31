import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin

/// A clickable/typeable element found in the frontmost app's accessibility tree.
struct UIElementInfo: @unchecked Sendable {
    let id: String
    let role: String
    let label: String
    /// Frame in global top-left-origin coordinates (the same space CGEvent uses).
    let frame: CGRect
    let element: AXUIElement
    /// Content-derived ref (role, subrole, identifier, title, description, window; "~N" for repeats). Unlike the
    /// positional id it survives a sibling appearing, so a re-scan can still find the same control.
    var ref: String = ""
    /// Current value of inputs and toggles, so a diff can show what typing or clicking changed.
    var value: String? = nil
    /// Lives in the focused window's sheet or dialog (listed first: it's what the user has to answer).
    var inDialog: Bool = false
    /// Window and observation that supplied this reference. Positional e-ids are valid only within this observation.
    var observationID: UUID? = nil
    var windowID: CGWindowID? = nil

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

enum AXEngine {
    static let userName = NSFullUserName()

    static var isTrusted: Bool {
        // Global cap on how long any Accessibility call may block (default is 6 s per call).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        return AXIsProcessTrusted()
    }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTab", "AXComboBox",
        "AXMenuBarItem", "AXDisclosureTriangle", "AXCell", "AXRow", "AXImage", "AXSegmentedControl",
        "AXStaticText", "AXMenuItem", "AXHeading", "AXGroup",
    ]

    nonisolated(unsafe) private static var enabledElectron = Set<pid_t>()

    /// Electron apps (Cursor, VS Code, Slack, Discord…) only publish their UI to Accessibility when asked.
    static func enableManualAccessibility(_ app: NSRunningApplication) {
        guard !enabledElectron.contains(app.processIdentifier) else { return }
        enabledElectron.insert(app.processIdentifier)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: - Scan

    /// Everything the scan needs from one element, fetched in a single round trip.
    private static let scanAttrs = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute, kAXValueAttribute, kAXIdentifierAttribute,
    ]
    /// Children read per node; a 5000-file list would otherwise cost more than the whole rest of the window.
    private static let childCap = 200

    /// Collects visible actionable elements from `app`, breadth-first, up to `limit`. A sheet or modal dialog on
    /// the focused window is walked first; the menu bar only when asked (`pressMenu` reaches it by path).
    static func elements(of app: NSRunningApplication, window snapshot: NativeWindowObservation? = nil, limit: Int = 200, menuBar: Bool = false, excludingWebContent: Bool = false) -> [UIElementInfo] {
        if let snapshot, snapshot.pid != app.processIdentifier || snapshot.staleness() != nil { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)

        var roots: [(AXUIElement, Bool)] = []
        let window = snapshot?.element ?? mainWindow(root)
        let dialog = window.flatMap { dialogElement(in: $0) }
        if let dialog, let window, !CFEqual(dialog.element, window) { roots.append((dialog.element, true)) }
        if let window { roots.append((window, dialog.map { CFEqual($0.element, window) } ?? false)) }
        if menuBar, let bar: AXUIElement = attr(root, kAXMenuBarAttribute) { roots.append((bar, false)) }
        let windowTitle = window.flatMap { attr($0, kAXTitleAttribute) as String? } ?? ""

        let screenBounds = NSScreen.screens.reduce(CGRect.null) { $0.union(flipped($1.frame)) }
        // Roots are walked one after another (not interleaved), so the sheet's controls come first.
        var pending = ArraySlice(roots.map { (element: $0.0, depth: 0, inDialog: $0.1) })
        var queue: [(element: AXUIElement, depth: Int, inDialog: Bool)] = []
        var head = 0
        var found: [UIElementInfo] = []
        var seen = Set<String>(), refCounts: [String: Int] = [:]
        // Gather a little past the limit, then drop the least useful (unlabeled groups, loose text) rather than
        // whatever happened to come last in the walk.
        let gather = limit + limit / 2

        while found.count < gather, head < 4000 {
            if head == queue.count {
                guard let next = pending.popFirst() else { break }
                queue.append(next)
            }
            let (element, depth, inDialog) = queue[head]
            head += 1
            if let dialog, !inDialog, CFEqual(element, dialog.element) { continue }   // already walked first
            let v = attrs(element, scanAttrs)
            let role = v[0] as? String ?? ""

            if actionableRoles.contains(role), let frame = frame(position: v[2], size: v[3]),
               frame.width > 2, frame.height > 2, screenBounds.intersects(frame) {
                // A password field's value never reaches the model: not as its label, not as its value.
                let secure = role == "AXSecureTextField" || v[1] as? String == "AXSecureTextField"
                let raw: Any? = secure ? Safety.redacted(v[8] as? String, role: role, subrole: v[1] as? String) : v[8]
                let label = label(element: element, role: role, title: v[4] as? String, desc: v[5] as? String,
                                  help: v[6] as? String, placeholder: v[7] as? String, value: raw as? String)
                // Unlabeled images/rows/cells are noise; unlabeled inputs are still useful.
                let input = isInput(role)
                let key = "\(role)|\(label)|\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
                // Some apps expose one control under several parents; once is enough.
                if (!label.isEmpty || input), seen.insert(key).inserted {
                    let base = stableRef(role: role, subrole: v[1] as? String, identifier: v[9] as? String,
                                         title: v[4] as? String, desc: v[5] as? String, window: windowTitle,
                                         fallback: input ? (v[7] as? String ?? v[6] as? String) : label)
                    let n = (refCounts[base] ?? 0) + 1
                    refCounts[base] = n
                    found.append(UIElementInfo(
                        id: "", role: role,
                        label: label.isEmpty ? "(unlabeled \(role.dropFirst(2)))" : label,
                        frame: frame, element: element,
                        ref: n == 1 ? base : "\(base)~\(n)",
                        value: valueText(raw, role: role), inDialog: inDialog, observationID: snapshot?.id, windowID: snapshot?.windowID))
                }
            }

            // Don't descend into closed menus from the menu bar.
            if role == "AXMenuBarItem" { continue }
            if depth < 30, !(excludingWebContent && role == "AXWebArea") {
                queue.append(contentsOf: children(of: element, role: role).map { ($0, depth + 1, inDialog) })
            }
        }
        if found.count > limit { found = trimmed(found, to: limit) }
        return found.enumerated().map { i, e in
            UIElementInfo(id: "e\(i)", role: e.role, label: e.label, frame: e.frame, element: e.element,
                          ref: e.ref, value: e.value, inDialog: e.inDialog, observationID: e.observationID, windowID: e.windowID)
        }
    }

    private static func isInput(_ role: String) -> Bool {
        role == "AXTextField" || role == "AXTextArea" || role.contains("Search") || role == "AXComboBox"
    }

    /// How much a line is worth to the model when space runs out: controls over rows over loose text over groups.
    static func priority(_ e: UIElementInfo) -> Int {
        let base: Int
        switch e.role {
        case "AXGroup": base = e.label.hasPrefix("(unlabeled") ? 0 : 1
        case "AXStaticText", "AXImage": base = 1
        case "AXCell", "AXRow", "AXHeading": base = 2
        default: base = 3
        }
        return e.inDialog ? base + 10 : base
    }

    /// Keeps the `count` most useful elements, in their original order.
    private static func trimmed(_ elements: [UIElementInfo], to count: Int) -> [UIElementInfo] {
        let keep = Set(elements.indices.sorted { (priority(elements[$0]), -$0) > (priority(elements[$1]), -$1) }.prefix(count))
        return elements.indices.filter(keep.contains).map { elements[$0] }
    }

    /// "e12 Button: Send" lines within `budget` characters. Over budget, whole low-value lines go (never a
    /// half-cut label), and a closing note says how many.
    static func listing(_ elements: [UIElementInfo], budget: Int = 8000, refs: Bool = false) -> String {
        let lines = elements.map { e in
            "\(e.id)\(refs ? " #\(e.ref)" : "") \(e.role.dropFirst(2)): \(e.label)"
                + (e.value.map { isInput(e.role) && !e.label.contains($0) ? " = \($0.prefix(60).debugDescription)" : "" } ?? "")
        }
        var total = lines.reduce(0) { $0 + $1.count + 1 }
        var dropped = Set<Int>()
        if total > budget {
            for i in elements.indices.sorted(by: { (priority(elements[$0]), -$0) < (priority(elements[$1]), -$1) }) {
                guard total > budget else { break }
                dropped.insert(i)
                total -= lines[i].count + 1
            }
        }
        var text = lines.indices.filter { !dropped.contains($0) }.map { lines[$0] }.joined(separator: "\n")
        if !dropped.isEmpty { text += "\n(\(dropped.count) less important elements not shown)" }
        return text
    }

    /// Short content hash (FNV-1a: stable across launches, unlike Hasher) of what an element *is*.
    private static func stableRef(role: String, subrole: String?, identifier: String?, title: String?, desc: String?,
                                  window: String, fallback: String?) -> String {
        var parts = [role, subrole ?? "", identifier ?? "", title ?? "", desc ?? "", window]
        // Rows, cells and loose text carry their name in the value or a child; inputs never hash their value.
        if (title ?? "").isEmpty, (desc ?? "").isEmpty, (identifier ?? "").isEmpty { parts.append(fallback ?? "") }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in parts.joined(separator: "\u{1f}").utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash ^ (hash >> 32)))
    }

    private static func valueText(_ raw: Any?, role: String) -> String? {
        if let s = raw as? String { return String(s.prefix(200)) }
        if let n = raw as? NSNumber, ["AXCheckBox", "AXRadioButton", "AXSlider", "AXIncrementor"].contains(role) { return n.stringValue }
        return nil
    }

    /// Finds an element by positional id ("e12") or stable ref ("#1a2b3c4d", "1a2b3c4d~2").
    static func lookup(_ id: String, in elements: [UIElementInfo]) -> UIElementInfo? {
        let key = id.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return elements.first { $0.ref == key } ?? elements.first { $0.id.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// A fresh scan may resolve a semantic ref only when it is unique. Numbered duplicates are observation-local.
    static func twin(of wanted: UIElementInfo, in elements: [UIElementInfo]) -> UIElementInfo? {
        guard !wanted.ref.isEmpty else { return nil }
        let base = wanted.ref.split(separator: "~").first.map(String.init) ?? ""
        let matches = elements.filter { $0.ref == base || $0.ref.hasPrefix(base + "~") }
        return matches.count == 1 && !wanted.ref.contains("~") ? matches[0] : nil
    }

    /// Children, at most `childCap`. Long tables and lists hand over their visible rows instead, since the first
    /// 200 of a scrolled list are usually off screen.
    private static func children(of element: AXUIElement, role: String, cap: Int = childCap) -> [AXUIElement] {
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, cap, &values) == .success,
              let kids = values as? [AXUIElement] else { return [] }
        if kids.count >= cap, ["AXTable", "AXOutline", "AXList", "AXBrowser"].contains(role) {
            let visible: [AXUIElement]? = attr(element, kAXVisibleRowsAttribute) ?? attr(element, kAXVisibleChildrenAttribute)
            if let visible, !visible.isEmpty { return Array(visible.prefix(cap)) }
        }
        return kids
    }

    // MARK: - Sheets and dialogs

    /// What the focused window is asking: a sheet on it, or the window itself being a modal dialog.
    static func dialog(of app: NSRunningApplication) -> (kind: String, title: String)? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = mainWindow(root), let found = dialogElement(in: window) else { return nil }
        var title: String = attr(found.element, kAXTitleAttribute) ?? ""
        if title.isEmpty {
            // Alerts carry their question as static text: the first one asking something, else the longest.
            var texts: [String] = [], queue = [found.element], head = 0
            while head < queue.count, head < 60 {
                let v = attrs(queue[head], [kAXRoleAttribute, kAXValueAttribute])
                head += 1
                if v[0] as? String == "AXStaticText", let s = v[1] as? String, !s.isEmpty { texts.append(s) }
                queue.append(contentsOf: children(of: queue[head - 1], role: "", cap: 30))
            }
            title = texts.first { $0.contains("?") } ?? texts.max { $0.count < $1.count } ?? ""
        }
        return (found.kind, String(title.prefix(120)))
    }

    /// The focused window, else the first. A focused sheet (Save panels) stands for its parent window here;
    /// `dialogElement` finds the sheet again.
    static func selectedWindow(of app: NSRunningApplication) -> AXUIElement? {
        mainWindow(AXUIElementCreateApplication(app.processIdentifier))
    }

    private static func mainWindow(_ root: AXUIElement, orFirst: Bool = true) -> AXUIElement? {
        guard let w: AXUIElement = attr(root, kAXFocusedWindowAttribute)
                ?? (orFirst ? (attr(root, kAXWindowsAttribute) as [AXUIElement]?)?.first : nil) else { return nil }
        if (attr(w, kAXRoleAttribute) as String?) == "AXSheet", let parent: AXUIElement = attr(w, kAXParentAttribute) { return parent }
        return w
    }

    private static func dialogElement(in window: AXUIElement) -> (kind: String, element: AXUIElement)? {
        for child in children(of: window, role: "", cap: 60) where (attr(child, kAXRoleAttribute) as String?) == "AXSheet" {
            return ("sheet", child)
        }
        let subrole: String = attr(window, kAXSubroleAttribute) ?? ""
        // Some main windows (Notes) call themselves AXDialog too; a real one is modal or has no minimize button.
        if subrole == "AXSystemDialog" || (attr(window, kAXModalAttribute) as Bool?) == true
            || (subrole == "AXDialog" && (attr(window, kAXMinimizeButtonAttribute) as AXUIElement?) == nil) {
            return ("dialog", window)
        }
        return nil
    }

    // MARK: - Reading

    private static func label(of element: AXUIElement, role: String) -> String {
        let v = attrs(element, [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute, kAXValueAttribute])
        return label(element: element, role: role, title: v[0] as? String, desc: v[1] as? String,
                     help: v[2] as? String, placeholder: v[3] as? String, value: Safety.redacted(v[4] as? String, of: element))
    }

    private static func label(element: AXUIElement, role: String, title: String?, desc: String?, help: String?,
                              placeholder: String?, value: String?) -> String {
        var parts: [String] = []
        for s in [title, desc, help, placeholder] {
            if let s, !s.isEmpty, !parts.contains(s) { parts.append(s) }
        }
        if parts.isEmpty, let v = value, !v.isEmpty {
            parts.append(String(v.prefix(80)))
        }
        if parts.isEmpty, let titleEl: AXUIElement = attr(element, kAXTitleUIElementAttribute),
           let t: String = attr(titleEl, kAXValueAttribute) ?? attr(titleEl, kAXTitleAttribute) {
            parts.append(t)
        }
        // Rows and cells often keep their text in a child static text.
        if parts.isEmpty, role == "AXCell" || role == "AXRow" {
            for child in children(of: element, role: role, cap: 4) {
                if let v: String = attr(child, kAXValueAttribute), !v.isEmpty { parts.append(v); break }
            }
        }
        let joined = parts.joined(separator: " — ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{200F}", with: "")
        // Apps call the user's own chat "You"; name it so models can match "message amrit nigam".
        let named = joined.replacingOccurrences(of: #"with You\b"#, with: "with \(userName) (You)", options: .regularExpression)
        return String(named.prefix(140))
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        let v = attrs(element, [kAXPositionAttribute, kAXSizeAttribute])
        return frame(position: v[0], size: v[1])
    }

    private static func frame(position: Any?, size: Any?) -> CGRect? {
        guard let p = position, let s = size, CFGetTypeID(p as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(s as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pos), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pos, size: sz)
    }

    private static func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Several attributes in one round trip (each separate read is its own IPC to the app); missing ones are nil.
    private static func attrs(_ element: AXUIElement, _ names: [String]) -> [Any?] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let array = values as? [AnyObject], array.count == names.count else { return names.map { _ in nil } }
        return array.map { v in
            // An attribute the element lacks comes back as an AXValue wrapping the error.
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
    }

    /// Converts a Cocoa (bottom-left origin) rect to global top-left coordinates.
    static func flipped(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Title of the focused window and a description of the focused element, for Jev's state.
    static func focusSummary(of app: NSRunningApplication) -> (window: String, focused: String) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var window = ""
        if let w = mainWindow(root, orFirst: false), let t: String = attr(w, kAXTitleAttribute) {
            window = t
        }
        var focused = "nothing"
        if let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) {
            let role: String = attr(f, kAXRoleAttribute) ?? "?"
            focused = "\(role.dropFirst(2)): \(label(of: f, role: role))"
        }
        return (window, focused)
    }

    /// Current text value of the focused element, used to verify typing landed.
    static func focusedValue(of app: NSRunningApplication) -> String? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) else { return nil }
        return attr(f, kAXValueAttribute)
    }

    /// The focused value as it may be shown to the model or logged (a password field's is masked).
    static func focusedValueShown(of app: NSRunningApplication) -> String? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) else { return nil }
        return Safety.redacted(attr(f, kAXValueAttribute), of: f)
    }

    private static let fingerprintAttrs = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]

    /// Cheap signature of what's on screen; if it doesn't change after an action, the action missed.
    static func fingerprint(of app: NSRunningApplication) -> Int {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = mainWindow(root, orFirst: false) else { return 0 }
        return fingerprint(of: window)
    }

    /// Content revision of an exact window. It must not silently switch to whichever window is now focused.
    static func fingerprint(of window: AXUIElement) -> Int {
        var hasher = Hasher()
        var queue: [AXUIElement] = [window]
        var head = 0
        while head < queue.count, head < 600 {
            let el = queue[head]
            head += 1
            let v = attrs(el, fingerprintAttrs)
            for x in v { hasher.combine(x as? String) }
            if let n = v[3] as? NSNumber { hasher.combine(n) }
            queue.append(contentsOf: children(of: el, role: v[0] as? String ?? ""))
        }
        return hasher.finalize()
    }

    // MARK: - Apps and processes

    /// The app that took the foreground after acting on `target` (a link opening the browser, a share sheet, a
    /// login helper), or nil while `target` is still in front, so the caller can scan that app instead.
    static func handoff(from target: NSRunningApplication) -> NSRunningApplication? {
        var pid: pid_t = 0
        // AX knows the focused app before NSWorkspace's notification catches up.
        if let focused: AXUIElement = attr(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) {
            AXUIElementGetPid(focused, &pid)
        }
        let front = (pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil) ?? NSWorkspace.shared.frontmostApplication
        guard let front, front.processIdentifier != target.processIdentifier,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return front
    }

    /// A pid plus when that process started: pids get reused, the pair doesn't.
    struct ProcessIdentity: Equatable, Sendable {
        let pid: pid_t
        let started: UInt64   // µs since 1970
    }

    static func identity(of pid: pid_t) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(pid: pid, started: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec))
    }

    static func identity(of app: NSRunningApplication) -> ProcessIdentity? { identity(of: app.processIdentifier) }

    /// False once the process is gone, even if its pid now belongs to something else.
    static func isSameProcess(_ identity: ProcessIdentity) -> Bool { self.identity(of: identity.pid) == identity }

    // MARK: - Input

    static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(15_000)
        up?.post(tap: .cghidEventTap)
    }

    /// Keyboard events go to `pid` when set (so they can't land in whatever window happens to be focused).
    static var targetPid: pid_t?
    /// A background run's app: its keys never go through the system stream, which belongs to the user.
    static var backgroundPid: pid_t?

    private static func post(_ event: CGEvent?, to pid: pid_t? = nil) {
        guard let event else { return }
        if let pid = pid ?? targetPid ?? backgroundPid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
    }

    /// One key press. Down and up are both built before anything is posted and the up is deferred, so a key is
    /// never left held; a chord also ends with a bare modifier release so ⌘/⌥ can't stay latched.
    private static func keystroke(_ key: CGKeyCode, flags: CGEventFlags = [], text: [UniChar]? = nil,
                                  source: CGEventSource?, to pid: pid_t? = nil) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        for event in [down, up] {
            event.flags = flags
            if let text { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
        }
        defer {
            post(up, to: pid)
            if !flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty,
               let release = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) {
                release.flags = []
                post(release, to: pid)
            }
        }
        post(down, to: pid)
    }

    enum PressDelivery { case unsupported, delivered, uncertain }

    /// Unsupported is the only safe signal for another input route. Timeouts may occur after the app applied it.
    static func axPressDelivery(_ element: AXUIElement) -> PressDelivery {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return .uncertain }
        guard (names as? [String] ?? []).contains(kAXPressAction as String) else { return .unsupported }
        switch AXUIElementPerformAction(element, kAXPressAction as CFString) {
        case .success: return .delivered
        case .actionUnsupported: return .unsupported
        default: return .uncertain
        }
    }

    static func axPress(_ element: AXUIElement) -> Bool {
        if case .delivered = axPressDelivery(element) { return true }
        return false
    }

    private static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    /// Gives keyboard focus to a text box through Accessibility.
    static func focus(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Read back the exact focus target (or its editable descendant), never merely "some text field".
    static func focusedWithin(_ target: AXUIElement, in app: NSRunningApplication) -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused: AXUIElement = attr(root, kAXFocusedUIElementAttribute),
              let role: String = attr(focused, kAXRoleAttribute),
              ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea"].contains(role) else { return false }
        var current: AXUIElement? = focused
        for _ in 0..<16 {
            guard let item = current else { break }
            if CFEqual(item, target) { return true }
            current = attr(item, kAXParentAttribute)
        }
        return false
    }

    // MARK: - Keyboard layout

    struct KeyStroke { let code: CGKeyCode; let flags: CGEventFlags }

    /// Keys that mean the same on every layout.
    private static let fixedKeys: [Character: KeyStroke] = [
        " ": .init(code: 0x31, flags: []), "\n": .init(code: 0x24, flags: []), "\r": .init(code: 0x24, flags: []),
        "\t": .init(code: 0x30, flags: []),
    ]

    /// US-layout key for each printable ASCII character, used when the real layout can't be read.
    private static let usKeys: [Character: KeyStroke] = {
        var map: [Character: KeyStroke] = [:]
        let plain: [(String, CGKeyCode)] = [
            ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05), ("z", 0x06), ("x", 0x07),
            ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D), ("e", 0x0E), ("r", 0x0F), ("y", 0x10),
            ("t", 0x11), ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("6", 0x16), ("5", 0x17), ("=", 0x18),
            ("9", 0x19), ("7", 0x1A), ("-", 0x1B), ("8", 0x1C), ("0", 0x1D), ("]", 0x1E), ("o", 0x1F), ("u", 0x20),
            ("[", 0x21), ("i", 0x22), ("p", 0x23), ("l", 0x25), ("j", 0x26), ("'", 0x27), ("k", 0x28), (";", 0x29),
            ("\\", 0x2A), (",", 0x2B), ("/", 0x2C), ("n", 0x2D), ("m", 0x2E), (".", 0x2F), ("`", 0x32),
        ]
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
        ]
        for (ch, code) in plain {
            let c = Character(ch)
            map[c] = .init(code: code, flags: [])
            if c.isLetter { map[Character(ch.uppercased())] = .init(code: code, flags: .maskShift) }
        }
        for (ch, base) in shifted { if let k = map[base] { map[ch] = .init(code: k.code, flags: .maskShift) } }
        return map
    }()

    nonisolated(unsafe) private static var layoutCache: (id: String, keys: [Character: KeyStroke])?

    /// Character → key on the user's current layout (AZERTY, QWERTZ, Dvorak…), from UCKeyTranslate, built once
    /// per layout. nil when the layout has no Unicode table, or off the main thread before the first read
    /// (HIToolbox asserts if asked from elsewhere).
    static func layoutKeys() -> [Character: KeyStroke]? {
        guard Thread.isMainThread else { return layoutCache?.keys }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        if let cache = layoutCache, cache.id == id { return cache.keys }
        guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let bytes = CFDataGetBytePtr(Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue()) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let kbdType = UInt32(LMGetKbdType())
        var keys: [Character: KeyStroke] = [:]
        // Plain keys win over Shift, Shift over Option: the simplest way to type each character.
        let states: [(UInt32, CGEventFlags)] = [(0, []), (UInt32(shiftKey >> 8), .maskShift),
                                                (UInt32(optionKey >> 8), .maskAlternate),
                                                (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate])]
        for (mods, flags) in states {
            for code in UInt16(0)..<128 {
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                guard UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), mods, kbdType, 0,
                                     &dead, chars.count, &length, &chars) == noErr,
                      dead == 0, length == 1, chars[0] >= 0x20, chars[0] != 0x7F else { continue }   // skip dead and control keys
                let ch = Character(String(utf16CodeUnits: chars, count: 1))
                if keys[ch] == nil { keys[ch] = .init(code: CGKeyCode(code), flags: flags) }
            }
        }
        layoutCache = (id, keys)
        return keys
    }

    /// The key for `ch`: layout-aware when the layout is readable, US otherwise.
    private static func stroke(for ch: Character) -> KeyStroke? {
        if let k = fixedKeys[ch] { return k }
        if let keys = layoutKeys() { return keys[ch] }
        return usKeys[ch]
    }

    /// Types text one character at a time the way a keyboard does: the real key on the user's layout (with
    /// Shift/Option when needed) plus the character itself, so apps that read key codes and apps that read text
    /// both get it right. Characters no key makes (emoji, other scripts) go as text alone.
    static func type(_ text: String) {
        guard !Task.isCancelled else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for ch in text {
            let k = stroke(for: ch) ?? KeyStroke(code: 0, flags: [])
            keystroke(k.code, flags: k.flags, text: Array(String(ch).utf16), source: source)
            usleep(4_000)
        }
    }

    /// Enters text reliably: short text is typed, longer text is pasted (fast keystroke bursts get dropped),
    /// with the user's clipboard restored afterwards.
    static func enter(_ text: String) {
        guard text.count > 12 else { type(text); return }
        paste(text)
    }

    /// Pastes text through the clipboard, restoring what was there.
    static func paste(_ text: String) {
        guard !Task.isCancelled else { return }
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(text, forType: .string)
        press(shortcutKey("v"), flags: .maskCommand)
        usleep(250_000)
        board.clearContents()
        if let saved { board.setString(saved, forType: .string) }
    }

    /// Frame of the app's focused (or first) window.
    static func windowFrame(of app: NSRunningApplication) -> CGRect? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        return mainWindow(root).flatMap { frame(of: $0) }
    }

    /// Sets the focused text field's value directly (for fields that ignore synthetic keystrokes).
    static func setFocusedValue(_ text: String, in app: NSRunningApplication) -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) else { return false }
        return AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, text as CFString) == .success
    }

    /// Frame of the element that has keyboard focus.
    static func focusedFrame(of app: NSRunningApplication) -> CGRect? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) else { return nil }
        return frame(of: f)
    }

    /// The Dock icon for an app, if it's in the Dock.
    static func dockItem(named name: String) -> (element: AXUIElement, frame: CGRect)? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        let wanted = name.lowercased()
        for list in (attr(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for item in (attr(list, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                guard let title: String = attr(item, kAXTitleAttribute),
                      title.replacingOccurrences(of: "\u{200E}", with: "").lowercased() == wanted,
                      let f = frame(of: item) else { continue }
                return (item, f)
            }
        }
        return nil
    }

    /// True if the focused field holds `text`, allowing for autocorrect, capitalisation and smart punctuation
    /// (or if the field doesn't report its contents at all, as some don't).
    static func fieldHolds(_ text: String, in app: NSRunningApplication) -> Bool {
        guard let value = focusedValue(of: app), !value.isEmpty else { return true }
        return similar(value, text)
    }

    /// Current frame of an element, or nil if it no longer exists.
    static func liveFrame(of element: AXUIElement) -> CGRect? { frame(of: element) }

    /// On-screen frame of the browser's page area (the largest AXWebArea in the focused window).
    static func webAreaFrame(of app: NSRunningApplication) -> CGRect? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = mainWindow(root, orFirst: false) else { return nil }
        var queue = [window], best: CGRect?, head = 0
        while head < queue.count, head < 1500 {
            let el = queue[head]
            head += 1
            let v = attrs(el, [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute])
            let role = v[0] as? String ?? ""
            if role == "AXWebArea", let f = frame(position: v[1], size: v[2]), f.width > 100 {
                if best.map({ f.width * f.height > $0.width * $0.height }) ?? true { best = f }
                continue   // don't descend into page content
            }
            queue.append(contentsOf: children(of: el, role: role))
        }
        return best
    }

    /// Loose text comparison that tolerates autocorrect, case and punctuation.
    static func similar(_ have: String, _ want: String) -> Bool {
        let clean = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let w = clean(want), h = clean(have)
        if w.isEmpty || h.contains(w) { return true }
        // Mostly there (a word autocorrected) counts; a clearly partial or missing text doesn't.
        let common = zip(w, h.suffix(w.count)).filter { $0 == $1 }.count
        return Double(common) / Double(w.count) >= 0.85
    }

    /// Text currently selected in the app's focused element, if any.
    static func selectedText(of app: NSRunningApplication) -> String? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute),
              let text: String = attr(f, kAXSelectedTextAttribute) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Selection via a synthetic ⌘C, for apps that don't expose it over AX (WhatsApp, Slack, Electron…).
    /// The user's clipboard is restored afterwards. Must run while `app` is still frontmost.
    static func copiedSelection(of app: NSRunningApplication) -> String? {
        copied(from: app) { pb in
            let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
    }

    /// All the text of the document in front (Preview, Quick Look…): ⌘A then ⌘C. For documents whose file is
    /// out of reach (e.g. a PDF inside WhatsApp's sandbox, which even `cp` can't copy). Must run while `app` is frontmost.
    static func copiedAll(of app: NSRunningApplication) -> String? {
        keystroke(shortcutKey("a"), flags: .maskCommand, source: CGEventSource(stateID: .privateState), to: app.processIdentifier)
        usleep(150_000)
        return copiedSelection(of: app)
    }

    /// The files selected in Finder (or any app that copies files), read by a ⌘C like copiedSelection —
    /// needs no Automation permission, unlike asking Finder with AppleScript.
    static func copiedFiles(of app: NSRunningApplication) -> [URL] {
        copied(from: app) { pb in
            pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        } ?? []
    }

    /// Presses ⌘C in `app`, reads the pasteboard with `read`, then puts back what the user had copied.
    private static func copied<T>(from app: NSRunningApplication, _ read: (NSPasteboard) -> T?) -> T? {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        let before = pb.changeCount
        // A private source ignores the ⌃⌥ the user may still be holding.
        keystroke(shortcutKey("c"), flags: .maskCommand, source: CGEventSource(stateID: .privateState), to: app.processIdentifier)
        let deadline = Date().addingTimeInterval(0.25)
        while pb.changeCount == before, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        guard pb.changeCount != before else { return nil }   // nothing selected → app copied nothing
        let value = read(pb)
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
        return value
    }

    /// The file the app's focused window has open (Preview, TextEdit, Pages, Word…), if it says.
    static func documentURL(of app: NSRunningApplication) -> URL? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let w = mainWindow(root), let doc: String = attr(w, kAXDocumentAttribute), let url = URL(string: doc) else { return nil }
        return url
    }

    /// Role and label of whatever is on screen at a point (for recording what the user clicked).
    static func describe(at point: CGPoint) -> (role: String, label: String) {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return ("something", "") }
        let role: String = attr(element, kAXRoleAttribute) ?? "AXUnknown"
        var text = label(of: element, role: role)
        // Many click targets are an unlabeled image or text inside a labeled button/row: use the parent's label.
        if text.isEmpty, let parent: AXUIElement = attr(element, kAXParentAttribute) {
            let pr: String = attr(parent, kAXRoleAttribute) ?? ""
            text = label(of: parent, role: pr)
        }
        return (String(role.dropFirst(2)), text)
    }

    /// Role and label of the focused element (for recording where the user typed).
    static func focusedDescription(of app: NSRunningApplication) -> (role: String, label: String) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) else { return ("field", "") }
        let role: String = attr(f, kAXRoleAttribute) ?? "AXTextField"
        let subrole: String = attr(f, kAXSubroleAttribute) ?? ""
        return (subrole == "AXSecureTextField" ? "AXSecureTextField" : String(role.dropFirst(2)), label(of: f, role: role))
    }

    /// Role of the element with keyboard focus (e.g. "AXTextArea"), if any.
    static func focusedRole(of app: NSRunningApplication) -> String? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) else { return nil }
        return attr(f, kAXRoleAttribute)
    }

    static func pressReturn() { press(0x24) }

    /// Return carrying its character, as typed text does: a Catalyst app (WhatsApp) posted to in the background
    /// takes the typed letters but ignores a bare Return key.
    static func typeReturn() {
        keystroke(0x24, text: [13], source: CGEventSource(stateID: .combinedSessionState))
    }

    /// ⌘N to one app only (a new Finder or browser window for the user), leaving `targetPid` to the run's typing.
    static func pressNewWindow(in pid: pid_t) {
        keystroke(shortcutKey("n"), flags: .maskCommand, source: CGEventSource(stateID: .hidSystemState), to: pid)
    }

    /// Scrolls the app's focused window; positive is up.
    static func scroll(_ lines: Int32, in app: NSRunningApplication) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var point = CGPoint(x: 600, y: 400)
        if let w = mainWindow(root, orFirst: false), let f = frame(of: w) {
            point = CGPoint(x: f.midX, y: f.midY)
        }
        // In a background run the wheel goes to the app at its window's middle; the pointer stays with the user.
        if backgroundPid == app.processIdentifier {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
            event?.location = point
            event?.postToPid(app.processIdentifier)
            return
        }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
        event?.location = point
        event?.post(tap: .cghidEventTap)
    }

    static func selectAll() { press(shortcutKey("a"), flags: .maskCommand) }

    /// The key a ⌘-shortcut letter sits on for this layout (⌘Z is a different key on AZERTY); US on layouts
    /// without Latin letters, which is what macOS itself does for shortcuts there.
    private static func shortcutKey(_ ch: Character) -> CGKeyCode {
        if let k = layoutKeys()?[ch], k.flags.isEmpty { return k.code }
        return usKeys[ch]?.code ?? 0
    }

    /// Keys with a name, which sit in the same place on every layout.
    private static let namedKeys: [String: CGKeyCode] = [
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
        "esc": 0x35, "escape": 0x35, "forwarddelete": 0x75, "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "spacebar": 0x31, "del": 0x33,
    ]
    /// Names the model spells out for punctuation ("cmd+minus", "cmd+plus" for zoom).
    private static let namedChars: [String: Character] = [
        "minus": "-", "hyphen": "-", "dash": "-", "plus": "=", "equal": "=", "equals": "=", "comma": ",",
        "period": ".", "dot": ".", "slash": "/", "backslash": "\\", "semicolon": ";", "quote": "'",
        "backtick": "`", "grave": "`", "leftbracket": "[", "rightbracket": "]",
    ]

    /// Presses a combo like "cmd+shift+t", "return" or "ctrl+a". Returns false for an unknown key.
    @discardableResult
    static func press(combo: String) -> Bool {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for raw in combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init) {
            // "Page_Down", "page-up": the same keys as "pagedown", "pageup".
            let part = raw.count > 1 ? raw.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") : raw
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default:
                if let code = namedKeys[part] { key = code; continue }
                guard let ch = namedChars[part] ?? (part.count == 1 ? part.first : nil) else { key = nil; continue }
                // A letter or symbol goes to whichever key makes it on this layout (adding Shift/Option if that key needs it).
                if let k = layoutKeys()?[ch] ?? usKeys[ch] { key = k.code; flags.formUnion(k.flags) } else { key = nil }
            }
        }
        guard let key else { return false }
        press(key, flags: flags)
        return true
    }

    static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        guard !Task.isCancelled else { return }
        keystroke(key, flags: flags, source: CGEventSource(stateID: .hidSystemState))
    }
}

// MARK: - Menus by path

extension AXEngine {
    /// Chooses a menu item by path ("File > Export…", "view > zoom in"), tolerant of case, accents and "…" vs
    /// "...". Presses the item directly (no menus flash open); opens the chain first only if the app needs that.
    /// On a miss the note lists what that level does offer.
    static func pressMenu(_ path: String, in app: NSRunningApplication) -> (ok: Bool, note: String) {
        let parts = path.components(separatedBy: CharacterSet(charactersIn: ">›→")).map(menuKey).filter { !$0.isEmpty }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard !parts.isEmpty, let bar: AXUIElement = attr(root, kAXMenuBarAttribute) else { return (false, "no menu bar") }
        var items = children(of: bar, role: "AXMenuBar")
        var chain: [AXUIElement] = []
        for (i, part) in parts.enumerated() {
            let titled = items.map { ($0, (attr($0, kAXTitleAttribute) as String?) ?? "") }.filter { !$0.1.isEmpty }
            let keyed = titled.map { ($0.0, $0.1, menuKey($0.1)) }
            guard let hit = keyed.first(where: { $0.2 == part }) ?? keyed.first(where: { $0.2.hasPrefix(part) })
                    ?? keyed.first(where: { $0.2.contains(part) }) else {
                let offered = titled.prefix(30).map(\.1).joined(separator: ", ")
                return (false, "no “\(part)” in \(i == 0 ? "the menu bar" : "that menu"); it has: \(offered)")
            }
            chain.append(hit.0)
            if i == parts.count - 1 {
                let enabled = { (attr(hit.0, kAXEnabledAttribute) as Bool?) != false }
                if enabled(), axPress(hit.0) { return (true, "chose \(hit.1)") }
                // Enabled states are only refreshed when a menu opens, and some apps only act on items in an open
                // menu: open each level, then try again.
                for opener in chain.dropLast() { _ = axPress(opener); usleep(80_000) }
                if enabled(), axPress(hit.0) { return (true, "chose \(hit.1)") }
                press(0x35)   // close whatever opened
                return (false, enabled() ? "“\(hit.1)” wouldn't press" : "“\(hit.1)” is greyed out")
            }
            // A menu bar item or submenu holds its items in a single AXMenu child.
            guard let menu = children(of: hit.0, role: "").first(where: { (attr($0, kAXRoleAttribute) as String?) == "AXMenu" }) else {
                return (false, "“\(hit.1)” has no submenu")
            }
            items = children(of: menu, role: "AXMenu")
        }
        return (false, "empty path")
    }

    /// Menu title reduced for matching: no case, accents, ellipsis or stray spaces.
    private static func menuKey(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Windows

extension AXEngine {
    enum WindowAction {
        case move(CGPoint), resize(CGSize), minimize, restore, fullscreen(Bool), close, raise
    }

    /// Moves, resizes, minimizes, restores, fullscreens, closes or raises a window of `app` (the one titled
    /// `title`, else the focused one), then reads it back. A move or resize the app refused is put back.
    static func window(_ action: WindowAction, in app: NSRunningApplication, titled title: String? = nil) -> (ok: Bool, note: String) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        let windows: [AXUIElement] = attr(root, kAXWindowsAttribute) ?? []
        let window: AXUIElement?
        if let title, !title.isEmpty {
            let want = menuKey(title)
            window = windows.first { menuKey(attr($0, kAXTitleAttribute) ?? "").contains(want) }
        } else if case .restore = action {
            // Minimized windows can drop out of AXWindows, so remember the one we minimized.
            let remembered = minimizedWindows[app.processIdentifier].flatMap { (attr($0, kAXMinimizedAttribute) as Bool?) == true ? $0 : nil }
            window = windows.first { (attr($0, kAXMinimizedAttribute) as Bool?) == true } ?? remembered ?? mainWindow(root, orFirst: false)
        } else {
            window = mainWindow(root)
        }
        guard let window else { return (false, title.map { "no window titled “\($0)”" } ?? "no window") }
        let flag = { (name: String) in (attr(window, name) as Bool?) == true }

        switch action {
        case .move(let point):
            guard let before = frame(of: window) else { return (false, "window has no position") }
            setPoint(window, kAXPositionAttribute, point)
            let after = settle { frame(of: window).map { abs($0.minX - point.x) <= 4 && abs($0.minY - point.y) <= 4 } ?? false }
            if after { return (true, "moved to \(Int(point.x)),\(Int(point.y))") }
            let landed = frame(of: window)
            setPoint(window, kAXPositionAttribute, before.origin)
            return (false, "the window only went to \(landed.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "?"); put it back")
        case .resize(let size):
            guard let before = frame(of: window) else { return (false, "window has no size") }
            setSize(window, size)
            let after = settle { frame(of: window).map { abs($0.width - size.width) <= 4 && abs($0.height - size.height) <= 4 } ?? false }
            if after { return (true, "resized to \(Int(size.width))×\(Int(size.height))") }
            let landed = frame(of: window)
            setSize(window, before.size)
            setPoint(window, kAXPositionAttribute, before.origin)
            return (false, "the app kept it at \(landed.map { "\(Int($0.width))×\(Int($0.height))" } ?? "?"); put it back")
        case .minimize:
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            guard settle(0.6, { flag(kAXMinimizedAttribute) }) else { return (false, "the window didn't minimize") }
            minimizedWindows[app.processIdentifier] = window
            return (true, "minimized")
        case .restore:
            guard flag(kAXMinimizedAttribute) else { return (true, "not minimized") }
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            app.activate()
            // A window that vanished reads as nil, not false, so ask for an explicit false.
            guard settle(0.6, { (attr(window, kAXMinimizedAttribute) as Bool?) == false }) else { return (false, "the window stayed minimized") }
            minimizedWindows[app.processIdentifier] = nil
            return (true, "restored")
        case .fullscreen(let on):
            if flag("AXFullScreen") == on { return (true, on ? "already full screen" : "already windowed") }
            if AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse) != .success,
               let button: AXUIElement = attr(window, kAXFullScreenButtonAttribute) {
                _ = axPress(button)
            }
            // The Spaces animation takes about a second.
            return settle(1.5) { flag("AXFullScreen") == on } ? (true, on ? "full screen" : "left full screen")
                : (false, "full screen didn't change")
        case .close:
            guard let button: AXUIElement = attr(window, kAXCloseButtonAttribute), axPress(button) else {
                return (false, "the window has no close button")
            }
            if settle(1, { !((attr(root, kAXWindowsAttribute) as [AXUIElement]?) ?? []).contains { CFEqual($0, window) } }) {
                return (true, "closed")
            }
            if let d = dialogElement(in: window) { return (false, "a \(d.kind) asked something before closing") }
            return (false, "the window is still open")
        case .raise:
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            app.activate()
            return settle { flag(kAXMainAttribute) } ? (true, "raised") : (false, "the window didn't come forward")
        }
    }

    nonisolated(unsafe) private static var minimizedWindows: [pid_t: AXUIElement] = [:]

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? { attr(element, name) }

    /// The app's windows, as Accessibility lists them.
    static func windows(of app: NSRunningApplication) -> [AXUIElement] {
        attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) ?? []
    }

    /// The window server's number for an Accessibility window (private, long-stable _AXUIElementGetWindow).
    static func windowID(of window: AXUIElement) -> CGWindowID? {
        typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        var id: CGWindowID = 0
        return unsafeBitCast(sym, to: GetWindow.self)(window, &id) == .success && id != 0 ? id : nil
    }

    /// Moves a window into `rect` (global top-left), shrinking it to fit.
    static func place(_ window: AXUIElement, in rect: CGRect) {
        if let f = frame(of: window), f.width > rect.width || f.height > rect.height {
            setSize(window, CGSize(width: min(f.width, rect.width), height: min(f.height, rect.height)))
        }
        setPoint(window, kAXPositionAttribute, rect.origin)
    }

    private static func setPoint(_ element: AXUIElement, _ name: String, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(element, name as CFString, v) }
    }

    private static func setSize(_ element: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) }
    }

    /// Polls `check` for up to `seconds` (windows animate), true as soon as it holds.
    private static func settle(_ seconds: Double = 0.6, _ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if check() { return true }
            usleep(50_000)
        } while Date() < deadline
        return check()
    }
}
