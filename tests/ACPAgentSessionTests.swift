import Foundation

enum Provider: String {
    case opencodeCLI = "opencode-cli"
    case cursorCLI = "cursor-cli"

    var displayName: String { self == .opencodeCLI ? "OpenCode" : "Cursor Agent" }
    func model(_ name: String) -> String { name }
}

/// The isolated ACP test build doesn't compile the app's file-backed settings loader. These fixtures let the test
/// prove that values from ClinQy's settings file are passed to the selected provider process.
enum Config {
    static func value(_ key: String) -> String? {
        ProcessInfo.processInfo.environment["CLINQY_TEST_CONFIG_\(key)"]
    }
}

private final class CollectedText: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []
    func append(_ text: String) { lock.withLock { value.append(text) } }
    func read() -> [String] { lock.withLock { value } }
}

@main struct ACPAgentSessionTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-acp-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let fake = ProcessInfo.processInfo.environment["CLINQY_FAKE_ACP"] else {
            throw NSError(domain: "ACP tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "CLINQY_FAKE_ACP must point at fake-acp-server.py"])
        }
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }

        for provider in [Provider.opencodeCLI, .cursorCLI] {
            let log = root.appendingPathComponent("\(provider.rawValue).jsonl")
            let wrapper = root.appendingPathComponent("\(provider.rawValue)-fake")
            let body = "#!/bin/sh\nexec /usr/bin/python3 \"\(fake)\" \"\(provider.rawValue)\" \"\(log.path)\"\n"
            try body.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)

            let agent = ACPAgentSession(provider: provider, executable: wrapper.path,
                                        system: "Do not use tools. Return plain text.", model: "vendor/model-test")
            let partial = CollectedText()
            let answer = try await agent.send("Say hello", image: Data([1, 2, 3]).base64EncodedString()) { partial.append($0) }
            check(answer == "Hello from ACP", "\(provider.displayName) collects streamed response")
            check(partial.read().last == answer, "\(provider.displayName) streams text to Clinqy")
            await agent.close()
            try await Task.sleep(for: .milliseconds(100))

            let messages = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
                .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            func request(_ method: String) -> [String: Any]? {
                messages.first { $0["method"] as? String == method }
            }
            check(request("authenticate")?["params"] as? [String: String] == ["methodId": provider == .opencodeCLI ? "opencode-login" : "cursor_login"],
                  "\(provider.displayName) uses its supported local login")
            check(((request("session/new")?["params"] as? [String: Any])?["mcpServers"] as? [Any] ?? []).isEmpty,
                  "\(provider.displayName) receives no Clinqy MCP tools")
            let mode = (request("session/set_mode")?["params"] as? [String: Any])?["modeId"] as? String
            check(mode == (provider == .opencodeCLI ? "clinqy" : "ask"), "\(provider.displayName) uses its model-only mode")
            let prompt = (request("session/prompt")?["params"] as? [String: Any])?["prompt"] as? [[String: Any]] ?? []
            check(prompt.contains { $0["type"] as? String == "image" && $0["data"] as? String == "AQID" },
                  "\(provider.displayName) receives screenshots as ACP image blocks")
            let denied = messages.first { ($0["id"] as? Int) == 77 }
            let outcome = (denied?["result"] as? [String: Any])?["outcome"] as? [String: Any]
            check(outcome?["optionId"] as? String == (provider == .opencodeCLI ? "reject" : "reject-once"),
                  "\(provider.displayName) selects its advertised ACP rejection option")

            if provider == .opencodeCLI {
                let setup = messages.first { $0["cwd"] != nil }
                check(setup?["apiKeyPassed"] as? Bool == true,
                      "OpenCode receives an API key saved in ClinQy's settings")
                check(setup?["databaseOverridePassed"] as? Bool == true,
                      "OpenCode receives its configured local database path")
                check(setup?["pureMode"] as? Bool == true,
                      "OpenCode external plugins are disabled for model-only sessions")
                check(setup?["inlineModelPreserved"] as? Bool == true,
                      "OpenCode's configured inline model preference is preserved")
                check(setup?["globalDenyLast"] as? Bool == true && setup?["agentDenyLast"] as? Bool == true,
                      "OpenCode inline config cannot append tool permissions after Clinqy's denials")
                let config = setup?["opencodeConfig"] as? [String: Any]
                check(config?["default_agent"] as? String == "clinqy", "OpenCode uses the isolated Clinqy agent")
                let rules = setup?["agentRules"] as? String ?? ""
                check(rules.contains("action: \"*\"") && rules.contains("effect: deny"), "OpenCode agent denies all tools")
            } else {
                let setup = messages.first { $0["cursorCliConfig"] != nil }
                check(setup?["apiKeyPassed"] as? Bool == true,
                      "Cursor receives an API key saved in ClinQy's settings")
                check(setup?["cursorInstructions"] as? String == "Do not use tools. Return plain text.",
                      "Cursor loads Clinqy's system instructions as project rules")
                let config = setup?["cursorCliConfig"] as? [String: Any]
                let permissions = config?["permissions"] as? [String: Any]
                let deny = permissions?["deny"] as? [String] ?? []
                check(deny.contains("Mcp(*:*)") && deny.contains("Shell(*)") && deny.contains("Write(*)"),
                      "Cursor project config denies MCP, shell, and file-write tools")
            }
        }
        print("PASS: \(checks) ACP provider/session checks (fake local agents; no account or model calls)")
    }
}
