import AppKit

/// CDP connection to a browser owned by Clinqy. No accessibility, global keyboard or foreground-window fallback.
@MainActor
final class WorkerCDP {
    private let socket: URLSessionWebSocketTask
    private var receiveTask: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    var lastChooser: [String: Any]?
    /// Cross-process (out-of-process) iframes are separate targets: frameId -> flattened session id.
    private(set) var sessions: [String: String] = [:]
    /// JS dialogs and downloads the page raised, with the decision made, drained into the next command result.
    var events: [[String: Any]] = []
    var dialogDecision: (accept: Bool, text: String?)?
    private(set) var contextRevision = 0
    private(set) var connected = true

    init(url: URL, session: URLSession) {
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 32 * 1024 * 1024
        socket.resume()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await self.socket.receive()
                    let data: Data
                    switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                    guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let id = body["id"] as? Int, let waiter = self.pending.removeValue(forKey: id) {
                        self.timeouts.removeValue(forKey: id)?.cancel()
                        if let error = body["error"] as? [String: Any] { waiter.resume(throwing: Self.error(error["message"] as? String ?? "Chrome command failed")) }
                        else { waiter.resume(returning: body["result"] as? [String: Any] ?? [:]) }
                    } else if let method = body["method"] as? String {
                        if method == "Page.fileChooserOpened" {
                            self.lastChooser = body["params"] as? [String: Any]
                            self.record(["kind": "fileChooser", "mode": (body["params"] as? [String: Any])?["mode"] ?? "", "state": "intercepted"])
                        }
                        self.handlePageEvent(method, body["params"] as? [String: Any] ?? [:], session: body["sessionId"] as? String)
                        if ["Runtime.executionContextsCleared", "Runtime.executionContextDestroyed", "Page.frameNavigated", "Page.frameAttached", "Page.frameDetached"].contains(method) {
                            self.contextRevision += 1
                        }
                    }
                }
            } catch { self.close() }
        }
    }
    func record(_ event: [String: Any]) {
        var e = event; e["at"] = Int(Date().timeIntervalSince1970 * 1000)
        events.append(e)
        if events.count > 50 { events.removeFirst() }
    }
    func drainEvents() -> [[String: Any]] { defer { events.removeAll() }; return events }

    private func handlePageEvent(_ method: String, _ params: [String: Any], session: String?) {
        switch method {
        case "Target.attachedToTarget":
            if let info = params["targetInfo"] as? [String: Any], info["type"] as? String == "iframe",
               let id = info["targetId"] as? String, let sessionID = params["sessionId"] as? String {
                sessions[id] = sessionID; contextRevision += 1
                // Frames nested inside this one that live in yet another process attach through this session.
                Task { [weak self] in
                    _ = try? await self?.call("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true], timeout: 3, session: sessionID)
                    _ = try? await self?.call("Page.enable", timeout: 3, session: sessionID)
                }
            }
        case "Target.detachedFromTarget":
            if let sessionID = params["sessionId"] as? String { sessions = sessions.filter { $0.value != sessionID }; contextRevision += 1 }
        case "Page.javascriptDialogOpening":
            // Nothing is confirmed for the user by default: alerts have one answer, leaving a page is what navigation
            // asked for, confirm/prompt are dismissed unless the task set a decision. Every dialog is reported.
            let type = params["type"] as? String ?? ""
            let explicit = dialogDecision; dialogDecision = nil
            let accept = explicit?.accept ?? (type == "alert" || type == "beforeunload")
            record(["kind": "dialog", "type": type, "message": String((params["message"] as? String ?? "").prefix(500)),
                    "decision": accept ? "accepted" : "dismissed", "basis": explicit == nil ? "default" : "explicit"])
            var answer: [String: Any] = ["accept": accept]
            if let text = explicit?.text { answer["promptText"] = text }
            Task { [weak self] in
                do { _ = try await self?.call("Page.handleJavaScriptDialog", answer, timeout: 3, session: session) }
                catch { self?.record(["kind": "dialog", "decision": "unanswered", "error": error.localizedDescription]) }
            }
        case "Browser.downloadWillBegin", "Page.downloadWillBegin":
            record(["kind": "download", "phase": "started", "guid": params["guid"] ?? "", "url": params["url"] ?? "", "filename": params["suggestedFilename"] ?? ""])
        case "Browser.downloadProgress", "Page.downloadProgress":
            if let state = params["state"] as? String, state != "inProgress" {
                record(["kind": "download", "phase": state, "guid": params["guid"] ?? "", "bytes": params["totalBytes"] ?? params["receivedBytes"] ?? 0])
            }
        default: break
        }
    }
    static func error(_ text: String) -> NSError { NSError(domain: "ChromeWorker", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    func call(_ method: String, _ parameters: [String: Any] = [:], timeout: Double = 12, session: String? = nil) async throws -> [String: Any] {
        guard connected else { throw Self.error("The Chrome worker disconnected. No other browser will be used.") }
        nextID += 1
        let id = nextID
        var envelope: [String: Any] = ["id": id, "method": method, "params": parameters]
        if let session { envelope["sessionId"] = session }
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let closing = ["Browser.close", "Target.closeTarget"].contains(method)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { done in
                guard closing || !Task.isCancelled else { done.resume(throwing: CancellationError()); return }
                pending[id] = done
                Task { [weak self] in
                    guard let self, self.pending[id] != nil else { return }
                    do { try await self.socket.send(.string(String(decoding: data, as: UTF8.self))) }
                    catch {
                        self.timeouts.removeValue(forKey: id)?.cancel()
                        self.pending.removeValue(forKey: id)?.resume(throwing: error)
                    }
                }
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.timeouts.removeValue(forKey: id)
                    self?.pending.removeValue(forKey: id)?.resume(throwing: Self.error("Chrome worker command timed out: " + method))
                }
            }
        } onCancel: {
            if !closing { Task { @MainActor [weak self] in
                self?.timeouts.removeValue(forKey: id)?.cancel()
                self?.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
            } }
        }
    }
    func close() {
        connected = false
        socket.cancel(with: .goingAway, reason: nil)
        receiveTask?.cancel(); receiveTask = nil
        for timeout in timeouts.values { timeout.cancel() }
        timeouts.removeAll()
        let waiters = pending.values; pending.removeAll()
        for waiter in waiters { waiter.resume(throwing: Self.error("Chrome worker disconnected")) }
    }
}

