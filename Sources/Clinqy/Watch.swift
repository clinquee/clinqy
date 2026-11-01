import AppKit
import ApplicationServices

/// Waits for text to appear in (or vanish from) an app by listening to its Accessibility notifications,
/// instead of re-reading the whole tree on a timer. A burst of notifications (a page re-rendering) costs one scan.
@MainActor
enum Watch {
    /// What wakes a watcher: text edits, elements coming and going, titles, focus and windows.
    private static let notifications = [
        kAXValueChangedNotification, kAXCreatedNotification, kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification, kAXFocusedUIElementChangedNotification, kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification, kAXSelectedChildrenChangedNotification, kAXLayoutChangedNotification,
        "AXLoadComplete",
    ]

    /// Minimum gap between two scans of the same process; notifications inside it collapse into one trailing scan.
    static let minGap: TimeInterval = 0.2
    /// Last scan time per pid, shared by every watcher (two waits on one app don't double the work).
    private static var lastScan: [pid_t: Date] = [:]

    /// With `window` the wait is bound to that observed window (and its sheets); without it, any window of the app counts.
    /// True once `text` is on screen in `app` (or, with `gone`, once it isn't); false after `timeout` seconds.
    /// Falls back to polling every 0.5 s when the app can't be observed (no Accessibility permission, odd process).
    static func until(app: NSRunningApplication, text: String, gone: Bool = false, timeout: TimeInterval,
                      window scope: AXUIElement? = nil) async -> Bool {
        let want = text.lowercased()
        let pid = app.processIdentifier
        // Chromium and Electron only publish web content once an assistive client asks for it.
        AXEngine.enableManualAccessibility(app)
        let met = { contains(pid: pid, want, window: scope) != gone }
        if met() { return true }
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Watcher(pid: pid, check: met, timeout: timeout, done: done).start()
        }
    }

    /// Case-insensitive search of every window's titles, descriptions and values (bounded, so huge trees stay cheap).
    static func contains(pid: pid_t, _ want: String, window scope: AXUIElement? = nil) -> Bool {
        lastScan[pid] = Date()
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.5)
        var queue: [AXUIElement] = scope.map { [$0] } ?? (attr(root, kAXWindowsAttribute) as [AXUIElement]?) ?? []
        if queue.isEmpty, scope == nil, let w: AXUIElement = attr(root, kAXFocusedWindowAttribute) { queue.append(w) }
        var head = 0
        while head < queue.count, head < 5000 {
            let el = queue[head]
            head += 1
            for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let s: String = attr(el, key), s.lowercased().contains(want) { return true }
            }
            if let children: [AXUIElement] = attr(el, kAXChildrenAttribute) { queue.append(contentsOf: children) }
        }
        return false
    }

    private static func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// One wait: an AXObserver on the app (or a poll timer), a timeout, and the continuation to resume once.
    @MainActor private final class Watcher {
        let pid: pid_t
        let check: () -> Bool
        let timeout: TimeInterval
        var done: CheckedContinuation<Bool, Never>?
        var observer: AXObserver?
        var timers: [Timer] = []
        var pending = false
        /// Keeps the watcher alive while the observer's C callback holds only an unretained pointer to it.
        var retainSelf: Watcher?

        init(pid: pid_t, check: @escaping () -> Bool, timeout: TimeInterval, done: CheckedContinuation<Bool, Never>) {
            self.pid = pid
            self.check = check
            self.timeout = timeout
            self.done = done
        }

        func start() {
            retainSelf = self
            timers.append(Timer.scheduledTimer(withTimeInterval: max(0.05, timeout), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(false) }
            })
            let observing = observe()
            // Without an observer, poll twice a second; with one, a slow backstop poll, because web views
            // don't always announce text that arrives inside an existing element.
            timers.append(Timer.scheduledTimer(withTimeInterval: observing ? 2 : 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poke() }
            })
        }

        private func observe() -> Bool {
            var created: AXObserver?
            let callback: AXObserverCallback = { _, _, _, refcon in
                guard let refcon else { return }
                let watcher = Unmanaged<Watcher>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { watcher.poke() }
            }
            guard AXObserverCreate(pid, callback, &created) == .success, let created else { return false }
            let root = AXUIElementCreateApplication(pid)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            var added = 0
            for name in Watch.notifications where AXObserverAddNotification(created, root, name as CFString, refcon) == .success {
                added += 1
            }
            guard added > 0 else { return false }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
            observer = created
            return true
        }

        /// Something changed: scan now, or once at the end of the per-pid gap if the app was scanned just now.
        func poke() {
            guard done != nil, !pending else { return }
            let since = Date().timeIntervalSince(Watch.lastScan[pid] ?? .distantPast)
            if since >= Watch.minGap { evaluate(); return }
            pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (Watch.minGap - since)) { [weak self] in
                MainActor.assumeIsolated {
                    self?.pending = false
                    self?.evaluate()
                }
            }
        }

        private func evaluate() {
            guard done != nil else { return }
            if check() { finish(true) }
        }

        func finish(_ ok: Bool) {
            guard let done else { return }
            self.done = nil
            timers.forEach { $0.invalidate() }
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
                let root = AXUIElementCreateApplication(pid)
                for name in Watch.notifications { AXObserverRemoveNotification(observer, root, name as CFString) }
            }
            observer = nil
            done.resume(returning: ok)
            DispatchQueue.main.async { self.retainSelf = nil }
        }
    }
}
