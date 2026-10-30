import Foundation

/// The in-memory route list is a bounded hot cache, not the lifetime of a learned procedure.
@MainActor final class ProcedureStore {
    private let db: SQLiteDatabase
    init(file: URL) throws {
        db = try SQLiteDatabase(file: file)
        try db.execute("CREATE TABLE IF NOT EXISTS procedures(id TEXT PRIMARY KEY, normalized TEXT NOT NULL, place TEXT NOT NULL, title TEXT NOT NULL, site TEXT, misses INTEGER NOT NULL, updated REAL NOT NULL, payload TEXT NOT NULL); CREATE INDEX IF NOT EXISTS procedures_request ON procedures(normalized,place,title); CREATE INDEX IF NOT EXISTS procedures_date ON procedures(updated DESC);")
    }
    func save(_ routes: [CachedRoute], importing: Bool = false) throws {
        try db.transaction {
            for route in routes {
                let data = try JSONEncoder.iso8601.encode(route)
                guard let safe = Secrets.maskJSON(data) else { continue }
                let sql = importing ? "INSERT OR IGNORE INTO procedures VALUES(?,?,?,?,?,?,?,?)"
                    : "INSERT INTO procedures VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET normalized=excluded.normalized,place=excluded.place,title=excluded.title,site=excluded.site,misses=excluded.misses,updated=excluded.updated,payload=excluded.payload"
                try db.execute(sql, [route.id.uuidString, Router.normalize(route.request), route.place, route.title, route.site,
                                     String(route.misses), String(route.last.timeIntervalSince1970), String(decoding: safe, as: UTF8.self)])
            }
        }
    }
    func recent() throws -> [CachedRoute] { try decode(db.rows("SELECT payload,misses FROM procedures ORDER BY updated DESC LIMIT 150")) }
    func exact(_ request: String, place: String, title: String) throws -> CachedRoute? {
        try decode(db.rows("SELECT payload,misses FROM procedures WHERE normalized=? AND ((place=? AND title=?) OR site IS NOT NULL) ORDER BY updated DESC LIMIT 1",
                           [Router.normalize(request), place, title])).first
    }
    func corrected(_ request: String) throws { try db.execute("UPDATE procedures SET misses=misses+1 WHERE normalized=?", [Router.normalize(request)]) }
    func remove(_ id: UUID) throws { try db.execute("DELETE FROM procedures WHERE id=?", [id.uuidString]) }
    private func decode(_ rows: [[String]]) throws -> [CachedRoute] {
        try rows.map { row in
            var route = try JSONDecoder.iso8601.decode(CachedRoute.self, from: Data(row[0].utf8))
            route.misses = Int(row[1]) ?? route.misses
            return route
        }
    }
}
