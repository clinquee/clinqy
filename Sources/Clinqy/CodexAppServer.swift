import Foundation
import Darwin

/// A model-only Codex conversation. Clinqy's outer harness remains the only executor of computer actions.
/// Protocol: https://learn.chatgpt.com/docs/app-server ; fields checked against `codex 0.165.0`
/// `app-server generate-json-schema --experimental`. Opt-in because older CLIs lack environment isolation.
actor CodexAppServer {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private struct Object: @unchecked Sendable { let value: [String: Any] }
    private let executable: String
    private let prefix: [String]
    private let system: String
    private let model: String
    private let effort: String?
    private let timeout: TimeInterval
    private let directory: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private let writes = DispatchQueue(label: "clinqy.codex.protocol-write")
    private var reader: Task<Void, Never>?
    private var outputStream: AsyncStream<Data>.Continuation?
    private var generation = UUID()
    private var buffer = Data()
    private var nextID = 0
    private var lastMethod = "startup"
    private var pending: [Int: CheckedContinuation<Object, Error>] = [:]
    private var threadID: String?
    private var turnID: String?
    private var awaitingTurnStart = false
    private var deferredEvents: [(String, Object)] = []
    private var sending = false
    private var closed = false
    private var messages: [String: String] = [:]
    private var messageOrder: [String] = []
    private var finalMessage: String?
    private var completion: Result<String, Error>?
    private var turnWaiter: CheckedContinuation<String, Error>?

    // Explicit disables are verified in effective config before any thread or inference is created.
    private static let disabledFeatures = ["apps", "plugins", "shell_tool", "unified_exec", "js_repl",
        "code_mode", "computer_use", "browser_use", "browser_use_external", "in_app_browser",
        "in_app_local_automation", "multi_agent", "hooks", "plugin_hooks", "codex_hooks",
        "image_generation", "imagegenext", "memory_tool", "apply_patch_freeform"]

    init(executable: String, arguments: [String] = [], system: String, model: String = "", effort: String? = nil, timeout: TimeInterval = 120) {
        self.executable = executable; self.prefix = arguments; self.system = system; self.model = model; self.effort = effort
        self.timeout = timeout
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-codex-session-" + UUID().uuidString)
    }

    /// Checks protocol and restrictions without starting an inference turn or changing CLI sign-in.
    func validateConfiguration() async throws {
        guard !closed, !sending else { throw failure("session is closed or busy") }
        do { if threadID == nil { try await prepare() } }
        catch { stop(error); throw error }
    }

    func send(_ text: String, image: String?) async throws -> String {
        guard !closed else { throw failure("session is closed; start a new task") }
        guard !sending else { throw failure("a turn is already running") }
        sending = true
        defer { sending = false }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                if threadID == nil { try await prepare() }
                try Task.checkCancellation()
                guard let threadID, !closed else { throw failure("session stopped") }
                turnID = nil; messages = [:]; messageOrder = []; finalMessage = nil; completion = nil
                awaitingTurnStart = true; deferredEvents = []
                var items: [[String: Any]] = [["type": "text", "text": text]]
                if let image {
                    guard Data(base64Encoded: image) != nil else { throw failure("invalid screenshot") }
                    items.append(["type": "image", "url": "data:image/jpeg;base64," + image])
                }
                // Empty environments disables shell/filesystem/computer execution, independent of sandbox mode.
                var turn: [String: Any] = ["threadId": threadID, "input": items,
                    "environments": [], "approvalPolicy": "untrusted",
                    "sandboxPolicy": ["type": "readOnly", "networkAccess": false]]
                if let effort { turn["effort"] = effort }
                let reply = try await request("turn/start", turn)
                guard let turn = reply.value["turn"] as? [String: Any], let id = turn["id"] as? String,
                      turnID == nil || turnID == id else { throw failure("invalid turn identity") }
                turnID = id
                awaitingTurnStart = false
                let buffered = deferredEvents; deferredEvents = []
                for (method, params) in buffered { event(method, params.value) }
                return try await withCheckedThrowingContinuation { continuation in
                    if let completion { continuation.resume(with: completion) }
                    else {
                        turnWaiter = continuation
                        let token = generation
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(self?.timeout ?? 120))
                            await self?.expireTurn(token, turn: id)
                        }
                    }
                }
            } catch {
                // A sent turn may have been processed. Never restart/replay it or fall back to exec automatically.
                stop(error)
                throw error
            }
        } onCancel: { Task { await self.close() } }
    }

    func close() { stop(failure("session cancelled; the last turn was not replayed")) }

    private func prepare() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try launch(disabledServers: [])
        try await initialize()
        let initial = try await effectiveConfig()
        let servers = (initial["mcp_servers"] as? [String: Any] ?? [:]).keys.sorted()
        // `mcp_servers={}` merges with user config, so explicitly disable every inherited server instead.
        if !servers.isEmpty {
            tearDown()
            try launch(disabledServers: servers)
            try await initialize()
        }
        let config = try await effectiveConfig()
        let features = config["features"] as? [String: Any] ?? [:]
        guard Self.disabledFeatures.allSatisfy({ features[$0] as? Bool == false }),
              config["web_search"] as? String == "disabled",
              (config["mcp_servers"] as? [String: [String: Any]] ?? [:]).values.allSatisfy({ $0["enabled"] as? Bool == false }) else {
            throw failure("could not verify model-only tool isolation; use CODEX_TRANSPORT=exec explicitly")
        }
        var params: [String: Any] = ["cwd": directory.path, "ephemeral": true, "environments": [],
            "sandbox": "read-only", "approvalPolicy": "untrusted",
            "baseInstructions": system + "\nReturn only the next assistant reply. All computer actions are performed by Clinqy. Do not call tools."]
        if !model.isEmpty { params["model"] = model }
        let result = try await request("thread/start", params)
        guard let thread = result.value["thread"] as? [String: Any], let id = thread["id"] as? String,
              let environments = thread["environments"] as? [Any], environments.isEmpty,
              let sandbox = result.value["sandbox"] as? [String: Any], sandbox["type"] as? String == "readOnly",
              sandbox["networkAccess"] as? Bool != true,
              result.value["approvalPolicy"] as? String == "untrusted" else {
            throw failure("server did not acknowledge model-only environment restrictions")
        }
        threadID = id
    }

    private func launch(disabledServers: [String]) throws {
        let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        var args = prefix + ["app-server", "--stdio"]
        for feature in Self.disabledFeatures { args += ["-c", "features." + feature + "=false"] }
        args += ["-c", "web_search=\"disabled\""]
        if !disabledServers.isEmpty {
            // CLI dotted paths split on '.', without parsing TOML key quotes. Put quoted names inside
            // an inline table instead, preserving dots/quotes and the inherited transport configuration.
            let entries = try disabledServers.map { server in
                let quoted = String(data: try JSONSerialization.data(withJSONObject: server,
                    options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
                return quoted + "={enabled=false}"
            }
            args += ["-c", "mcp_servers={" + entries.joined(separator: ",") + "}"]
        }
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
        p.currentDirectoryURL = directory
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        // A child can close stdin during a screenshot write. Suppress SIGPIPE on this pipe only, so
        // FileHandle reports EPIPE to the adapter instead of terminating the entire desktop app.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw failure("could not configure safe child-process input")
        }
        let token = UUID(); generation = token; buffer = Data()
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; errors = stderr.fileHandleForReading
        let stream = AsyncStream<Data> { continuation in
            outputStream = continuation
            output?.readabilityHandler = { handle in
                let data = handle.availableData
                continuation.yield(data)
                if data.isEmpty { continuation.finish() }
            }
        }
        // One consumer preserves chunk ordering; a Task per chunk can corrupt fragmented JSON.
        reader = Task { [weak self] in
            for await data in stream { await self?.receive(data, generation: token) }
        }
        // Discard stderr rather than log provider output that could contain private account information.
        errors?.readabilityHandler = { handle in _ = handle.availableData }
        // EOF, rather than terminationHandler, drains final stdout messages before reporting process death.
        process = p
        do { try p.run() } catch { tearDown(); throw error }
    }

    private func initialize() async throws {
        _ = try await request("initialize", ["clientInfo": ["name": "clinqy", "title": "Clinqy", "version": "1"],
            "capabilities": ["experimentalApi": true]])
        try write(["method": "initialized"])
    }

    private func effectiveConfig() async throws -> [String: Any] {
        let result = try await request("config/read", ["includeLayers": false])
        guard let config = result.value["config"] as? [String: Any] else { throw failure("missing effective configuration") }
        return config
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> Object {
        guard !closed, process?.isRunning == true else { throw failure("server stopped; no turn was replayed") }
        nextID += 1; let id = nextID, token = generation
        lastMethod = method
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try write(["id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                await self?.expireRequest(token, id: id)
            }
        }
    }

    private func write(_ object: [String: Any]) throws {
        guard let input else { throw failure("server input is closed") }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        let token = generation, payload = data
        // A child that stops reading a large image must not block actor cancellation or timeouts.
        writes.async { [weak self] in
            do { try input.write(contentsOf: payload) }
            catch { Task { await self?.writeFailed(token) } }
        }
    }

    private func receive(_ data: Data, generation token: UUID) {
        guard token == generation, !closed else { return }
        guard !data.isEmpty else { stop(failure("server disconnected during " + lastMethod + "; no turn was replayed")); return }
        buffer.append(data)
        guard buffer.count <= 16 * 1024 * 1024 else { stop(failure("oversized server response")); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                stop(failure("invalid server message")); return
            }
            if let method = object["method"] as? String {
                // No server-initiated request is authorized, including approvals and dynamic tools.
                if object["id"] != nil { stop(failure("server requested an unauthorized tool or approval")); return }
                event(method, object["params"] as? [String: Any] ?? [:])
            } else if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                if object["error"] != nil { continuation.resume(throwing: failure("server rejected the request; check CLI compatibility and sign-in")) }
                else if let value = object["result"] as? [String: Any] { continuation.resume(returning: Object(value: value)) }
                else { continuation.resume(throwing: failure("missing server result")) }
            }
            if closed { return }
        }
    }

    private func event(_ method: String, _ params: [String: Any]) {
        guard sending, params["threadId"] as? String == threadID else { return }
        if awaitingTurnStart {
            guard deferredEvents.count < 1000 else { stop(failure("too many events before turn acknowledgement")); return }
            deferredEvents.append((method, Object(value: params))); return
        }
        let eventTurn = (params["turnId"] as? String) ?? (params["turn"] as? [String: Any])?["id"] as? String
        guard let turnID, eventTurn == turnID else { return }
        if method == "item/started" || method == "item/completed", let item = params["item"] as? [String: Any] {
            let type = item["type"] as? String ?? ""
            guard ["userMessage", "agentMessage", "reasoning", "contextCompaction"].contains(type) else {
                stop(failure("server attempted a tool in a model-only session")); return
            }
            if type == "agentMessage", let id = item["id"] as? String, let text = item["text"] as? String {
                if messages[id] == nil { messageOrder.append(id) }; messages[id] = text
                if item["phase"] as? String == "final_answer" { finalMessage = text }
            }
        } else if method == "item/agentMessage/delta", let id = params["itemId"] as? String, let text = params["delta"] as? String {
            if messages[id] == nil { messageOrder.append(id) }; messages[id, default: ""] += text
        } else if method == "turn/completed", let turn = params["turn"] as? [String: Any] {
            let text = (finalMessage ?? messageOrder.last.flatMap { messages[$0] } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if turn["status"] as? String == "completed", !text.isEmpty { complete(.success(text)) }
            else { stop(failure("turn failed or was interrupted; it was not replayed")) }
        }
    }

    private func complete(_ result: Result<String, Error>) {
        completion = result
        let waiter = turnWaiter; turnWaiter = nil; waiter?.resume(with: result)
    }
    private func expireRequest(_ token: UUID, id: Int) {
        if token == generation, pending[id] != nil { stop(failure("server request timed out; it was not replayed")) }
    }
    private func expireTurn(_ token: UUID, turn: String) {
        if token == generation, turnID == turn, completion == nil { stop(failure("turn timed out; it was not replayed")) }
    }
    private func writeFailed(_ token: UUID) {
        if token == generation, !closed { stop(failure("server input disconnected; no turn was replayed")) }
    }
    private func stop(_ error: Error) {
        guard !closed else { return }
        closed = true
        let requests = pending; pending = [:]
        for continuation in requests.values { continuation.resume(throwing: error) }
        complete(.failure(error)); tearDown()
        try? FileManager.default.removeItem(at: directory)
    }
    private func tearDown() {
        generation = UUID()
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        process?.terminationHandler = nil
        outputStream?.finish(); outputStream = nil; reader?.cancel(); reader = nil
        if let process, process.isRunning {
            process.terminate()
            // Bound cleanup even for an unresponsive child; Process retains the original process identity.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        if let input { writes.async { try? input.close() } }
        try? output?.close(); try? errors?.close()
        process = nil; input = nil; output = nil; errors = nil; buffer = Data()
    }
    private func failure(_ message: String) -> Failure { Failure(message: "Codex app-server: " + message) }
}
