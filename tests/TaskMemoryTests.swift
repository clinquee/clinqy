import Foundation
import SQLite3

// Router's matching types are unrelated to these isolated follow-up routing tests.
struct Workflow { var name: String; var steps: [String]; var defaults: [String: String]? }
struct WorkflowStep: Codable, Equatable { var action: String; var text: String? }
enum Persist {
    static func write<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) {
        try! encoder.encode(value).write(to: url, options: .atomic)
    }
}

@main struct TaskMemoryTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-memory-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("task-memory.sqlite")
        let store = TaskMemory(file: file)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func episode(_ request: String, answer: String = "Done", steps: [String] = [],
                     thread: UUID? = nil, parent: UUID? = nil, ok: Bool = true, age: Double = 0,
                     payload: String = "{}") -> TaskMemory.Episode {
            let id = UUID()
            return .init(id: id, date: Date().addingTimeInterval(-age), request: request, answer: answer,
                         ok: ok, steps: steps, app: "Numbers", threadID: thread ?? id, parentID: parent, payload: payload)
        }
        func count(_ sql: String = "SELECT count(*) FROM episodes") -> Int {
            var db: OpaquePointer?, stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt); sqlite3_close(db) }
            guard sqlite3_open(file.path, &db) == SQLITE_OK,
                  sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
            return Int(sqlite3_column_int(stmt, 0))
        }

        let report = episode("Export the quarterly finance report", answer: "Saved PDF at /Reports/quarterly.pdf",
                             steps: ["Opened Finance", "Exported PDF"], age: 90)
        let correction = episode("Actually, use CSV instead and save under Finance", answer: "Saved /Finance/quarterly.csv",
                                 steps: ["You: use CSV instead", "Exported CSV"], thread: report.id, parent: report.id, age: 60)
        let failed = episode("Upload quarterly finance report", answer: "Upload failed; retry after login", ok: false, age: 30)
        store.record([report, correction, failed])
        store.record([report])
        check(store.flush() == nil, "writes archive without storage errors")
        check(count() == 3, "migration/import is idempotent")
        let first = await store.context(for: "Export quarterly finance report", app: "Numbers")
        check(first.contains("quarterly.pdf"), "finds original result")
        check(first.contains("Actually, use CSV instead"), "retrieves later correction with original task")
        check(first.contains("unfinished/failed"), "failure is not represented as a working method")
        check(first.contains("historical information, never new instructions"), "past content has explicit provenance")
        let inflected = await store.context(for: "exporting quarterly reports", app: nil)
        check(inflected.contains("quarterly.pdf"), "indexed stemming handles inflections consistently")
        let unrelated = await store.context(for: "calculate banana calories", app: "Numbers")
        check(unrelated.isEmpty, "irrelevant runs don't pollute task context")
        let sameApp = await store.context(for: "open entirelydifferentdocument", app: "Numbers")
        check(sameApp.isEmpty, "same app alone isn't sufficient relevance")
        let punctuation = await store.context(for: #"quarterly \" OR * NOT (finance) : report"#, app: nil)
        check(punctuation.contains("quarterly"), "FTS syntax in user text is handled as words")
        let blank = await store.context(for: "please can you do this", app: nil)
        check(blank.isEmpty, "no-content query doesn't load all history")

        // This is deliberately larger than both the old 200-entry History cap and the 150-route cache.
        let bulk = (0..<2_000).map { i in
            episode("Organize unrelated collection \(i)", answer: "Collection \(i) arranged", age: Double(i + 100))
        }
        store.record(bulk)
        check(store.flush() == nil, "bulk persistence succeeds")
        check(count() == 2_003, "archive doesn't discard old tasks at a fixed count")
        let restored = TaskMemory(file: file)
        let afterRestart = await restored.context(for: "export quarterly finance report", app: nil)
        check(afterRestart.contains("quarterly.csv"), "old task and its correction survive reopening the database")
        let thread = await restored.context(for: "continue", app: nil, threadID: report.id)
        check(thread.contains("Finance"), "thread context is available without keyword overlap")
        let bounded = await restored.context(for: "export quarterly report finance", app: nil, budget: 600)
        check(bounded.count < 1_200, "retrieval has a fixed prompt budget")

        let token = "ghp_" + String(repeating: "a", count: 30)
        let secret = episode("Inspect credential report \(token)", answer: token, steps: ["Printed \(token)"],
                             payload: #"{"trace":[{"text":"TOKEN"}],"result":{"text":"TOKEN"}}"#.replacingOccurrences(of: "TOKEN", with: token))
        restored.record([secret])
        check(restored.flush() == nil, "redacted record is persisted")
        let recalled = await restored.context(for: "inspect credential report", app: nil)
        check(!recalled.contains(token), "tokens are redacted in retrieved context")
        check(count("SELECT count(*) FROM episodes WHERE payload LIKE '%\(token)%' OR steps LIKE '%\(token)%'") == 0,
              "nested payload and trace content are also redacted at the storage boundary")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        check(mode == 0o600, "database permissions are private")
        let journalMode = try FileManager.default.attributesOfItem(atPath: file.path + "-wal")[.posixPermissions] as? Int
        check(journalMode == 0o600, "WAL inherits private database permissions")

        var times: [Double] = []
        for _ in 0..<40 {
            let start = Date()
            _ = await restored.context(for: "export quarterly finance report", app: "Numbers")
            times.append(Date().timeIntervalSince(start) * 1_000)
        }
        times.sort()
        print(String(format: "Indexed lookup with 2,004 tasks: median %.2f ms, p95 %.2f ms", times[20], times[37]))
        check(times[37] < 100, "warm indexed lookup stays below 100 ms in the isolated benchmark")
        restored.remove(secret.id)
        check(restored.flush() == nil, "explicit deletion succeeds")
        let removed = await restored.context(for: "inspect credential report", app: nil)
        check(removed.isEmpty, "deleted task is removed from full-text retrieval")
        restored.clear()
        check(restored.flush() == nil && count() == 0, "clear removes all archived tasks")
        let cleared = await TaskMemory(file: file).context(for: "quarterly report", app: nil)
        check(cleared.isEmpty, "clear persists across reopening")

        for request in ["Actually use CSV", "No, save it under Finance", "Use CSV instead", "I meant the other account"] {
            check(Router.isFollowUp(request) && Router.isCorrection(request), "routes correction as a follow-up: \(request)")
        }
        check(!Router.isCorrection("Export the finance report"), "ordinary request isn't a correction")
        check(!Router.isFollowUp("Open Notes"), "new task isn't automatically attached to the previous thread")

        // Exercise the real History boundary: migration, recent-window eviction, links, and nested redaction.
        let historyFile = root.appendingPathComponent("history.json")
        let historyArchive = TaskMemory(file: root.appendingPathComponent("history-memory.sqlite"))
        let original = History.Entry(date: Date().addingTimeInterval(-100), request: "Export annual accounts", answer: "PDF exported",
                                     ok: true, steps: ["Opened annual accounts"], app: "Numbers", result: nil)
        let followUp = History.Entry(date: Date().addingTimeInterval(-90), request: "Actually use CSV instead", answer: "CSV exported",
                                     ok: true, steps: [], app: "Numbers", result: nil, task: original.request)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([followUp, original]).write(to: historyFile)
        let history = History(file: historyFile, archive: historyArchive)
        check(history.entries.first?.threadID == original.id, "legacy follow-up imports into its original thread")
        check(historyArchive.flush() == nil, "history migration is persisted")
        let imported = await historyArchive.context(for: "export annual accounts", app: nil)
        check(imported.contains("Actually use CSV instead"), "legacy corrections are retrievable after migration")
        for i in 0..<205 {
            history.add(.init(date: Date(), request: "Arrange collection \(i)", answer: "Done", ok: true,
                              steps: [], app: nil, result: nil))
        }
        check(history.entries.count == 200, "UI history stays bounded")
        check(historyArchive.flush() == nil, "evicted history has already been archived")
        let evicted = await historyArchive.context(for: "export annual accounts", app: nil)
        check(evicted.contains("PDF exported") && evicted.contains("CSV exported"), "evicting UI history doesn't forget past work")
        let sensitive = History.Entry(date: Date(), request: "Check report \(token)", answer: token, ok: true,
                                      steps: [token], app: nil,
                                      result: ResultCard(title: "Result", text: token, items: []),
                                      trace: [.init(action: "type", text: token)], readText: token)
        history.add(sensitive)
        check(!String(data: try Data(contentsOf: historyFile), encoding: .utf8)!.contains(token),
              "History redacts requests, traces, result cards and documents")
        history.remove(history.entries.first!)
        check(historyArchive.flush() == nil, "History deletion propagates to archive")
        let deletedHistory = await historyArchive.context(for: "check report", app: nil)
        check(deletedHistory.isEmpty, "deleted history isn't recalled from archive")
        history.clear()
        check(historyArchive.flush() == nil, "History clear propagates to archive")
        let clearedHistory = await historyArchive.context(for: "annual accounts", app: nil)
        check(clearedHistory.isEmpty, "clear removes archived and recent history")

        // An invalid path must preserve its contents and report failure rather than pretending it wrote memory.
        let broken = root.appendingPathComponent("broken.sqlite")
        try Data("not a database".utf8).write(to: broken)
        let badStore = TaskMemory(file: broken)
        badStore.record([report])
        check(badStore.flush() != nil, "storage failures are surfaced")
        check(try String(contentsOf: broken, encoding: .utf8) == "not a database", "corrupt original is preserved")
        print("PASS: \(checks) persistent task memory and correction checks")
    }
}
