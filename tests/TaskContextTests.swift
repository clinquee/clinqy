import Foundation

enum Secrets { static func mask(_ text: String) -> String { text } }
@MainActor final class Probe { var marker = "" }

@main struct TaskContextTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        let contexts = (0..<3).map { _ in TaskExecutionContext() }
        let outputs = await withTaskGroup(of: String.self) { group in
            for (index, context) in contexts.enumerated() {
                group.addTask { @MainActor in
                    await TaskExecution.$current.withValue(context) {
                        let probe = context.service(Probe.self, make: Probe.init)
                        probe.marker = "worker-\(index)"
                        try? await Task.sleep(for: .milliseconds(30))
                        let nested = Task { @MainActor in TaskExecution.current?.service(Probe.self, make: Probe.init).marker ?? "lost" }
                        return await nested.value
                    }
                }
            }
            var result: [String] = []
            for await value in group { result.append(value) }
            return result.sorted()
        }
        check(outputs == ["worker-0", "worker-1", "worker-2"], "three suspended jobs retain their own observations and nested task identity")
        check(TaskExecution.current == nil, "background contexts never leak onto the foreground controller")
        check(CursorVisibility.suppressPrimary(browserCursor: true, backgroundIndicators: 0, foregroundRunning: true), "page cursor replaces native companion during browser actions")
        check(CursorVisibility.suppressPrimary(browserCursor: false, backgroundIndicators: 3, foregroundRunning: false), "corner cursors replace idle companion during background jobs")
        check(!CursorVisibility.suppressPrimary(browserCursor: false, backgroundIndicators: 3, foregroundRunning: true), "independent native task keeps its own companion")
        check(CursorVisibility.suppressPrimary(browserCursor: true, backgroundIndicators: 3, foregroundRunning: true), "browser cursor ownership stays exclusive alongside background indicators")
        check(CursorVisibility.suppressPrimary(browserCursor: true, backgroundIndicators: 0, foregroundRunning: false), "companion stays hidden until page overlay cleanup completes")
        check(!CursorVisibility.suppressPrimary(browserCursor: false, backgroundIndicators: 0, foregroundRunning: false), "ordinary companion returns after browser feedback is cleared")
        check(CursorVisibility.suppressPrimary(browserCursor: false, backgroundIndicators: 0, foregroundRunning: true, inputPanelVisible: true), "new-task composer owns input without a duplicate desktop companion")
        check(contexts[0].service(Probe.self, make: Probe.init) !== contexts[1].service(Probe.self, make: Probe.init), "services are distinct instances")
        let stopped = Task { await TaskExecution.$current.withValue(contexts[0]) { try? await Task.sleep(for: .seconds(10)) } }
        stopped.cancel(); await stopped.value
        check(contexts[1].service(Probe.self, make: Probe.init).marker == "worker-1", "canceling one job doesn't reset another")
        check(BrowserTaskRouting.isBrowserTask("On Chrome open 3 tabs and work simultaneously"), "Chrome tasks default to browser workers")
        check(BrowserTaskRouting.requestsParallel("Open three tabs"), "explicit tab fanout detected")
        check(BrowserTaskRouting.requestsExistingTabs("Read the three already open Chrome tabs"), "already-open tab request enables discovery")
        check(BrowserTaskRouting.requestsExistingTabs("The assignment tabs are open already"), "trailing existing-tab wording enables discovery")
        check(BrowserTaskRouting.requestsExistingTabs("Do these tabs in parallel"), "referenced current tabs enable discovery")
        check(!BrowserTaskRouting.requestsExistingTabs("Open three new tabs about Pokemon"), "new-tab task does not discover personal tabs")
        check(!BrowserTaskRouting.requestsParallel("Open a tab and then log in"), "dependent single workflow is not split")
        check(BrowserTaskRouting.browser(in: "On Chrome open YouTube") == "Google Chrome", "explicit browser overrides default")
        check(!BrowserTaskRouting.isBrowserTask("Open TextEdit and write a note"), "native task retains the main controller")
        check(!BrowserTaskRouting.isBrowserTask("Open WhatsApp and write a message"), "WhatsApp app uses the independent desktop slot")
        check(BrowserTaskRouting.isBrowserTask("Write a message in WhatsApp Web"), "explicit WhatsApp Web uses the browser pool")
        check(BrowserTaskRouting.isBrowserTask("Do this in Arc"), "explicit browser choice starts a browser job")
        check(TaskCapacity.canStart(background: false, foregroundRunning: false, backgroundRunning: 3, limit: 3), "native task can start alongside browser workers")
        check(!TaskCapacity.canStart(background: true, foregroundRunning: false, backgroundRunning: 3, limit: 3), "excess browser jobs queue")
        check(TaskCapacity.canStart(background: true, foregroundRunning: true, backgroundRunning: 2, limit: 3), "new browser task can start during native work")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TaskStore(file: folder.appendingPathComponent("tasks.json"))
        store.backgroundLimit = 3
        let ids = (0..<4).map { store.enqueue("Browser \($0)", source: .mac, background: true)! }
        for id in ids.prefix(3) { check(store.start(id), "three durable jobs can run together") }
        check(!store.start(ids[3]), "fourth durable browser job waits")
        let native = store.enqueue("Native", source: .mac, background: false)!
        check(store.start(native), "foreground starts while three background records are running")
        let another = store.enqueue("Other native", source: .mac, background: false)!
        check(!store.start(another), "two native controllers cannot fight for input")
        store.coordinate(ids[0])
        check(store.start(ids[3]), "coordinator waiting for children frees its browser slot")
        check(store.record(ids[0])?.coordinating == true, "parent coordination state is durable")
        check(store.activeBackground.count == 3 && store.activeForeground?.id == native, "separate foreground and background ownership")
        print("PASS \(checks) parallel task ownership, capacity, routing and cancellation checks")
    }
}
