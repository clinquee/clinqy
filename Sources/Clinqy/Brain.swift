import Foundation

/// A long-lived `agy` (or `claude -p`) process speaking stream-json. Keeping it alive means each turn costs only
/// model time (~1 s), and the conversation (what was tried, what the screen looked like) stays in context.
final class AgySession: @unchecked Sendable {
    enum BrainError: LocalizedError {
        case notInstalled, failed(String), died, busy

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return Provider.current == .agyCLI
                    ? "Agy CLI not found. Install Antigravity (or set AGY_PATH), or add an API key to ~/.config/clinqy/env"
                    : "Claude CLI not found. Install Claude Code (or set CLAUDE_PATH), or add an API key to ~/.config/clinqy/env"
            case .failed(let message):
                if message.contains("Not logged in") {
                    return Provider.current == .agyCLI
                        ? "Agy CLI isn't logged in. Run `agy` in a terminal once and log in."
                        : "Claude CLI isn't logged in. Run `claude` in a terminal once and log in."
                }
                return message
            case .died: return Provider.current == .agyCLI ? "The Agy process stopped unexpectedly" : "The Claude process stopped unexpectedly"
            case .busy: return "Still waiting on the previous reply"
            }
        }
    }

    static var agyPath: String? {
        if let explicit = Config.value("AGY_PATH") { return explicit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var claudePath: String? {
        if let explicit = Config.value("CLAUDE_PATH") { return explicit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    let sessionProvider: Provider
    let sessionModel: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: CheckedContinuation<String, Error>?
    /// The current turn's reply so far, and who wants to see it grow (see `send`).
    private var partialText = ""
    private var partialHandler: (@Sendable (String) -> Void)?
    private var dead = false
    private var lastErrorMessage: String?
    /// Set when PROVIDER is an HTTP API (see Providers.swift): turns go there instead of to a CLI process.
    private var api: APIChat?
    private var isAgy = true
    private var sessionDir: URL?
    private var systemPrompt = ""
    private var isFirstTurn = true

    /// `effort` overrides the configured reasoning effort (AGY_EFFORT / CLAUDE_EFFORT) for this session.
    init(system: String, model: String, provider: Provider = Provider.current, effort: String? = nil) throws {
        self.systemPrompt = system
        self.sessionProvider = provider
        self.sessionModel = provider.model(model)
        if provider != .agyCLI && provider != .claudeCLI {
            api = try APIChat(provider: provider, system: system, model: model, effort: effort)
            return
        }
        let path = provider == .agyCLI ? Self.agyPath : Self.claudePath
        guard let path else { throw BrainError.notInstalled }
        let execName = URL(fileURLWithPath: path).lastPathComponent
        isAgy = (provider == .agyCLI) || (execName == "agy")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-session-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.sessionDir = tempDir

        // Write AGENTS.md so agy automatically picks up system rules
        let agentsFile = tempDir.appendingPathComponent("AGENTS.md")
        try? system.write(to: agentsFile, atomically: true, encoding: .utf8)

        process.executableURL = URL(fileURLWithPath: path)
        if isAgy {
            var args = [
                "--sandbox",
                "--input-format", "stream-json", "--output-format", "stream-json",
                "--disable-slash-commands", "--dangerously-skip-permissions",
            ]
            var m = provider.model(model)
            let explicitEffort = effort ?? (isAgy
                ? (Config.value("AGY_EFFORT") ?? Config.value("CLAUDE_EFFORT"))
                : (Config.value("CLAUDE_EFFORT") ?? Config.value("AGY_EFFORT")))
            let effortSuffixes = ["-low", "-medium", "-high", "-xhigh", "-max"]
            let matchedSuffix = effortSuffixes.first { m.hasSuffix($0) }

            if let matchedSuffix {
                if let explicitEffort = explicitEffort?.lowercased(), !explicitEffort.isEmpty {
                    // Strip the baked-in suffix so agy doesn't reject explicit effort as a conflict
                    m = String(m.dropLast(matchedSuffix.count))
                    args += ["--effort", explicitEffort]
                }
                // When no explicit effort is set, let the model's baked-in suffix dictate effort; omit --effort
            } else if !m.contains("claude") {
                // Models without baked-in suffix (e.g. gemini-3.8-flash, gemini-3.1-pro) accept --effort
                let defaultEffort = model.lowercased() == "opus" ? "high" : "low"
                let effort = (explicitEffort ?? defaultEffort).lowercased()
                args += ["--effort", effort]
            }

            if !m.isEmpty && m != "default" {
                args += ["--model", m]
            }
            process.arguments = args
        } else {
            process.arguments = [
                "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--model", model, "--effort", effort ?? Config.value("CLAUDE_EFFORT") ?? "low", "--tools", "", "--system-prompt", system,
                "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence",
                "--include-partial-messages",
            ]
        }

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.currentDirectoryURL = tempDir
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            if let str = String(data: chunk, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                self.lock.withLock { self.lastErrorMessage = str }
            }
        }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty { self.fail(BrainError.died); return }
            self.consume(chunk)
        }
        process.terminationHandler = { [weak self] _ in self?.fail(BrainError.died) }
        try process.run()
    }

    var isAlive: Bool {
        if let api { return api.isAlive }
        return lock.withLock { !dead } && process.isRunning
    }

    /// Sends one user turn (text plus an optional JPEG) and returns the reply text. `partial` sees the reply text so
    /// far each time it grows (on a background thread). The HTTP and one-shot CLI providers don't stream, so it isn't
    /// called for them.
    var visionDelivery: VisionPolicy.Delivery { api == nil && isAgy ? .fileReference : .embedded }

    func send(_ text: String, image: String? = nil, partial: (@Sendable (String) -> Void)? = nil) async throws -> String {
        if let api { return try await api.send(text, image: image, partial: partial) }

        var line: Data
        if isAgy {
            var promptText = text
            if isFirstTurn {
                promptText = "<instructions>\n\(systemPrompt)\n</instructions>\n\n" + promptText
                isFirstTurn = false
            }
            if let image, let imgData = Data(base64Encoded: image), let dir = sessionDir {
                let screenURL = dir.appendingPathComponent("screen.jpg")
                try imgData.write(to: screenURL, options: .atomic)
                promptText += "\nVisual input (file reference): the current screenshot is \(screenURL.path). Open this exact file with view_file before choosing any visual action or screenshot coordinates. If you cannot inspect it, use semantic ids only and report that visual input is unavailable."
            }
            let payload: [String: Any] = [
                "event": "user",
                "message": ["role": "user", "content": [["type": "text", "text": promptText]]]
            ]
            line = try JSONSerialization.data(withJSONObject: payload)
        } else {
            var content: [[String: Any]] = []
            if let image {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image]])
            }
            content.append(["type": "text", "text": text])
            line = try JSONSerialization.data(withJSONObject: [
                "type": "user", "message": ["role": "user", "content": content],
            ])
        }
        line.append(0x0A)

        let reply: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            lock.lock()
            if dead {
                let err = lastErrorMessage.map { BrainError.failed($0) } ?? BrainError.died
                lock.unlock()
                continuation.resume(throwing: err)
                return
            }
            if pending != nil { lock.unlock(); continuation.resume(throwing: BrainError.busy); return }
            pending = continuation
            partialText = ""
            partialHandler = partial
            lock.unlock()
            input.fileHandleForWriting.write(line)
        }
        UsageStore.record(provider: sessionProvider, model: sessionModel)
        return reply
    }

    func close() {
        if let api { api.close(); return }
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        if let sessionDir { try? FileManager.default.removeItem(at: sessionDir) }
        fail(BrainError.died)
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var results: [Result<String, Error>] = []
        var grown: String?
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            // Agy streaming partial text
            if event["event"] as? String == "step_update",
               let step = event["step_update"] as? [String: Any],
               step["step_type"] as? String == "agent_response",
               let piece = step["text_delta"] as? String, pending != nil {
                partialText += piece
                grown = partialText
                continue
            }
            // Claude streaming partial text
            if event["type"] as? String == "stream_event" {
                if let e = event["event"] as? [String: Any], let delta = e["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta", let piece = delta["text"] as? String, pending != nil {
                    partialText += piece
                    grown = partialText
                }
                continue
            }
            // Agy final result
            if event["event"] as? String == "result", let res = event["result"] as? [String: Any] {
                let status = res["status"] as? String
                let text = res["response"] as? String ?? ""
                let err = res["error"] as? String
                if status == "ERROR" || (err != nil && !err!.isEmpty) {
                    let msg = err ?? (text.isEmpty ? "Agy process error" : text)
                    lastErrorMessage = msg
                    results.append(.failure(BrainError.failed(msg)))
                } else {
                    results.append(.success(text))
                }
                continue
            }
            // Claude final result
            if event["type"] as? String == "result" {
                let text = event["result"] as? String ?? ""
                results.append(event["is_error"] as? Bool == true ? .failure(BrainError.failed(text)) : .success(text))
                continue
            }
        }
        var toResume: [(CheckedContinuation<String, Error>, Result<String, Error>)] = []
        for result in results {
            if let p = pending { toResume.append((p, result)); pending = nil; partialHandler = nil }
        }
        let handler = results.isEmpty ? partialHandler : nil
        lock.unlock()
        if let grown, let handler { handler(grown) }
        for (continuation, result) in toResume { continuation.resume(with: result) }
    }

    private func fail(_ error: Error) {
        lock.lock()
        dead = true
        let p = pending
        pending = nil
        partialHandler = nil
        var errMsg = lastErrorMessage
        lock.unlock()
        if let msg = errMsg, (msg.contains("OAuth") || msg.contains("Not logged in") || msg.contains("Failed to authenticate")) && !msg.contains("claude auth login") {
            errMsg = "\(msg) — run 'claude auth login' in your terminal."
        }
        let errToThrow = errMsg.map { BrainError.failed($0) } ?? error
        p?.resume(throwing: errToThrow)
    }
}

