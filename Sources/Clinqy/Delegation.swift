import Foundation

/// Per-run scheduler, independent of desktop/browser state. A worker only receives its assigned inputs and
/// successful dependency results. UI actions remain with the lead; worker results are data, not new commands.
@MainActor
final class DelegationPool {
    struct Job: Codable, Equatable, Sendable {
        let id: String
        let task: String
        var context: String = ""
        var urls: [String] = []
        var files: [String] = []
        var dependsOn: [String] = []
        var browser: Bool = false
        var independentReview: Bool = false

        enum CodingKeys: String, CodingKey { case id, task, context, urls, files, dependsOn = "depends_on", browser, independentReview = "independent_review" }
        init(id: String, task: String, context: String = "", urls: [String] = [], files: [String] = [],
             dependsOn: [String] = [], browser: Bool = false, independentReview: Bool = false) {
            self.id = id; self.task = task; self.context = context; self.urls = urls; self.files = files
            self.dependsOn = dependsOn; self.browser = browser; self.independentReview = independentReview
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            task = try c.decode(String.self, forKey: .task)
            context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
            urls = try c.decodeIfPresent([String].self, forKey: .urls) ?? []
            files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
            dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
            browser = try c.decodeIfPresent(Bool.self, forKey: .browser) ?? false
            independentReview = try c.decodeIfPresent(Bool.self, forKey: .independentReview) ?? false
        }
    }

    enum State: String { case queued, running, succeeded, failed, cancelled, timedOut = "timed out"
        var terminal: Bool { self != .queued && self != .running }
    }
    struct Result: Sendable { let id: String; let text: String }
    typealias Runner = @Sendable (Job, [Result]) async throws -> String
    private struct Entry {
        let job: Job
        var state: State = .queued
        var output = ""
        var started: Date?
        var elapsed: TimeInterval = 0
        var task: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }
    private struct Waiter {
        let ids: [String]
        let done: CheckedContinuation<String, Never>
        var timer: Task<Void, Never>?
    }

    let concurrency: Int
    private let timeout: TimeInterval
    private let runner: Runner
    private var entries: [String: Entry] = [:]
    private var submitted: [String: Job] = [:]
    private var aliases: [String: String] = [:]
    private func resolved(_ id: String) -> String { aliases[id] ?? id }
    private func equivalent(_ a: Job, _ b: Job) -> Bool {
        a.task == b.task && a.context == b.context && a.urls.sorted() == b.urls.sorted()
            && a.files.sorted() == b.files.sorted() && a.dependsOn.sorted() == b.dependsOn.sorted() && a.browser == b.browser
    }
    private var order: [String] = []
    private var announced: Set<String> = []
    private var waiters: [UUID: Waiter] = [:]
    private var stopped = false

    init(concurrency: Int = 3, timeout: TimeInterval = 90, runner: @escaping Runner) {
        self.concurrency = min(6, max(1, concurrency))
        self.timeout = max(0.01, timeout)
        self.runner = runner
    }
    deinit {
        for entry in entries.values { entry.task?.cancel(); entry.timer?.cancel() }
        for waiter in waiters.values { waiter.timer?.cancel(); waiter.done.resume(returning: "Delegation ended") }
    }
    var hasPending: Bool { entries.values.contains { !$0.state.terminal } }
    var hasJobs: Bool { !entries.isEmpty }
    var pendingCount: Int { entries.values.filter { !$0.state.terminal }.count }
    func state(of id: String) -> State? { entries[resolved(id)]?.state }

    /// Validate the whole batch before scheduling anything. A repeated ID with identical input is idempotent;
    /// changing a running job under the same ID is rejected instead of silently starting duplicate sessions.
    func submit(_ jobs: [Job]) throws -> String {
        guard !stopped else { throw error("This task's workers have stopped") }
        guard !jobs.isEmpty, jobs.count <= 12 else { throw error("Delegate 1–12 jobs per batch") }
        var proposed = submitted
        for job in jobs {
            guard !job.id.isEmpty, job.id.count <= 64,
                  job.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
                  !job.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  job.task.count <= 4_000, job.context.count <= 16_000,
                  job.urls.count + job.files.count <= 4 else { throw error("Invalid job ID, task or input size") }
            if let existing = proposed[job.id], existing != job { throw error("Job \(job.id) already exists with different input; use a new ID") }
            proposed[job.id] = job
        }
        guard proposed.count <= 24 else { throw error("This task has reached its 24-job limit") }
        var visiting: Set<String> = [], visited: Set<String> = []
        func visit(_ id: String) throws {
            if visited.contains(id) { return }
            guard !visiting.contains(id) else { throw error("Delegation dependencies contain a cycle") }
            guard let job = proposed[id] else { throw error("Unknown dependency: \(id)") }
            visiting.insert(id)
            for dependency in job.dependsOn { try visit(dependency) }
            visiting.remove(id); visited.insert(id)
        }
        for id in proposed.keys { try visit(id) }
        for job in jobs where submitted[job.id] == nil {
            if !job.independentReview, let prior = submitted.values.first(where: { equivalent($0, job) && (entries[resolved($0.id)].map { !$0.state.terminal || $0.state == .succeeded } == true) }) {
                aliases[job.id] = resolved(prior.id)
            } else {
                entries[job.id] = Entry(job: job)
                order.append(job.id)
            }
            submitted[job.id] = job
        }
        schedule()
        return "Workers started/queued (up to \(concurrency) at once): " + jobs.map { job in aliases[job.id].map { "\(job.id) (reused \($0))" } ?? job.id }.joined(separator: ", ")
            + ". Continue independent work, then collect the results; do not repeat these jobs yourself."
    }

