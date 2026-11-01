import Foundation

// No model or on-device encoder is needed for the exact-repeat path under test.
final class Embedder {
    static let shared = Embedder()
    var calls = 0
    var usesModel = false
    func vector(_ text: String) -> [Float]? { calls += 1; return nil }
    func cached(_ text: String) -> [Float]? { nil }
    func warm(_ texts: [String]) {}
    static func cosine(_ a: [Float], _ b: [Float]) -> Float { 0 }
}
enum FastLane { static let riskyLabel = #"(?i)\b(send|submit|delete|pay|upload)\b"# }

@main struct RouteMemoryTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-route-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("routes.json")
        let cache = ReplayCache(file: file)
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        let trace = [WorkflowStep(action: "click", target: .init(kind: "web", role: "button", label: "Reports")),
                     WorkflowStep(action: "click", target: .init(kind: "web", role: "button", label: "Quarterly"))]
        for _ in 0..<2 {
            cache.record(request: "Open quarterly reports", trace: trace, app: "Chrome", url: "https://finance.example.com", title: "Finance")
        }
        let fast = cache.replayable(request: "Please open quarterly reports", app: "Chrome", url: "https://finance.example.com", title: "Finance")
        check(fast?.steps == trace, "proven exact request reuses its method")
        check(Embedder.shared.calls == 0, "exact same-place replay doesn't compute a query embedding")
        let differentPlace = cache.replayable(request: "Open quarterly reports", app: "Chrome", url: "https://other.example.com", title: "Finance")
        check(differentPlace == nil, "matching words don't authorize replay in a different place")
        cache.corrected(request: "In the background: Open quarterly reports")
        let corrected = cache.replayable(request: "Open quarterly reports", app: "Chrome", url: "https://finance.example.com", title: "Finance")
        check(corrected == nil, "user correction disables the previously proven route, including background history")
        cache.record(request: "Open quarterly reports", trace: trace.reversed(), app: "Chrome", url: "https://finance.example.com", title: "Finance")
        check(cache.replayable(request: "Open quarterly reports", app: "Chrome", url: "https://finance.example.com", title: "Finance")?.steps == trace.reversed(),
              "a later successful run replaces the old method")

        var risky = trace
        risky.append(WorkflowStep(action: "click", target: .init(kind: "web", role: "button", label: "Submit")))
        for _ in 0..<2 {
            cache.record(request: "Submit quarterly reports", trace: risky, app: "Chrome", url: "https://finance.example.com", title: "Finance")
        }
        check(cache.replayable(request: "Submit quarterly reports", app: "Chrome", url: "https://finance.example.com", title: "Finance") == nil,
              "submit route stays off automatic replay")
        // Persist only the test cache; don't initialize the global app store through Persist.flush().
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(cache.all).write(to: file, options: .atomic)
        let restored = ReplayCache(file: file)
        check(restored.all.count == 2, "routes restore after reopening")
        check(restored.replayable(request: "Open quarterly reports", app: "Chrome", url: "https://finance.example.com", title: "Finance") != nil,
              "restored method remains replayable")
        for i in 0..<170 {
            cache.record(request: "Open historical report \(i)", trace: trace, app: "Chrome", url: "https://finance.example.com", title: "Finance")
        }
        check(cache.all.count <= 150, "hot route list remains bounded")
        let cold = ReplayCache(file: file)
        check(cold.replayable(request: "Open quarterly reports", app: "Chrome", url: "https://finance.example.com", title: "Finance") != nil,
              "proven procedures survive hot-cache eviction and reopening")
        cold.corrected(request: "Open quarterly reports")
        check(ReplayCache(file: file).replayable(request: "Open quarterly reports", app: "Chrome", url: "https://finance.example.com", title: "Finance") == nil,
              "corrections invalidate cold procedures durably")
        let researched = History.Entry(date: Date(), request: "Write a current market report", answer: "Drafted", ok: true,
                                       steps: ["Researched current sources", "Typed draft"], app: "Chrome", result: nil,
                                       trace: trace, requiresFreshWork: true)
        check(Workflow.from(researched) == nil, "fresh research can't become a partial UI-only replay with stale content")
        print("PASS: \(checks) route reuse and correction checks")
    }
}