typealias ClaudeSession = AgySession

/// Keeps one session started ahead of time so a request never waits for process startup.
@MainActor
enum Brain {
    static func defaultModel(for provider: Provider = Provider.current) -> String {
        switch provider {
        case .agyCLI:
            return Config.value("AGY_MODEL") ?? Config.value("CLAUDE_MODEL") ?? "sonnet"
        case .codexCLI:
            return Config.value("CODEX_MODEL") ?? ""
        case .claudeCLI:
            return Config.value("CLAUDE_MODEL") ?? Config.value("AGY_MODEL") ?? "sonnet"
        case .anthropic:
            return Config.value("ANTHROPIC_MODEL") ?? Config.value("CLAUDE_MODEL") ?? "sonnet"
        case .openai:
            return Config.value("OPENAI_MODEL") ?? "sonnet"
        case .gemini:
            return Config.value("GEMINI_MODEL") ?? "sonnet"
        case .openrouter:
            return Config.value("OPENROUTER_MODEL") ?? "sonnet"
        case .ollama, .compatible:
            return Config.value("LOCAL_MODEL") ?? "qwen3-vl"
        }
    }
    static var model: String { defaultModel(for: Provider.current) }
    private static var warm: AgySession?

    static func reloadModel() {
        warm?.close()
        warm = nil
        prewarm()
    }

