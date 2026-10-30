import Foundation
import SQLite3
import Darwin

/// Small checked SQLite boundary. Owners serialize access (MainActor or a dedicated queue); statements never
/// outlive a call. WAL + FULL keeps recovery writes durable without rewriting unrelated records.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(file.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Self.error("Can't open local database") }
        defer { Darwin.close(fd) }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else { throw Self.error("Can't protect local database") }
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(handle); handle = nil
            throw error
        }
        sqlite3_busy_timeout(handle, 250)
        do { try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON;") }
        catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, _ values: [String?] = []) throws {
        if values.isEmpty {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
            return
        }
        try withStatement(sql, values) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
    }

    func rows(_ sql: String, _ values: [String?] = []) throws -> [[String]] {
        try withStatement(sql, values) { statement in
            var rows: [[String]] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return rows }
                guard code == SQLITE_ROW else { throw failure() }
                rows.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                })
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func withStatement<T>(_ sql: String, _ values: [String?], _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let code = value.map { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
                ?? sqlite3_bind_null(statement, Int32(index + 1))
            guard code == SQLITE_OK else { throw failure() }
        }
        return try body(statement)
    }
    private func failure() -> NSError { Self.error(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Database unavailable") }
    private static func error(_ text: String) -> NSError { NSError(domain: "Clinqy.SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
