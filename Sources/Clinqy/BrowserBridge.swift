import AppKit
import Network
import Combine

/// Talks to the Clinqy browser extension over a localhost WebSocket. The extension reads the live page
/// (exact buttons, links, fields and where they are) and performs precise clicks and fills in it.
/// Only browser-extension origins may connect, so web pages can't reach this server.
@MainActor
final class BrowserBridge: ObservableObject {
    private static let primary = BrowserBridge()
    static var shared: BrowserBridge {
        TaskExecution.current?.service(BrowserBridge.self) { BrowserBridge(transport: primary) } ?? primary
    }
    private let transport: BrowserBridge?
    init(transport: BrowserBridge? = nil) { self.transport = transport }
    static let port: NWEndpoint.Port = 47823

    struct PageElement {
        let index: Int
        let role: String
        let text: String
        /// Rect in page viewport coordinates.
        let rect: CGRect
        let editable: Bool
        let extra: String
        /// What the element is on its page (role, name, question, frame…); its index stays the same while this does.
        var key = ""
        /// Current value/choice (fields, dropdowns), and state flags (checked, covered, disabled…), for diffs.
        var value: String?
        var flags: Set<String> = []
        /// The question a field or choice answers (its group's label), its placeholder, and a dropdown's choices.
        var question: String?
        var placeholder: String?
        var options: [String] = []
        var dropdown = false
    }

    /// A scrolling box (usually a modal's body) with fields/buttons scrolled out of it.
    struct Pane { let name: String; let modal: Bool; let above: Int; let below: Int }

    struct Page {
        let connection: ObjectIdentifier
        let url: String
        let title: String
        let viewport: CGSize
        let scrollY: Double
        let scrollMax: Double
        let headings: [String]
        let elements: [PageElement]
        /// Error/status messages showing on the page ("This is a required question").
        var messages: [String] = []
        /// Visible text that isn't an element (confirmations, details, prices).
        var text = ""
        /// Fields/buttons above and below the visible part (so the model knows to scroll).
        var above = 0, below = 0
        /// document.readyState ("loading" = still arriving).
        var ready = "complete"
        /// Why the page couldn't be read, when it couldn't (never just "0 elements").
        var problem: String?
        /// Viewport's on-screen rect estimated from window geometry (fallback when Accessibility can't say).
        var estimatedArea: CGRect?
        /// Scrolling boxes (modals) with more fields out of view; their counts are included in above/below.
        var panes: [Pane] = []
        /// The browser tab this was read from; `pinned` = read by id (snapshot(tab:)), so commands go to that tab
        /// even while it's in the background.
        var tabId: Int?
        var pinned = false
        /// Tokens bind references to an exact document and listing, including same-URL reloads.
        var documentID: String?
        var snapshotID: String?
    }

    private var listener: NWListener?
    private var connectionStorage: [ObjectIdentifier: NWConnection] = [:]
    private var connections: [ObjectIdentifier: NWConnection] {
        get { transport?.connections ?? connectionStorage }
        set { if let transport { transport.connections = newValue } else { connectionStorage = newValue } }
    }
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var counter = 0

