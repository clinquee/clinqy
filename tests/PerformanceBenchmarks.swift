import Foundation
import SQLite3

@main struct Bench {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-audit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }
        func percentile(_ values: [Double], _ p: Double) -> Double { values.sorted()[min(values.count - 1, Int(Double(values.count - 1) * p))] }
        for n in [100, 1_000, 10_000] {
            let file = root.appendingPathComponent("tasks-\(n).json")
            let records = (0..<n).map { i in
                TaskStore.Record(request: "Review the project report number \(i)", files: [], source: .mac, background: true,
                                 state: .succeeded, stage: "Completed", completedSteps: 20, lastConfirmedStep: "read", result: "Report reviewed")
            }
            try JSONEncoder().encode(records).write(to: file)
            let start = Date()
            let store = TaskStore(file: root.appendingPathComponent("tasks-\(n).sqlite"), legacyFile: file)
            let startup = ms(start)
            let reopen = Date()
            _ = TaskStore(file: root.appendingPathComponent("tasks-\(n).sqlite"), legacyFile: file)
            let reopenMs = ms(reopen)
            let id = store.enqueue("Audit synthetic task", source: .mac)!
            precondition(store.start(id))
            var samples: [Double] = []
            for i in 0..<20 {
                let t = Date()
                precondition(store.beginAction(id, kind: "read"))
                store.endAction(id, kind: "read", outcome: .confirmed, completedSteps: i)
                samples.append(ms(t))
            }
            let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            print(String(format: "TaskStore n=%d JSON=%d bytes migration=%.2f ms reopen=%.2f ms begin+end median=%.2f ms p95=%.2f ms", n, bytes, startup, reopenMs, percentile(samples, 0.5), percentile(samples, 0.95)))
        }
        for n in [2_000, 20_000] {
            let file = root.appendingPathComponent("memory-\(n).sqlite")
            let memory = TaskMemory(file: file)
            _ = await memory.context(for: "", app: nil)
            var db: OpaquePointer?, stmt: OpaquePointer?
            precondition(sqlite3_open(file.path, &db) == SQLITE_OK)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            precondition(sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK)
            precondition(sqlite3_prepare_v2(db, "INSERT INTO episodes(id,date,request,answer,ok,steps,app,thread,parent,payload) VALUES(?,1,?,?,1,?,'Numbers',?,NULL,'{}')", -1, &stmt, nil) == SQLITE_OK)
            let common = "review project report summarize findings compare research analysis export finance update recent annual budget status account"
            let steps = String(data: try JSONEncoder().encode((0..<12).map { "Step \($0): \(common)" }), encoding: .utf8)!
            for i in 0..<n {
                let id = UUID().uuidString
                let request = i == 0 ? "Summarize zephyr contract cedar" : "Review project report \(i)"
                for (index, value) in [id, request, common, steps, id].enumerated() {
                    sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient)
                }
                precondition(sqlite3_step(stmt) == SQLITE_DONE)
                sqlite3_reset(stmt)
            }
            sqlite3_finalize(stmt)
            precondition(sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)
            for (label, query) in [("selective", "summarize zephyr contract cedar"), ("common-short", "review project report"), ("common-long", common)] {
                var times: [Double] = []
                for _ in 0..<8 {
                    let start = Date()
                    let context = await memory.context(for: query, app: "Numbers")
                    precondition(!context.isEmpty)
                    times.append(ms(start))
                }
                print(String(format: "TaskMemory n=%d %@ median=%.2f ms p95=%.2f ms", n, label, percentile(times, 0.5), percentile(times, 0.95)))
            }
        }
    }
}
