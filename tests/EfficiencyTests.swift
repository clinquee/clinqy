import Foundation
import SQLite3

actor LoadCounter { var calls = 0; func next() -> Int { calls += 1; return calls }; func count() -> Int { calls } }

@main struct EfficiencyTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-efficiency-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); fatalError(message) }
            checks += 1
        }

        let legacy = root.appendingPathComponent("tasks.json"), file = root.appendingPathComponent("tasks.sqlite")
        var old = (0..<10_000).map { i in TaskStore.Record(request: "Review report \(i)", files: [], source: .mac, background: true, state: .succeeded) }
        old[0].dispatchKey = "archived-dispatch"
        let legacyData = try JSONEncoder().encode(old)
        try legacyData.write(to: legacy)
        let store = TaskStore(file: file, legacyFile: legacy)
        check(store.records.count <= 500, "UI task window remains bounded after importing large history")
        check(store.record(old[0].id)?.request == old[0].request, "older records remain addressable in indexed storage")
        check(store.find(old[0].shortID)?.id == old[0].id, "short-ID lookup reaches cold history")
        check(store.enqueue("Scheduled duplicate", source: .mac, idempotencyKey: "archived-dispatch") == old[0].id, "scheduled dispatch deduplication reaches archived records")
        let id = store.enqueue("New task", source: .mac)!
        check(store.start(id), "migrated task database starts work")
        var samples: [Double] = []
        for index in 0..<30 {
            let started = Date()
            check(store.beginAction(id, kind: "read"), "durable pre-action checkpoint")
            store.endAction(id, kind: "read", outcome: .confirmed, completedSteps: index)
            samples.append(Date().timeIntervalSince(started) * 1_000)
        }
        samples.sort()
        check(samples[27] < 20, "checkpoint latency doesn't scale with 10,000 archived tasks")
        let restored = TaskStore(file: file, legacyFile: legacy)
        check(restored.record(id)?.state == .interrupted, "restart preserves recovery semantics")
        check(try Data(contentsOf: legacy) == legacyData, "JSON migration preserves its original source")
        let db = try SQLiteDatabase(file: file)
        check(try db.rows("SELECT count(*) FROM tasks").first?.first == "10001", "migration is idempotent")
        try db.execute("CREATE TRIGGER reject_write BEFORE UPDATE ON tasks BEGIN SELECT RAISE(FAIL,'fixture write failure'); END")
        check(!store.beginAction(id, kind: "click"), "failed durable write prevents the action")
        check(store.record(id)?.pendingAction == nil, "failed checkpoint isn't published as durable state")
        print(String(format: "10,000-task checkpoint pair: median %.2f ms, p95 %.2f ms", samples[15], samples[27]))

        let cache = SourceCache(), counter = LoadCounter()
        let loader: @Sendable () async throws -> String = {
            _ = await counter.next()
            try await Task.sleep(for: .milliseconds(100))
            return "Shared source"
        }
        let a = Task { try await cache.value(for: "same", load: loader) }
        let b = Task { try await cache.value(for: "same", load: loader) }
        try await Task.sleep(for: .milliseconds(20)); a.cancel()
        do { _ = try await a.value; preconditionFailure("cancelled consumer resumed successfully") } catch { checks += 1 }
        check(try await b.value == "Shared source", "another consumer retains the shared request")
        check(await counter.count() == 1, "overlapping source requests coalesce")
        _ = try await cache.value(for: "same", load: loader)
        check(await counter.count() == 1, "finished source snapshot is reused")
        await cache.cancelAll()
        do { _ = try await cache.value(for: "late", load: loader); preconditionFailure("stopped cache loaded source") } catch { checks += 1 }

        let stdinFile = root.appendingPathComponent("prompt with spaces.txt")
        try Data("private Unicode input héllo".utf8).write(to: stdinFile)
        let fed = await ProcessRunner.run("/bin/sh", ["-c", "prompt_file=$1; shift; exec \"$@\" < \"$prompt_file\"", "fixture", stdinFile.path, "/bin/cat"], directory: root)
        check(fed.status == 0 && fed.output == "private Unicode input héllo", "CLI wrapper passes stdin safely through the cancellable process group")
        let cwd = await ProcessRunner.run("/bin/pwd", [], directory: root)
        check(cwd.status == 0 && URL(fileURLWithPath: cwd.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path, "subprocess working directory is explicit: \(cwd.output) versus \(root.path)")
        let marker = root.appendingPathComponent("must-not-exist")
        let process = Task { await ProcessRunner.run("/bin/sh", ["-c", "echo started; sleep 5; echo late > \"$1\"", "fixture", marker.path]) }
        try await Task.sleep(for: .milliseconds(60))
        let stop = Date(); process.cancel()
        let result = await process.value
        check(Date().timeIntervalSince(stop) < 1, "cancelling a shell closes its child process group promptly")
        check(result.status != 0 && !FileManager.default.fileExists(atPath: marker.path), "cancelled descendants cannot finish the command")
        let timeout = await ProcessRunner.run("/bin/sh", ["-c", "sleep 3; echo late"], timeout: 0.05)
        check(timeout.output.contains("timed out"), "subprocess deadline is enforced")
        let bounded = await ProcessRunner.run("/usr/bin/yes", ["fixture"], timeout: 0.03, outputLimit: 1_024)
        check(bounded.output.utf8.count < 1_200 && bounded.output.contains("truncated"), "command output is bounded while the pipe is drained")

        var frames = ServerEvents()
        check(frames.line(": keepalive") == nil, "SSE comments aren't model data")
        check(frames.line("data: {\"choices\":") == nil, "SSE waits for a complete event")
        _ = frames.line("data: [{\"delta\":{\"content\":\"hello\"}}]}")
        var stream = ModelStream()
        check(try stream.consume(frames.line("")!) && stream.text == "hello", "multi-line SSE events decode incrementally")
        _ = try stream.consume(#"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#)
        check(stream.inputTokens == 12 && stream.outputTokens == 3, "usage-only frames are retained")
        _ = try stream.consume("[DONE]")
        check(stream.finished, "terminal event is recognized")
        var anthropic = ModelStream()
        _ = try anthropic.consume(#"{"type":"content_block_delta","delta":{"text":"Answer"}}"#)
        _ = try anthropic.consume(#"{"type":"message_stop"}"#)
        check(anthropic.text == "Answer" && anthropic.finished, "Anthropic stream dialect is decoded")
        var gemini = ModelStream()
        _ = try gemini.consume(#"{"candidates":[{"content":{"parts":[{"text":"private thought","thought":true},{"text":"Answer"}]},"finishReason":"STOP"}]}"#)
        check(gemini.text == "Answer" && gemini.finished, "Gemini reasoning isn't exposed as answer text")
        do { _ = try stream.consume(#"{"error":{"message":"fixture error"}}"#); preconditionFailure("stream error ignored") } catch { checks += 1 }
        let (network, _) = try await URLSession.shared.bytes(from: URL(string: CommandLine.arguments[1])!)
        defer { network.task.cancel() }
        var wire = ServerEvents(), decoded = ModelStream()
        for try await byte in network { if let event = try wire.byte(byte) { _ = try decoded.consume(event) } }
        if let event = wire.flush() { _ = try decoded.consume(event) }
        check(decoded.text == "héllo" && decoded.finished, "actual URLSession SSE preserves event boundaries and Unicode")
        let turns = [ConversationBudget.Turn(user: true, text: "Original task requirements", image: "old")]
            + (0..<100).map { ConversationBudget.Turn(user: $0 % 2 == 0, text: "Turn \($0): " + String(repeating: "x", count: 2_000), image: $0 == 99 ? "latest" : nil) }
        let compacted = ConversationBudget.compact(turns)
        check(compacted.first?.text == "Original task requirements", "conversation compaction retains the original task")
        check(compacted.reduce(0, { $0 + $1.text.count }) <= 100_000, "conversation remains within its text budget")
        check(compacted.filter { $0.image != nil }.count == 1 && compacted.last?.image == "latest", "old screenshot payloads are released")
        check(compacted.contains { $0.text.contains("Older conversation compacted") }, "omissions are explicit")
        let huge = [ConversationBudget.Turn(user: true, text: "Task", image: nil), .init(user: true, text: String(repeating: "😀", count: 100_000), image: "newest")]
        let small = ConversationBudget.compact(huge, characters: 1_000)
        check(small.reduce(0, { $0 + $1.text.count }) <= 1_000 && small.last?.image == "newest", "a giant latest turn respects small budgets without splitting Unicode")
        print("PASS: \(checks) scalable storage, source sharing, cancellation and streaming checks")
    }
}
