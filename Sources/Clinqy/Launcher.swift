import AppKit

/// Opening and focusing apps and URLs.
@MainActor
enum Launcher {
    nonisolated static let browserIDs: Set<String> = [
        "company.thebrowser.Browser", "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.dia",
    ]

    static var defaultBrowserName: String? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?
            .deletingPathExtension().lastPathComponent
    }

    /// Title of the frontmost window: cheap way to notice a page change.
    static var frontURLHint: String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "" }
        return AXEngine.focusSummary(of: app).window
    }

    nonisolated static func isBrowser(_ app: NSRunningApplication) -> Bool { browserIDs.contains(app.bundleIdentifier ?? "") }

    /// A copy of a browser another tool drives (Playwright, Puppeteer, a test runner): a throwaway profile with no
    /// extensions, under a debugging pipe or port. Not the user's browser, so Clinqy neither works in it nor moves it.
    static func isAutomated(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        if let known = automated[pid] { return known }
        var size = 0
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var args = ""
        if sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 {
                args = String(decoding: buffer.prefix(size).map { UInt8(bitPattern: $0 == 0 ? 32 : $0) }, as: UTF8.self)
            }
        }
        let found = args.contains("--remote-debugging-pipe") || args.contains("--remote-debugging-port")
            || args.contains("playwright_") || args.contains("puppeteer_") || args.contains("--enable-automation")
        automated[pid] = found
        return found
    }
    private static var automated: [pid_t: Bool] = [:]

    /// The running app called `name` (lowercased), leaving out browsers another tool drives.
    static func running(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.cleanName?.lowercased() == name && !isAutomated($0) }
    }

    /// Brings a running app (or finds and launches one by name) to the front with its window loaded.
    static func open(appNamed name: String) async -> NSRunningApplication? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let url = running(named: wanted)?.bundleURL ?? find(named: wanted)
        guard let url else { return nil }
        return await launch(url)
    }

    static func launch(_ url: URL) async -> NSRunningApplication? {
        // The windows the user already has: a background run moves only the ones it opens to Clinqy's hidden screen.
        let had = NSWorkspace.shared.runningApplications.first { $0.bundleURL == url }.map { Hand.windowIDs(pid: $0.processIdentifier) } ?? []
        let config = NSWorkspace.OpenConfiguration()
        config.activates = !Background.active
        guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: config) else { return nil }
        // `open` on a running app whose windows are closed brings a window back (-g: without coming to the front).
        _ = await Shell.run("/usr/bin/open", Background.active ? ["-g", url.path] : [url.path])
        if Background.active {
            for _ in 0..<40 where AXEngine.elements(of: app, limit: 5, menuBar: true).count <= 1 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            Background.track(app, had: had)
            AgentScreen.adopt(app, keep: had)
            await bringToFront(app)
            return app
        }
        for _ in 0..<40 {
            if app.isActive, AXEngine.elements(of: app, limit: 5, menuBar: true).count > 1 { break }
            app.activate()
            try? await Task.sleep(for: .milliseconds(100))
        }
        return app
    }

    /// What is actually true of an app right now. "Launched" and "ready to be driven" are different claims, so callers
    /// report each one rather than assuming the app is frontmost with a usable window.
    struct Readiness: Equatable {
        var running: Bool
        var frontmost: Bool
        var windows: Int
        var accessible: Bool
        /// Frontmost with a window and an accessibility tree: input can be aimed at it.
        var ready: Bool { running && frontmost && windows > 0 && accessible }
        var summary: String {
            if !running { return "is not running" }
            var gaps: [String] = []
            if !frontmost { gaps.append("not frontmost") }
            if windows == 0 { gaps.append("no window yet") }
            if !accessible { gaps.append("accessibility tree not readable yet") }
            return gaps.isEmpty ? "is frontmost with a window" : "was opened but is " + gaps.joined(separator: ", ")
        }
    }

    static func readiness(of app: NSRunningApplication) -> Readiness {
        let running = !app.isTerminated
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        let windows = running ? AXEngine.windows(of: app).count : 0
        let accessible = running && AXEngine.elements(of: app, limit: 5, menuBar: true).count > 1
        return Readiness(running: running, frontmost: frontmost, windows: windows, accessible: accessible)
    }

    static func bringToFront(_ app: NSRunningApplication) async {
        if Background.active { return focusBehind(app) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else { return }
        // Plain activate() is ignored while we aren't frontmost; opening the app always works.
        if let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            app.activate()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A background run's stand-in for bringing `app` forward: it becomes the run's app (keys go to it) and its window
    /// takes synthetic focus without being raised, so the user's app stays in front. A browser working in Clinqy's own
    /// window needs none of that (its page input goes through the extension), and the user's own windows of the
    /// same browser mustn't be disturbed.
    private static func focusBehind(_ app: NSRunningApplication) {
        Background.app = app
        Background.track(app)
        if app.isHidden { app.unhide() }
        guard !(isBrowser(app) && Background.tab != nil), app.processIdentifier != getpid() else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        if let info = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == app.processIdentifier
                                         && $0[kCGWindowLayer as String] as? Int == 0 }),
           let id = info[kCGWindowNumber as String] as? Int {
            SkyLight.focus(pid: app.processIdentifier, window: CGWindowID(id))
        }
    }

    /// Opens a URL as a real tab (Arc would otherwise show external links in its "Little Arc" popup).
    static func openURL(_ url: URL) async {
        let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        if !Background.active, browser?.lastPathComponent == "Arc.app" {
            let script = "tell application \"Arc\" to tell front window to make new tab with properties {URL:\"\(url.absoluteString)\"}\ntell application \"Arc\" to activate"
            if await Shell.run("/usr/bin/osascript", ["-e", script]).status == 0 { return }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = !Background.active
        if let browser {
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func find(named name: String) -> URL? {
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "\(fm.homeDirectoryForCurrentUser.path)/Applications", "/Applications/Utilities"]
        var fuzzy: URL?
        for dir in dirs {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                let base = item.dropLast(4).lowercased()
                if base == name { return URL(fileURLWithPath: "\(dir)/\(item)") }
                if fuzzy == nil, name.count >= 3, base.hasPrefix(name) || base.contains(name) {
                    fuzzy = URL(fileURLWithPath: "\(dir)/\(item)")
                }
            }
        }
        return fuzzy
    }
}

/// Runs a command off the main thread with a time limit.
enum Shell {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) async -> (status: Int32, output: String) {
        await ProcessRunner.run(path, args, timeout: timeout)
    }
}
