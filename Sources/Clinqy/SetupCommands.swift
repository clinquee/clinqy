import AppKit

/// Adds Clinqy as an MCP server to coding agents, keeping their other servers (the setup window and `Clinqy connect`).
enum AgentConnect {
    static let ids = ["claude", "codex", "agy", "cursor", "gemini", "windsurf", "opencode"]

    static var exe: String {
        // The installed app, not a build folder that may move.
        let installed = "/Applications/Clinqy.app/Contents/MacOS/Clinqy"
        if let own = Bundle.main.executablePath, own.hasPrefix("/Applications/") { return own }
        return FileManager.default.isExecutableFile(atPath: installed) ? installed : (Bundle.main.executablePath ?? installed)
    }

    /// Connects one agent and says what was done.
    @discardableResult
    static func connect(_ id: String) throws -> String {
        switch id {
        case "claude", "claude-code", "claudecode":
            guard let claude = AgySession.claudePath else { throw fail("Claude Code isn't installed") }
            try run(claude, ["mcp", "add", "clinqy", "-s", "user", "--", exe, "mcp"], okIfContains: "already exists")
            return "Claude Code: added (claude mcp add clinqy)"
        case "agy", "antigravity":
            guard let agy = AgySession.agyPath else { throw fail("agy isn't installed") }
            try run(agy, ["mcp", "add", "clinqy", "--", exe, "mcp"], okIfContains: "already exists")
            return "agy: added (agy mcp add clinqy)"
        case "opencode":
            guard let opencode = opencodePath else {
                throw fail("OpenCode CLI isn't installed or isn't on PATH (set OPENCODE_PATH in ~/.config/clinqy/env)")
            }
            try run(opencode, ["mcp", "add", "clinqy", "--global", "--", exe, "mcp"], okIfContains: "already exists")
            return "OpenCode: added the clinqy MCP server globally (opencode mcp add clinqy)"
        case "cursor":
            try addJSONServer(".cursor/mcp.json")
            return "Cursor: added to ~/.cursor/mcp.json"
        case "gemini", "gemini-cli":
            try addJSONServer(".gemini/settings.json")
            return "Gemini CLI: added to ~/.gemini/settings.json"
        case "windsurf":
            try addJSONServer(".codeium/windsurf/mcp_config.json")
            return "Windsurf: added to ~/.codeium/windsurf/mcp_config.json"
        case "codex":
            try addCodexServer()
            return "Codex: added to ~/.codex/config.toml"
        default:
            throw fail("I don't know the agent \(id.debugDescription). Choices: \(ids.joined(separator: ", "))")
        }
    }

