import Foundation

/// Setup-screen state that must not leak between providers or between connection tests.
/// Credentials typed for one provider stay with it, and a connection test's result is applied only if no newer
/// test or provider change has happened since it started.
struct ConnectionDrafts {
    private var keys: [String: String] = [:]
    private(set) var generation = 0

    /// Leaving `provider`: remember what was typed for it.
    mutating func stash(_ key: String, for provider: String) { keys[provider] = key }

    /// Arriving at `provider`: its own draft, else what is saved, else empty. Never the previous provider's key.
    func draft(for provider: String, saved: String?) -> String { keys[provider] ?? saved ?? "" }

    mutating func reset() { keys = [:] }

    /// A new test (or a provider change) retires every earlier test; returns the id the new one must present.
    @discardableResult mutating func beginTest() -> Int { generation += 1; return generation }
    func accepts(_ id: Int) -> Bool { id == generation }
}