    var isConnected: Bool { ChromeWorker.shared.connected || !connections.isEmpty }
    var connectedBrowserNames: [String] {
        Array(Set(owners.filter { connections[$0.key] != nil }.values.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })).sorted()
    }

    enum BridgeError: LocalizedError {
        case notConnected, timeout, failed(String)
        var errorDescription: String? {
            switch self {
            case .notConnected: return "browser extension not connected"
            case .timeout: return "browser extension didn't answer"
            case .failed(let why): return why
            }
        }
    }

    func start() {
        guard transport == nil, listener == nil else { return }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        // Browser pages send their own origin; only extensions (chrome-extension://…) are let in.
        ws.setClientRequestHandler(.main) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value ?? ""
            let ok = origin.hasPrefix("chrome-extension://") || origin.hasPrefix("moz-extension://")
            return .init(status: ok ? .accept : .reject, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: Self.port)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { return }
        listener.newConnectionHandler = { [weak self] conn in
            MainActor.assumeIsolated { self?.accept(conn) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        conn.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    self?.connections[key] = conn
                    self?.identify(conn, key: key)
                case .failed, .cancelled:
                    self?.connections[key] = nil
                    self?.owners[key] = nil
                default: break
                }
            }
        }
        conn.start(queue: .main)
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any], msg["type"] as? String == "hello" {
                    self.checkVersion(msg["version"] as? String ?? "", on: conn)
                    if msg["version"] as? String == Self.extensionVersion { self.tidyAfterRestart(conn) }
                }
                if let data, let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = msg["id"] as? String, let cont = self.pending.removeValue(forKey: id) {
                    if msg["ok"] as? Bool == true {
                        cont.resume(returning: (msg["result"] as? [String: Any]) ?? [:])
                    } else {
                        cont.resume(throwing: BridgeError.failed(msg["error"] as? String ?? "extension error"))
                    }
                }
                if error == nil { self.receive(conn) } else { self.connections[ObjectIdentifier(conn)] = nil }
            }
        }
    }

    private func request(_ conn: NWConnection, _ body: [String: Any], timeout: Double = 2.5) async throws -> [String: Any] {
        if let transport { return try await transport.request(conn, body, timeout: timeout) }
        counter += 1
        let id = "r\(counter)"
        var msg = body
        msg["id"] = id
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { throw BridgeError.failed("bad request") }
        let closing = ["closeTab", "closeAgentWindow"].contains(body["cmd"] as? String ?? "")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                guard closing || !Task.isCancelled else { cont.resume(throwing: CancellationError()); return }
                pending[id] = cont
                let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                conn.send(content: data, contentContext: .init(identifier: "msg", metadata: [meta]), isComplete: true,
                          completion: .contentProcessed { _ in })
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.pending.removeValue(forKey: id)?.resume(throwing: BridgeError.timeout)
                }
            }
        } onCancel: {
            if !closing { Task { @MainActor [weak self] in self?.pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) } }
        }
    }

    /// The extension version this app was built with (extension/manifest.json). A browser still running an older
    /// copy is told to reload it from disk, once per version, so updates never need a manual reload.
    static let extensionVersion = "1.9.15"
    /// Reloads asked for, per old version. Each browser on that version needs its own (asking once per version left a
    /// second browser running its old worker); the cap keeps a browser that stays old from being reloaded forever.
    private var reloadAsked: [String: Int] = [:]

    private func checkVersion(_ version: String, on conn: NWConnection) {
        guard version != Self.extensionVersion, reloadAsked[version, default: 0] < 3 else { return }
        reloadAsked[version, default: 0] += 1
        let key = ObjectIdentifier(conn)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            let browser = self?.owners[key].map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "a browser"
            Agent.writeLog("browser extension v\(version) connected in \(browser), app expects v\(Self.extensionVersion): reloading it")
        }
        Self.refreshInstalledCopy()
        Task { _ = try? await request(conn, ["cmd": "reload"], timeout: 5) }
    }

    /// As each browser connects in the first minute after Clinqy starts: a background window an earlier Clinqy left
    /// open (it crashed, or was killed before it could close it) is closed, so it never sits on the user's screen.
    /// Not once this Clinqy has a hidden screen or a background run: then that window is in use.
    private let started = Date()

    private func tidyAfterRestart(_ conn: NWConnection) {
        guard Date().timeIntervalSince(started) < 60, AgentScreen.bounds == nil, !Background.active else { return }
        Task {
            do {
                let r = try await request(conn, ["cmd": "closeAgentWindow"], timeout: 3)
                if let id = r["closed"] as? Int { Agent.writeLog("closed a background window an earlier Clinqy left open (window \(id))") }
            } catch {
                Agent.writeLog("couldn't check for a background window an earlier Clinqy left open: \(error.localizedDescription)")
            }
        }
    }

    /// The user took over Clinqy's background window: it's theirs now, never closed by Clinqy.
    func releaseBackgroundWindows() async {
        for conn in connections.values { _ = try? await request(conn, ["cmd": "releaseAgentWindow"], timeout: 2) }
    }

    /// The browser loads the extension from a copy in Application Support (setup made it): after an app update that
    /// copy is still the old one, so a reload would only bring the old version back. Puts this app's copy there first.
    private static func refreshInstalledCopy() {
        let fm = FileManager.default
        let installed = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clinqy/extension")
        guard let bundled = Bundle.main.url(forResource: "extension", withExtension: nil), fm.fileExists(atPath: installed.path) else { return }
        let unchanged = ["manifest.json", "bridge.js", "page.js"].allSatisfy {
            fm.contentsEqual(atPath: installed.appendingPathComponent($0).path, andPath: bundled.appendingPathComponent($0).path)
        }
        guard !unchanged else { return }
        for name in (try? fm.contentsOfDirectory(atPath: bundled.path)) ?? [] {
            let target = installed.appendingPathComponent(name)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: bundled.appendingPathComponent(name), to: target)
        }
        Agent.writeLog("updated the browser extension's files to v\(Self.extensionVersion)")
    }

    /// Asks every connected browser to reload the extension (after it's been updated on disk).
    func reloadAll() async -> Int {
        var n = 0
        for (_, conn) in connections where (try? await request(conn, ["cmd": "reload"], timeout: 5)) != nil { n += 1 }
        return n
    }

    /// Debug: every connected browser's raw answer to a snapshot request.
    func debugSnapshots() async -> [String] {
        var out: [String] = []
        for (_, conn) in connections {
            do {
                let v = (try? await request(conn, ["cmd": "version"], timeout: 3))?["version"] as? String ?? "?"
                let r = try await request(conn, ["cmd": "snapshot"], timeout: 5)
                out.append("v\(v) screen=\(r["screen"] != nil) focused=\(r["focused"] ?? "nil") url=\(r["url"] ?? "-") elements=\((r["elements"] as? [Any])?.count ?? -1) restricted=\(r["restricted"] ?? false)")
            } catch { out.append("error: \(error.localizedDescription)") }
        }
        return out
    }

    /// Text selected on the page in the focused browser window, if any.
    func selection(in app: NSRunningApplication? = nil) async -> String? {
        for (_, conn) in candidates(for: app) {
            guard let r = try? await request(conn, ["cmd": "selection"], timeout: 1.2), r["focused"] as? Bool == true else { continue }
            let text = (r["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    struct TabInfo: Sendable { let id: Int; let url: String; let connection: ObjectIdentifier }

    /// The active tab of the focused browser window.
    func activeTab(in app: NSRunningApplication? = nil) async -> TabInfo? {
        for (key, conn) in candidates(for: app) {
            guard let r = try? await request(conn, ["cmd": "tabInfo"], timeout: 1.5), r["focused"] as? Bool == true,
                  let id = r["id"] as? Int else { continue }
            return TabInfo(id: id, url: r["url"] as? String ?? "", connection: key)
        }
        return nil
    }

    /// Whether `app` (a browser) has the extension connected.
    func isConnected(_ app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleURL?.resolvingSymlinksInPath().path else { return false }
        return owners.contains { connections[$0.key] != nil && $0.value == bundle }
    }

    private var activityRunning = false
    @Published private(set) var pageCursorVisible = false
    private var activityGeneration = 0
    private var activityTabs: [ObjectIdentifier: Set<Int>] = [:]
    private var activityRequests: [ObjectIdentifier: Set<String>] = [:]

    func beginActivityRun() {
        activityGeneration += 1; pageCursorVisible = false
        activityRunning = true; activityTabs = [:]; activityRequests = [:]
    }
    func useNativeCursor() { pageCursorVisible = false }

    func endActivityRun() {
        activityRunning = false
        let ended = activityTabs, requests = activityRequests
        activityTabs = [:]; activityRequests = [:]
        let generation = activityGeneration
        Task {
            for key in Set(ended.keys).union(requests.keys) {
                guard let conn = connections[key] else { continue }
                let ids = Array(ended[key] ?? []), operations = Array(requests[key] ?? [])
                _ = try? await request(conn, ["cmd": "clinqyDone", "tabIds": ids, "operationIDs": operations], timeout: 5)
            }
            if activityGeneration == generation && !activityRunning { pageCursorVisible = false }
        }
    }

    /// One extension request returns the exact tab it created. A lost acknowledgement is never followed by
    /// keyboard input or a second open. The extension deduplicates retries using the run's operation id.
    func openForegroundTab(_ url: URL, in app: NSRunningApplication, reusing tab: TabInfo?, operationID: String) async throws -> TabInfo {
        pageCursorVisible = true
        guard let (key, conn) = await frontConnection(for: app) else { throw BridgeError.notConnected }
        let result: TabInfo
        if let tab {
            guard tab.connection == key else { throw BridgeError.failed("The browser profile changed; take another look") }
            _ = try await request(conn, ["cmd": "navigate", "tabId": tab.id, "url": url.absoluteString, "activity": true], timeout: 5)
            result = TabInfo(id: tab.id, url: url.absoluteString, connection: key)
        } else {
            activityRequests[key, default: []].insert(operationID)
            let raw = try await request(conn, ["cmd": "newTab", "url": url.absoluteString, "operationID": operationID, "activity": true], timeout: 8)
            guard let id = raw["id"] as? Int else { throw BridgeError.failed("The browser did not confirm the new tab. Take another look before retrying.") }
            result = TabInfo(id: id, url: url.absoluteString, connection: key)
        }
        activityTabs[key, default: []].insert(result.id)
        return result
    }

    private var taskGeneration = 0
    private var taskConnection: ObjectIdentifier?
    private var taskTabs: Set<Int> = []

    func beginBackgroundRun() {
        taskGeneration += 1
        taskConnection = nil
        taskTabs = []
    }

    func endBackgroundRun() {
        // Explicit ids prevent late cleanup from detaching the next run's debugger.
        guard let key = taskConnection, let conn = connections[key] else { return }
        let ids = Array(taskTabs)
        Task { _ = try? await request(conn, ["cmd": "clinqyDone", "tabIds": ids], timeout: 5) }
    }

    func ownsBackgroundPage(_ page: Page?) -> Bool {
        guard let page, let id = page.tabId else { return false }
        if !Background.usesExtension { return page.connection == ChromeWorker.shared.identity }
        return page.connection == taskConnection && taskTabs.contains(id)
    }

    /// Opens an inactive tab in the connected, signed-in profile. Once selected, the connection stays pinned;
    /// a disconnect must never cause a task to migrate to another browser/profile or the desktop.
    func backgroundTab(_ url: String, in app: NSRunningApplication? = nil, at: CGRect? = nil, select: Bool = true) async -> (tab: TabInfo, browser: NSRunningApplication?, window: CGRect?)? {
        do {
            if !Background.usesExtension {
                let worker = ChromeWorker.shared
                let id = try await worker.newTab(url, select: select)
                return (TabInfo(id: id, url: url, connection: worker.identity), worker.app, CGRect(x: 0, y: 0, width: 1440, height: 900))
            }
            let generation = taskGeneration
            let key: ObjectIdentifier
            let conn: NWConnection
            if let selected = taskConnection {
                guard let existing = connections[selected] else { throw BridgeError.notConnected }
                key = selected; conn = existing
            } else {
                guard let preferred = app ?? NSWorkspace.shared.runningApplications.first(where: {
                    $0.cleanName == Background.browserName && isConnected($0)
                }) else { throw BridgeError.failed("Connect the Clinqy extension in " + Background.browserName + "; another browser will not be used instead.") }
                guard let selected = await frontConnection(for: preferred) else {
                    throw BridgeError.failed("Connect the Clinqy extension in the browser profile you want to use.")
                }
                guard generation == taskGeneration, Background.active, !Task.isCancelled else { throw CancellationError() }
                key = selected.0; conn = selected.1
                taskConnection = key
                // Each job cleans up only its own tabs; global cleanup would detach parallel jobs.
            }
            guard generation == taskGeneration, Background.active, !Task.isCancelled else { throw CancellationError() }
            let result = try await request(conn, ["cmd": "clinqyTab", "url": url, "width": 1280, "height": 900], timeout: 15)
            guard let id = result["id"] as? Int else { throw BridgeError.failed("The extension did not open a task tab") }
            guard generation == taskGeneration, Background.active, !Task.isCancelled else {
                _ = try? await request(conn, ["cmd": "clinqyDone", "tabIds": [id]], timeout: 5)
                throw CancellationError()
            }
            taskTabs.insert(id)
            let browser = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.resolvingSymlinksInPath().path == owners[key] }
            return (TabInfo(id: id, url: url, connection: key), browser, nil)
        } catch { Agent.writeLog("background browser: " + error.localizedDescription); return nil }
    }

    private func requireTaskTab(_ tab: TabInfo) throws {
        if Background.active && Background.usesExtension {
            guard tab.connection == taskConnection, taskTabs.contains(tab.id) else {
                throw BridgeError.failed("This tab does not belong to the current task")
            }
        }
    }

    /// Reads `tab` by id, wherever it is (Clinqy's background window included). The page is pinned to it.
    func snapshot(of tab: TabInfo) async -> Page? {
        if tab.connection == ChromeWorker.shared.identity {
            guard let raw = try? await ChromeWorker.shared.command("snapshot", tabID: tab.id) else { return nil }
            var page = parse(raw, connection: tab.connection)
            page.pinned = true
            page.estimatedArea = CGRect(origin: .zero, size: page.viewport)
            return page
        }
        do { try requireTaskTab(tab) } catch { return nil }
        guard let conn = connections[tab.connection],
              let r = try? await request(conn, ["cmd": "snapshot", "tabId": tab.id, "workOnly": Background.active && Background.usesExtension], timeout: 5) else { return nil }
        var page = parse(r, connection: tab.connection)
        page.pinned = true
        return page
    }

    /// Captures one owned task tab through the extension. Capturing a hidden tab can take longer than a normal command.
    /// Model inputs are JPEG (matching the providers' image/jpeg payload); exports stay lossless PNG.
    func taskVisionScreenshot(of tab: TabInfo) async -> Data? {
        if tab.connection == ChromeWorker.shared.identity {
            guard let raw = try? await ChromeWorker.shared.command("captureVision", tabID: tab.id),
                  let encoded = raw["image"] as? String else { return nil }
            return Data(base64Encoded: encoded).flatMap(Screenshot.visionJPEG)
        }
        guard let png = await taskScreenshot(of: tab) else { return nil }
        return Screenshot.visionJPEG(png)
    }

    func taskScreenshot(of tab: TabInfo, preview: Bool = false) async -> Data? {
        if tab.connection == ChromeWorker.shared.identity {
            guard let raw = try? await ChromeWorker.shared.command(preview ? "capturePreview" : "captureTask", tabID: tab.id), let png = raw["image"] as? String else { return nil }
            return Data(base64Encoded: png)
        }
        do { try requireTaskTab(tab) } catch { return nil }
        guard let conn = connections[tab.connection] else {
            Agent.writeLog("telegram screenshot: task browser disconnected")
            return nil
        }
        let finalCapture = !Background.active
        defer {
            if finalCapture {
                // Even a failed final capture must release the debugger it may have attached.
                Task { _ = try? await request(conn, ["cmd": "clinqyDone", "tabIds": [tab.id]], timeout: 5) }
            }
        }
        do {
            let reply = try await request(conn, ["cmd": "captureTask", "tabId": tab.id, "workOnly": Background.active && Background.usesExtension], timeout: 12)
            guard let base64 = reply["image"] as? String, let image = Data(base64Encoded: base64) else {
                Agent.writeLog("telegram screenshot: browser returned no image")
                return nil
            }
            Agent.writeLog("telegram screenshot: captured \(image.count) bytes from task tab")
            return image
        } catch {
            Agent.writeLog("telegram screenshot: \(error.localizedDescription)")
            return nil
        }
    }

    /// Runs a tab-level command (newTab, goBack, navigate) in the browser that owns `tab`.
    @discardableResult
    func tabCommand(_ cmd: String, on tab: TabInfo, _ args: [String: Any] = [:]) async -> [String: Any]? {
        if tab.connection == ChromeWorker.shared.identity { return try? await ChromeWorker.shared.command(cmd, tabID: tab.id, args: args) }
        do { try requireTaskTab(tab) } catch { return nil }
        guard let conn = connections[tab.connection] else { return nil }
        var body = args
        body["tabId"] = tab.id
        body["workOnly"] = Background.active && Background.usesExtension
        body["cmd"] = cmd
        return try? await request(conn, body, timeout: 3)
    }

    /// User-requested reveal, separate from background task selection (which never changes focus).
    func revealTaskTab(_ tab: TabInfo) async {
        do { try requireTaskTab(tab) } catch { return }
        guard let conn = connections[tab.connection] else { return }
        _ = try? await request(conn, ["cmd": "switchTab", "tabId": tab.id], timeout: 3)
    }

    /// Cheap readiness checks avoid rescanning every element while navigation is still in progress.
    func waitForNavigation(on tab: TabInfo, to requested: String, previous: String? = nil, timeout: Double = 8) async -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + timeout
        repeat {
            guard !Task.isCancelled else { return false }
            guard let info = await tabCommand("tabInfo", on: tab) else { return false }
            let url = info["url"] as? String ?? ""
            let ready = info["ready"] as? String ?? info["status"] as? String ?? "loading"
            let changed = url == requested || (url != previous && url != "about:blank" && url.hasPrefix("http"))
            if changed, ready == "complete" || ready == "interactive",
               ProcessInfo.processInfo.systemUptime - start >= 0.08 { return true }
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return false }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    // MARK: - Page API

    /// Snapshot of the page in the focused browser window (asks every connected browser; the focused one answers for itself).
    /// Which browser each connection comes from (its app bundle path, e.g. /Applications/Arc.app), found from
    /// the process on the other end. A page must only ever be read from the browser that's actually in front:
    /// with Chrome in front and only Arc connected, Arc's tab must not be mistaken for Chrome's.
    private var ownerStorage: [ObjectIdentifier: String] = [:]
    private var owners: [ObjectIdentifier: String] {
        get { transport?.owners ?? ownerStorage }
        set { if let transport { transport.owners = newValue } else { ownerStorage = newValue } }
    }

    private func identify(_ conn: NWConnection, key: ObjectIdentifier) {
        guard case let .hostPort(_, port) = conn.endpoint else { return }
        Task.detached {
            let r = await Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port.rawValue)", "-sTCP:ESTABLISHED", "-Fp"], timeout: 5)
            let me = ProcessInfo.processInfo.processIdentifier
            let pids = r.output.split(separator: "\n").filter { $0.hasPrefix("p") }.compactMap { Int32($0.dropFirst()) }.filter { $0 != me }
            var bundle: String?
            for pid in pids {
                var buf = [CChar](repeating: 0, count: 4096)
                guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
                let path = String(cString: buf)
                if let r = path.range(of: ".app/") { bundle = String(path[..<r.lowerBound]) + ".app"; break }
            }
            let owner = bundle
            await MainActor.run { self.owners[key] = owner ?? "?" }
        }
    }

    /// Connections to ask about `app` (a browser): its own; while a connection is still being identified, that
    /// one too; none if this browser has no extension connected. nil app = any (the focused window decides).
    private func candidates(for app: NSRunningApplication?) -> [(ObjectIdentifier, NWConnection)] {
        let all = connections.map { ($0.key, $0.value) }
        guard let bundle = app?.bundleURL?.resolvingSymlinksInPath().path else { return all }
        let own = all.filter { owners[$0.0] == bundle }
        return own.isEmpty ? all.filter { owners[$0.0] == nil } : own
    }

    func snapshot(for app: NSRunningApplication? = nil) async -> Page? {
        let pool = candidates(for: app)
        for (key, conn) in pool {
            guard let r = try? await request(conn, ["cmd": "snapshot"], timeout: 5), r["focused"] as? Bool == true else { continue }
            return parse(r, connection: key)
        }
        // Nobody reports focus (e.g. the page hasn't got keyboard focus yet): use the only candidate, if one.
        if pool.count == 1, let (key, conn) = pool.first,
           let r = try? await request(conn, ["cmd": "snapshot"], timeout: 5) {
            return parse(r, connection: key)
        }
        return nil
    }

    func perform(_ cmd: String, on page: Page, _ args: [String: Any] = [:], timeout: Double = 4) async throws -> [String: Any] {
        guard let documentID = page.documentID, let snapshotID = page.snapshotID, let tabID = page.tabId else {
            throw BridgeError.failed("This browser observation has no freshness tokens. Update the extension and take a fresh look.")
        }
        var body = args
        body["documentID"] = documentID
        body["snapshotID"] = snapshotID
        // Every action remains pinned to the observed tab, even when the user switches tabs.
        body["tabId"] = tabID
        if page.connection == ChromeWorker.shared.identity { return try await ChromeWorker.shared.command(cmd, tabID: tabID, args: body) }
        try requireTaskTab(TabInfo(id: tabID, url: page.url, connection: page.connection))
        guard let conn = connections[page.connection] else { throw BridgeError.notConnected }
        body["workOnly"] = Background.active && Background.usesExtension
        body["activity"] = activityRunning
        if activityRunning { pageCursorVisible = true }
        if activityRunning { activityTabs[page.connection, default: []].insert(tabID) }
        body["cmd"] = cmd
        return try await request(conn, body, timeout: timeout)
    }

    // MARK: - Tabs

    struct BrowserTab { let id: Int; let title: String; let url: String; let active: Bool; let opened: Bool }

    /// The browser in front (its connection), as for snapshots: the one reporting a focused window, else the only one.
    private func frontConnection(for app: NSRunningApplication?) async -> (ObjectIdentifier, NWConnection)? {
        let pool = candidates(for: app)
        for (key, conn) in pool {
            if let r = try? await request(conn, ["cmd": "tabInfo"], timeout: 1.5), r["focused"] as? Bool == true { return (key, conn) }
        }
        return pool.count == 1 ? pool.first : nil
    }

    /// Tabs of the front browser window, in strip order. `opened` = Clinqy opened it (only those can be closed).
    func tabs(in app: NSRunningApplication? = nil) async throws -> [BrowserTab] {
        if Background.active && Background.usesExtension {
            guard let key = taskConnection, let conn = connections[key] else { return [] }
            let raw = try await request(conn, ["cmd": "tabs", "workOnly": true], timeout: 3)
            return (raw["tabs"] as? [[String: Any]] ?? []).compactMap { t in
                guard let id = t["id"] as? Int, taskTabs.contains(id) else { return nil }
                return BrowserTab(id: id, title: t["title"] as? String ?? "", url: t["url"] as? String ?? "", active: id == Background.tab?.id, opened: true)
            }
        }
        if Background.active {
            let raw = try await ChromeWorker.shared.command("tabs", tabID: nil)
            return (raw["tabs"] as? [[String: Any]] ?? []).compactMap { t in
                guard let id = t["id"] as? Int else { return nil }
                return BrowserTab(id: id, title: t["title"] as? String ?? "", url: t["url"] as? String ?? "", active: t["active"] as? Bool == true, opened: true)
            }
        }
        guard let (_, conn) = await frontConnection(for: app) else { throw BridgeError.notConnected }
        let r = try await request(conn, ["cmd": "tabs"], timeout: 3)
        return (r["tabs"] as? [[String: Any]] ?? []).compactMap { t in
            guard let id = t["id"] as? Int else { return nil }
            return BrowserTab(id: id, title: t["title"] as? String ?? "", url: t["url"] as? String ?? "",
                              active: t["active"] as? Bool == true, opened: t["opened"] as? Bool == true)
        }
    }

    /// Brings tab `id` to the front of its window.
    func switchTab(_ id: Int, in app: NSRunningApplication? = nil) async throws {
        if Background.active {
            guard let tab = Background.tab else { throw BridgeError.notConnected }
            guard await snapshot(of: TabInfo(id: id, url: "", connection: tab.connection)) != nil else { throw BridgeError.failed("Task tab unavailable") }
            return // Selecting a task tab never activates a browser window.
        }
        guard let (_, conn) = await frontConnection(for: app) else { throw BridgeError.notConnected }
        _ = try await request(conn, ["cmd": "switchTab", "tabId": id], timeout: 3)
    }

    /// Closes tab `id` — only a tab Clinqy opened (the extension refuses others, with a reason).
    func closeTab(_ id: Int, in app: NSRunningApplication? = nil) async throws {
        if Background.active {
            guard let tab = Background.tab else { throw BridgeError.notConnected }
            let target = TabInfo(id: id, url: "", connection: tab.connection)
            try requireTaskTab(target)
            guard await tabCommand("closeTab", on: target) != nil else { throw BridgeError.failed("Task tab unavailable") }
            taskTabs.remove(id)
            return
        }
        guard let (_, conn) = await frontConnection(for: app) else { throw BridgeError.notConnected }
        _ = try await request(conn, ["cmd": "closeTab", "tabId": id], timeout: 3)
    }

    /// Reads tab `id` without bringing it to the front. The page is pinned: perform() on it acts on that tab.
    func snapshot(tab id: Int, in app: NSRunningApplication? = nil) async -> Page? {
        if Background.active {
            guard let tab = Background.tab else { return nil }
            return await snapshot(of: TabInfo(id: id, url: "", connection: tab.connection))
        }
        guard let (key, conn) = await frontConnection(for: app),
              let r = try? await request(conn, ["cmd": "snapshot", "tabId": id], timeout: 5) else { return nil }
        var page = parse(r, connection: key)
        page.pinned = true
        return page
    }

    /// The tab list as the model sees it: "tab 123 (active): Title — url", "(opened by you)" where it's ours.
    static func describe(_ tabs: [BrowserTab]) -> String {
        tabs.map { "tab \($0.id)\($0.active ? " (active)" : "")\($0.opened ? " (opened by you)" : ""): \($0.title.prefix(80)) — \($0.url.prefix(120))" }
            .joined(separator: "\n")
    }

    // MARK: - Snapshot diffs

    /// Compact changes from `previous` to `current`, one per line: "+ w12 button: Next [..]" (new), "- w7 link: Jobs"
    /// (gone), "~ w3 value \"\" → \"360000\"", "~ w5 now covered", plus new/cleared messages and heading changes.
    /// "" = nothing changed. nil = the page changed too much for a diff to help (another address or tab, a page
    /// that couldn't be read, or more than half its elements changed): send the full listing instead.
    static func diff(previous: Page, current: Page) -> String? {
        guard previous.connection == current.connection, previous.tabId == current.tabId,
              previous.documentID == current.documentID,
              previous.problem == nil, current.problem == nil,
              samePage(previous.url, current.url) else { return nil }
        let old = Dictionary(previous.elements.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(current.elements.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        func line(_ e: PageElement) -> String { "w\(e.index) \(e.role): \(e.text)\(e.extra.isEmpty ? "" : " [\(e.extra.prefix(160))]")" }
        var added: [String] = [], removed: [String] = [], changed: [String] = []
        for e in current.elements {
            guard let was = old[e.index], was.key == e.key else { added.append("+ " + line(e)); continue }
            var what: [String] = []
            if was.value != e.value { what.append("value \((was.value ?? "").debugDescription) → \((e.value ?? "").debugDescription)") }
            for flag in ["checked", "selected", "covered", "disabled", "invalid", "focused"] where was.flags.contains(flag) != e.flags.contains(flag) {
                what.append(e.flags.contains(flag) ? "now \(flag)" : "no longer \(flag)")
            }
            if !what.isEmpty { changed.append("~ w\(e.index) \(e.role) \(e.text.prefix(40).debugDescription): " + what.joined(separator: ", ")) }
        }
        for e in previous.elements where new[e.index]?.key != e.key { removed.append("- w\(e.index) \(e.role): \(e.text.prefix(60))") }
        // Mostly different: a new step or screen — the full listing reads better than a wall of +/- lines.
        let total = max(previous.elements.count, current.elements.count)
        if total >= 6, Double(added.count + removed.count + changed.count) > Double(total) * 0.5 { return nil }
        var out = removed + added + changed
        if previous.headings != current.headings, !current.headings.isEmpty { out.append("headings now: " + current.headings.joined(separator: " | ")) }
        for m in current.messages where !previous.messages.contains(m) { out.append("! message: “\(m)”") }
        for m in previous.messages where !current.messages.contains(m) { out.append("message gone: “\(m)”") }
        if previous.above != current.above || previous.below != current.below {
            out.append("not shown now: \(current.above) fields/buttons above, \(current.below) below")
        }
        return out.joined(separator: "\n")
    }

    /// Where the out-of-view fields are when they're inside a scrolling box (a modal's body), e.g.
    /// "in the “Apply to Acme” dialog: 4 fields/buttons below (scroll moves the dialog)". nil when there are none.
    static func paneSummary(_ page: Page) -> String? {
        let parts = page.panes.filter { $0.above + $0.below > 0 }.map { p -> String in
            let name = p.name.isEmpty ? (p.modal ? "the dialog" : "a scrolling panel") : "the “\(p.name)” \(p.modal ? "dialog" : "panel")"
            return "in \(name): \(p.above) above, \(p.below) below\(p.modal ? " (scroll moves the dialog)" : "")"
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Same document: origin and path (a changed query or #hash on a single-page app is still the same page).
    private static func samePage(_ a: String, _ b: String) -> Bool {
        guard let x = URLComponents(string: a), let y = URLComponents(string: b) else { return a == b }
        return x.scheme == y.scheme && x.host == y.host && x.port == y.port && x.path == y.path
    }

    /// The viewport sits at the bottom of the window, flush with its sides: window origin + the difference
    /// between outer and inner size (toolbars on top, side panels split evenly).
    private static func estimate(_ r: [String: Any]) -> CGRect? {
        guard let sc = r["screen"] as? [String: Any], let vp = r["viewport"] as? [String: Any] else { return nil }
        func d(_ o: [String: Any], _ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        guard let x = d(sc, "x"), let y = d(sc, "y"), let ow = d(sc, "ow"), let oh = d(sc, "oh"),
              let vw = d(vp, "w"), let vh = d(vp, "h"), vw > 0, vh > 0 else { return nil }
        return CGRect(x: x + max(0, ow - vw) / 2, y: y + max(0, oh - vh), width: vw, height: vh)
    }

    private func parse(_ r: [String: Any], connection: ObjectIdentifier) -> Page {
        Replay.Recorder.shared.page(r)
        let vp = r["viewport"] as? [String: Any]
        let scroll = r["scroll"] as? [String: Any]
        let els = (r["elements"] as? [[String: Any]] ?? []).map { e -> PageElement in
            func d(_ k: String) -> Double { (e[k] as? NSNumber)?.doubleValue ?? 0 }
            var extra: [String] = []
            if let q = e["q"] as? String { extra.append("in “\(q)”") }
            if let frame = e["frame"] as? String { extra.append("inside \(frame)") }
            if e["dropdown"] as? Bool == true { extra.append("dropdown") }
            if let v = e["value"] as? String { extra.append("value=\(v.debugDescription)") }
            if let p = e["placeholder"] as? String, (e["text"] as? String) != p { extra.append("placeholder=\(p.debugDescription)") }
            if let o = e["options"] as? String { extra.append("options: \(o)") }
            let flags = ["required", "invalid", "focused", "checked", "unchecked", "selected", "disabled", "covered"].filter { e[$0] as? Bool == true }
            extra += flags
            if let href = e["href"] as? String { extra.append("→ \(href)") }
            return PageElement(index: (e["i"] as? Int) ?? 0, role: e["role"] as? String ?? "?", text: e["text"] as? String ?? "",
                               rect: CGRect(x: d("x"), y: d("y"), width: d("w"), height: d("h")),
                               editable: e["editable"] as? Bool == true, extra: extra.joined(separator: " "),
                               key: [e["frame"] as? String ?? "", e["key"] as? String ?? "\(e["role"] ?? "")|\(e["text"] ?? "")"].joined(separator: "|"),
                               value: e["value"] as? String, flags: Set(flags), question: e["q"] as? String,
                               placeholder: e["placeholder"] as? String,
                               options: (e["options"] as? String).map { $0.components(separatedBy: " | ") } ?? [],
                               dropdown: e["dropdown"] as? Bool == true)
        }
        let panes = (r["panes"] as? [[String: Any]] ?? []).map {
            Pane(name: $0["name"] as? String ?? "", modal: $0["modal"] as? Bool == true, above: $0["above"] as? Int ?? 0, below: $0["below"] as? Int ?? 0)
        }
        return Page(connection: connection, url: r["url"] as? String ?? "", title: r["title"] as? String ?? "",
                    viewport: CGSize(width: (vp?["w"] as? NSNumber)?.doubleValue ?? 1, height: (vp?["h"] as? NSNumber)?.doubleValue ?? 1),
                    scrollY: (scroll?["y"] as? NSNumber)?.doubleValue ?? 0, scrollMax: (scroll?["max"] as? NSNumber)?.doubleValue ?? 0,
                    headings: r["headings"] as? [String] ?? [], elements: els,
                    messages: r["messages"] as? [String] ?? [], text: r["text"] as? String ?? "",
                    above: r["above"] as? Int ?? 0, below: r["below"] as? Int ?? 0, ready: r["ready"] as? String ?? "complete",
                    problem: r["error"] as? String, estimatedArea: Self.estimate(r), panes: panes, tabId: r["tabId"] as? Int,
                    documentID: r["documentID"] as? String, snapshotID: r["snapshotID"] as? String)
    }
}