    static func prewarm() {
        if warm?.isAlive == true { return }
        warm = try? AgySession(system: AgentPrompt.system, model: model)
    }

    /// Hands out the warm session (or a fresh one) and starts warming the next.
    static func session(model override: String? = nil, provider overrideProvider: Provider? = nil) throws -> AgySession {
        let currentProvider = overrideProvider ?? Provider.current
        let defaultM = defaultModel(for: currentProvider)
        let effectiveModel = override ?? defaultM
        if let override, override != defaultM { return try AgySession(system: AgentPrompt.system, model: override, provider: currentProvider) }
        let s: AgySession
        if let w = warm, w.isAlive, w.sessionProvider == currentProvider {
            s = w
        } else {
            warm?.close()
            s = try AgySession(system: AgentPrompt.system, model: effectiveModel, provider: currentProvider)
        }
        warm = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { prewarm() }
        return s
    }

    /// Pulls the JSON object out of a reply, tolerating code fences or stray prose around it.
    static func json(from reply: String) -> [String: Any]? {
        let envelope = { (obj: [String: Any]) -> [String: Any] in
            // A bare action ({"do":"ask",…}) instead of the reply envelope: run it as the turn's only action.
            obj["do"] != nil && obj["actions"] == nil ? ["say": "", "actions": [obj], "done": false] : obj
        }
        if let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
           let obj = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] {
            return envelope(obj)
        }
        // A reply that "corrects" itself ("Wait — correcting format: {…}") or wraps the JSON in stray tool tags holds
        // more than one object: the last complete reply object is the one meant.
        for obj in objects(in: reply).reversed() where obj["actions"] != nil || obj["say"] != nil || obj["do"] != nil {
            return envelope(obj)
        }
        // Sometimes the model writes tool-call tags instead (`<invoke name="scroll"><parameter name="dir">up</parameter>…`):
        // read every one, with its parameters, as an action.
        return invokes(in: reply)
    }

    /// The first action of a reply that's still being written, once that action is complete ("actions":[{…} closed).
    /// nil until then, or when the reply isn't the usual {"say","actions"} object.
    static func firstAction(inPartial text: String) -> [String: Any]? {
        guard let open = text.range(of: #""actions"\s*:\s*\["#, options: .regularExpression) else { return nil }
        var i = open.upperBound
        while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
        guard i < text.endIndex, text[i] == "{" else { return nil }
        let start = i
        var depth = 0, inString = false, escaped = false
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let object = String(text[start...i])
                    guard let action = try? JSONSerialization.jsonObject(with: Data(object.utf8)) as? [String: Any], action["do"] is String else { return nil }
                    return action
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Every complete top-level {…} in `text` that parses as a JSON object, in order.
    static func objects(in text: String) -> [[String: Any]] {
        var found: [[String: Any]] = []
        var depth = 0, inString = false, escaped = false
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = depth > 0
            } else if c == "{" {
                if depth == 0 { start = i }
                depth += 1
            } else if c == "}", depth > 0 {
                depth -= 1
                if depth == 0, let s = start,
                   let obj = try? JSONSerialization.jsonObject(with: Data(text[s...i].utf8)) as? [String: Any] {
                    found.append(obj)
                }
            }
            i = text.index(after: i)
        }
        return found
    }

    static func invokes(in reply: String) -> [String: Any]? {
        guard let block = try? NSRegularExpression(pattern: #"<invoke name="([A-Za-z_]+)"\s*/?>(.*?)(?:</invoke>|(?=<invoke )|$)"#,
                                                   options: [.dotMatchesLineSeparators]),
              let param = try? NSRegularExpression(pattern: #"<parameter name="([A-Za-z_]+)">(.*?)</parameter>"#,
                                                   options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = reply as NSString
        var actions: [[String: Any]] = []
        var done = false, say = ""
        for m in block.matches(in: reply, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            let body = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
            var action: [String: Any] = ["do": name]
            let bns = body as NSString
            for p in param.matches(in: body, range: NSRange(location: 0, length: bns.length)) {
                let key = bns.substring(with: p.range(at: 1))
                let raw = bns.substring(with: p.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                // Numbers, booleans, arrays arrive as JSON; anything else is text.
                action[key] = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) ?? raw
            }
            if name == "done" || name == "finish" { done = true; say = action["say"] as? String ?? action["text"] as? String ?? say; continue }
            actions.append(action)
        }
        guard !actions.isEmpty || done else { return nil }
        return ["say": say, "actions": actions, "done": done]
    }
}
