import Foundation

/// Correlates extension responses with the requests that are waiting for them.
/// An id is only ever honoured when it comes back on the connection the request was sent to, and ids carry a
/// per-launch epoch so a restarted app can never mistake an old process's "r1" for its own.
struct BridgeRequestTable<Waiter, Owner: Hashable> {
    private struct Entry { let owner: Owner; let waiter: Waiter }
    private var entries: [String: Entry] = [:]
    private var counter = 0
    let epoch: String

    init(epoch: String = String(UUID().uuidString.prefix(8)).lowercased()) { self.epoch = epoch }

    var count: Int { entries.count }

    /// A fresh id for a request that is about to be sent to `owner`.
    mutating func register(_ waiter: Waiter, owner: Owner) -> String {
        counter += 1
        let id = "r\(epoch)-\(counter)"
        entries[id] = Entry(owner: owner, waiter: waiter)
        return id
    }

    /// The waiter for `id`, only if the response arrived from the connection the request went to.
    /// A response for a known id from a different connection is ignored and leaves the request pending.
    mutating func claim(_ id: String, from owner: Owner) -> Waiter? {
        guard let entry = entries[id], entry.owner == owner else { return nil }
        entries.removeValue(forKey: id)
        return entry.waiter
    }

    /// Removes a request regardless of who would answer it (timeout, cancellation).
    mutating func discard(_ id: String) -> Waiter? { entries.removeValue(forKey: id)?.waiter }

    /// Every request sent to a connection that has gone away.
    mutating func drain(owner: Owner) -> [Waiter] {
        let ids = entries.filter { $0.value.owner == owner }.map(\.key)
        return ids.compactMap { entries.removeValue(forKey: $0)?.waiter }
    }
}
