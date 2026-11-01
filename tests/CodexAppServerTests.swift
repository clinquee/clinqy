import Foundation

@main struct CodexAppServerTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-codex-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = URL(fileURLWithPath: "tests/fake-codex-server.py").standardizedFileURL.path
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        func session(_ scenario: String, timeout: TimeInterval = 2) -> CodexAppServer {
            CodexAppServer(executable: "/usr/bin/python3", arguments: [script, scenario, root.appendingPathComponent(scenario + ".jsonl").path],
                           system: "Reply with a Clinqy action.", timeout: timeout)
        }
        func records(_ scenario: String) throws -> [[String: Any]] {
            try String(contentsOf: root.appendingPathComponent(scenario + ".jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        }
        let server = session("success")
        check(try await server.send("First input", image: Data([1, 2, 3]).base64EncodedString()) == "Reply 1", "collects only matching final turn")
        check(try await server.send("Second input", image: nil) == "Reply 2", "reuses live conversation")
        await server.close()
        let success = try records("success")
        check(success.filter { $0["argv"] != nil }.count == 2, "restarts preflight process only to disable inherited servers")
        check(success.filter { $0["method"] as? String == "thread/start" }.count == 1, "one persistent thread")
        let turns = success.filter { $0["method"] as? String == "turn/start" }
        check(turns.count == 2, "one request per input")
        let firstItems = (turns[0]["params"] as! [String: Any])["input"] as! [[String: Any]]
        check(firstItems.count == 2 && firstItems[1]["type"] as? String == "image", "image is a structured input")
        let secondItems = (turns[1]["params"] as! [String: Any])["input"] as! [[String: Any]]
        check(secondItems.count == 1 && secondItems[0]["text"] as? String == "Second input", "history and old screenshots are not replayed")
        // Effort: forwarded on every turn only when one was configured; otherwise the CLI's default stands.
        check((turns[0]["params"] as! [String: Any])["effort"] == nil, "no effort configured sends none")
        let efforted = CodexAppServer(executable: "/usr/bin/python3",
                                      arguments: [script, "success", root.appendingPathComponent("effort.jsonl").path],
                                      system: "Reply with a Clinqy action.", effort: "high", timeout: 2)
        check(try await efforted.send("Think", image: nil) == "Reply 1", "effort session answers")
        await efforted.close()
        let effortTurns = try records("effort").filter { $0["method"] as? String == "turn/start" }
        check(effortTurns.count == 1 && (effortTurns[0]["params"] as! [String: Any])["effort"] as? String == "high", "effort reaches turn/start")
        let early = session("early")
        check(try await early.send("Early first", image: nil) == "Early 1", "buffers events before RPC acknowledgement")
        check(try await early.send("Early second", image: nil) == "Early 2", "rejects old turn completion before acknowledgement")
        await early.close()
        for mode in ["unsafe", "unsafe-ack", "new-server", "drop", "tool", "tool-item", "failed", "wait"] {
            let failing = session(mode, timeout: 0.05)
            do { _ = try await failing.send("Do not replay", image: nil); preconditionFailure("accepted " + mode) }
            catch { check(true, "fails closed: " + mode) }
            do { _ = try await failing.send("Retry", image: nil); preconditionFailure("restarted closed " + mode) }
            catch { check(true, "never restarts uncertain session: " + mode) }
            let history = try records(mode)
            check(history.filter { $0["method"] as? String == "turn/start" }.count <= 1, "no turn replay: " + mode)
            if mode.hasPrefix("unsafe") || mode == "new-server" {
                check(!history.contains { $0["method"] as? String == "turn/start" }, "unsafe configuration cannot infer")
            }
        }
        let cancelled = session("wait", timeout: 10)
        let task = Task { try await cancelled.send("Wait", image: nil) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; preconditionFailure("cancel ignored") }
        catch { check(true, "cancellation closes active protocol session") }
        await cancelled.close()
        let blocked = session("stop-reading", timeout: 10)
        let huge = Data(repeating: 42, count: 2 * 1024 * 1024).base64EncodedString()
        let blockedTask = Task { try await blocked.send("Large image", image: huge) }
        try await Task.sleep(for: .milliseconds(300))
        let beforeCancel = Date()
        blockedTask.cancel()
        do { _ = try await blockedTask.value; preconditionFailure("blocked writer ignored cancellation") }
        catch { check(Date().timeIntervalSince(beforeCancel) < 2, "blocked image write does not block cancellation") }
        await blocked.close()
        try await Task.sleep(for: .milliseconds(1300))
        let pids = try records("stop-reading").compactMap { $0["pid"] as? Int32 }
        check(pids.allSatisfy { kill($0, 0) != 0 }, "unresponsive child is reaped after bounded cleanup")
        if let path = ProcessInfo.processInfo.environment["CLINQY_CODEX_PREFLIGHT"] {
            let installed = CodexAppServer(executable: path, system: "Reply with text only.")
            try await installed.validateConfiguration()
            await installed.close()
            check(true, "installed CLI acknowledges all restrictions without inference")
        }
        print("PASS: \(checks) Codex session protocol/isolation checks (no model calls)")
    }
}
