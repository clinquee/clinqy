import Foundation
import SQLite3

/// Which model service answers. Set PROVIDER in ~/.config/clinqy/env (`Clinqy model <name>`); with none set,
/// PROVIDER_ORDER is checked from left to right and the first configured provider is used.
enum Provider: String, CaseIterable, Sendable {
    case claudeCLI = "claude-cli", agyCLI = "agy-cli", codexCLI = "codex-cli"
    case opencodeCLI = "opencode-cli", cursorCLI = "cursor-cli"
    case anthropic, openai, gemini, openrouter, ollama, compatible = "openai-compatible"

    private final class ProbeResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ value: Bool) { lock.withLock { self.value = value } }
        func get() -> Bool { lock.withLock { value } }
    }

    var displayName: String {
        switch self {
        case .claudeCLI: return "Claude Code"
        case .agyCLI: return "Antigravity CLI"
        case .codexCLI: return "Codex CLI"
        case .opencodeCLI: return "OpenCode"
        case .cursorCLI: return "Cursor Agent"
        case .anthropic: return "Anthropic API"
        case .openai: return "OpenAI API"
        case .gemini: return "Google Gemini"
        case .openrouter: return "OpenRouter"
        case .ollama: return "Ollama"
        case .compatible: return "OpenAI-compatible API"
        }
    }

    var isConfigured: Bool {
        switch self {
        case .claudeCLI: return AgySession.claudePath != nil && Self.isClaudeLoggedIn
        case .agyCLI: return cliPath != nil
        case .codexCLI: return cliPath != nil && Self.codexLoginCache.isLoggedIn(path: cliPath)
        case .opencodeCLI:
            return cliPath != nil && (Config.value("OPENCODE_API_KEY")?.isEmpty == false || Self.openCodeAuthExists)
        case .cursorCLI: return cliPath != nil && Self.cursorAuthExists
        case .anthropic, .openai, .gemini, .openrouter: return key != nil
        case .ollama: return Self.localServerReachable
        case .compatible: return Config.value("OPENAI_BASE_URL") != nil
        }
    }

    static var isManagedByEnvironment: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["PROVIDER"] != nil || env["USE_AGY"] != nil ||
            CommandLine.arguments.contains(where: { ["--agy", "--agy-cli", "--claude", "--claude-cli", "--codex", "--codex-cli", "--opencode", "--opencode-cli", "--cursor", "--cursor-cli"].contains($0) })
    }

    /// Flag switch: set via --agy command line flag, USE_AGY=1/true, or PROVIDER=agy-cli.
    static var useAgy: Bool {
        if CommandLine.arguments.contains("--agy") || CommandLine.arguments.contains("--agy-cli") { return true }
        if CommandLine.arguments.contains("--claude") || CommandLine.arguments.contains("--claude-cli") { return false }
        if let val = Config.value("USE_AGY")?.lowercased() {
            return ["1", "true", "yes", "on"].contains(val)
        }
        if let raw = Config.value("PROVIDER")?.lowercased() {
            return ["agy", "agy-cli", "antigravity", "gemini-cli"].contains(raw)
        }
        return false
    }

    private final class LoginCache: @unchecked Sendable {
        let lock = NSLock()
        var value = UserDefaults.standard.bool(forKey: "claudeLoginAvailable")
        var checked = Date.distantPast
        var refreshing = false
        func read() -> Bool {
            lock.lock()
            let result = value
            let refresh = !refreshing && Date().timeIntervalSince(checked) > 60
            if refresh { refreshing = true }
            lock.unlock()
            if refresh {
                DispatchQueue.global(qos: .utility).async {
                    let available = Self.probe()
                    self.lock.lock(); self.value = available; self.checked = Date(); self.refreshing = false; self.lock.unlock()
                    UserDefaults.standard.set(available, forKey: "claudeLoginAvailable")
                }
            }
            return result
        }
        private static func probe() -> Bool {
            #if os(macOS)
            // No credential bytes leave this process or enter logs/preferences.
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: deadline)
                defer { deadline.cancel() }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let oauth = object["claudeAiOauth"] as? [String: Any],
                      let token = oauth["accessToken"] as? String else { return false }
                return !token.isEmpty
            } catch { return false }
            #else
            return true
            #endif
        }
    }
    private static let loginCache = LoginCache()
    /// UI and startup never wait on a Keychain subprocess. A short-lived cached availability check refreshes off-main.
    static var isClaudeLoggedIn: Bool { loginCache.read() }

    /// Codex exposes a non-interactive login-status command. Cache the result because provider choices are refreshed
    /// several times while the dashboard and task bar are open.
    private final class CodexLoginCache {
        private let lock = NSLock()
        private var lastPath: String?
        private var value = false
        private var checked = Date.distantPast

        func isLoggedIn(path: String?) -> Bool {
            guard let path else { return false }
            return lock.withLock {
                guard path != lastPath || Date().timeIntervalSince(checked) > 30 else { return value }
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["login", "status"]
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: deadline)
                    defer { deadline.cancel() }
                    let status = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(data: status, encoding: .utf8)?.lowercased() ?? ""
                    value = process.terminationStatus == 0 && text.contains("logged in using chatgpt")
                } catch {
                    value = false
                }
                lastPath = path
                checked = Date()
                return value
            }
        }
    }
    private static let codexLoginCache = CodexLoginCache()

    static var current: Provider {
        if CommandLine.arguments.contains("--agy") || CommandLine.arguments.contains("--agy-cli") { return .agyCLI }
        if CommandLine.arguments.contains("--claude") || CommandLine.arguments.contains("--claude-cli") { return .claudeCLI }
        if CommandLine.arguments.contains("--codex") || CommandLine.arguments.contains("--codex-cli") { return .codexCLI }
        if CommandLine.arguments.contains("--opencode") || CommandLine.arguments.contains("--opencode-cli") { return .opencodeCLI }
        if CommandLine.arguments.contains("--cursor") || CommandLine.arguments.contains("--cursor-cli") { return .cursorCLI }
        if useAgy { return .agyCLI }
        if let raw = Config.value("PROVIDER")?.lowercased() {
            switch raw {
            case "agy", "agy-cli", "antigravity", "gemini-cli": return .agyCLI
            case "claude", "claude-code", "cli": return .claudeCLI
            case "codex": return .codexCLI
            case "opencode", "open-code": return .opencodeCLI
            case "cursor", "cursor-agent": return .cursorCLI
            case "google": return .gemini
            case "compatible", "custom": return .compatible
            default: if let p = Provider.parse(raw) { return p }
            }
        }
        // Nothing chosen ("auto"): use the configured priority order, ignoring unavailable providers.
        let order = Config.value("PROVIDER_ORDER") ?? "claude-cli,codex-cli,agy-cli,opencode-cli,cursor-cli,anthropic,openai,gemini,openrouter,ollama,openai-compatible"
        if let selected = order.split(separator: ",").compactMap({ Provider.parse(String($0).trimmingCharacters(in: .whitespaces)) }).first(where: \.isConfigured) {
            return selected
        }
        if ClaudeSession.claudePath != nil { return .claudeCLI }
        return [.anthropic, .openai, .gemini, .openrouter].first { $0.key != nil } ?? .claudeCLI
    }

    static func parse(_ raw: String) -> Provider? {
        switch raw.lowercased() {
        case "agy", "antigravity", "gemini-cli": return .agyCLI
        case "claude", "claude-code", "cli": return .claudeCLI
        case "codex": return .codexCLI
        case "gpt", "chatgpt": return .openai
        case "opencode", "open-code": return .opencodeCLI
        case "cursor", "cursor-agent": return .cursorCLI
        case "google": return .gemini
        case "compatible", "custom": return .compatible
        default: return Provider(rawValue: raw.lowercased())
        }
    }

    private static var openCodeAuthExists: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dataHome = Config.value("XDG_DATA_HOME") ?? "\(home)/.local/share"
        let authFiles = ["\(dataHome)/opencode/auth.json", "\(home)/.opencode/auth.json"]
        var databases = ["\(dataHome)/opencode/opencode.db"]
        if let database = Config.value("OPENCODE_DB"), !database.isEmpty {
            databases.append((database as NSString).expandingTildeInPath)
        }
        return authFiles.contains(where: Self.openCodeAuthFileHasCredentials)
            || databases.contains(where: Self.openCodeDatabaseHasCredentials)
    }

    /// OpenCode creates its SQLite database for sessions even before anyone logs in. Check credential rows rather
    /// than treating an empty database as a signed-in provider. Read only: credential values never leave SQLite.
    private static func openCodeDatabaseHasCredentials(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        // OpenCode shares this table with OAuth-backed MCP services. Only model-provider integrations count here;
        // MCP integration IDs use the `mcp_` prefix. The separate `auth` table can represent non-model accounts.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
                                 "SELECT 1 FROM credential WHERE integration_id IS NOT NULL AND substr(integration_id, 1, 4) != 'mcp_' LIMIT 1",
                                 -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// OpenCode v1 and migration-era installs keep provider credentials in auth.json.
    private static func openCodeAuthFileHasCredentials(_ path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return root.values.contains { value in
            guard let record = value as? [String: Any], let type = record["type"] as? String else { return false }
            let fields: [String]
            switch type.lowercased() {
            case "api": fields = ["key"]
            case "oauth": fields = ["access", "refresh"]
            case "wellknown": fields = ["key", "token"]
            default: return false
            }
            return fields.contains { (record[$0] as? String)?.isEmpty == false }
        }
    }

    private static var localServerReachable: Bool {
        guard let url = URL(string: "\(Provider.ollama.baseURL)/api/tags") else { return false }
        let finished = DispatchSemaphore(value: 0)
        let result = ProbeResult()
        let task = URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 0.4)) { _, response, _ in
            result.set((response as? HTTPURLResponse).map { (200..<500).contains($0.statusCode) } ?? false)
            finished.signal()
        }
        task.resume()
        if finished.wait(timeout: .now() + .milliseconds(450)) == .timedOut { task.cancel() }
        return result.get()
    }

    private final class CursorLoginCache {
        private let lock = NSLock()
        private var lastPath: String?
        private var value = false
        private var checked = Date.distantPast

        func isLoggedIn(path: String?) -> Bool {
            guard let path else { return false }
            if ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"].contains(where: { Config.value($0)?.isEmpty == false }) { return true }
            return lock.withLock {
                guard path != lastPath || Date().timeIntervalSince(checked) > 30 else { return value }
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["status"]
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: deadline)
                    defer { deadline.cancel() }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let status = String(data: data, encoding: .utf8)?.lowercased() ?? ""
                    if status.contains("not authenticated") || status.contains("unauthenticated") ||
                        status.contains("not signed in") || status.contains("not logged in") {
                        value = false
                    } else if process.terminationStatus == 0 &&
                        (status.contains("authenticated") || status.contains("signed in") || status.contains("logged in")) {
                        value = true
                    } else {
                        // Some CLI builds crash or omit status output. Let ACP validate the local login when used.
                        value = true
                    }
                } catch {
                    value = true
                }
                lastPath = path
                checked = Date()
                return value
            }
        }
    }
    private static let cursorLoginCache = CursorLoginCache()
    private static var cursorAuthExists: Bool {
        cursorLoginCache.isLoggedIn(path: Provider.cursorCLI.cliPath)
    }

    /// The CLI's executable, for the CLI providers (AGY_PATH / CLAUDE_PATH / CODEX_PATH, else the usual install spots).
    var cliPath: String? {
        let name: String
        switch self {
        case .agyCLI: return AgySession.agyPath
        case .claudeCLI: return AgySession.claudePath
        case .codexCLI: name = "codex"
        case .opencodeCLI: name = "opencode"
        case .cursorCLI: name = "cursor-agent"
        default: return nil
        }
        let pathKey = self == .cursorCLI ? "CURSOR_AGENT_PATH" : name.uppercased() + "_PATH"
        if let explicit = Config.value(pathKey) { return explicit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [name]
        if self == .cursorCLI { candidates = ["agent", "cursor-agent"] }
        let fromPath = ProcessInfo.processInfo.environment["PATH"].map { path in
            path.split(separator: ":").flatMap { dir in candidates.map { "\(dir)/\($0)" } }
        } ?? []
        let spots = candidates.flatMap { binary in
            ["\(home)/.local/bin/\(binary)", "\(home)/.opencode/bin/\(binary)", "/opt/homebrew/bin/\(binary)", "/usr/local/bin/\(binary)", "\(home)/.npm-global/bin/\(binary)", "\(home)/.bun/bin/\(binary)"]
        }
        return (fromPath + spots)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isACP: Bool { self == .opencodeCLI || self == .cursorCLI }
    var isCLI: Bool { self == .agyCLI || self == .claudeCLI || self == .codexCLI || isACP }

    var key: String? {
        let names: [String]
        switch self {
        case .agyCLI, .claudeCLI, .codexCLI, .opencodeCLI, .cursorCLI, .ollama: return nil
        case .anthropic: names = ["ANTHROPIC_API_KEY"]
        case .openai: names = ["OPENAI_API_KEY"]
        case .gemini: names = ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .openrouter: names = ["OPENROUTER_API_KEY"]
        case .compatible: names = ["OPENAI_COMPATIBLE_API_KEY", "OPENAI_API_KEY"]
        }
        return names.lazy.compactMap { Config.value($0) }.first { !$0.isEmpty }
    }

    /// The model id for one of the app's names for a model ("sonnet" for the agent, "haiku" for the fast helper,
    /// "opus" for `--model opus`). Anything else is taken as the provider's own model id.
    func model(_ name: String) -> String {
        let alias = name.lowercased()
        let tier = ["haiku": 0, "sonnet": 1, "opus": 2][alias]
        guard let tier else { return name }
        switch self {
        case .agyCLI: return ["gemini-3.8-flash", "gemini-3.8-flash", "gemini-3.1-pro"][tier]
        case .claudeCLI: return alias == "haiku" ? "claude-haiku-5-5" : name
        // The CLIs pick their own default model for your account; only an explicit model id is passed on.
        case .codexCLI: return ""
        case .opencodeCLI: return Config.value("OPENCODE_MODEL") ?? ""
        case .cursorCLI: return Config.value("CURSOR_MODEL") ?? ""
        case .anthropic: return ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"][tier]
        case .openrouter: return ["anthropic/claude-haiku-5.5", "anthropic/claude-sonnet-5.5", "anthropic/claude-opus-5.5"][tier]
        case .openai: return ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"][tier]
        case .gemini: return ["gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.6-flash"][tier]
        case .ollama, .compatible: return Config.value("LOCAL_MODEL") ?? "qwen3-vl"
        }
    }

    var label: String {
        switch self {
        case .claudeCLI: return "Claude Code CLI: \(AgySession.claudePath ?? "❌ not found")"
        case .agyCLI: return "Antigravity CLI (agy): \(AgySession.agyPath ?? "❌ not found")"
        case .codexCLI: return "Codex CLI: \(cliPath ?? "❌ not found")"
        case .opencodeCLI: return "OpenCode: \(cliPath ?? "❌ not found")"
        case .cursorCLI: return "Cursor Agent: \(cliPath ?? "❌ not found")"
        case .ollama: return "Ollama (\(baseURL))"
        case .compatible: return "OpenAI-compatible API (\(baseURL)\(key == nil ? ", no key" : ""))"
        default: return "\(rawValue) API (\(key == nil ? "❌ no key" : "key set"))"
        }
    }

    var baseURL: String {
        let explicit = Config.value("OPENAI_BASE_URL").map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        switch self {
        case .openai: return explicit ?? "https://api.openai.com/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .ollama: return explicit ?? "http://localhost:11434/v1"
        case .compatible: return explicit ?? "http://localhost:1234/v1"
        case .anthropic: return Config.value("ANTHROPIC_BASE_URL") ?? "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .agyCLI, .claudeCLI, .codexCLI, .opencodeCLI, .cursorCLI: return ""
        }
    }

    static func routed(_ key: String, fallback: Provider) -> Provider {
        guard let raw = Config.value(key), let provider = parse(raw) else { return fallback }
        return provider.isConfigured ? provider : fallback
    }
}

/// One conversation over a provider's HTTP API or configured Codex transport. App-server keeps a live
/// model-only thread; the compatibility exec transport sends the exchange again on each turn.
final class APIChat: @unchecked Sendable {
    private typealias Turn = ConversationBudget.Turn

    private let provider: Provider
    private let key: String?
    private let system: String
    private let model: String
    private let effort: String
    /// The reasoning effort that was asked for (argument or configuration); nil when none was, so a CLI's own default stands.
    private let requestedEffort: String?
    private let requestedModel: String
    private let transport: String
    private let codexServer: CodexAppServer?
    private let lock = NSLock()
    private var turns: [Turn] = []
    private var inFlight: Task<String, Error>?
    private var closed = false
    /// Set after the provider rejected the reasoning setting for this model, so later turns leave it out.
    private var plain = false

    init(provider: Provider, system: String, model: String, effort: String? = nil) throws {
        let key = provider.key
        if provider.isCLI, provider.cliPath == nil {
            let pathEnv = provider == .codexCLI ? "CODEX_PATH" : provider == .agyCLI ? "AGY_PATH" : "CLAUDE_PATH"
            throw AgySession.BrainError.failed("\(provider.rawValue): not found. Install it, or set \(pathEnv) in ~/.config/clinqy/env")
        }
        if key == nil, !provider.isCLI, provider != .ollama, provider != .compatible {
            throw AgySession.BrainError.failed("No API key for \(provider.rawValue). Add it to ~/.config/clinqy/env (see the README).")
        }
        self.provider = provider
        self.key = key
        self.system = system
        self.model = provider.model(model)
        let asked = effort ?? Config.value("AGY_EFFORT") ?? Config.value("CLAUDE_EFFORT")
        requestedEffort = asked.map { $0.lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
        requestedModel = model
        self.effort = (asked ?? "low").lowercased()
        let transport = (Config.value("CODEX_TRANSPORT") ?? "exec").lowercased()
        if provider == .codexCLI, !["exec", "app-server"].contains(transport) {
            throw AgySession.BrainError.failed("CODEX_TRANSPORT must be exec or app-server")
        }
        self.transport = provider == .codexCLI ? transport : "http"
        codexServer = provider == .codexCLI && transport == "app-server"
            ? CodexAppServer(executable: provider.cliPath!, system: system, model: provider.model(model),
                             effort: ModelRoute.codexEffort(requestedEffort)) : nil
        let route = self.route
        DispatchQueue.main.async { Agent.writeLog(route.summary) }
    }

    /// The session's effective configuration (see ModelRoute): requested vs resolved vs sent.
    var route: ModelRoute {
        let sent: String?
        switch provider {
        case .codexCLI: sent = ModelRoute.codexEffort(requestedEffort)
        case .gemini: sent = ModelRoute.geminiLevel(effort)
        case .openai: sent = ModelRoute.openAIEffort(model: model, effort: effort)
        default: sent = nil
        }
        let images: String
        let tools: String
        switch (provider, transport) {
        case (.codexCLI, "app-server"):
            images = "per-turn (the thread keeps earlier turns; each screenshot is sent once)"
            tools = "none (environments empty, features/MCP/web search verified disabled)"
        case (.codexCLI, _):
            images = "latest-only (text transcript replayed each turn, newest screenshot attached)"
            tools = "none requested (exec, read-only sandbox)"
        default:
            images = "latest-only (earlier screenshots replaced by a note)"
            tools = "none"
        }
        return ModelRoute(provider: provider.rawValue, requestedModel: requestedModel, resolvedModel: model,
                          requestedEffort: requestedEffort, sentEffort: sent, transport: transport,
                          imageHistory: images, tools: tools)
    }

    var isAlive: Bool { lock.withLock { !closed } }

    func close() {
        lock.lock()
        closed = true
        let task = inFlight
        lock.unlock()
        task?.cancel()
        if let codexServer { Task { await codexServer.close() } }
    }

    func send(_ text: String, image: String?, partial: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let task = try lock.withLock { () throws -> Task<String, Error> in
            if closed { throw ClaudeSession.BrainError.died }
            if inFlight != nil { throw ClaudeSession.BrainError.busy }
            turns.append(Turn(user: true, text: text, image: image))
            turns = ConversationBudget.compact(turns)
            let task = Task { try await self.complete(partial: partial) }
            inFlight = task
            return task
        }
        do {
            let reply = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            lock.withLock { turns.append(Turn(user: false, text: reply, image: nil)); inFlight = nil }
            return reply
        } catch {
            // Drop the unanswered turn so the conversation still alternates.
            lock.withLock { if turns.last?.user == true { turns.removeLast() }; inFlight = nil }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw ClaudeSession.BrainError.died }
            throw error
        }
    }

    private func complete(partial: (@Sendable (String) -> Void)?) async throws -> String {
        // Only the newest screenshot is sent again: older ones cost tokens on every turn and are out of date anyway.
        let history = lock.withLock { () -> [Turn] in
            let lastImage = turns.lastIndex { $0.image != nil }
            return turns.enumerated().map { i, t in
                var t = t
                if t.image != nil, i != lastImage { t.image = nil; t.text = "[earlier screenshot omitted]\n" + t.text }
                return t
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        do {
            return try await request(history, deadline: deadline, plain: lock.withLock { plain }, partial: partial)
        } catch ClaudeSession.BrainError.failed(let message) where message.hasPrefix("HTTP 400") && [.openai, .gemini].contains(provider) && !lock.withLock({ plain }) {
            lock.withLock { plain = true }
            return try await request(history, deadline: deadline, plain: true, partial: partial)
        }
    }

    private func request(_ history: [Turn], deadline: TimeInterval, plain: Bool, partial: (@Sendable (String) -> Void)?) async throws -> String {
        if provider == .codexCLI {
            if let codexServer, let latest = history.last {
                // Only new input goes to the persistent thread. Never auto-fallback/replay a failed turn.
                let reply = try await codexServer.send(latest.text, image: latest.image)
                UsageStore.record(provider: provider, model: model)
                return reply
            }
            return try await runCLI(history)
        }
        var req: URLRequest
        var body: [String: Any]
        switch provider {
        case .anthropic:
            req = URLRequest(url: URL(string: provider.baseURL + "/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var messages: [[String: Any]] = history.map { t in
                var content: [[String: Any]] = []
                if let image = t.image {
                    content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image]])
                }
                content.append(["type": "text", "text": t.text])
                return ["role": t.user ? "user" : "assistant", "content": content]
            }
            // Cache the conversation so far: each turn then only pays for what's new.
            if var last = messages.popLast(), var content = last["content"] as? [[String: Any]], !content.isEmpty {
                content[content.count - 1]["cache_control"] = ["type": "ephemeral"]
                last["content"] = content
                messages.append(last)
            }
            body = [
                "model": model, "max_tokens": 8192, "messages": messages,
                "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            ]
        case .gemini:
            req = URLRequest(url: URL(string: "\(provider.baseURL)/models/\(model):generateContent")!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let contents: [[String: Any]] = history.map { t in
                var parts: [[String: Any]] = []
                if let image = t.image { parts.append(["inlineData": ["mimeType": "image/jpeg", "data": image]]) }
                parts.append(["text": t.text])
                return ["role": t.user ? "user" : "model", "parts": parts]
            }
            var generation: [String: Any] = ["maxOutputTokens": 8192]
            if !plain { generation["thinkingConfig"] = ["thinkingLevel": ModelRoute.geminiLevel(effort)] }
            body = ["systemInstruction": ["parts": [["text": system]]], "contents": contents, "generationConfig": generation]
        case .openai, .openrouter, .ollama, .compatible:
            req = URLRequest(url: URL(string: provider.baseURL + "/chat/completions")!)
            if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            if provider == .openrouter { req.setValue("Clinqy", forHTTPHeaderField: "X-Title") }
            var messages: [[String: Any]] = [["role": "system", "content": system]]
            for t in history {
                if let image = t.image {
                    messages.append(["role": "user", "content": [
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image)"]],
                        ["type": "text", "text": t.text],
                    ]])
                } else {
                    messages.append(["role": t.user ? "user" : "assistant", "content": t.text])
                }
            }
            body = ["model": model, "messages": messages]
            if !plain, provider == .openai, let level = ModelRoute.openAIEffort(model: model, effort: effort) {
                body["reasoning_effort"] = level
            }
        case .agyCLI, .claudeCLI, .codexCLI, .opencodeCLI, .cursorCLI:
            throw ClaudeSession.BrainError.failed("\(provider.rawValue) isn't an HTTP provider")
        }
        // Streaming transport also forwards cumulative text to the validated early-action parser.
        if provider == .gemini {
            req.url = URL(string: "\(provider.baseURL)/models/\(model):streamGenerateContent?alt=sse")
        } else { body["stream"] = true }
        if provider == .openai { body["stream_options"] = ["include_usage": true] }
        req.httpMethod = "POST"
        req.timeoutInterval = max(0.1, deadline - ProcessInfo.processInfo.systemUptime)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var received = try await URLSession.shared.bytes(for: req)
        for attempt in 0..<2 {
            guard let http = received.1 as? HTTPURLResponse, [429, 503].contains(http.statusCode) else { break }
            received.0.task.cancel()
            let requested = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            let delay = min(8, max(0.2, requested ?? (pow(2, Double(attempt)) + Double.random(in: 0...0.25))))
            guard ProcessInfo.processInfo.systemUptime + delay < deadline else { throw ClaudeSession.BrainError.failed("Model request deadline exceeded") }
            try await Task.sleep(for: .seconds(delay))
            try Task.checkCancellation()
            req.timeoutInterval = max(0.1, deadline - ProcessInfo.processInfo.systemUptime)
            received = try await URLSession.shared.bytes(for: req)
        }
        let (bytes, response) = received
        let expiry = DispatchWorkItem { bytes.task.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: expiry)
        defer { expiry.cancel(); bytes.task.cancel() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let isStream = response.mimeType?.contains("event-stream") == true || response.mimeType?.contains("ndjson") == true
        if (200..<300).contains(status), isStream {
            var events = ServerEvents(), stream = ModelStream()
            var lastDelivery = DispatchTime.now().uptimeNanoseconds
            var wireBytes = 0
            for try await byte in bytes {
                if wireBytes % 4_096 == 0 { try Task.checkCancellation() }
                wireBytes += 1
                guard wireBytes <= 4_000_000 else { throw ClaudeSession.BrainError.failed("Model stream exceeded the response budget") }
                if let event = try events.byte(byte), try stream.consume(event) {
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now - lastDelivery > 20_000_000 { partial?(stream.text); lastDelivery = now }
                }
            }
            if let event = events.flush() { _ = try stream.consume(event) }
            guard stream.finished, !stream.text.isEmpty else { throw ClaudeSession.BrainError.failed("Model stream ended before a complete answer") }
            partial?(stream.text)
            UsageStore.record(provider: provider, model: model, inputTokens: stream.inputTokens, outputTokens: stream.outputTokens)
            return stream.text
        }
        // Compatible servers may ignore streaming. Keep their JSON response path without issuing a second request.
        var data = Data()
        for try await byte in bytes {
            if data.count >= 4_000_000 { throw ClaudeSession.BrainError.failed("Model response exceeded the response budget") }
            data.append(byte)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = json?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? (json?["error"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw ClaudeSession.BrainError.failed("HTTP \(status) from \(provider.rawValue): \(message)")
        }
        let text: String?
        switch provider {
        case .anthropic:
            text = (json?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        case .gemini:
            let parts = ((json?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            text = parts?.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        default:
            let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            text = message?["content"] as? String
        }
        guard let text, !text.isEmpty else {
            throw ClaudeSession.BrainError.failed("Empty reply from \(provider.rawValue) (\(model))")
        }
        let usage = Self.reportedUsage(json, provider: provider)
        UsageStore.record(provider: provider, model: model, inputTokens: usage.input, outputTokens: usage.output)
        return text
    }

    private static func reportedUsage(_ json: [String: Any]?, provider: Provider) -> (input: Int?, output: Int?) {
        guard let json else { return (nil, nil) }
        let usage = json["usage"] as? [String: Any]
        let metadata = json["usageMetadata"] as? [String: Any]
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        switch provider {
        case .anthropic:
            return (int(usage?["input_tokens"]), int(usage?["output_tokens"]))
        case .gemini:
            return (int(metadata?["promptTokenCount"]), int(metadata?["candidatesTokenCount"]))
        default:
            return (int(usage?["prompt_tokens"]), int(usage?["completion_tokens"]))
        }
    }

    /// Explicit compatibility transport for CLIs without the model-only app-server protocol.
    /// Each turn runs once with the conversation so far; failed app-server turns never enter this path.
    private func runCLI(_ history: [Turn]) async throws -> String {
        guard let path = provider.cliPath else { throw ClaudeSession.BrainError.notInstalled }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-\(provider.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let imageURL = dir.appendingPathComponent("screen.jpg")
        let hasImage = history.last?.image.flatMap { Data(base64Encoded: $0) }.map { (try? $0.write(to: imageURL)) != nil } ?? false
        let lastURL = dir.appendingPathComponent("last.txt")

        var transcript = "<instructions>\n\(system)\n</instructions>\n\n"
        for t in history { transcript += t.user ? "<user>\n\(t.text)\n</user>\n\n" : "<assistant>\n\(t.text)\n</assistant>\n\n" }
        transcript += "Write only the assistant's next reply to the last <user> turn, following <instructions>. Don't run commands or edit files."

        var args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never", "--output-last-message", lastURL.path]
        if hasImage { args += ["--image", imageURL.path] }
        if !model.isEmpty { args += ["--model", model] }
        // Only an explicitly configured effort is forwarded; otherwise the CLI keeps its own default.
        if let level = ModelRoute.codexEffort(requestedEffort) { args += ["-c", "model_reasoning_effort=\"\(level)\""] }
        args.append("-")

        let promptURL = dir.appendingPathComponent("prompt.txt")
        try Data(transcript.utf8).write(to: promptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptURL.path)
        // A fixed shell wrapper feeds stdin without putting a long/private transcript in process arguments.
        // exec preserves ProcessRunner's group leader, so cancellation/deadlines terminate CLI descendants too.
        let command = ["-c", "prompt_file=$1; shift; exec \"$@\" < \"$prompt_file\"", "clinqy-model", promptURL.path, path] + args
        let output = await ProcessRunner.run("/bin/sh", command, timeout: 120, outputLimit: 4_000_000, directory: dir)
        try Task.checkCancellation()
        guard output.status == 0 else { throw ClaudeSession.BrainError.failed("\(provider.rawValue) exited \(output.status): \(output.output.suffix(400))") }
        if let size = try? lastURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 4_000_000 {
            throw ClaudeSession.BrainError.failed("Model response exceeded the response budget")
        }

        let reply = (try? String(contentsOf: lastURL, encoding: .utf8)) ?? output.output
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeSession.BrainError.failed("Empty reply from \(provider.rawValue)") }
        UsageStore.record(provider: provider, model: model)
        return text
    }
}
