import Foundation

actor WorkerProbe {
    var active = 0, peak = 0
    var started: [String] = []
    var inputs: [String: [DelegationPool.Result]] = [:]
    func begin(_ id: String, dependencies: [DelegationPool.Result]) {
        active += 1; peak = max(peak, active); started.append(id); inputs[id] = dependencies
    }
    func end() { active -= 1 }
    func snapshot() -> (Int, Int, [String]) { (active, peak, started) }
    func dependencies(_ id: String) -> [DelegationPool.Result] { inputs[id] ?? [] }
}

@main struct DelegationTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        func rejected(_ block: () throws -> Void) -> Bool { do { try block(); return false } catch { return true } }
        func job(_ id: String, dependencies: [String] = []) -> DelegationPool.Job {
            .init(id: id, task: "Analyze \(id)", dependsOn: dependencies)
        }
        func runner(_ probe: WorkerProbe, delay: Double = 0.1) -> DelegationPool.Runner {
            { job, dependencies in
                await probe.begin(job.id, dependencies: dependencies)
                do {
                    try await Task.sleep(for: .seconds(delay))
                    await probe.end()
                    if job.id == "bad" { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Source failed"]) }
                    return "Answer for \(job.id)"
                } catch {
                    // A deliberately failed completed job has already decremented the probe.
                    if job.id != "bad" || error is CancellationError { await probe.end() }
                    throw error
                }
            }
        }

        let probe = WorkerProbe()
        let pool = DelegationPool(concurrency: 2, timeout: 2, runner: runner(probe))
        _ = try pool.submit([job("a"), job("b"), job("c")])
        check(pool.state(of: "a") == .running && pool.state(of: "c") == .queued, "concurrency is bounded; overflow queues")
        let immediate = await pool.collect()
        check(immediate.contains("running") && immediate.contains("queued"), "nonblocking collection returns progress")
        let results = await pool.collect(wait: true, timeout: 2)
        check(results.contains("Answer for a") && results.contains("Answer for c"), "waiting returns all completed results")
        let snapshot = await probe.snapshot()
        check(snapshot.0 == 0 && snapshot.1 == 2, "workers actually overlap without exceeding the limit")
        check(!pool.hasPending && pool.hasJobs, "completed work is terminal")
        check(pool.drainResults().isEmpty, "collected results aren't redundantly injected next turn")
        _ = try pool.submit([job("a")])
        check((await probe.snapshot()).2.filter { $0 == "a" }.count == 1, "same ID and inputs don't start duplicate sessions")
        check(rejected { _ = try pool.submit([job("new"), .init(id: "a", task: "Different task")]) }, "changing a reused ID rejects the entire batch")
        check(pool.state(of: "new") == nil, "invalid batch never partially starts")

        _ = try pool.submit([.init(id: "reuse", task: "Analyze a"), .init(id: "after_reuse", task: "Combine reused evidence", dependsOn: ["reuse"])])
        _ = await pool.collect(wait: true, timeout: 2)
        check(!(await probe.snapshot()).2.contains("reuse"), "equivalent jobs share a single worker session")
        check(await probe.dependencies("after_reuse").first?.id == "reuse", "dependency aliases preserve their requested IDs")
        _ = try pool.submit([.init(id: "review", task: "Analyze a", independentReview: true)])
        _ = await pool.collect(wait: true, timeout: 2)
        check((await probe.snapshot()).2.contains("review"), "independent reviews deliberately receive a separate session")

        let graphProbe = WorkerProbe()
        let graph = DelegationPool(concurrency: 3, timeout: 2, runner: runner(graphProbe, delay: 0.03))
        _ = try graph.submit([job("summary", dependencies: ["source_a", "source_b"]), job("source_a"), job("source_b")])
        check(graph.state(of: "summary") == .queued, "dependency declared later in the batch is supported")
        _ = await graph.collect(wait: true, timeout: 2)
        let inputs = await graphProbe.dependencies("summary")
        check(Set(inputs.map(\.id)) == ["source_a", "source_b"], "dependent worker gets exactly its successful dependencies")
        check(inputs.allSatisfy { $0.text.hasPrefix("Answer for") }, "dependency outputs are passed to the worker")
        let notification = graph.drainResults()
        check(notification.isEmpty, "collect consumes dependency results once")

        let validation = DelegationPool(runner: runner(WorkerProbe()))
        check(rejected { _ = try validation.submit([job("a", dependencies: ["b"]), job("b", dependencies: ["a"])]) }, "cycles are rejected")
        check(!validation.hasJobs, "cycle doesn't leave queued work behind")
        check(rejected { _ = try validation.submit([job("a", dependencies: ["missing"])]) }, "missing dependencies are rejected")
        check(rejected { _ = try validation.submit([job("a", dependencies: ["a"])]) }, "self-dependency is rejected")
        check(rejected { _ = try validation.submit([.init(id: "../bad", task: "Analyze")]) }, "IDs are constrained")
        check(rejected { _ = try validation.submit([.init(id: "empty", task: " ")]) }, "empty assignments are rejected")
        check(rejected { _ = try validation.submit([.init(id: "large", task: "Analyze", context: String(repeating: "x", count: 16_001))]) }, "scoped context has a size budget")
        check(rejected { _ = try validation.submit([.init(id: "sources", task: "Analyze", files: Array(repeating: "a.txt", count: 5))]) }, "source I/O fan-out is bounded")
        let minimal = try JSONDecoder().decode(DelegationPool.Job.self, from: Data(#"{"id":"simple","task":"Calculate"}"#.utf8))
        check(minimal.context.isEmpty && minimal.urls.isEmpty && !minimal.browser, "minimal action JSON has sensible defaults")

        let failProbe = WorkerProbe()
        let failure = DelegationPool(concurrency: 2, runner: runner(failProbe, delay: 0.02))
        _ = try failure.submit([job("bad"), job("dependent", dependencies: ["bad"]), job("grandchild", dependencies: ["dependent"]), job("independent")])
        let failed = await failure.collect(wait: true, timeout: 2)
        check(failure.state(of: "dependent") == .failed && failure.state(of: "grandchild") == .failed, "failed dependency propagates through the DAG")
        check(!(await failProbe.snapshot()).2.contains("dependent"), "failed dependencies don't waste sessions")
        check(failed.contains("Answer for independent"), "one failure doesn't discard independent work")

        _ = try failure.submit([.init(id: "retry_bad", task: "Analyze bad")])
        _ = await failure.collect(wait: true, timeout: 2)
        check((await failProbe.snapshot()).2.contains("retry_bad"), "a failed equivalent job can be retried with a new ID")

        let timed = DelegationPool(concurrency: 1, timeout: 0.03, runner: runner(WorkerProbe(), delay: 0.3))
        _ = try timed.submit([job("slow"), job("next", dependencies: ["slow"])])
        _ = await timed.collect(wait: true, timeout: 1)
        check(timed.state(of: "slow") == .timedOut && timed.state(of: "next") == .failed, "timeout cancels a job and prevents dependent work")
        let waitProbe = WorkerProbe()
        let waiting = DelegationPool(timeout: 2, runner: runner(waitProbe, delay: 0.15))
        _ = try waiting.submit([job("slow")])
        _ = await waiting.collect(wait: true, timeout: 0.01)
        check(waiting.state(of: "slow") == .running, "a collect timeout doesn't cancel useful work")
        let waiter = Task { await waiting.collect(wait: true, timeout: 2) }
        waiter.cancel()
        _ = await waiter.value
        check(waiting.hasPending, "cancelling a wait doesn't abandon the task")
        waiting.cancelAll()
        check(waiting.state(of: "slow") == .cancelled, "stopping the parent cancels workers")
        check(rejected { _ = try waiting.submit([job("late")]) }, "stopped pool can't launch more sessions")

        let stale = DelegationPool(timeout: 1) { _, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return "Late answer based on old instructions"
        }
        _ = try stale.submit([job("old")])
        stale.cancelAll(reason: "User correction", stop: false)
        _ = try stale.submit([job("revised")])
        _ = await stale.collect(ids: ["revised"], wait: true, timeout: 1)
        check(stale.state(of: "old") == .cancelled, "late results cannot overwrite cancellation")
        check(stale.state(of: "revised") == .succeeded, "correction can submit a revised assignment")
        check(!stale.status(ids: ["old"]).contains("Late answer"), "cancelled stale output cannot reach the lead")

        let automatic = DelegationPool { job, _ in "Evidence for \(job.id)" }
        _ = try automatic.submit([job("auto")])
        while automatic.hasPending { await Task.yield() }
        check(automatic.drainResults().contains("Evidence for auto"), "results arrive even without explicit collection")
        check(automatic.drainResults().isEmpty, "automatic delivery happens only once")
        let bounded = DelegationPool { _, _ in String(repeating: "x", count: 10_000) }
        _ = try bounded.submit((0..<8).map { job("large_\($0)") })
        _ = await bounded.collect(wait: true, timeout: 2)
        let boundedResults = bounded.status()
        check(boundedResults.count < 21_000 && boundedResults.contains("More output available"), "aggregate results cannot flood the lead context")
        check(bounded.status(ids: ["large_7"]).count < 6_300, "omitted results are still retrievable by ID")
        check(bounded.status(ids: ["large_7"]).contains("Worker output truncated"), "long output is never silently presented as complete")

        func benchmark(_ concurrency: Int) async throws -> Double {
            let batch = DelegationPool(concurrency: concurrency, timeout: 3, runner: runner(WorkerProbe(), delay: 0.1))
            let start = Date()
            _ = try batch.submit((0..<6).map { job("bench_\($0)") })
            _ = await batch.collect(wait: true, timeout: 3)
            return Date().timeIntervalSince(start)
        }
        let serial = try await benchmark(1), parallel = try await benchmark(3)
        check(serial / parallel > 2, "independent jobs complete substantially faster in parallel")
        print(String(format: "Six simulated 100 ms jobs: serial %.0f ms, parallel %.0f ms (%.2f×)", serial * 1_000, parallel * 1_000, serial / parallel))
        print("PASS: \(checks) asynchronous delegation checks")
    }
}
