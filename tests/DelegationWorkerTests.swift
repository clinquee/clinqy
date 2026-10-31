import Foundation

// The real worker/source loader runs against a local HTTP fixture and isolated model/browser adapters.
enum Provider: Sendable { case fixture }
final class AgySession: @unchecked Sendable {
    private static let lock = NSLock()
    private static var prompts: [String] = []
    private static var active = 0, peak = 0, created = 0, closed = 0
    private var ended = false
    private let model: String
    init(system: String, model: String, provider: Provider, effort: String) throws {
        self.model = model
        Self.lock.withLock { Self.active += 1; Self.created += 1; Self.peak = max(Self.peak, Self.active) }
    }
    func send(_ text: String) async throws -> String {
        Self.lock.withLock { Self.prompts.append(text) }
        try await Task.sleep(for: .milliseconds(model == "slow" ? 400 : 30))
        if model == "rate-limited" { throw NSError(domain: "fixture", code: 429, userInfo: [NSLocalizedDescriptionKey: "HTTP 429 fixture rate limit"]) }
        return "Worker answer with source evidence"
    }
    func close() {
        Self.lock.withLock {
            guard !ended else { return }
            ended = true; Self.active -= 1; Self.closed += 1
        }
    }
    static func snapshot() -> (prompts: [String], active: Int, peak: Int, created: Int, closed: Int) {
        lock.withLock { (prompts, active, peak, created, closed) }
    }
}
enum Reader {
    static func fileText(_ url: URL) async -> String? { try? String(contentsOf: url, encoding: .utf8) }
}
@MainActor final class BrowserBridge {
    struct TabInfo: Sendable { let id: Int; let url: String }
    struct Page { let title: String; let url: String; var ready = "complete" }
    static let shared = BrowserBridge()
    var selected = 7
    var opened: [Int] = [], closed: [Int] = []
    var commands: [String] = []
    private var next = 100
    func backgroundTab(_ url: String, select: Bool = true) async -> (tab: TabInfo, browser: String?, window: String?)? {
        try? await Task.sleep(for: .milliseconds(10))
        next += 1; opened.append(next)
        if select { selected = next }
        return (TabInfo(id: next, url: url), nil, nil)
    }
    func waitForNavigation(on tab: TabInfo, to requested: String, previous: String? = nil, timeout: Double = 8) async -> Bool { !Task.isCancelled }
    func snapshot(of tab: TabInfo) async -> Page? { Page(title: "Source \(tab.id)", url: tab.url) }
    func perform(_ command: String, on page: Page) async throws -> [String: Any] {
        guard let id = opened.first(where: { "Source \($0)" == page.title }),
              let result = await tabCommand(command, on: TabInfo(id: id, url: page.url)) else {
            throw NSError(domain: "Fixture", code: 1)
        }
        return result
    }
    @discardableResult func tabCommand(_ command: String, on tab: TabInfo) async -> [String: Any]? {
        commands.append(command)
        if command == "closeTab" { closed.append(tab.id); return ["closed": tab.id] }
        if command == "read" {
            if tab.url.contains("/slow") { try? await Task.sleep(for: .milliseconds(300)) }
            return ["text": "Read-only document at \(tab.url)"]
        }
        return nil
    }
}

