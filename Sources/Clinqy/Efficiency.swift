import AppKit

/// Shared budgets for decorative work. Agent observations and exported screenshots keep their own fidelity.
@MainActor enum Efficiency {
    /// Demonstration pacing is opt-in; decoration never holds up normal automation.
    static var humanMotion: Bool { ["on", "1", "true", "yes"].contains((Config.value("HUMAN_MOTION") ?? "off").lowercased()) }
    static let previewInterval: TimeInterval = 1
    static let waitingPreviewInterval: TimeInterval = 3
    private(set) static var constrained = limited()
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { constrained = limited() }
            })
        }
    }

    /// Motion runs at the fastest connected display's refresh rate (120 Hz on ProMotion), decoration at 30 fps.
    static func animationInterval(moving: Bool) -> TimeInterval {
        if constrained { return 1 / (moving ? 30.0 : 20.0) }
        let display = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        return 1 / (moving ? Double(min(120, max(60, display))) : 30.0)
    }

    private static func limited() -> Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }
}
