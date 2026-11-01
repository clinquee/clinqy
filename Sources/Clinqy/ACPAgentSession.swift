import Foundation

/// A model-only ACP session over a vendor CLI's existing local login. OpenCode runs with a temporary primary
/// agent that denies every tool; Cursor runs in its documented read-only Ask mode. Clinqy remains the only executor
/// of computer actions.
actor ACPAgentSession {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let provider: Provider
    private let executable: String
    private let system: String
    private let model: String
    private let directory: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: Task<Void, Never>?
    private var streamContinuation: AsyncStream<Data>.Continuation?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var sessionID: String?
    private var generation = UUID()
    private var closed = false
    private var sending = false
    private var responseText = ""
    private var partial: (@Sendable (String) -> Void)?

    init(provider: Provider, executable: String, system: String, model: String) {
        self.provider = provider
        self.executable = executable
        self.system = system
        self.model = model
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clinqy-\(provider.rawValue)-\(UUID().uuidString)")
    }

    func send(_ text: String, image: String?, partial: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard !closed, !sending else { throw Failure(message: "The \(provider.displayName) session is closed or busy") }
        sending = true
        defer { sending = false; self.partial = nil }
        do {
            if sessionID == nil { try await prepare() }
            guard let sessionID else { throw Failure(message: "ACP session did not start") }
            responseText = ""
            self.partial = partial
            var content: [[String: Any]] = []
            content.append(["type": "text", "text": text])
            if let image {
                guard Data(base64Encoded: image) != nil else { throw Failure(message: "Invalid screenshot encoding") }
                content.append(["type": "image", "mimeType": "image/jpeg", "data": image])
            }
            let result = try await request("session/prompt", ["sessionId": sessionID, "prompt": content], timeout: 120)
            guard result["stopReason"] as? String != "cancelled" else {
                throw Failure(message: "\(provider.displayName) cancelled the turn")
            }
            let answer = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { throw Failure(message: "Empty reply from \(provider.displayName)") }
            return answer
        } catch {
            stop(error)
            throw error
        }
    }

    func close() { Task { stop(Failure(message: "ACP session closed")) } }

    private func prepare() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if provider == .opencodeCLI {
            try writeOpenCodeIsolation()
        } else if provider == .cursorCLI {
            try writeCursorIsolation()
        }
        try launch()
        let initialized = try await request("initialize", [
            "protocolVersion": 1,
            "clientInfo": ["name": "clinqy", "version": "1"],
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
        ])
        try notify(["method": "initialized"])

        if provider == .cursorCLI {
            do {
                _ = try await request("authenticate", ["methodId": "cursor_login"])
            } catch {
                throw Failure(message: "Cursor Agent couldn't use its current login. Run `agent login` and retry. \(error.localizedDescription)")
            }
        } else if let methods = initialized["authMethods"] as? [[String: Any]],
                  methods.contains(where: { $0["id"] as? String == "opencode-login" && $0["type"] as? String == "agent" }) {
            _ = try await request("authenticate", ["methodId": "opencode-login"])
        }

        let created = try await request("session/new", ["cwd": directory.path, "mcpServers": []])
        guard let id = created["sessionId"] as? String, !id.isEmpty else {
            throw Failure(message: "\(provider.displayName) returned no ACP session ID")
        }
        sessionID = id
        let mode = provider == .cursorCLI ? "ask" : "clinqy"
        _ = try await request("session/set_mode", ["sessionId": id, "modeId": mode])
        if !model.isEmpty {
            _ = try await request("session/set_config_option", ["sessionId": id, "configId": "model", "value": model])
        }
    }

    private func writeOpenCodeIsolation() throws {
        let agents = directory.appendingPathComponent(".opencode/agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let rules = """
        ---
        description: Clinqy model-only response agent
        mode: primary
        permissions:
          - action: "*"
            resource: "*"
            effect: deny
        ---
        \(system)
        """
        try rules.write(to: agents.appendingPathComponent("clinqy.md"), atomically: true, encoding: .utf8)
        let config = #"{"$schema":"https://opencode.ai/config.json","default_agent":"clinqy","permissions":[{"action":"*","resource":"*","effect":"deny"}]}"#
        try config.write(to: directory.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)
    }

    private func writeCursorIsolation() throws {
        // Cursor CLI loads AGENTS.md from the project root as persistent instructions.
        try system.write(to: directory.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let configDirectory = directory.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let config: [String: Any] = [
            "version": 1,
            "editor": ["vimMode": false],
            "permissions": ["allow": [String](), "deny": [
                "Shell(*)", "Read(*)", "Write(*)", "WebFetch(*)", "Mcp(*:*)",
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        try data.write(to: configDirectory.appendingPathComponent("cli.json"), options: .atomic)
    }

    private func launch() throws {
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["acp"]
        child.currentDirectoryURL = directory
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        let providerEnvironmentKeys: [String]
        if provider == .cursorCLI {
            providerEnvironmentKeys = ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"]
        } else if provider == .opencodeCLI {
            providerEnvironmentKeys = ["OPENCODE_API_KEY", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "OPENCODE_DB"]
        } else {
            providerEnvironmentKeys = []
        }
        for key in providerEnvironmentKeys {
            if let value = Config.value(key) { environment[key] = value }
        }
        if provider == .opencodeCLI {
            // Keep this process model-only even when the user's global config enables plugins or tools.
            environment["OPENCODE_PURE"] = "true"
            environment["OPENCODE_CONFIG_CONTENT"] = try enforcedOpenCodeConfigContent(Config.value("OPENCODE_CONFIG_CONTENT"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = ["\(home)/.local/bin", "\(home)/.opencode/bin", "/opt/homebrew/bin", "/usr/local/bin", existingPath]
            .joined(separator: ":")
        child.environment = environment
        let token = UUID()
        generation = token
        let stream = AsyncStream<Data> { continuation in
            streamContinuation = continuation
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                continuation.yield(data)
                if data.isEmpty { continuation.finish() }
            }
        }
        reader = Task { [weak self] in
            for await data in stream { await self?.receive(data, token: token) }
        }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        do { try child.run() } catch { tearDown(); throw error }
    }

    private func enforcedOpenCodeConfigContent(_ existing: String?) throws -> String {
        var config: [String: Any] = [:]
        if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let data = existing.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data),
                  let object = value as? [String: Any] else {
                throw Failure(message: "OPENCODE_CONFIG_CONTENT must be a JSON object for isolated ACP sessions")
            }
            config = object
        }
        let denyAll: [String: String] = ["action": "*", "resource": "*", "effect": "deny"]

        var globalRules = config["permissions"] as? [[String: Any]] ?? []
        if config["permissions"] != nil && !(config["permissions"] is [[String: Any]]) {
            throw Failure(message: "OPENCODE_CONFIG_CONTENT permissions must be an array")
        }
        globalRules.append(denyAll)
        config["permissions"] = globalRules

        var agents = config["agents"] as? [String: Any] ?? [:]
        if config["agents"] != nil && !(config["agents"] is [String: Any]) {
            throw Failure(message: "OPENCODE_CONFIG_CONTENT agents must be an object")
        }
        var clinqy = agents["clinqy"] as? [String: Any] ?? [:]
        if agents["clinqy"] != nil && !(agents["clinqy"] is [String: Any]) {
            throw Failure(message: "OPENCODE_CONFIG_CONTENT agents.clinqy must be an object")
        }
        var agentRules = clinqy["permissions"] as? [[String: Any]] ?? []
        if clinqy["permissions"] != nil && !(clinqy["permissions"] is [[String: Any]]) {
            throw Failure(message: "OPENCODE_CONFIG_CONTENT agents.clinqy.permissions must be an array")
        }
        agentRules.append(denyAll)
        clinqy["permissions"] = agentRules
        agents["clinqy"] = clinqy
        config["agents"] = agents

        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else {
            throw Failure(message: "Couldn't encode isolated OpenCode ACP settings")
        }
        return result
    }

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 20) async throws -> [String: Any] {
        guard !closed, process?.isRunning == true else { throw Failure(message: "\(provider.displayName) ACP process stopped") }
        nextID += 1
        let id = nextID, token = generation
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try notify(["id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(id, token: token, method: method)
            }
        }
    }

    private func notify(_ object: [String: Any]) throws {
        guard let input else { throw Failure(message: "\(provider.displayName) ACP input closed") }
        var message = object
        message["jsonrpc"] = "2.0"
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data, token: UUID) {
        guard token == generation, !closed else { return }
        guard !data.isEmpty else { Task { stop(Failure(message: "\(provider.displayName) ACP process ended")) }; return }
        buffer.append(data)
        guard buffer.count <= 16 * 1024 * 1024 else { Task { stop(Failure(message: "Oversized ACP response")) }; return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                Task { stop(Failure(message: "Invalid ACP response from \(provider.displayName)")) }
                return
            }
            if let method = object["method"] as? String {
                if let id = object["id"] {
                    if method == "session/request_permission" {
                        // Match a reject option advertised by this agent; never invent or approve an option.
                        let options = (object["params"] as? [String: Any])?["options"] as? [[String: Any]] ?? []
                        let reject = options.first { $0["kind"] as? String == "reject_once" }
                            ?? options.first { $0["kind"] as? String == "reject_always" }
                        let outcome: [String: Any]
                        if let optionID = reject?["optionId"] as? String {
                            outcome = ["outcome": "selected", "optionId": optionID]
                        } else {
                            outcome = ["outcome": "cancelled"]
                        }
                        try? notify(["id": id, "result": ["outcome": outcome]])
                    } else {
                        try? notify(["id": id, "error": ["code": -32601, "message": "Unsupported ACP request"]])
                    }
                } else {
                    event(method, object["params"] as? [String: Any] ?? [:])
                }
            } else if let id = object["id"] as? Int, let waiter = pending.removeValue(forKey: id) {
                if let error = object["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "request failed"
                    if provider == .opencodeCLI && message.lowercased().contains("auth") {
                        waiter.resume(throwing: Failure(message: "OpenCode needs a provider login. Run `opencode auth login` and retry. \(message)"))
                    } else {
                        waiter.resume(throwing: Failure(message: "\(provider.displayName): \(message)"))
                    }
                } else if let result = object["result"] as? [String: Any] {
                    waiter.resume(returning: result)
                } else {
                    waiter.resume(throwing: Failure(message: "Missing ACP result from \(provider.displayName)"))
                }
            }
        }
    }

    private func event(_ method: String, _ params: [String: Any]) {
        guard method == "session/update", params["sessionId"] as? String == sessionID,
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "agent_message_chunk" else { return }
        let chunk: String?
        if let content = update["content"] as? [String: Any] { chunk = content["text"] as? String }
        else { chunk = update["text"] as? String }
        guard let chunk, !chunk.isEmpty else { return }
        responseText += chunk
        partial?(responseText)
    }

    private func expire(_ id: Int, token: UUID, method: String) {
        guard token == generation, let waiter = pending.removeValue(forKey: id) else { return }
        waiter.resume(throwing: Failure(message: "Timed out waiting for \(provider.displayName) during \(method)"))
        Task { stop(Failure(message: "ACP request timed out")) }
    }

    private func stop(_ error: Error) {
        guard !closed else { return }
        closed = true
        for (_, waiter) in pending { waiter.resume(throwing: error) }
        pending.removeAll()
        tearDown()
        try? FileManager.default.removeItem(at: directory)
    }

    private func tearDown() {
        output?.readabilityHandler = nil
        streamContinuation?.finish()
        reader?.cancel()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
    }
}