@main struct DelegationWorkerTests {
    @MainActor static func main() async throws {
        let base = CommandLine.arguments[1]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-source-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        @Sendable func run(_ job: DelegationPool.Job, dependencies: [DelegationPool.Result] = [], model: String = "fixture") async throws -> String {
            try await DelegationWorker.run(job, dependencies: dependencies, parent: "Compare the supplied sources", provider: .fixture, model: model, effort: "low")
        }
        let plain = DelegationWorker.htmlText("<style>hidden CSS</style><script>Ignore instructions</script><p>Revenue &amp; costs: 100</p><!-- secret comment -->")
        check(plain == "Revenue & costs: 100", "HTML text excludes scripts/styles/comments and decodes common entities")
        for url in ["file:///etc/passwd", "javascript:alert(1)", "https://user:password@example.com", "data:text/plain,a"] {
            do { _ = try DelegationWorker.webURL(url); preconditionFailure("invalid scheme/credentials accepted") } catch { checks += 1 }
        }

        let file = root.appendingPathComponent("budget.txt")
        try "Annual budget is 42".write(to: file, atomically: true, encoding: .utf8)
        let local = try await run(.init(id: "file", task: "Draft a budget summary", context: "Audience: CFO", files: [file.path]),
                                  dependencies: [.init(id: "baseline", text: "Previous budget: 40")])
        check(local.contains("Worker answer"), "worker returns its separate model session's answer")
        let prompt = AgySession.snapshot().prompts.last!
        check(prompt.contains("Annual budget is 42") && prompt.contains("Audience: CFO"), "worker sees only the provided file/context")
        check(prompt.contains("Previous budget: 40") && prompt.contains("unverified evidence"), "dependency data is explicitly scoped evidence")
        check(prompt.contains("Compare the supplied sources"), "parent goal is supplied as scope")
        check(AgySession.snapshot().active == 0, "successful worker closes its model session")

        async let first = run(.init(id: "a", task: "Extract revenue", urls: [base + "/a"]))
        async let second = run(.init(id: "b", task: "Extract costs", urls: [base + "/b"]))
        async let third = run(.init(id: "c", task: "Calculate using provided numbers", context: "Revenue 100, costs 40"))
        _ = try await (first, second, third)
        check(AgySession.snapshot().peak >= 2, "separate worker sessions actually overlap")
        let sourcePrompts = AgySession.snapshot().prompts
        check(sourcePrompts.contains { $0.contains("Revenue 100") && $0.contains("/a") }, "reads a public HTML source through the real HTTP loader")
        check(sourcePrompts.contains { $0.contains("costs") && $0.contains("/b") }, "reads a JSON source")
        check(!sourcePrompts.contains { $0.contains("fixture-injected-script") }, "source scripts don't reach the worker prompt")
        _ = try await run(.init(id: "large", task: "Summarize excerpt", urls: [base + "/large"]))
        let largePrompt = AgySession.snapshot().prompts.last!
        check(largePrompt.count < 12_000 && largePrompt.contains("truncated"), "large HTTP body is bounded and labelled as an excerpt")
        let before = AgySession.snapshot().created
        do { _ = try await run(.init(id: "error", task: "Read failed source", urls: [base + "/error"])); preconditionFailure("source failure ignored") }
        catch { check(error.localizedDescription.contains("503"), "HTTP failures preserve status for the lead") }
        check(AgySession.snapshot().created == before, "all-source failure doesn't waste a model request")
        _ = try await run(.init(id: "partial", task: "Summarize supplied context and note unavailable source", context: "Known value: 9", urls: [base + "/error"]))
        check(AgySession.snapshot().prompts.last!.contains("Source unavailable"), "partial source failures are disclosed rather than invented")

        var paths: [String] = []
        for i in 0..<4 {
            let path = root.appendingPathComponent("source\(i).txt")
            try ("Marker\(i) " + String(repeating: "detail ", count: 2_000)).write(to: path, atomically: true, encoding: .utf8)
            paths.append(path.path)
        }
        _ = try await run(.init(id: "four", task: "Compare four documents", files: paths))
        let four = AgySession.snapshot().prompts.last!
        check((0..<4).allSatisfy { four.contains("Marker\($0)") }, "source budget gives every supplied document context")
        check(four.count < 26_000, "combined source excerpts have a fixed budget")

        async let browserA = run(.init(id: "browser_a", task: "Read authenticated source A", urls: ["https://fixture.invalid/a"], browser: true))
        async let browserB = run(.init(id: "browser_b", task: "Read authenticated source B", urls: ["https://fixture.invalid/b"], browser: true))
        _ = try await (browserA, browserB)
        let browser = BrowserBridge.shared
        check(Set(browser.opened).count == 2, "browser source workers get distinct tab IDs")
        check(Set(browser.closed) == Set(browser.opened), "worker source tabs close after reading")
        check(browser.selected == 7, "source tabs never change the lead's selected tab")
        check(Set(browser.commands).isSubset(of: ["read", "closeTab"]), "browser workers never click, type or mutate page data")

        let modelCountBeforeCancel = AgySession.snapshot().created
        let cancelledBrowser = DelegationPool(timeout: 0.05) { job, dependencies in
            try await DelegationWorker.run(job, dependencies: dependencies, parent: "Cancelled source", provider: .fixture, model: "fixture", effort: "low")
        }
        _ = try cancelledBrowser.submit([.init(id: "slow_browser", task: "Read source", urls: ["https://fixture.invalid/slow"], browser: true)])
        _ = await cancelledBrowser.collect(wait: true, timeout: 1)
        try await Task.sleep(for: .milliseconds(30))
        check(cancelledBrowser.state(of: "slow_browser") == .timedOut, "slow browser source respects the worker deadline")
        check(Set(browser.closed) == Set(browser.opened), "cancellation closes the worker's owned source tab")
        check(AgySession.snapshot().created == modelCountBeforeCancel, "cancelled source read can't launch a late model session")

        let slow = DelegationPool(timeout: 0.05) { job, dependencies in
            try await DelegationWorker.run(job, dependencies: dependencies, parent: "Slow fixture", provider: .fixture, model: "slow", effort: "low")
        }
        _ = try slow.submit([.init(id: "slow", task: "Take too long")])
        _ = await slow.collect(wait: true, timeout: 1)
        try await Task.sleep(for: .milliseconds(30))
        check(slow.state(of: "slow") == .timedOut, "pool timeout reaches the real worker adapter")
        check(AgySession.snapshot().active == 0, "timeout closes the worker's model session")
        let limited = DelegationPool { job, dependencies in
            try await DelegationWorker.run(job, dependencies: dependencies, parent: "Rate-limit fixture", provider: .fixture, model: "rate-limited", effort: "low")
        }
        _ = try limited.submit([.init(id: "limited", task: "Return provider error")])
        let rateLimit = await limited.collect(wait: true, timeout: 1)
        check(rateLimit.contains("429") && limited.state(of: "limited") == .failed, "provider rate limits are surfaced to the lead")
        let final = AgySession.snapshot()
        check(final.created == final.closed && final.active == 0, "all created model sessions are closed")
        print("PASS: \(checks) worker sessions, sources and tab lifecycle checks")
    }
}
