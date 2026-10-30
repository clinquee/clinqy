import Foundation
import Combine

/// Durable task state shared by the Mac UI and Telegram. Recovery never executes a stored request.
@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    enum State: String, Codable {
        case queued, running, waiting, needsAttention, interrupted, succeeded, failed, cancelled
        var terminal: Bool { [.interrupted, .succeeded, .failed, .cancelled].contains(self) }
        var label: String {
            switch self {
            case .needsAttention: return "Needs attention"
            default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
            }
        }
    }
    enum Source: String, Codable { case mac, telegram }
    struct Record: Codable, Identifiable, Equatable {
        var id = UUID()
        var request: String
        var files: [String]
        var source: Source
        var background: Bool
        var state: State = .queued
        var stage = "Queued"
        var completedSteps = 0
        var lastConfirmedStep: String?
        /// Written before an action starts, cleared only after it returns. Its contents contain no arguments/secrets.
        var pendingAction: String?
        /// A returned input whose application effect still needs independent readback.
        var unverifiedAction: String?
        var dispatchKey: String?
        var lastActionOutcome: ActionOutcome?
        var result: String?
        var createdAt = Date()
        var updatedAt = Date()
        var requiresReview = false
        var conversationID: Int64?
        var reviewReason: String?
        var coordinating: Bool?
        var parentID: UUID?
        var outputs: [String]?

        var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
        var status: String {
            var lines = ["\(state.label): \(request)", "Now: \(stage)", "\(completedSteps) steps completed"]
            if let lastConfirmedStep { lines.append("Last confirmed step: " + lastConfirmedStep) }
            if let pendingAction { lines.append("Outcome needs checking: " + pendingAction + ". It will not be replayed automatically.") }
            if let unverifiedAction { lines.append("Unverified outcome: " + unverifiedAction + ". Check the real state before retrying.") }
            if let result { lines.append(result) }
            if requiresReview { lines.append(reviewReason ?? "Review this queued task before starting it after a restart.") }
            return lines.joined(separator: "\n")
        }
    }
    @Published private(set) var records: [Record] = []
    @Published private(set) var storageError: String?
    var onReady: ((UUID) -> Void)?
    private let redact: (String) -> String
    private var database: SQLiteDatabase?
    private var positions: [UUID: Int] = [:]
    private var corrupt = false

    init(file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clinqy/tasks.sqlite"),
         legacyFile: URL? = nil, redact: @escaping (String) -> String = Secrets.mask) {
        self.redact = redact
        do {
            let db = try SQLiteDatabase(file: file)
            database = db
            try db.execute("CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY COLLATE NOCASE, state TEXT NOT NULL, updated REAL NOT NULL, payload TEXT NOT NULL); CREATE INDEX IF NOT EXISTS tasks_updated ON tasks(updated DESC); CREATE INDEX IF NOT EXISTS tasks_state ON tasks(state); CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);")
            let legacy = legacyFile ?? (file.lastPathComponent == "tasks.sqlite" ? file.deletingLastPathComponent().appendingPathComponent("tasks.json") : nil)
            if try db.rows("SELECT value FROM metadata WHERE key='legacy_imported'").isEmpty {
                try db.transaction {
                    if let legacy, FileManager.default.fileExists(atPath: legacy.path) {
                        let old = try JSONDecoder().decode([Record].self, from: Data(contentsOf: legacy))
                        for item in old { try persist(item, replace: false) }
                    }
                    try db.execute("INSERT INTO metadata VALUES('legacy_imported','1')")
                }
            }
            // Keep unfinished work and a recent UI window in memory. All older records remain addressable in SQL.
            let rows = try db.rows("SELECT payload FROM tasks WHERE state IN ('queued','running','waiting','needsAttention','interrupted') OR id IN (SELECT id FROM tasks ORDER BY updated DESC LIMIT 500) ORDER BY updated")
            records = try rows.map { try JSONDecoder().decode(Record.self, from: Data($0[0].utf8)) }
            try db.transaction {
                for index in records.indices {
                    switch records[index].state {
                    case .running, .waiting, .needsAttention:
                        records[index].state = .interrupted
                        records[index].stage = "Clinqy stopped before this task finished. Check the real outcome before sending new instructions."
                        records[index].updatedAt = Date()
                        try persist(records[index])
                    case .queued:
                        records[index].requiresReview = true
                        records[index].reviewReason = "Restored after restart. Review the request and files, then start it explicitly."
                        try persist(records[index])
                    default: break
                    }
                }
            }
            rebuildPositions()
        } catch {
            corrupt = true
            storageError = "Task history couldn't be read safely. Existing files were preserved; automatic task starts are disabled."
        }
    }

    func record(_ id: UUID?) -> Record? {
        guard let id else { return nil }
        if let index = positions[id] { return records[index] }
        return stored("SELECT payload FROM tasks WHERE id=?", [id.uuidString]).first
    }
    func find(_ shortID: String) -> Record? {
        guard shortID.count >= 4, shortID.count <= 36, shortID.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        let matches = stored("SELECT payload FROM tasks WHERE id LIKE ? LIMIT 2", [shortID + "%"])
        return matches.count == 1 ? matches[0] : nil
    }
    var backgroundLimit = 3
    var activeForeground: Record? { records.last { !$0.background && [.running, .waiting, .needsAttention].contains($0.state) } }
    var activeBackground: [Record] { records.filter { $0.background && $0.coordinating != true && [.running, .waiting, .needsAttention].contains($0.state) } }
    func coordinate(_ id: UUID) { _ = change(id) { $0.coordinating = true; $0.stage = "Waiting for parallel browser tasks" } }

    var active: Record? { records.last { [.running, .waiting, .needsAttention].contains($0.state) } }
    var queued: [Record] { records.filter { $0.state == .queued }.sorted { $0.createdAt < $1.createdAt } }
    var recovery: [Record] { records.filter { $0.state == .interrupted || ($0.state == .queued && $0.requiresReview) } }

    @discardableResult
    func enqueue(_ request: String, files: [URL] = [], source: Source, background: Bool = true, conversationID: Int64? = nil, idempotencyKey: String? = nil, parentID: UUID? = nil) -> UUID? {
        if let idempotencyKey {
            if let existing = records.first(where: { $0.dispatchKey == idempotencyKey }) { return existing.id }
            if let existing = stored("SELECT payload FROM tasks WHERE json_extract(payload, '$.dispatchKey')=? LIMIT 1", [idempotencyKey]).first { return existing.id }
        }
        let clean = redact(request)
        let item = Record(request: clean, files: files.map(\.path), source: source, background: background,
                          requiresReview: clean != request, conversationID: conversationID,
                          reviewReason: clean != request ? "Private values were removed from this request. Rewrite it without secrets before running it." : nil)
        var scheduled = item
        scheduled.dispatchKey = idempotencyKey
        scheduled.parentID = parentID
        guard !corrupt else { return nil }
        do { try persist(scheduled); records.append(scheduled); positions[scheduled.id] = records.count - 1; trimPublishedRecords(); storageError = nil }
        catch { storageError = "Couldn't save task state. Work is stopped to preserve safe recovery."; return nil }
        return item.id
    }

    @discardableResult
    func start(_ id: UUID, explicitlyReviewed: Bool = false) -> Bool {
        guard let item = record(id), item.state == .queued, !item.requiresReview || explicitlyReviewed,
              item.reviewReason?.contains("Private values") != true,
              TaskCapacity.canStart(background: item.background, foregroundRunning: activeForeground != nil,
                  backgroundRunning: activeBackground.count, limit: backgroundLimit) else { return false }
        guard item.files.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
            update(id, state: .failed, stage: "An attached file is missing. Reattach it and send a new task.")
            return false
        }
        return change(id) { $0.state = .running; $0.stage = "Getting started"; $0.requiresReview = false; $0.reviewReason = nil }
    }

    /// Explicitly review a restored queued request without consuming a slot before it can run.
    @discardableResult
    func reviewQueued(_ id: UUID) -> Bool {
        guard let item = record(id), item.state == .queued,
              item.reviewReason?.contains("Private values") != true else { return false }
        return change(id) { $0.requiresReview = false; $0.reviewReason = nil }
    }

    @discardableResult
    func update(_ id: UUID?, state: State? = nil, stage: String? = nil, completedSteps: Int? = nil, background: Bool? = nil) -> Bool {
        guard let id, let item = record(id), !item.state.terminal else { return id == nil }
        return change(id) {
            if let state { $0.state = state }
            if let stage { $0.stage = redact(stage) }
            if let completedSteps { $0.completedSteps = completedSteps }
            if let background { $0.background = background }
        }
    }

    /// Must succeed before executing an action, otherwise fail closed instead of losing the recovery checkpoint.
    func beginAction(_ id: UUID?, kind: String) -> Bool {
        guard let id else { return true } // Unattended/test runs do not enter user history.
        guard let item = record(id), !item.state.terminal else { return false }
        return change(id) { $0.state = .running; $0.pendingAction = kind; $0.stage = "Working: " + kind }
    }
    @discardableResult
    func endAction(_ id: UUID?, kind: String, outcome: ActionOutcome, completedSteps: Int) -> Bool {
        guard let id else { return true }
        guard let item = record(id), !item.state.terminal else { return false }
        return change(id) {
            $0.pendingAction = nil
            $0.completedSteps = completedSteps
            $0.lastActionOutcome = outcome
            if outcome.isConfirmed { $0.lastConfirmedStep = kind }
            if outcome.needsVerification { $0.unverifiedAction = kind }
        }
    }
    /// Only a successful, explicit state assertion resolves an uncertain side effect.
    @discardableResult
    func confirmAction(_ id: UUID?, evidence: String) -> Bool {
        guard let id else { return true }
        guard let item = record(id), !item.state.terminal else { return false }
        return change(id) {
            if let action = $0.unverifiedAction { $0.lastConfirmedStep = action + " (" + redact(evidence) + ")" }
            $0.unverifiedAction = nil
        }
    }
    func setOutputs(_ id: UUID?, files: [URL]) {
        guard let id else { return }
        _ = change(id) { $0.outputs = files.map(\.path) }
    }
    func finish(_ id: UUID?, ok: Bool, answer: String) {
        guard let id else { return }
        _ = change(id) {
            $0.state = answer == "Stopped" ? .cancelled : ok && $0.pendingAction == nil && $0.unverifiedAction == nil ? .succeeded : .failed
            let checked = ok && ($0.pendingAction != nil || $0.unverifiedAction != nil)
                ? "Outcome not confirmed. Check the real application before retrying. " + answer : answer
            $0.stage = redact(checked)
            $0.result = redact(checked)
            // Preserve an in-flight checkpoint when cancellation races with a side effect.
        }
    }
    func cancelQueued(_ id: UUID) {
        guard record(id)?.state == .queued else { return }
        _ = change(id) { $0.state = .cancelled; $0.stage = "Cancelled before starting" }
    }
    func requestStart(_ id: UUID) { guard record(id)?.state == .queued else { return }; onReady?(id) }

    private func change(_ id: UUID, _ action: (inout Record) -> Void) -> Bool {
        guard !corrupt, var item = record(id) else { return false }
        action(&item); item.updatedAt = Date()
        do {
            try persist(item) // Durable acknowledgement comes before publishing or executing a side effect.
            if let index = positions[id] { records[index] = item }
            else { records.append(item); positions[id] = records.count - 1 }
            trimPublishedRecords()
            storageError = nil
            return true
        } catch {
            storageError = "Couldn't save task state. Work is stopped to preserve safe recovery."
            return false
        }
    }

    private func persist(_ item: Record, replace: Bool = true) throws {
        guard let database else { throw NSError(domain: "Clinqy.Tasks", code: 1) }
        let payload = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        let sql = replace
            ? "INSERT INTO tasks VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,updated=excluded.updated,payload=excluded.payload"
            : "INSERT OR IGNORE INTO tasks VALUES(?,?,?,?)"
        try database.execute(sql, [item.id.uuidString, item.state.rawValue, String(item.updatedAt.timeIntervalSince1970), payload])
    }
    private func stored(_ sql: String, _ values: [String]) -> [Record] {
        guard let rows = try? database?.rows(sql, values) else { return [] }
        return rows.compactMap { try? JSONDecoder().decode(Record.self, from: Data($0[0].utf8)) }
    }
    private func trimPublishedRecords() {
        guard records.count > 600 else { return }
        let recent = Set(records.suffix(500).map(\.id))
        records.removeAll { $0.state.terminal && $0.state != .interrupted && !recent.contains($0.id) }
        rebuildPositions()
    }
    private func rebuildPositions() { positions = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) }) }
}
