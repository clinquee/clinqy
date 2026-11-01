import Foundation

/// Per-run, bounded source snapshots and single-flight loading. Cancelling one consumer doesn't cancel a shared
/// request needed by another; cancelling its final consumer tears down the underlying request immediately.
actor SourceCache {
    nonisolated let session: URLSession
    private struct Cached { let text: String; var used: Date }
    private struct Flight {
        let generation: UUID
        var task: Task<Void, Never>?
        var consumers: [UUID: CheckedContinuation<String, Error>]
    }
    private var cached: [String: Cached] = [:]
    private var flights: [String: Flight] = [:]
    private var stopped = false

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }

    func value(for key: String, load: @escaping @Sendable () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        if let value = cached[key] {
            cached[key]?.used = Date()
            return value.text
        }
        let consumer = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { done in
                guard !Task.isCancelled else { done.resume(throwing: CancellationError()); return }
                if flights[key] != nil { flights[key]?.consumers[consumer] = done; return }
                let generation = UUID()
                flights[key] = Flight(generation: generation, consumers: [consumer: done])
                flights[key]?.task = Task { [weak self] in
                    let result: Result<String, Error>
                    do { result = .success(try await load()) } catch { result = .failure(error) }
                    await self?.finish(key, generation: generation, result: result)
                }
            }
        } onCancel: { Task { await self.withdraw(key, consumer: consumer) } }
    }

    private func finish(_ key: String, generation: UUID, result: Result<String, Error>) {
        guard let flight = flights[key], flight.generation == generation else { return }
        flights.removeValue(forKey: key)
        if case .success(let text) = result, text.utf8.count <= 64_000 {
            cached[key] = Cached(text: text, used: Date())
            while cached.count > 32 || cached.values.reduce(0, { $0 + $1.text.utf8.count }) > 512_000 {
                guard let oldest = cached.min(by: { $0.value.used < $1.value.used })?.key else { break }
                cached.removeValue(forKey: oldest)
            }
        }
        for waiter in flight.consumers.values { waiter.resume(with: result) }
    }
    private func withdraw(_ key: String, consumer: UUID) {
        guard let waiter = flights[key]?.consumers.removeValue(forKey: consumer) else { return }
        waiter.resume(throwing: CancellationError())
        if flights[key]?.consumers.isEmpty == true {
            flights.removeValue(forKey: key)?.task?.cancel()
        }
    }
    func cancelAll() {
        stopped = true
        let pending = flights.values
        flights.removeAll(); cached.removeAll()
        for flight in pending {
            flight.task?.cancel()
            for waiter in flight.consumers.values { waiter.resume(throwing: CancellationError()) }
        }
        session.invalidateAndCancel()
    }
}