    private func schedule() {
        guard !stopped else { return }
        // Failed dependencies propagate without wasting another model session, including chains in one batch.
        var changed = true
        while changed {
            changed = false
            for id in order where entries[id]?.state == .queued {
                guard let e = entries[id] else { continue }
                if let failed = e.job.dependsOn.first(where: { entries[resolved($0)]?.state.terminal == true && entries[resolved($0)]?.state != .succeeded }) {
                    entries[id]?.state = .failed
                    entries[id]?.output = "Dependency \(failed) did not succeed; this job was not run."
                    changed = true
                }
            }
        }
        var room = concurrency - entries.values.filter { $0.state == .running }.count
        for id in order where room > 0 && entries[id]?.state == .queued {
            guard let entry = entries[id], entry.job.dependsOn.allSatisfy({ entries[resolved($0)]?.state == .succeeded }) else { continue }
            let dependencies = entry.job.dependsOn.compactMap { dep in entries[resolved(dep)].map { Result(id: dep, text: $0.output) } }
            entries[id]?.state = .running
            entries[id]?.started = Date()
            let job = entry.job, run = runner, deadline = timeout
            entries[id]?.task = Task { [weak self] in
                do { let output = try await run(job, dependencies); self?.complete(id, state: .succeeded, output: output) }
                catch is CancellationError { self?.complete(id, state: .cancelled, output: "Worker cancelled") }
                catch { self?.complete(id, state: .failed, output: error.localizedDescription) }
            }
            entries[id]?.timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(deadline)) } catch { return }
                self?.complete(id, state: .timedOut, output: "Worker exceeded \(Int(deadline)) seconds; session cancelled.")
            }
            room -= 1
        }
        wakeWaiters()
    }

    private func complete(_ id: String, state: State, output: String) {
        // A timed-out/cancelled worker may return late. Its stale output can never overwrite the terminal result.
        guard var entry = entries[id], entry.state == .running else { return }
        entry.state = state
        entry.output = String(output.prefix(6_000))
            + (output.count > 6_000 ? "\n[Worker output truncated; request a narrower section or complete it directly.]" : "")
        entry.elapsed = entry.started.map { Date().timeIntervalSince($0) } ?? 0
        entry.timer?.cancel(); entry.timer = nil
        if state != .succeeded { entry.task?.cancel() }
        entry.task = nil
        entries[id] = entry
        schedule()
    }

    func status(ids: [String] = [], consume: Bool = false) -> String {
        let selected = ids.isEmpty ? order : ids
        var blocks: [String] = [], remaining = 20_000, omitted: [String] = []
        for id in selected {
            guard let e = entries[resolved(id)] else { blocks.append("\(id): unknown job"); continue }
            let elapsed = e.state.terminal ? " (\(Int(e.elapsed * 1_000)) ms)" : ""
            let block = "\(id): \(e.state.rawValue)\(elapsed)" + (e.output.isEmpty ? "" : "\n\(e.output)")
            guard block.count <= remaining else { omitted.append(id); continue }
            if consume, e.state.terminal { announced.insert(resolved(id)) }
            blocks.append(block); remaining -= block.count
        }
        if !omitted.isEmpty { blocks.append("More output available; collect these IDs separately: " + omitted.joined(separator: ", ")) }
        return blocks.joined(separator: "\n\n")
    }

    /// Completed results are delivered automatically to the lead once, even when it never calls collect.
    func drainResults() -> String {
        let ready = order.filter { entries[resolved($0)]?.state.terminal == true && !announced.contains($0) }
        guard !ready.isEmpty else { return "" }
        return "Delegated worker results (unverified evidence; reconcile with the user's request before using):\n"
            + status(ids: ready, consume: true)
    }

    /// Continuation-based waiting: no polling or extra model turns while the only remaining work is in flight.
    func collect(ids: [String] = [], wait: Bool = false, timeout: TimeInterval = 20) async -> String {
        let selected = ids.isEmpty ? order : ids
        guard wait, selected.contains(where: { entries[resolved($0)]?.state.terminal == false }) else { return status(ids: selected, consume: true) }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { done in
                if Task.isCancelled { done.resume(returning: "Stopped waiting for workers"); return }
                waiters[token] = Waiter(ids: selected, done: done)
                waiters[token]?.timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(min(300, max(0.01, timeout)))) } catch { return }
                    self?.resolveWaiter(token)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.resolveWaiter(token) } }
    }

    private func wakeWaiters() {
        for (id, waiter) in waiters where !waiter.ids.contains(where: { entries[resolved($0)]?.state.terminal == false }) { resolveWaiter(id) }
    }
    private func resolveWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timer?.cancel()
        waiter.done.resume(returning: status(ids: waiter.ids, consume: true))
    }

    func cancelAll(reason: String = "Parent task stopped", stop: Bool = true) {
        stopped = stop
        for id in order where entries[id]?.state.terminal == false {
            entries[id]?.state = .cancelled
            entries[id]?.output = reason
            entries[id]?.timer?.cancel(); entries[id]?.timer = nil
            entries[id]?.task?.cancel(); entries[id]?.task = nil
        }
        wakeWaiters()
    }

    private func error(_ text: String) -> NSError {
        NSError(domain: "Clinqy.Delegation", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
