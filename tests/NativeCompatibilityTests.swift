import AppKit

// This fixture creates native AppKit windows rather than a browser.
enum Launcher { static func isBrowser(_ app: NSRunningApplication) -> Bool { false } }

// Fixture controls contain only test strings; production redaction is irrelevant to this isolated driver probe.
enum Safety {
    static func redacted(_ value: String?, role: String, subrole: String?) -> String? { value }
    static func redacted(_ value: String?, of element: AXUIElement) -> String? { value }
    static func isSecureField(_ element: AXUIElement) -> Bool { false }
}

@MainActor private final class Fixture: NSObject {
    var windows: [NSWindow] = []
    var presses = 0
    @objc func press(_ sender: NSButton) { presses += 1; sender.title = "Fixture count \(presses)" }
    func start() {
        NSApplication.shared.setActivationPolicy(.accessory)
        for (index, size) in [CGSize(width: 320, height: 180), CGSize(width: 640, height: 380)].enumerated() {
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 100 + index * 50, y: 100 + index * 50), size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Clinqy disposable fixture \(index)"
            let button = NSButton(title: "Fixture count 0", target: self, action: #selector(press(_:)))
            button.frame = CGRect(x: 30, y: 30, width: 220, height: 40)
            window.contentView?.addSubview(button)
            for column in 0..<2 {
                let field = NSTextField(string: "fixture field \(column)")
                field.frame = CGRect(x: 20 + column * 150, y: 90, width: 130, height: 24)
                window.contentView?.addSubview(field)
            }
            window.orderBack(nil)
            windows.append(window)
        }
        print(windows.map { String($0.windowNumber) }.joined(separator: ",")); fflush(stdout)
    }
}

@main struct NativeCompatibilityTests {
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--fixture") {
            let fixture = Fixture()
            fixture.start()
            NSApplication.shared.run()
            return
        }
        guard AXIsProcessTrusted() else {
            print("SKIP: native fixture requires Accessibility permission for this test executable; no permission prompt or input was issued.")
            return
        }
        guard CGSessionCopyCurrentDictionary() != nil, !NSScreen.screens.isEmpty else {
            print("SKIP: native fixture requires a logged-in graphical macOS session; no fixture or input was created.")
            return
        }
        var checks = 0
        enum Failure: Error { case check(String) }
        func check(_ value: Bool, _ label: String) throws { guard value else { throw Failure.check(label) }; checks += 1 }
        func windows(excluding pid: pid_t) -> [CGWindowID] {
            let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            return rows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
                .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pointer = CGEvent(source: nil)?.location
        let clipboard = NSPasteboard.general.changeCount
        let beforeOrder = windows(excluding: -1)
        let measuredFrom = Date()
        let inputTypes: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        let inputCounts = inputTypes.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--fixture"]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 { line.append(byte) }
        let ids = String(decoding: line, as: UTF8.self).split(separator: ",").compactMap { UInt32($0) }
        try check(ids.count == 2, "fixture created two independently addressable windows")
        guard let app = NSRunningApplication(processIdentifier: process.processIdentifier) else { throw Failure.check("fixture application disappeared") }
        var smallWindow: NativeWindowObservation?, largeWindow: NativeWindowObservation?
        for _ in 0..<20 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            smallWindow = NativeWindowObservation.capture(app, windowID: ids[0])
            largeWindow = NativeWindowObservation.capture(app, windowID: ids[1])
            if smallWindow != nil && largeWindow != nil { break }
        }
        guard let small = smallWindow, let large = largeWindow else {
            print("SKIP: this macOS session did not expose the disposable fixture through Accessibility/WindowServer; no input was issued.")
            return
        }
        try check(small.windowID != large.windowID && small.frame.width < large.frame.width, "exact small window is not replaced by largest same-process window")
        let controls = AXEngine.elements(of: app, window: small)
        try check(!controls.isEmpty && controls.allSatisfy { $0.windowID == small.windowID && $0.observationID == small.id }, "all controls belong to the exact observation")
        guard let button = controls.first(where: { $0.role == "AXButton" && $0.label == "Fixture count 0" }) else { throw Failure.check("fixture button not exposed") }
        try check(AXEngine.axPressDelivery(button.element) == .delivered, "one semantic action delivered only to fixture")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try check(small.staleness(includeContent: true) != nil, "changed fixture content invalidates earlier observation")
        let largeControls = AXEngine.elements(of: app, window: large)
        try check(largeControls.contains { $0.label == "Fixture count 0" }, "same-labelled control in other window is unchanged")
        guard let refreshed = NativeWindowObservation.capture(app, windowID: small.windowID) else { throw Failure.check("fixture window disappeared") }
        let fields = AXEngine.elements(of: app, window: refreshed).filter { $0.role == "AXTextField" }.sorted { $0.frame.minX < $1.frame.minX }
        try check(fields.count == 2, "fixture exposes two independent text fields")
        try check(AXEngine.focus(fields[0].element), "focus delivered to exact disposable field")
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        try check(AXEngine.focusedWithin(fields[0].element, in: app), "exact requested focused field is accepted")
        try check(!AXEngine.focusedWithin(fields[1].element, in: app), "another text field is rejected despite its editable role")
        try check(!AXEngine.focusedWithin(button.element, in: app), "non-input target is not accepted as text focus")
        AXEngine.place(large.element, in: large.frame.offsetBy(dx: 12, dy: 0))
        try check(large.staleness() != nil, "moving the exact fixture window invalidates old geometry")
        let inputNow = inputTypes.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
        if inputNow != inputCounts {
            print("SKIP: foreground/pointer/clipboard/window-order isolation measurement was inconclusive because HID input occurred during the \(String(format: "%.2f", Date().timeIntervalSince(measuredFrom)))s probe; target/focus checks still ran.")
        } else {
            try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == front, "foreground app unchanged")
            try check(CGEvent(source: nil)?.location == pointer, "system pointer unchanged")
            try check(NSPasteboard.general.changeCount == clipboard, "shared clipboard unchanged")
            try check(windows(excluding: process.processIdentifier) == beforeOrder, "existing user windows preserve their order")
        }
        print("PASS: \(checks) native fixture compatibility checks (this fixture only; no general native-app support implied)")
    }
}