    /// Explicit --skill installs the bundled entrypoint. Preserve an existing customized skill unless
    /// --replace-skill was requested; MCP connection itself never overwrites personal instructions.
    static func installSkill(_ id: String, replace: Bool) throws -> String {
        let directory: String
        switch id {
        case "claude", "claude-code", "claudecode": directory = ".claude/skills/clinqy"
        case "codex": directory = ".codex/skills/clinqy"
        default: throw fail("Skill installation supports claude and codex")
        }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(directory + "/SKILL.md")
        if FileManager.default.fileExists(atPath: file.path) && !replace { return "Existing skill preserved at " + file.path + " (use --replace-skill to update it)" }
        let source = Bundle.main.resourceURL?.appendingPathComponent("skills/clinqy/SKILL.md")
        guard let source, let data = try? Data(contentsOf: source) else { throw fail("Bundled skill is unavailable; build the app with ./build.sh --bundle-only") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return "Installed skill at " + file.path
    }

    private static func fail(_ s: String) -> NSError { NSError(domain: "Clinqy", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

    /// OpenCode may be launched from the Dock with a much shorter PATH than a terminal. Check its installer,
    /// common package-manager locations and the current PATH; OPENCODE_PATH is available for custom installs.
    private static var opencodePath: String? {
        if let configured = Config.value("OPENCODE_PATH") { return configured }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var candidates = path.split(separator: ":").map { "\($0)/opencode" }
        candidates += [
            "\(home)/.opencode/bin/opencode",
            "\(home)/.local/bin/opencode",
            "\(home)/.bun/bin/opencode",
            "\(home)/.volta/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
        ]
        let nvmVersions = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersions) {
            candidates += versions.sorted(by: >).map { "\(nvmVersions)/\($0)/bin/opencode" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ path: String, _ args: [String], okIfContains: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus != 0 && !text.contains(okIfContains) {
            throw fail(text.split(separator: "\n").first.map(String.init) ?? "Failed")
        }
    }

    /// Adds Clinqy under "mcpServers", keeping every other server and setting in the file.
    private static func addJSONServer(_ relative: String) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw fail("\(relative) isn't a JSON object; left it alone")
            }
            root = obj
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["clinqy"] = ["command": exe, "args": ["mcp"]]
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private static func addCodexServer() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if old.contains("[mcp_servers.clinqy]") { return }
        let block = "\n[mcp_servers.clinqy]\ncommand = \"\(exe)\"\nargs = [\"mcp\"]\n"
        try (old + block).write(to: url, atomically: true, encoding: .utf8)
    }
}

/// `Clinqy model | connect | settings | permissions | extension install | doctor`: setting Clinqy up from a terminal,
/// the same steps as the setup window. This is what the one-prompt install has a coding agent run.
@MainActor
enum SetupCommands {
    nonisolated static let names: Set<String> = ["model", "models", "connect", "settings", "config", "permissions", "doctor", "check", "extension", "update"]

    static func run(_ command: String, _ args: [String]) -> Never {
        let code: Int32
        switch command {
        case "model", "models": code = model(args)
        case "connect": code = connect(args)
        case "settings", "config": code = settings(args)
        case "permissions": code = permissions()
        case "update": code = update(args)
        case "extension": code = args.first == "install" ? extensionInstall(args.dropFirst().first) : extensionOther(args)
        default: code = doctor()
        }
        exit(code)
    }

    // ── Model ──

    /// The names `Clinqy model <name>` takes, as in the setup window.
    private static let choices: [(name: String, choice: ModelChoice, what: String)] = [
        ("claude", .claude, "Claude Code (your Claude login)"),
        ("codex", .codex, "Codex CLI (your ChatGPT login)"),
        ("agy", .agy, "Antigravity CLI (your Google login)"),
        ("opencode", .opencode, "OpenCode (your connected provider login)"),
        ("cursor", .cursor, "Cursor Agent (your Cursor login)"),
        ("ollama", .ollama, "a local model with Ollama"),
        ("anthropic", .anthropic, "Anthropic API key"),
        ("openai", .openai, "OpenAI API key"),
        ("gemini", .gemini, "Gemini API key"),
        ("openrouter", .openrouter, "OpenRouter API key"),
        ("compatible", .compatible, "an OpenAI-compatible server"),
    ]

    private static var isAuto: Bool { Config.value("PROVIDER") == nil && Config.value("USE_AGY") == nil }

    private static func name(_ p: Provider) -> String { choices.first { $0.choice.provider == p }?.name ?? p.rawValue }

    /// nil when ready to try; otherwise what to do first.
    private static func notReady(_ p: Provider) -> String? {
        switch p {
        case .claudeCLI:
            guard AgySession.claudePath != nil else { return "Claude Code isn't installed: curl -fsSL https://claude.ai/install.sh | bash" }
            return Provider.isClaudeLoggedIn ? nil : "Claude Code isn't logged in: run `claude` once in a terminal and log in"
        case .agyCLI:
            return p.cliPath == nil ? "\(name(p)) isn't installed (or set its executable path in the settings file)" : nil
        case .codexCLI:
            guard p.cliPath != nil else { return "Codex CLI isn't installed (or set CODEX_PATH in the settings file)" }
            return p.isConfigured ? nil : "Codex CLI isn't signed in with ChatGPT: run `codex login` once"
        case .opencodeCLI:
            guard p.cliPath != nil else { return "OpenCode isn't installed: https://opencode.ai/docs/cli/" }
            return p.isConfigured ? nil : "OpenCode isn't connected: run `opencode auth login` once"
        case .cursorCLI:
            guard p.cliPath != nil else { return "Cursor Agent isn't installed: https://cursor.com/docs/cli" }
            return p.isConfigured ? nil : "Cursor Agent isn't logged in: run `agent login` once"
        case .ollama:
            let has = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app"].contains { FileManager.default.fileExists(atPath: $0) }
            return has ? nil : "Ollama isn't installed: https://ollama.com/download, then ollama pull qwen3-vl"
        case .compatible:
            return Config.value("OPENAI_BASE_URL") == nil ? "set OPENAI_BASE_URL and LOCAL_MODEL in the settings file (Clinqy settings)" : nil
        default:
            return p.key == nil ? "no API key yet: run `Clinqy settings` and paste it after the \(ModelChoice.from(p).keyName ?? "key")= line" : nil
        }
    }

    private static func model(_ args: [String]) -> Int32 {
        let first = args.first?.lowercased()
        let provider: Provider
        switch first {
        case nil:
            let p = Provider.current
            print("Clinqy uses: \(name(p)) (\(p.label)), model \(Brain.defaultModel(for: p))"
                  + (isAuto ? " — picked automatically (Clinqy model <name> to choose)" : ""))
            print("\nChoices (Clinqy model <name> [model-id], or Clinqy model auto):")
            for c in choices {
                let state = notReady(c.choice.provider) == nil ? (c.choice.provider.isCLI ? "installed" : "ready")
                    : (c.choice.provider.isCLI ? "not installed" : "needs setup")
                print("  \(c.choice.provider == p ? "*" : " ") \(c.name.padding(toLength: 11, withPad: " ", startingAt: 0)) \(c.what.padding(toLength: 38, withPad: " ", startingAt: 0)) \(state)")
            }
            return 0
        case "test":
            provider = Provider.current
        case "auto":
            do { try Config.write(["PROVIDER": nil, "USE_AGY": nil]) } catch { return failed("couldn't save the settings file: \(error.localizedDescription)") }
            provider = Provider.current
            print("Clinqy picks the first configured provider in PROVIDER_ORDER: \(name(provider)).")
        case let n?:
            guard let c = choices.first(where: { $0.name == n })?.choice ?? ModelChoice(rawValue: n)
                    ?? Provider(rawValue: n).map(ModelChoice.from) else {
                return failed("I don't know the model \(n.debugDescription). Choices: \(choices.map(\.name).joined(separator: ", ")), auto")
            }
            var s: [String: String?] = ["PROVIDER": c.provider.rawValue, "USE_AGY": c == .agy ? "1" : nil]
            let id = args.count > 1 ? args[1] : nil
            switch c {
            case .claude: if let id { s["CLAUDE_MODEL"] = id }
            case .agy: if let id { s["AGY_MODEL"] = id }
            case .codex: if let id { s["CODEX_MODEL"] = id }
            case .opencode: if let id { s["OPENCODE_MODEL"] = id }
            case .cursor: if let id { s["CURSOR_MODEL"] = id }
            case .ollama:
                s["LOCAL_MODEL"] = id ?? Config.value("LOCAL_MODEL") ?? "qwen3-vl"
                s["OPENAI_BASE_URL"] = Config.value("OPENAI_BASE_URL") ?? "http://localhost:11434/v1"
            case .compatible: if let id { s["LOCAL_MODEL"] = id }
            default: if let id { s["CLAUDE_MODEL"] = id }
            }
            do { try Config.write(s) } catch { return failed("couldn't save the settings file: \(error.localizedDescription)") }
            provider = c.provider
            print("Clinqy now uses \(name(provider)) (saved in \(Config.fileURL.path)).")
        }
        if let fix = notReady(provider) {
            print("✗ Not ready: \(fix)\n  Then run: Clinqy model test")
            return 1
        }
        let modelID = Brain.defaultModel(for: provider)
        print("Checking that \(name(provider)) answers (model \(modelID))…")
        let started = Date()
        switch answers(provider, modelID) {
        case .success:
            print(String(format: "✓ It works (%.1f s).", Date().timeIntervalSince(started)))
            // A running Clinqy read the old setting when it started.
            if first != "test", appRunning { print("Restarting Clinqy so it uses it."); restartAppIfRunning() }
            return 0
        case .failure(let error):
            print("✗ It didn't answer: \(error.localizedDescription)")
            if provider.isCLI { print("  If you haven't yet, run `\(name(provider))` once in a terminal and log in, then: Clinqy model test") }
            return 1
        }
    }

    /// One real request through the provider, the same way a task sends one (90 s at most).
    private static func answers(_ p: Provider, _ model: String) -> Result<String, Error> {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<String, Error> = .failure(NSError(domain: "Clinqy", code: 1, userInfo: [NSLocalizedDescriptionKey: "no reply after 90 seconds"]))
        Task.detached {
            do {
                let s = try AgySession(system: "You are checking a connection. Reply with exactly one word: OK.", model: model, provider: p)
                defer { s.close() }
                let reply = try await s.send("Reply with OK.")
                result = .success(reply)
            } catch { result = .failure(error) }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 90)
        return result
    }

    private static func restartAppIfRunning() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.amritnigam.clinqy")
            .first(where: { $0.processIdentifier != getpid() }) else { return }
        app.terminate()
        for _ in 0..<30 where !app.isTerminated { usleep(100_000) }
        openApp()
    }

    // ── Coding agents ──

    private static func connect(_ args: [String]) -> Int32 {
        let ids = args.filter { !$0.hasPrefix("--") }.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return failed("usage: Clinqy connect <\(AgentConnect.ids.joined(separator: "|"))> ...") }
        var code: Int32 = 0
        for id in ids {
            do {
                print("✓ \(try AgentConnect.connect(id))")
                if args.contains("--skill") || args.contains("--replace-skill") {
                    print("✓ \(try AgentConnect.installSkill(id, replace: args.contains("--replace-skill")))")
                }
            } catch {
                print("✗ \(id): \(error.localizedDescription)")
                code = 1
            }
        }
        if code == 0 { print("Restart those agents to see Clinqy’s task and direct control tools (observe, act, wait, verify, release).") }
        return code
    }