@MainActor
final class ChromeWorker {
    private static let primary = ChromeWorker()
    static var shared: ChromeWorker {
        guard let context = TaskExecution.current else { return primary }
        return context.service(ChromeWorker.self) {
            ChromeWorker(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clinqy/BrowserJobs/" + context.id.uuidString))
        }
    }
    var identity: ObjectIdentifier { ObjectIdentifier(self) }
    private let root: URL
    private let scriptURL: URL?
    private let executable: URL
    private let session: URLSession
    private var process: Process?
    private var browser: WorkerCDP?
    private var starting: Task<Void, Error>?
    private(set) var loginMode = false
    private var nextTab = 1_000_000
    private var tabs: [Int: Tab] = [:]
    private var selected: Int?
    private var cachedPageScript: String?
    /// Tabs whose page is frozen (scripts, timers and animations stopped) because no run is using them.
    private var frozen: Set<Int> = []
    /// Commands under way per tab; a tab is never frozen in the middle of one.
    private var inFlight: [Int: Int] = [:]
    /// Bumped when a background run starts, so the previous run's late cleanup leaves the new run's tabs alone.
    private(set) var generation = 0
    private var runActive = false
    private var idleStop: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    /// An idle worker is quit after this long; its profile (and sign-ins) stay on disk for the next run.
    static let idleLifetime: Duration = .seconds(600)
    private(set) var headless = true
    var connected: Bool { browser?.connected == true }
    var app: NSRunningApplication? { process.flatMap { NSRunningApplication(processIdentifier: $0.processIdentifier) } }

    /// Where a frame's content sits in the top page's coordinates: origin plus the CSS scale applied to it (and to
    /// every ancestor). Rotated or skewed frames have no such placement and are refused, never guessed at.
    struct Placement: Equatable {
        var x = 0.0, y = 0.0, sx = 1.0, sy = 1.0
        static let identity = Placement()
        func point(_ px: Double, _ py: Double) -> CGPoint { CGPoint(x: x + px * sx, y: y + py * sy) }
        func moved(from other: Placement, tolerance: Double = 0.5) -> Bool {
            abs(x - other.x) > tolerance || abs(y - other.y) > tolerance || abs(sx - other.sx) > 0.01 || abs(sy - other.sy) > 0.01
        }
        /// A child's box (in its parent's local coordinates, with its own scale) composed onto this placement.
        func composing(localX: Double, localY: Double, scaleX: Double, scaleY: Double) -> Placement {
            let origin = point(localX, localY)
            return Placement(x: origin.x, y: origin.y, sx: sx * scaleX, sy: sy * scaleY)
        }
        /// Placement from a DOM.getBoxModel content quad (corner order: top-left, top-right, bottom-right, bottom-left)
        /// and the element's unscaled layout size. Nil when the quad is rotated or skewed.
        /// `content` positions the frame's viewport; the larger `border` quad against the layout width/height gives the scale.
        static func fromQuad(content q: [Double], border b: [Double], width: Double, height: Double) -> Placement? {
            guard q.count >= 8, b.count >= 8, width > 0, height > 0 else { return nil }
            for quad in [q, b] {
                guard abs(quad[3] - quad[1]) <= 0.5, abs(quad[6] - quad[0]) <= 0.5 else { return nil }   // rotated or skewed
            }
            let sx = hypot(b[2] - b[0], b[3] - b[1]) / width, sy = hypot(b[6] - b[0], b[7] - b[1]) / height
            return Placement(x: q[0], y: q[1], sx: abs(sx - 1) < 0.005 ? 1 : sx, sy: abs(sy - 1) < 0.005 ? 1 : sy)
        }
    }
    private struct Element { let frame: String; let local: Int; let offset: Placement }
    private final class Tab {
        let target: String
        let cdp: WorkerCDP
        var commandActive = false
        var commandWaiters: [CheckedContinuation<Void, Never>] = []
        var elements: [Int: Element] = [:]
        var keys: [String: Int] = [:]
        var nextElement = 0
        var page = ""
        var documentID: String?
        var snapshotID: String?
        var frameTokens: [String: [String: Any]] = [:]
        var frames: [String] = []
        var parents: [String: String] = [:]
        var unreadable: [[String: String]] = []
        var focusedFrame: String?
        var incomplete = false
        var uploads: [URL] = []
        var helperContexts: [String: Int] = [:]
        var contextRevision = -1
        var frameRevision = -1
        var finalCapture: String?
        var finalCaptureTask: Task<String?, Never>?
        var freezeGeneration: Int?
        init(target: String, cdp: WorkerCDP) { self.target = target; self.cdp = cdp }
    }

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clinqy/ChromeWorker"),
         executable: URL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), scriptURL: URL? = nil) {
        self.root = root; self.executable = executable; self.scriptURL = scriptURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    func start() async throws {
        guard !loginMode else { throw WorkerCDP.error("Finish signing in to Worker Chrome from Clinqy's menu before starting background web tasks.") }
        idleStop?.cancel(); idleStop = nil
        if let stopping { await stopping.value }
        if connected { return }
        if let starting { return try await starting.value }
        let task = Task { try await launch(headless: true) }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch(headless: Bool) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw WorkerCDP.error("Install Google Chrome to use background web tasks.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let portFile = root.appendingPathComponent("DevToolsActivePort")
        // Never attach to an old browser or a normal Chrome session merely because its endpoint file exists.
        guard process?.isRunning != true else { throw WorkerCDP.error("The owned Chrome process is still starting or unavailable. Finish worker sign-in or restart Clinqy before retrying.") }
        try await closeOrphan(allowHeaded: !headless)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("Uploads"))
        try? FileManager.default.removeItem(at: portFile)
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--user-data-dir=" + root.path, "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
                           "--no-first-run", "--no-default-browser-check", "--disable-background-mode", "--window-size=1440,900"]
            + (headless ? ["--headless=new"] : ["about:blank"])
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); process = child; self.headless = headless
        for _ in 0..<150 {
            try Task.checkCancellation()
            guard child.isRunning else { throw WorkerCDP.error("Worker Chrome exited before it was ready. Your normal Chrome session was not used.") }
            if let text = try? String(contentsOf: portFile, encoding: .utf8), let port = Int(text.split(separator: "\n").first ?? ""),
               let url = URL(string: "http://127.0.0.1:\(port)/json/version"),
               let (data, _) = try? await session.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let address = json["webSocketDebuggerUrl"] as? String, let socketURL = URL(string: address),
               ["127.0.0.1", "localhost"].contains(socketURL.host ?? "") {
                let connection = WorkerCDP(url: socketURL, session: session)
                _ = try await connection.call("Browser.getVersion")
                browser = connection
                let owner: [String: Any] = ["pid": child.processIdentifier, "socket": socketURL.absoluteString, "headless": headless]
                let ownerFile = root.appendingPathComponent("owner.json")
                try JSONSerialization.data(withJSONObject: owner).write(to: ownerFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownerFile.path)
                let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
                try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                _ = try await connection.call("Browser.setDownloadBehavior", ["behavior": "allow", "downloadPath": downloads.path, "eventsEnabled": true])
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        child.terminate()
        throw WorkerCDP.error("Worker Chrome didn't become ready. Your normal Chrome session was not used.")
    }

    /// After a Clinqy crash, close only a Chrome process whose binary, profile argument and recorded endpoint all match.
    /// Old task targets are discarded; nothing from an interrupted run is executed.
    private func closeOrphan(allowHeaded: Bool) async throws {
        let file = root.appendingPathComponent("owner.json")
        guard let data = try? Data(contentsOf: file), let owner = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = owner["pid"] as? Int32, let address = owner["socket"] as? String, let url = URL(string: address),
              ["127.0.0.1", "localhost"].contains(url.host ?? "") else { return }
        let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "command="]
        let output = Pipe(); ps.standardOutput = output; ps.standardError = FileHandle.nullDevice
        try ps.run()
        let command = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()
        guard command.contains(executable.path), command.contains("--user-data-dir=" + root.path), command.contains("--remote-debugging-port=0") else {
            try? FileManager.default.removeItem(at: file); return
        }
        guard allowHeaded || owner["headless"] as? Bool == true else { throw WorkerCDP.error("Worker Chrome sign-in was interrupted. Open Worker Chrome from Clinqy's menu, then finish sign-in before starting a task.") }
        let orphan = WorkerCDP(url: url, session: session)
        _ = try? await orphan.call("Browser.close", timeout: 3)
        orphan.close()
        for _ in 0..<30 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try? FileManager.default.removeItem(at: file)
    }

    func openLogin() async throws {
        await stop()
        loginMode = true
        do {
            try await launch(headless: false)
            guard let browser else { throw WorkerCDP.error("Worker Chrome didn't start") }
            let targets = try await browser.call("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
            if let target = targets.first(where: { $0["type"] as? String == "page" })?["targetId"] as? String {
                _ = try await browser.call("Target.activateTarget", ["targetId": target])
            }
            app?.activate()
        } catch { loginMode = false; throw error }
    }
    func finishLogin() async { await stop(); loginMode = false }
    func shutdown() {
        for tab in tabs.values { tab.cdp.close() }
        tabs.removeAll(); selected = nil; frozen.removeAll()
        idleStop?.cancel(); idleStop = nil
        browser?.close(); browser = nil
        if let process, process.isRunning { process.terminate() }
    }

    /// A background run finished: close every tab but the one its result shows, freeze that one so its page stops
    /// using CPU, and quit Chrome if nothing needs it for a while.
    func runStarted() {
        generation += 1
        runActive = true
        cachedPageScript = nil // Development helper changes take effect on the next run.
        for (id, tab) in tabs where tab.finalCaptureTask != nil {
            tab.finalCaptureTask = nil
            tab.freezeGeneration = nil
            frozen.remove(id)
        }
        idleStop?.cancel(); idleStop = nil
    }

    func runEnded(keep: Int?, generation run: Int) async {
        guard run == generation else { return }
        runActive = false
        guard !loginMode, browser != nil else { return }
        for (id, tab) in tabs where id != keep {
            guard run == generation else { return }
            // Retire the tab before yielding: a new run must not acquire one being closed.
            tabs.removeValue(forKey: id)
            frozen.remove(id)
            _ = try? await browser?.call("Target.closeTarget", ["targetId": tab.target], timeout: 3)
            tab.cdp.close()
            for url in tab.uploads { try? FileManager.default.removeItem(at: url) }
        }
        guard run == generation else { return }
        if selected.map({ tabs[$0] == nil }) ?? false { selected = keep }
        if let keep { await freeze(keep, generation: run) }
        guard run == generation else { return }
        scheduleIdleStop()
    }

    /// Only between runs, and never under a command. Marked first, so a command that arrives meanwhile thaws it
    /// (CDP handles one connection's calls in order).
    private func freeze(_ id: Int, generation run: Int) async {
        guard run == generation, !runActive, inFlight[id, default: 0] == 0,
              let tab = tabs[id], tab.cdp.connected, !frozen.contains(id) else { return }
        frozen.insert(id)
        tab.freezeGeneration = run
        // Chrome may resume page timers to service captureScreenshot. Capture once BEFORE freezing;
        // final previews/exports subsequently return these bytes without touching the renderer.
        let capture = Task { [cdp = tab.cdp] in
            (try? await cdp.call("Page.captureScreenshot", ["format": "png", "captureBeyondViewport": false]))?["data"] as? String
        }
        tab.finalCaptureTask = capture
        let image = await capture.value
        guard tab.freezeGeneration == run else { return }
        tab.finalCaptureTask = nil
        guard run == generation, !runActive, inFlight[id, default: 0] == 0, tab.cdp.connected else {
            frozen.remove(id)
            return
        }
        tab.finalCapture = image
        if (try? await tab.cdp.call("Page.setWebLifecycleState", ["state": "frozen"], timeout: 3)) == nil,
           run == generation, tab.freezeGeneration == run { frozen.remove(id) }
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: Self.idleLifetime)
            guard let self, !Task.isCancelled, !self.runActive, !self.loginMode, self.inFlight.isEmpty else { return }
            let stop = Task { await self.stop() }
            self.stopping = stop
            await stop.value
            self.stopping = nil
        }
    }

    func stop() async {
        idleStop?.cancel(); idleStop = nil
        frozen.removeAll()
        if let browser { _ = try? await browser.call("Browser.close", timeout: 3) }
        for tab in tabs.values { tab.cdp.close(); for url in tab.uploads { try? FileManager.default.removeItem(at: url) } }
        tabs.removeAll(); selected = nil
        browser?.close(); browser = nil
        if let process {
            for _ in 0..<30 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate() }
        }
        process = nil
    }

    func newTab(_ url: String, select: Bool = true) async throws -> Int {
        try await start()
        guard let browser else { throw WorkerCDP.error("Chrome worker is not connected") }
        let result = try await browser.call("Target.createTarget", ["url": url, "background": true])
        guard let target = result["targetId"] as? String else { throw WorkerCDP.error("Chrome didn't return a task target") }
        do {
            // Resolve the owned target's WebSocket via this process's loopback endpoint.
            let portText = try String(contentsOf: root.appendingPathComponent("DevToolsActivePort"), encoding: .utf8)
            guard let port = portText.split(separator: "\n").first,
                  let address = URL(string: "http://127.0.0.1:\(port)/json/list") else { throw WorkerCDP.error("Missing worker endpoint") }
            let (data, _) = try await session.data(from: address)
            let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            guard let socket = targets.first(where: { $0["id"] as? String == target })?["webSocketDebuggerUrl"] as? String,
                  let url = URL(string: socket), ["127.0.0.1", "localhost"].contains(url.host ?? "") else { throw WorkerCDP.error("The worker's own page endpoint is unavailable") }
            let connection = WorkerCDP(url: url, session: session)
            _ = try await connection.call("Page.enable")
            _ = try await connection.call("Runtime.enable")
            _ = try await connection.call("Page.setInterceptFileChooserDialog", ["enabled": true])
            // Cross-origin iframes live in their own processes; flattened auto-attach gives each a session to read it through.
            _ = try await connection.call("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true])
            _ = try await connection.call("Emulation.setDeviceMetricsOverride", ["width": 1440, "height": 900, "deviceScaleFactor": 1, "mobile": false])
            nextTab += 1
            tabs[nextTab] = Tab(target: target, cdp: connection)
            if select { selected = nextTab }
            return nextTab
        } catch {
            // A cancellation or attachment failure after createTarget mustn't leave an untracked page running.
            _ = try? await browser.call("Target.closeTarget", ["targetId": target], timeout: 3)
            throw error
        }
    }

    /// Runs one command; page-initiated events (dialogs and their decisions, file choosers, downloads) and the
    /// freshness of any screenshot travel back with the result.
    func command(_ command: String, tabID: Int?, args: [String: Any] = [:]) async throws -> [String: Any] {
        var out = try await run(command, tabID: tabID, args: args)
        guard let id = tabID, let tab = tabs[id] else { return out }
        var events = tab.cdp.drainEvents()
        if let browser { events += browser.drainEvents().filter { $0["kind"] as? String == "download" } }
        if !events.isEmpty, out["events"] == nil { out["events"] = events }
        if ["captureTask", "capturePreview", "captureVision"].contains(command) {
            out["capturedAt"] = Int(Date().timeIntervalSince1970 * 1000); out["coverage"] = "viewport"
            if let d = tab.documentID, let s = tab.snapshotID { out["documentID"] = d; out["snapshotID"] = s }
            out["fromFrozenCapture"] = !runActive && command != "captureVision" && frozen.contains(id)
        }
        return out
    }

    private func run(_ command: String, tabID: Int?, args: [String: Any]) async throws -> [String: Any] {
        if command == "newTab" { return ["id": try await newTab(args["url"] as? String ?? "about:blank")] }
        if command == "tabs" {
            var result: [[String: Any]] = []
            for id in tabs.keys.sorted() {
                if let info = try? await self.command("tabInfo", tabID: id) { result.append(info.merging(["opened": true, "active": id == selected]) { _, new in new }) }
            }
            return ["tabs": result]
        }
        guard let id = tabID, let tab = tabs[id], tab.cdp.connected else { throw WorkerCDP.error("The owned worker tab is gone. No foreground tab will be used.") }
        if tab.commandActive { await withCheckedContinuation { tab.commandWaiters.append($0) } }
        else { tab.commandActive = true }
        defer {
            if tab.commandWaiters.isEmpty { tab.commandActive = false }
            else { tab.commandWaiters.removeFirst().resume() }
        }
        // Work whose caller was cancelled while it waited its turn never reaches the page.
        try Task.checkCancellation()
        guard tabs[id] === tab, tab.cdp.connected else { throw WorkerCDP.error("The queued worker tab is no longer available") }
        inFlight[id, default: 0] += 1
        idleStop?.cancel(); idleStop = nil
        // Used outside a run (a preview, a Telegram screenshot): back to sleep afterwards.
        let run = generation
        defer {
            inFlight[id, default: 1] -= 1
            if inFlight[id] == 0 { inFlight.removeValue(forKey: id) }
            if !runActive { Task { await freeze(id, generation: run); if !runActive { scheduleIdleStop() } } }
        }
        let captureOnly = !runActive && (command == "captureTask" || command == "capturePreview")
        if captureOnly {
            var image = tab.finalCapture
            if image == nil, let capture = tab.finalCaptureTask { image = await capture.value }
            if let image, !image.isEmpty {
                return ["image": image, "tabId": id]
            }
            if frozen.contains(id) { throw WorkerCDP.error("The final task screenshot is unavailable. Start a task to refresh the page.") }
        } else { tab.finalCapture = nil; tab.freezeGeneration = nil }
        if !captureOnly, frozen.contains(id) {
            _ = try await tab.cdp.call("Page.setWebLifecycleState", ["state": "active"], timeout: 3)
            frozen.remove(id)
        }
        let unguarded: Set<String> = ["dialogPolicy", "switchTab", "closeTab", "tabInfo", "navigate", "goBack", "captureTask", "capturePreview", "captureVision", "snapshot"]
        if !unguarded.contains(command) {
            guard let documentID = tab.documentID, let snapshotID = tab.snapshotID,
                  args["documentID"] as? String == documentID, args["snapshotID"] as? String == snapshotID,
                  let top = tab.frames.first else { throw WorkerCDP.error("Stale browser observation. Take a new look before acting.") }
            _ = try await call(tab, frame: top, function: "check")
            if ["cdpKey", "cdpType", "cdpScroll"].contains(command) {
                // Trusted input routes through the browser's live focus/hit testing. A top-document token
                // alone cannot authorize input after an embedded document was replaced or added.
                let observed = tab.frames
                try await collectFrames(tab)
                guard !tab.incomplete, Set(tab.frames) == Set(observed) else {
                    tab.frames = observed
                    throw WorkerCDP.error("The embedded frame set changed or is unreadable. Take a new look before input.")
                }
                for frame in tab.frames { _ = try await call(tab, frame: frame, function: "check") }
            }
            if command == "cdpClick", let index = args["index"] as? Int {
                guard let element = tab.elements[index] else { throw WorkerCDP.error("The click target is stale. Take a new look.") }
                let liveOffset = try await placement(element.frame, tab: tab)
                guard !liveOffset.moved(from: element.offset) else {
                    throw WorkerCDP.error("The embedded frame moved. Take a new look before clicking.")
                }
                let located = try await call(tab, frame: element.frame, function: "locate", args: [element.local])
                guard located["hit"] as? Bool == true, located["still"] as? Bool == true,
                      let x = (args["x"] as? NSNumber)?.doubleValue, let y = (args["y"] as? NSNumber)?.doubleValue,
                      let px = (located["px"] as? NSNumber)?.doubleValue, let py = (located["py"] as? NSNumber)?.doubleValue,
                      abs(x - element.offset.point(px, py).x) <= 2, abs(y - element.offset.point(px, py).y) <= 2 else {
                    throw WorkerCDP.error("The click target moved or was covered. Take a new look.")
                }
            }
        }
        switch command {
        case "dialogPolicy":
            tab.cdp.dialogDecision = args["clear"] as? Bool == true ? nil : (args["accept"] as? Bool == true, args["text"] as? String)
            return ["dialogPolicy": args["clear"] as? Bool == true ? NSNull() : ["accept": args["accept"] as? Bool == true]]
        case "switchTab": selected = id; return ["id": id] // logical selection only; never activate a host window
        case "closeTab":
            _ = try await browser?.call("Target.closeTarget", ["targetId": tab.target]); tab.cdp.close(); for url in tab.uploads { try? FileManager.default.removeItem(at: url) }; tabs.removeValue(forKey: id)
            return ["closed": id]
        case "tabInfo":
            let info = try await evaluate(tab, expression: "({url:location.href,title:document.title,ready:document.readyState})")
            return (info as? [String: Any] ?? [:]).merging(["id": id, "focused": false]) { _, new in new }
        case "navigate": _ = try await tab.cdp.call("Page.navigate", ["url": args["url"] as? String ?? "about:blank"]); return ["ok": true]
        case "goBack":
            let history = try await tab.cdp.call("Page.getNavigationHistory")
            if let index = history["currentIndex"] as? Int, index > 0, let entries = history["entries"] as? [[String: Any]], let entry = entries[index - 1]["id"] {
                _ = try await tab.cdp.call("Page.navigateToHistoryEntry", ["entryId": entry])
            }
            return ["ok": true]
        case "captureTask": return ["image": try await tab.cdp.call("Page.captureScreenshot", ["format": "png", "captureBeyondViewport": false])["data"] ?? "", "tabId": id]
        case "capturePreview":
            return ["image": try await tab.cdp.call("Page.captureScreenshot", ["format": "jpeg", "quality": 70,
                           "optimizeForSpeed": true, "captureBeyondViewport": false])["data"] ?? "", "tabId": id]
        case "captureVision":
            return ["image": try await tab.cdp.call("Page.captureScreenshot", ["format": "jpeg", "quality": 85,
                           "optimizeForSpeed": true, "captureBeyondViewport": false])["data"] ?? "", "tabId": id]
        case "snapshot": return try await snapshot(tab, id: id)
        case "cdpType": _ = try await tab.cdp.call("Input.insertText", ["text": args["text"] as? String ?? ""]); return ["typed": true]
        case "cdpGesture":
            guard let raw = args["gesture"] as? String, let kind = PointerGesture.Kind(rawValue: raw),
                  let index = args["index"] as? Int else { throw WorkerCDP.error("gesture and source index are required") }
            func point(_ index: Int) async throws -> PointerGesture.Point {
                guard let element = tab.elements[index] else { throw WorkerCDP.error("Gesture target is stale") }
                let liveOffset = try await placement(element.frame, tab: tab)
                guard !liveOffset.moved(from: element.offset) else {
                    throw WorkerCDP.error("Gesture frame moved; observe again")
                }
                let spot = try await call(tab, frame: element.frame, function: "locate", args: [element.local, false])
                guard spot["hit"] as? Bool == true, spot["still"] as? Bool == true,
                      let x = (spot["px"] as? NSNumber)?.doubleValue, let y = (spot["py"] as? NSNumber)?.doubleValue else {
                    throw WorkerCDP.error("Gesture target moved or is covered; observe again")
                }
                let top = liveOffset.point(x, y)
                return .init(x: top.x, y: top.y)
            }
            // Resolve the destination first: locating it must never invalidate the source by scrolling.
            let destination: PointerGesture.Point?
            if kind == .drag {
                guard let index = args["toIndex"] as? Int else { throw WorkerCDP.error("drag needs a destination index") }
                destination = try await point(index)
            } else { destination = nil }
            let source = try await point(index)
            guard let plan = PointerGesture(kind: kind, start: source, end: destination) else { throw WorkerCDP.error("Invalid gesture coordinates") }
            var held = false
            var last = source
            let route = try await inputMap(tab, frame: tab.elements[index]?.frame)
            func routed(_ cdp: [String: Any]) -> [String: Any] {
                var event = cdp
                if let x = (cdp["x"] as? NSNumber)?.doubleValue, let y = (cdp["y"] as? NSNumber)?.doubleValue {
                    event["x"] = (x - route.place.x) / route.place.sx; event["y"] = (y - route.place.y) / route.place.sy
                }
                return event
            }
            do {
                for event in plan.events {
                    try Task.checkCancellation()
                    if event.phase == .down { held = true }
                    last = event.point
                    _ = try await tab.cdp.call("Input.dispatchMouseEvent", routed(event.cdp), session: route.session)
                    if event.phase == .up { held = false }
                    if kind == .drag { try await Task.sleep(for: .milliseconds(20)) }
                }
            } catch {
                if held {
                    _ = try? await tab.cdp.call("Input.dispatchMouseEvent", routed(["type": "mouseReleased", "x": last.x, "y": last.y,
                        "button": kind == .right_click ? "right" : "left", "buttons": 0, "clickCount": 1]), session: route.session)
                }
                throw error
            }
            return ["delivered": true, "verified": false]
        case "cdpClick":
            let (session, spot) = try await inputTarget(tab, frame: (args["index"] as? Int).flatMap { tab.elements[$0]?.frame },
                                                         x: (args["x"] as? NSNumber)?.doubleValue ?? 0, y: (args["y"] as? NSNumber)?.doubleValue ?? 0)
            func mouse(_ type: String, _ button: String, _ buttons: Int, _ count: Int?) async throws {
                var event: [String: Any] = ["type": type, "button": button, "buttons": buttons, "x": spot.x, "y": spot.y]
                if let count { event["clickCount"] = count }
                _ = try await tab.cdp.call("Input.dispatchMouseEvent", event, session: session)
            }
            try await mouse("mouseMoved", "none", 0, nil)
            for count in 1...max(1, args["count"] as? Int ?? 1) {
                try await mouse("mousePressed", "left", 1, count)
                try await mouse("mouseReleased", "left", 0, count)
            }
            return ["clicked": true]
        case "cdpScroll":
            _ = try await tab.cdp.call("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": args["x"] ?? 200, "y": args["y"] ?? 200, "deltaX": 0, "deltaY": args["dy"] ?? 0]); return ["scrolled": true]
        case "cdpKey": return try await key(args["keys"] as? String ?? "", tab: tab)
        default: return try await pageCommand(command, tab: tab, args: args)
        }
    }

    private func pageScript() throws -> String {
        if let cachedPageScript { return cachedPageScript }
        let candidates = [scriptURL, Bundle.main.resourceURL?.appendingPathComponent("extension/page.js"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("extension/page.js")].compactMap { $0 }
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw WorkerCDP.error("The worker's page helpers are missing. Rebuild Clinqy.") }
        let script = try String(contentsOf: source, encoding: .utf8)
        cachedPageScript = script
        return script
    }
    private func evaluate(_ tab: Tab, expression: String, context: Int? = nil, frame: String? = nil) async throws -> Any {
        var args: [String: Any] = ["expression": expression, "returnByValue": true, "awaitPromise": true, "userGesture": true]
        if let context { args["contextId"] = context }
        let result = try await tab.cdp.call("Runtime.evaluate", args, timeout: 20, session: frame.flatMap { session(for: $0, tab: tab) })
        if let details = result["exceptionDetails"] as? [String: Any] {
            let description = (details["exception"] as? [String: Any])?["description"] as? String ?? ""
            if description.contains("this page has no file upload field") {
                throw WorkerCDP.error("this page has no file upload field (it may use its own picker, e.g. Google Drive)")
            }
            if description.contains("ambiguous file upload fields") { throw WorkerCDP.error("ambiguous file upload fields; choose the exact input") }
            throw WorkerCDP.error("The worker page operation failed. Take a fresh look before retrying.")
        }
        return (result["result"] as? [String: Any])?["value"] ?? NSNull()
    }
    private func call(_ tab: Tab, frame: String, function: String, args: [Any] = []) async throws -> [String: Any] {
        if tab.contextRevision != tab.cdp.contextRevision {
            tab.helperContexts.removeAll()
            tab.contextRevision = tab.cdp.contextRevision
        }
        let encoded = String(data: try JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]), encoding: .utf8)!
        let expression: String
        if function == "snapshot" { expression = "window.__clinqy.snapshot()" }
        else {
            guard let token = tab.frameTokens[frame] else { throw WorkerCDP.error("Take a fresh snapshot of this frame before acting") }
            let expected = String(data: try JSONSerialization.data(withJSONObject: token), encoding: .utf8)!
            expression = "window.__clinqy.invoke(\"\(function)\",\(encoded),\(expected))"
        }
        if let cached = tab.helperContexts[frame] {
            do { return try await evaluate(tab, expression: expression, context: cached, frame: frame) as? [String: Any] ?? [:] }
            // The page navigated before Chrome's event arrived: the helper never ran, so a fresh one can.
            catch where error.localizedDescription.contains("Cannot find context") { tab.helperContexts[frame] = nil }
        }
        // A cross-process iframe is reached through its own session; its attach event can trail the frame tree briefly.
        var result: [String: Any]
        do { result = try await tab.cdp.call("Page.createIsolatedWorld", ["frameId": frame, "worldName": "ClinqyWorker"], session: session(for: frame, tab: tab)) }
        catch {
            var attached: String?
            for _ in 0..<10 where attached == nil && frame != tab.frames.first {
                try await Task.sleep(for: .milliseconds(100)); attached = session(for: frame, tab: tab)
            }
            guard let attached else { throw error }
            result = try await tab.cdp.call("Page.createIsolatedWorld", ["frameId": frame, "worldName": "ClinqyWorker"], session: attached)
        }
        guard let context = result["executionContextId"] as? Int else { throw WorkerCDP.error("An embedded frame isn't available to this worker") }
        _ = try await evaluate(tab, expression: try pageScript(), context: context, frame: frame)
        tab.helperContexts[frame] = context
        return try await evaluate(tab, expression: expression, context: context, frame: frame) as? [String: Any] ?? [:]
    }
    private func frameList(_ tree: [String: Any]) -> [String] {
        var ids = [(tree["frame"] as? [String: Any])?["id"] as? String].compactMap { $0 }
        for child in tree["childFrames"] as? [[String: Any]] ?? [] { ids += frameList(child) }
        return ids
    }
    /// Where to send pointer input for a point given in top-page coordinates. Input to a cross-process iframe goes to
    /// its own session in that process's coordinates (the page-level router does not forward into it in every mode);
    /// everything else goes to the page at the top-page coordinates, as before.
    private func inputMap(_ tab: Tab, frame: String?) async throws -> (session: String?, place: Placement) {
        guard let frame, let session = session(for: frame, tab: tab) else { return (nil, .identity) }
        var root = frame
        while tab.cdp.sessions[root] == nil, let up = tab.parents[root] { root = up }
        return (session, try await placement(root, tab: tab))
    }
    private func inputTarget(_ tab: Tab, frame: String?, x: Double, y: Double) async throws -> (String?, CGPoint) {
        let (session, place) = try await inputMap(tab, frame: frame)
        return (session, CGPoint(x: (x - place.x) / place.sx, y: (y - place.y) / place.sy))
    }
    /// The CDP session that owns `frame`: its own when it is a process root (cross-process iframe), else its nearest such ancestor's.
    private func session(for frame: String, tab: Tab) -> String? {
        var current: String? = frame
        while let f = current, f != tab.frames.first {
            if let s = tab.cdp.sessions[f] { return s }
            current = tab.parents[f]
        }
        return nil
    }
    /// Every frame of the page, cross-process ones included. Page.getFrameTree on the page omits iframes that live in
    /// another process, so each attached iframe session reports its own subtree and its parent frame.
    private func collectFrames(_ tab: Tab) async throws {
        guard let tree = try await tab.cdp.call("Page.getFrameTree")["frameTree"] as? [String: Any] else { throw WorkerCDP.error("Chrome returned no page frame") }
        var frames = frameList(tree), parents: [String: String] = [:]
        parentMap(tree, into: &parents)
        for (rootID, session) in tab.cdp.sessions.sorted(by: { $0.key < $1.key }) where !frames.contains(rootID) {
            guard let sub = (try? await tab.cdp.call("Page.getFrameTree", timeout: 3, session: session))?["frameTree"] as? [String: Any],
                  let root = sub["frame"] as? [String: Any], root["id"] as? String == rootID, let parent = root["parentId"] as? String,
                  frames.contains(parent) || parents[parent] != nil else { continue }
            frames += frameList(sub)
            parentMap(sub, into: &parents)
            parents[rootID] = parent
        }
        tab.frames = frames; tab.parents = parents
    }
    private func parentMap(_ tree: [String: Any], parent: String? = nil, into map: inout [String: String]) {
        let id = (tree["frame"] as? [String: Any])?["id"] as? String
        if let id, let parent { map[id] = parent }
        for child in tree["childFrames"] as? [[String: Any]] ?? [] { parentMap(child, parent: id, into: &map) }
    }
    /// The frame's content placement in top-page coordinates. DOM box models are relative to the root of the
    /// process the owner lives in (the top page, or a cross-process iframe), so the owner's box is measured there and
    /// composed with that root's own placement. Scale comes from the box model; rotation or skew is refused.
    private func placement(_ frame: String, tab: Tab) async throws -> Placement {
        guard frame != tab.frames.first else { return .identity }
        guard var root = tab.parents[frame] else { throw WorkerCDP.error("Can't locate embedded frame") }
        while root != tab.frames.first, tab.cdp.sessions[root] == nil {
            guard let up = tab.parents[root] else { throw WorkerCDP.error("Can't locate embedded frame") }
            root = up
        }
        let rootPlacement = try await placement(root, tab: tab)
        let session = tab.cdp.sessions[root]   // root is the top page or a cross-process root
        let owner = try await tab.cdp.call("DOM.getFrameOwner", ["frameId": frame], session: session)
        guard let node = owner["backendNodeId"] else { throw WorkerCDP.error("Can't locate embedded frame") }
        let model = try await tab.cdp.call("DOM.getBoxModel", ["backendNodeId": node], session: session)["model"] as? [String: Any]
        guard let content = model?["content"] as? [Double], let border = model?["border"] as? [Double],
              let local = Placement.fromQuad(content: content, border: border, width: (model?["width"] as? NSNumber)?.doubleValue ?? 0,
                                             height: (model?["height"] as? NSNumber)?.doubleValue ?? 0) else {
            throw WorkerCDP.error("The embedded frame is rotated, skewed or has no box, so its coordinates can't be placed")
        }
        return rootPlacement.composing(localX: local.x, localY: local.y, scaleX: local.sx, scaleY: local.sy)
    }
    private struct FrameSnapshot: Sendable { let frame: String; let data: Data?; let origin: Placement; var error: String? = nil }
    private func frameSnapshot(_ frame: String, tab: Tab) async -> FrameSnapshot {
        do {
            try Task.checkCancellation()
            let part = try await call(tab, frame: frame, function: "snapshot")
            let origin = try await placement(frame, tab: tab)
            return FrameSnapshot(frame: frame, data: try JSONSerialization.data(withJSONObject: part), origin: origin)
        } catch { return FrameSnapshot(frame: frame, data: nil, origin: .identity, error: error.localizedDescription) }
    }

    private func snapshot(_ tab: Tab, id: Int) async throws -> [String: Any] {
        // Frame list is cached by context revision; frame events and cross-process attach/detach bump it.
        if tab.frames.isEmpty || tab.frameRevision != tab.cdp.contextRevision {
            let revision = tab.cdp.contextRevision
            try await collectFrames(tab)
            tab.frameRevision = revision
        }
        tab.incomplete = tab.frames.count > 64
        tab.unreadable = tab.frames.count > 64 ? [["frame": "\(tab.frames.count - 64) frame(s)", "reason": "more than 64 frames; the rest are not read"]] : []
        guard let top = tab.frames.first else { throw WorkerCDP.error("The worker page has no frame") }
        var result = try await call(tab, frame: top, function: "snapshot")
        // A cross-process iframe attaches shortly after it appears; if the page shows more iframes than the worker
        // has found, give the attach a moment before declaring them unreadable.
        func directChildren() -> Int { tab.frames.filter { tab.parents[$0] == top }.count }
        for _ in 0..<6 where (result["frames"] as? [Any])?.count ?? 0 > directChildren() {
            try await Task.sleep(for: .milliseconds(250))
            try await collectFrames(tab)
        }
        let visibleBoxes = (result["frames"] as? [Any])?.count ?? 0
        if visibleBoxes > directChildren() {
            tab.incomplete = true
            tab.unreadable.append(["frame": "\(visibleBoxes - directChildren()) iframe(s)", "reason": "the page shows more iframes than the browser reported; the extra ones were not attached"])
        }
        let url = result["url"] as? String ?? ""
        guard let documentID = result["documentID"] as? String else { throw WorkerCDP.error("The page helpers need updating; no document token was returned") }
        if tab.documentID != documentID { tab.keys.removeAll(); tab.nextElement = 0 }
        tab.page = url; tab.documentID = documentID; tab.snapshotID = UUID().uuidString
        tab.frameTokens.removeAll()
        tab.elements.removeAll()
        // Four in-flight frame reads overlap CDP round trips without flooding Chrome with large snapshots.
        var parts: [String: FrameSnapshot] = [:]
        await withTaskGroup(of: FrameSnapshot.self) { group in
            var frames = tab.frames.prefix(64).dropFirst().makeIterator()
            for _ in 0..<4 { if let frame = frames.next() { group.addTask { await self.frameSnapshot(frame, tab: tab) } } }
            for await part in group {
                parts[part.frame] = part
                if let frame = frames.next() { group.addTask { await self.frameSnapshot(frame, tab: tab) } }
            }
        }
        var elements: [[String: Any]] = []
        for frame in tab.frames.prefix(64) {
            do {
                let part: [String: Any]
                let origin: Placement
                if frame == top { part = result; origin = .identity }
                else {
                    guard let read = parts[frame], let data = read.data,
                          let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        tab.incomplete = true
                        tab.unreadable.append(["frame": frame, "reason": parts[frame]?.error ?? "its page helper did not answer"]); continue
                    }
                    part = decoded; origin = read.origin
                }
                guard let document = part["documentID"] as? String, let revision = part["snapshotID"] as? String else {
                    throw WorkerCDP.error("An embedded frame has no freshness token")
                }
                tab.frameTokens[frame] = ["documentID": document, "snapshotID": revision]
                for var element in part["elements"] as? [[String: Any]] ?? [] {
                    guard let local = element["i"] as? Int else { continue }
                    let key = frame + ":" + document + ":" + (element["key"] as? String ?? "\(element["role"] ?? ""):\(element["text"] ?? ""):\(local)")
                    let global: Int
                    if let previous = tab.keys[key] { global = previous }
                    else { global = tab.nextElement; tab.nextElement += 1; tab.keys[key] = global }
                    element["i"] = global
                    let placed = origin.point(element["x"] as? Double ?? 0, element["y"] as? Double ?? 0)
                    element["x"] = placed.x
                    element["y"] = placed.y
                    if origin.sx != 1 { element["w"] = (element["w"] as? Double ?? 0) * origin.sx }
                    if origin.sy != 1 { element["h"] = (element["h"] as? Double ?? 0) * origin.sy }
                    elements.append(element)
                    tab.elements[global] = Element(frame: frame, local: local, offset: origin)
                }
            } catch {
                if frame == top { throw error }
                tab.incomplete = true
                tab.unreadable.append(["frame": frame, "reason": error.localizedDescription])
            }
        }
        result["elements"] = elements; result["tabId"] = id; result["focused"] = false
        result["documentID"] = tab.documentID; result["snapshotID"] = tab.snapshotID
        result["window"] = ["left": 0, "top": 0, "width": 1440, "height": 900]
        // Coverage is explicit: which frames are in this listing and which are not, and why.
        result["frameCoverage"] = tab.unreadable.map { ["frame": ($0["frame"] ?? "").prefix(8) + "…", "status": "unreadable", "reason": $0["reason"] ?? ""] }
        if tab.incomplete {
            result["error"] = "An embedded frame could not be read safely (" + tab.unreadable.map { $0["reason"] ?? "" }.joined(separator: "; ") + "). Its form review or upload needs attention."
        }
        return result
    }

    private func pageCommand(_ command: String, tab: Tab, args: [String: Any]) async throws -> [String: Any] {
        guard let top = tab.frames.first else { throw WorkerCDP.error("Take a worker page snapshot first") }
        let index = args["index"] as? Int ?? -1
        let element = tab.elements[index]
        func indexed(_ name: String, _ extra: [Any] = []) async throws -> [String: Any] {
            guard let element else { throw WorkerCDP.error("The task element no longer exists. Take a fresh look.") }
            return try await call(tab, frame: element.frame, function: name, args: [element.local] + extra)
        }
        switch command {
        case "values":
            let indices = Array((args["indices"] as? [Int] ?? []).prefix(200))
            let groups = Dictionary(grouping: indices.compactMap { index in tab.elements[index].map { (index, $0) } }, by: { $0.1.frame })
            var result: [String: Any] = [:]
            try await withThrowingTaskGroup(of: [String: String].self) { group in
                for (frame, items) in groups {
                    group.addTask { @MainActor in
                        let reply = try await self.call(tab, frame: frame, function: "values", args: [items.map { $0.1.local }])
                        let values = reply["values"] as? [String: Any] ?? [:]
                        return Dictionary(uniqueKeysWithValues: items.compactMap { item in (values[String(item.1.local)] as? String).map { (String(item.0), $0) } })
                    }
                }
                for try await values in group { result.merge(values) { _, new in new } }
            }
            return ["values": result]
        case "click", "focus", "value", "isActive", "prepare", "state", "chosen", "alive", "focusFor": return try await indexed(command)
        case "clickOption":
            guard let frame = args["pointFrame"] as? String, tab.frameTokens[frame] != nil, let token = args["pointToken"] as? String else {
                throw WorkerCDP.error("The option has no current target token. Take a new look.")
            }
            return try await call(tab, frame: frame, function: "clickOption", args: [token])
        case "activeOption": return try await indexed(command, [args["want"] ?? ""])
        case "fill": return try await indexed(command, [args["text"] ?? ""])
        case "locate", "findOption":
            var result = command == "locate" ? try await indexed(command, [args["reveal"] as? Bool ?? true]) : try await call(tab, frame: element?.frame ?? top, function: command, args: [args["text"] ?? "", element?.local ?? -1])
            if command == "findOption" { result["pointFrame"] = element?.frame ?? top }
            let place = element?.offset ?? .identity
            for (kx, ky) in [("x", "y"), ("px", "py")] {
                if let vx = result[kx] as? Double, let vy = result[ky] as? Double { let p = place.point(vx, vy); result[kx] = p.x; result[ky] = p.y }
            }
            return result
        case "images": return try await call(tab, frame: top, function: "images")
        case "review", "read", "tables":
            guard !tab.incomplete else { throw WorkerCDP.error("An embedded frame is unreadable; I won't present an incomplete form review.") }
            let function = command == "read" ? "readText" : command
            var result = try await call(tab, frame: top, function: function)
            for frame in tab.frames.dropFirst() {
                let part = try await call(tab, frame: frame, function: function)
                if command == "read" { result["text"] = (result["text"] as? String ?? "") + "\n" + (part["text"] as? String ?? "") }
                else { for key in command == "review" ? ["items", "messages", "missing"] : ["tables"] { result[key] = (result[key] as? [Any] ?? []) + (part[key] as? [Any] ?? []) } }
            }
            return result
        case "upload":
            if element != nil { return try await indexed("upload", [args["name"] ?? "attachment", args["type"] ?? "", args["data"] ?? ""]) }
            var possible: [(String, Int)] = []
            for frame in tab.frames {
                let count = try await call(tab, frame: frame, function: "fileInputCount")["count"] as? Int ?? 0
                if count > 0 { possible.append((frame, count)) }
            }
            guard !possible.isEmpty else { throw WorkerCDP.error("this page has no file upload field (it may use its own picker, e.g. Google Drive)") }
            guard possible.count == 1, possible[0].1 == 1 else { throw WorkerCDP.error("ambiguous file upload fields; choose the exact input") }
            return try await call(tab, frame: possible[0].0, function: "upload", args: [-1, args["name"] ?? "attachment", args["type"] ?? "", args["data"] ?? ""])
        case "uploadVia":
            guard let element, let base64 = args["data"] as? String, let data = Data(base64Encoded: base64) else { throw WorkerCDP.error("The upload file is missing") }
            _ = try await indexed("markUpload")
            let directory = root.appendingPathComponent("Uploads").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            tab.uploads.append(directory) // Chrome may read the file lazily when the form is submitted.
            let name = ((args["name"] as? String ?? "attachment") as NSString).lastPathComponent
            let file = directory.appendingPathComponent(name == "." || name == ".." ? "attachment" : name)
            try data.write(to: file)
            tab.cdp.lastChooser = nil
            _ = try await call(tab, frame: element.frame, function: "click", args: [element.local])
            for _ in 0..<30 {
                if let node = tab.cdp.lastChooser?["backendNodeId"] {
                    _ = try await tab.cdp.call("DOM.setFileInputFiles", ["backendNodeId": node, "files": [file.path]])
                    return ["ok": true, "files": [name]]
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw WorkerCDP.error("The site's file chooser wasn't available to the worker. No Mac file picker was opened.")
        case "activeValue":
            for frame in tab.frames {
                let result = try await call(tab, frame: frame, function: "activeValue")
                if result["editable"] as? Bool == true, result["hasFocus"] as? Bool == true { tab.focusedFrame = frame; return result }
            }
            return try await call(tab, frame: top, function: "activeValue")
        case "fillActive": return try await call(tab, frame: tab.focusedFrame ?? top, function: "fillActive", args: [args["text"] ?? ""])
        case "scroll": return try await call(tab, frame: top, function: "scroll", args: [args["dy"] ?? 0])
        case "waitText": return try await call(tab, frame: top, function: "waitText", args: [args["text"] ?? "", args["gone"] ?? false, args["ms"] ?? 10000])
        default: throw WorkerCDP.error("Unsupported worker command: " + command)
        }
    }

    private func key(_ chord: String, tab: Tab) async throws -> [String: Any] {
        guard BackgroundPolicy.route(["do": "key", "keys": chord], hasWorkerPage: true) == .browser else { throw WorkerCDP.error("This shortcut isn't allowed in worker Chrome") }
        let parts = chord.lowercased().split(separator: "+").map(String.init)
        let last = parts.last ?? ""
        let codes: [String: (String, String, Int)] = ["return": ("Enter", "Enter", 13), "enter": ("Enter", "Enter", 13), "tab": ("Tab", "Tab", 9), "escape": ("Escape", "Escape", 27), "esc": ("Escape", "Escape", 27), "backspace": ("Backspace", "Backspace", 8), "delete": ("Backspace", "Backspace", 8), "down": ("ArrowDown", "ArrowDown", 40), "up": ("ArrowUp", "ArrowUp", 38), "left": ("ArrowLeft", "ArrowLeft", 37), "right": ("ArrowRight", "ArrowRight", 39), "space": (" ", "Space", 32)]
        let value = codes[last] ?? (last, "Key" + last.uppercased(), Int(last.uppercased().utf16.first ?? 0))
        let modifiers = (parts.contains("shift") ? 8 : 0) | (parts.contains("cmd") || parts.contains("command") || parts.contains("meta") ? 4 : 0) | (parts.contains("ctrl") || parts.contains("control") ? 2 : 0)
        var args: [String: Any] = ["type": "rawKeyDown", "key": value.0, "code": value.1, "windowsVirtualKeyCode": value.2, "modifiers": modifiers]
        if last == "a", modifiers != 0 { args["commands"] = ["selectAll"] }
        _ = try await tab.cdp.call("Input.dispatchKeyEvent", args)
        args["type"] = "keyUp"; args.removeValue(forKey: "commands")
        _ = try await tab.cdp.call("Input.dispatchKeyEvent", args)
        return ["pressed": true]
    }
}