    // ── Settings ──

    private static func settings(_ args: [String]) -> Int32 {
        let url = Config.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let template = Bundle.main.url(forResource: "env", withExtension: "example").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            try? (template ?? "# Clinqy settings: KEY=value lines (see env.example in the repo)\n").write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        print(url.path)
        if !args.contains("--path") { NSWorkspace.shared.open(url) }
        return 0
    }

    // ── The running app: permissions and the browser extension ──

    private static func openApp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-b", "com.amritnigam.clinqy"]
        try? p.run()
        p.waitUntilExit()
    }

    private static var appRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.amritnigam.clinqy").contains { $0.processIdentifier != getpid() }
    }

    /// Opens a clinqy:// link in the running app (starting it first), with the token only local programs can read.
    private static func link(_ host: String, _ query: [String: String] = [:]) -> Bool {
        if !appRunning {
            openApp()
            for _ in 0..<50 where !appRunning { usleep(100_000) }
            usleep(1_500_000)
        }
        let tokenURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/clinqy/cli-token")
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        var c = URLComponents()
        c.scheme = "clinqy"
        c.host = host
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "token", value: token)]
        guard let url = c.url else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", url.absoluteString]
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The app's own view of its permissions and the extension (this process's permissions would be the terminal's).
    private static func status() -> [String: Any]? {
        let id = "s\(getpid())-\(Int.random(in: 1000...9999))"
        guard link("status", ["id": id]) else { return nil }
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clinqy/cli/\(id).json")
        for _ in 0..<60 {
            if let data = try? Data(contentsOf: file), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                try? FileManager.default.removeItem(at: file)
                return obj
            }
            usleep(250_000)
        }
        return nil
    }

    private static func missing(_ s: [String: Any]) -> [String] {
        ((s["permissions"] as? [[String: Any]]) ?? []).filter { $0["granted"] as? Bool != true }.compactMap { $0["name"] as? String }
    }

    private static func permissions() -> Int32 {
        guard let s = status() else { return failed("Clinqy didn't answer. Is it installed in /Applications?") }
        let lacking = missing(s)
        if lacking.isEmpty { print("✓ All permissions are on."); return 0 }
        _ = link("permissions")
        print("Clinqy needs: \(lacking.joined(separator: ", ")).")
        print("I asked macOS for them: turn each one on for Clinqy in System Settings → Privacy & Security.")
        print("After turning on Screen Recording, macOS restarts Clinqy (or quit and open it again). Then run: Clinqy permissions")
        return 1
    }

    private static func extensionOther(_ args: [String]) -> Int32 {
        if args.first == "reload" { return link("reload-extension") ? 0 : 1 }
        print("usage: Clinqy extension install [chrome|arc|brave|edge]")
        return 2
    }

    /// Clinqy loads its own extension (extensions page → Developer mode → Load unpacked), then waits until it connects.
    private static func extensionInstall(_ browser: String?) -> Int32 {
        guard let s = status() else { return failed("Clinqy didn't answer. Is it installed in /Applications?") }
        func connected(_ status: [String: Any]) -> Bool {
            guard let browser else { return status["extension"] as? Bool == true }
            let names = ["chrome": "Google Chrome", "arc": "Arc", "brave": "Brave Browser", "edge": "Microsoft Edge"]
            let name = names[browser.lowercased()] ?? browser
            return (status["browserConnections"] as? [String] ?? []).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        if connected(s) { print("✓ The browser extension is already connected."); return 0 }
        let lacking = missing(s).filter { $0 != "Automation (System Events)" }
        guard lacking.isEmpty else {
            return failed("Clinqy needs these permissions before it can add the extension: \(lacking.joined(separator: ", ")). Run: Clinqy permissions")
        }
        print("Clinqy is adding its extension to \(browser ?? "your browser"): it moves the mouse for a minute, so hands off.")
        guard link("extension-install", browser.map { ["browser": $0] } ?? [:]) else { return failed("couldn't reach Clinqy") }
        for _ in 0..<60 {
            sleep(3)
            if let now = status() {
                if connected(now) { print("✓ The browser extension is connected."); return 0 }
                if let err = now["extensionInstall"] as? String, !err.isEmpty { return failedExtension(err, s) }
            }
        }
        return failedExtension("it didn't connect within 3 minutes", s)
    }

    private static func failedExtension(_ why: String, _ s: [String: Any]) -> Int32 {
        let folder = s["extensionFolder"] as? String ?? "~/Library/Application Support/Clinqy/extension"
        print("✗ Couldn't add the extension by itself (\(why)). By hand: open your browser's extensions page (chrome://extensions),")
        print("  turn on Developer mode, click Load unpacked and pick this folder: \(folder)")
        return 1
    }

    // ── Updates ──

    /// `Clinqy update [--check]`: is a newer Clinqy for Mac out? Without --check, installs it and reopens Clinqy.
    private static func update(_ args: [String]) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var found: Result<Updater.Release?, Error> = .success(nil)
        Task.detached { do { found = .success(try await Updater.newestRelease()) } catch { found = .failure(error) }; sem.signal() }
        sem.wait()
        let release: Updater.Release
        switch found {
        case .failure(let e): return failed("couldn't check for updates: \(e.localizedDescription)")
        case .success(let r?) where Updater.isNewer(r.version, than: Updater.current): release = r
        case .success(let r): print("✓ Clinqy \(Updater.current) is the newest\(r.map { " (latest release: \($0.version))" } ?? "")."); return 0
        }
        print("Clinqy \(release.version) is out (this is \(Updater.current)): \(release.page.absoluteString)")
        if args.contains("--check") { return 0 }
        let target = URL(fileURLWithPath: args.firstIndex(of: "--to").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                         ?? "/Applications/Clinqy.app")
        print("Downloading…")
        nonisolated(unsafe) var staged: Result<URL, Error> = .failure(NSError(domain: "Clinqy", code: 1))
        Task.detached { do { staged = .success(try await Updater.download(release)) } catch { staged = .failure(error) }; sem.signal() }
        sem.wait()
        switch staged {
        case .failure(let e): return failed("the update failed: \(e.localizedDescription)")
        case .success(let app):
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.amritnigam.clinqy").first { $0.processIdentifier != getpid() && $0.bundleURL == target }
            do { try Updater.swapInAndReopen(app, replacing: target, waitingFor: running?.processIdentifier, reopen: running != nil) } catch {
                return failed("couldn't install it: \(error.localizedDescription)")
            }
            running?.terminate()
            // The swap runs once the old app has quit; wait for it so this command ends with the new version in place.
            for _ in 0..<150 {
                usleep(200_000)
                let v = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
                if v == release.version { print("✓ Installed Clinqy \(release.version) at \(target.path)\(running != nil ? " and reopened it" : "").") ; return 0 }
            }
            return failed("the new version didn't land at \(target.path) within 30 s")
        }
    }

    // ── Doctor ──

    private static func doctor() -> Int32 {
        var ok = true
        let p = Provider.current
        if let fix = notReady(p) { ok = false; print("✗ Model: \(name(p)): \(fix)") } else {
            print("✓ Model: \(name(p)), model \(Brain.defaultModel(for: p))\(isAuto ? " (picked automatically)" : "") — `Clinqy model test` checks it answers")
        }
        if var s = status() {
            // Just started (or restarted): the extension takes a few seconds to reconnect.
            for _ in 0..<5 where s["extension"] as? Bool != true {
                sleep(2)
                s = status() ?? s
            }
            let lacking = missing(s)
            if lacking.isEmpty { print("✓ Permissions: all on") } else { ok = false; print("✗ Permissions missing: \(lacking.joined(separator: ", ")) — run: Clinqy permissions") }
            if s["extension"] as? Bool == true { print("✓ Browser extension: connected") } else {
                ok = false
                print("✗ Browser extension: not connected — run: Clinqy extension install")
            }
        } else {
            ok = false
            print("✗ Clinqy app: didn't answer (is it in /Applications?)")
        }
        let onPath = FileManager.default.isExecutableFile(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/clinqy").path)
        print(onPath ? "✓ The clinqy command: ~/.local/bin/clinqy" : "· The clinqy command: not on the PATH yet (Clinqy installs it when it starts)")
        print(ok ? "Everything's ready. Tap ⌃⌥ (Control + Option) and ask something." : "Fix the ✗ lines above, then run: Clinqy doctor")
        return ok ? 0 : 1
    }

    private static func failed(_ s: String) -> Int32 {
        print("✗ \(s)")
        return 1
    }
}
