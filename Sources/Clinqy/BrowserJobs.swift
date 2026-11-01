import AppKit
import SwiftUI
import Combine

/// Independent browser agents share a transport, not a current page or a native input controller.
/// A parent can coordinate child jobs without occupying an execution slot while they run.
@MainActor
final class BrowserJobs: ObservableObject {
    static let shared = BrowserJobs()
    final class Job: ObservableObject, Identifiable {
        let id: UUID
        let request: String
        let test: Bool
        let model: String?
        let provider: Provider?
        let files: [URL]
        let browser: String?
        let parent: UUID?
        let receipt: String?
        let context: TaskExecutionContext
        let color: NSColor
        @Published var agent: Agent?
        @Published var status = "Queued"
        @Published var finished = false
        @Published var indicatorVisible = true
        @Published var ok = false
        @Published var answer = ""
        var children: [UUID] = []
        var observer: AnyCancellable?
        var detail: NSPanel?
        var buddy: Buddy?
        var waiters: [CheckedContinuation<Void, Never>] = []
        var started = false
        init(id: UUID, request: String, test: Bool, model: String?, provider: Provider?, files: [URL], browser: String?, parent: UUID?, receipt: String?, color: NSColor) {
            self.id = id; self.request = request; self.test = test; self.model = model; self.provider = provider
            self.files = files; self.browser = browser; self.parent = parent; self.receipt = receipt; self.color = color
            context = TaskExecutionContext(id: id)
        }
        var coordinating: Bool { !children.isEmpty }
    }
    @Published private(set) var jobs: [Job] = []
    @Published var limit: Int = min(16, max(1, Int(Config.value("MAX_BACKGROUND_TASKS") ?? "") ?? (UserDefaults.standard.object(forKey: "backgroundTaskLimit") as? Int ?? 3))) {
        didSet { TaskStore.shared.backgroundLimit = limit; UserDefaults.standard.set(limit, forKey: "backgroundTaskLimit"); drain() }
    }
    private var panel: NSPanel?
    private func color(at index: Int) -> NSColor {
        NSColor(calibratedHue: (0.5 + CGFloat(index) * 0.61803398875).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.95, alpha: 1)
    }
    var running: [Job] { jobs.filter { $0.started && !$0.finished && !$0.coordinating } }
    var indicators: [Job] { jobs.filter(\.indicatorVisible) }

    @discardableResult
    func submit(_ request: String, test: Bool = false, model: String? = nil, provider: Provider? = nil, files: [URL] = [],
                taskID: UUID? = nil, browser: String? = nil, parent: UUID? = nil, receipt: String? = nil, reviewed: Bool = false) -> UUID? {
        pruneCompleted()
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, jobs.filter({ !$0.finished }).count < 64 else { return nil }
        let id: UUID
        if let taskID { id = taskID }
        else if test { id = UUID() }
        else if let saved = TaskStore.shared.enqueue(request, files: files, source: .mac, background: true) { id = saved }
        else { return nil }
        if jobs.contains(where: { $0.id == id }) { return id }
        let job = Job(id: id, request: request, test: test, model: model, provider: provider, files: files,
                      browser: BrowserTaskRouting.browser(in: request) ?? browser, parent: parent, receipt: receipt,
                      color: color(at: jobs.count))
        if reviewed, let item = TaskStore.shared.record(id), item.requiresReview {
            guard TaskStore.shared.start(id, explicitlyReviewed: true) else { return nil }
        }
        jobs.append(job)
        TaskStore.shared.backgroundLimit = limit
        showDock()
        drain()
        return id
    }

    private func drain() {
        for job in jobs where !job.started && !job.finished {
            guard running.count < limit else { break }
            if !job.test, TaskStore.shared.record(job.id)?.state != .running,
               !TaskStore.shared.start(job.id) {
                if let record = TaskStore.shared.record(job.id), record.state.terminal {
                    complete(job, answer: record.stage, ok: false)
                    if record.source == .telegram { Telegram.shared.failedToStart(taskID: job.id, reason: record.stage) }
                }
                continue
            }
            job.started = true
            start(job)
        }
        showDock()
    }

    private func start(_ job: Job) {
        let buddy = Buddy()
        buddy.suppressed = true
        buddy.tint = job.color
        buddy.parkingSlot = jobs.filter { !$0.finished }.firstIndex(where: { $0.id == job.id }) ?? 0
        let worker = Agent(buddy: buddy, context: job.context)
        worker.isolatedBrowserJob = true
        worker.selectedFiles = job.files
        if TaskStore.shared.record(job.id)?.source == .telegram { Telegram.shared.attach(worker, taskID: job.id) }
        job.buddy = buddy; job.agent = worker; job.status = "Starting"
        job.observer = worker.$phase.combineLatest(worker.$narration).sink { [weak self, weak job] phase, narration in
            guard let self, let job, !job.finished else { return }
            job.status = phase == .waiting ? "Needs your answer" : job.coordinating ? "Waiting for parallel tasks" : narration.isEmpty ? "Working" : String(narration.prefix(100))
            self.objectWillChange.send()
        }
        worker.onQuestion = { [weak self, weak job] in
            guard let self, let job else { return }
            job.status = "Needs your answer — click to respond"
            self.objectWillChange.send()
        }
        worker.onResult = { [weak self, weak worker] in
            self?.objectWillChange.send()
            if let worker, let result = worker.result { Telegram.shared.present(result, from: worker) }
        }
        worker.onFinish = { [weak self, weak job] answer, ok in
            guard let self, let job else { return }
            self.complete(job, answer: answer, ok: ok)
        }
        if job.parent == nil, BrowserTaskRouting.requestsParallel(job.request) {
            worker.parallelBrowserTasks = { [weak self, weak job] requests in
                guard let self, let job else { return (false, "Task stopped") }
                return await self.parallel(job, requests: requests)
            }
        }
        TaskExecution.$current.withValue(job.context) {
            Background.chooseBrowser(job.browser)
            BrowserBridge.shared.allowsExistingTabDiscovery = BrowserTaskRouting.requestsExistingTabs(job.request)
            worker.submit(job.request, test: job.test, model: job.model, provider: job.provider, background: true, taskID: job.test ? nil : job.id)
        }
        if !worker.isRunning {
            let reason = worker.answer.isEmpty ? "Couldn't start this task" : worker.answer
            complete(job, answer: reason, ok: false)
            if TaskStore.shared.record(job.id)?.source == .telegram { Telegram.shared.failedToStart(taskID: job.id, reason: reason) }
        }
    }

    private func parallel(_ parent: Job, requests: [String]) async -> (ok: Bool, summary: String) {
        guard parent.children.isEmpty, !parent.finished, jobs.filter({ !$0.finished }).count + requests.count <= 64 else { return (false, "This task already launched its parallel work; it was not repeated.") }
        // Reserve all children before draining; a synchronous start/failure cannot finish an incomplete group.
        var childIDs: [UUID] = []
        for request in requests {
            let owner = TaskStore.shared.record(parent.id)
            let id = parent.test ? UUID() : TaskStore.shared.enqueue(request, source: owner?.source ?? .mac, background: true, conversationID: owner?.conversationID, parentID: parent.id)
            guard let id else { continue }
            let child = Job(id: id, request: request, test: parent.test, model: parent.model, provider: parent.provider, files: parent.files,
                            browser: BrowserTaskRouting.browser(in: request) ?? parent.browser, parent: parent.id, receipt: nil,
                            color: color(at: jobs.count))
            jobs.append(child); childIDs.append(id)
            Telegram.shared.registerBrowserTask(id)
        }
        guard childIDs.count == requests.count else {
            for id in childIDs { cancel(id) }
            return (false, "Couldn't save every child task. No additional work was launched.")
        }
        parent.children = childIDs; parent.status = "Coordinating \(childIDs.count) browser tasks"
        if !parent.test { TaskStore.shared.coordinate(parent.id) }
        drain()
        await withTaskCancellationHandler {
            if !childIDs.allSatisfy({ id in jobs.first(where: { $0.id == id })?.finished == true }) {
                await withCheckedContinuation { parent.waiters.append($0) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(parent.id) }
        }
        let children = childIDs.compactMap { id in jobs.first { $0.id == id } }
        parent.agent?.deliveredImageOutputs = children.reduce(0) { $0 + ($1.agent?.deliveredImageOutputs ?? 0) }
        let text = children.enumerated().map { "Task \($0.offset + 1) — \($0.element.ok ? "Done" : "Needs checking"): \($0.element.answer)" }.joined(separator: "\n\n")
        return (children.count == requests.count && children.allSatisfy(\.ok), text)
    }

    private func complete(_ job: Job, answer: String, ok: Bool) {
        guard !job.finished else { return }
        job.finished = true; job.ok = ok; job.answer = answer; job.status = ok ? "Done — click to check" : "Stopped — click for details"
        if let receipt = job.receipt { RunReceipt.write(id: receipt, ok: ok, answer: answer, steps: job.agent?.steps.map(\.text) ?? []) }
        if let parentID = job.parent, let parent = jobs.first(where: { $0.id == parentID }),
           parent.children.allSatisfy({ id in jobs.first(where: { $0.id == id })?.finished == true }) {
            let waiters = parent.waiters; parent.waiters = []; waiters.forEach { $0.resume() }
        }
        objectWillChange.send()
        Task { @MainActor [weak self, weak job] in
            try? await Task.sleep(for: .seconds(8))
            if let job { self?.dismiss(job.id, closeDetails: false) }
        }
        // Agent.finish persists the terminal checkpoint after invoking onFinish. Defer queue
        // admission until that write completes, otherwise a full queue can remain stranded.
        Task { @MainActor [weak self] in await Task.yield(); self?.drain() }
    }

    func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), !job.finished else { return }
        for child in job.children { cancel(child) }
        if let agent = job.agent, agent.isRunning { agent.cancel() }
        else { if !job.test { TaskStore.shared.cancelQueued(id) }; complete(job, answer: "Stopped", ok: false) }
    }
    func cancelReceipt(_ receipt: String) -> Bool {
        guard let job = jobs.first(where: { $0.receipt == receipt && !$0.finished }) else { return false }
        cancel(job.id); return true
    }
    func answer(_ id: UUID, text: String?) { jobs.first { $0.id == id }?.agent?.answer(text) }
    func shutdown() { for job in jobs where !job.finished { cancel(job.id) }; jobs.forEach { $0.buddy?.dismiss() } }
    func reveal(_ job: Job) {
        guard let tab = job.agent?.browserTab else { return }
        TaskExecution.$current.withValue(job.context) {
            Task { await BrowserBridge.shared.revealTaskTab(tab) }
        }
    }
    func dismiss(_ id: UUID, closeDetails: Bool = true) {
        guard let job = jobs.first(where: { $0.id == id }), job.finished else { return }
        if closeDetails { job.detail?.close() }
        job.indicatorVisible = false; job.buddy?.dismiss()
        pruneCompleted(); objectWillChange.send(); showDock()
    }
    private func pruneCompleted() {
        // Keep hidden child results until their parent has collected them, and preserve open result windows.
        var expired: Set<UUID> = []
        for root in jobs where root.parent == nil && root.finished && !root.indicatorVisible {
            let family = jobs.filter { $0.id == root.id || $0.parent == root.id }
            if family.allSatisfy({ $0.finished && !$0.indicatorVisible && $0.detail?.isVisible != true }) {
                family.forEach { $0.detail = nil; expired.insert($0.id) }
            }
        }
        jobs.removeAll { expired.contains($0.id) }
    }
    func details(_ job: Job) {
        if job.detail == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 490, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Clinqy — " + String(job.request.prefix(65)); window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BrowserJobDetails(job: job, pool: self)); window.center(); job.detail = window
        }
        job.detail?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showDock() {
        guard !indicators.isEmpty else { panel?.orderOut(nil); return }
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .statusBar; window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]; window.hidesOnDeactivate = false
            window.contentView = BrowserDockHost(rootView: BrowserJobDock(pool: self)); panel = window
        }
        let width = CGFloat(min(8, indicators.count) * 36 + 8)
        let height = CGFloat(((indicators.count + 7) / 8) * 36 + 8)
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel?.setFrame(NSRect(x: visible.maxX - width - 12, y: visible.maxY - height - 8, width: width, height: height), display: true)
        panel?.orderFrontRegardless()
    }
}

private final class BrowserDockHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct BrowserJobDock: View {
    @ObservedObject var pool: BrowserJobs
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: max(1, min(8, pool.indicators.count))), alignment: .trailing, spacing: 4) {
            ForEach(pool.indicators) { job in BrowserJobCursor(job: job, pool: pool) }
        }.padding(4)
    }
}
private struct BrowserJobCursor: View {
    @ObservedObject var job: BrowserJobs.Job
    let pool: BrowserJobs
    @State private var showing = false
    @State private var leaving: Task<Void, Never>?
    private func hover(_ inside: Bool) {
        leaving?.cancel()
        if inside { showing = true }
        else { leaving = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { showing = false }
        } }
    }
    var body: some View {
        Button { showing = false; pool.details(job) } label: {
            Image(systemName: job.finished ? "cursorarrow" : "cursorarrow.rays")
                .font(.system(size: 23)).foregroundStyle(Color(nsColor: job.color))
                .symbolEffect(.pulse, options: .repeating, isActive: job.started && !job.finished && job.agent?.question == nil)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .overlay(alignment: .bottomTrailing) {
                    if job.finished || job.agent?.question != nil {
                        Image(systemName: job.finished ? (job.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill") : "questionmark.circle.fill")
                            .font(.system(size: 10)).foregroundStyle(job.finished && job.ok ? .green : .orange)
                    }
                }.frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Browser task: " + job.status).onHover(perform: hover)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(job.status).font(.headline)
                    Text(job.request).font(.system(size: 12)).lineLimit(8)
                    HStack {
                        Button("Details") { showing = false; pool.details(job) }
                        Spacer()
                        Button(job.finished ? "Dismiss" : "Stop task") {
                            showing = false
                            if job.finished { pool.dismiss(job.id) } else { pool.cancel(job.id) }
                        }
                    }
                    Divider()
                    Stepper("\(pool.limit) tasks at once", value: Binding(get: { pool.limit }, set: { pool.limit = $0 }), in: 1...16)
                        .font(.system(size: 11))
                }.padding(14).frame(width: 270).onHover(perform: hover)
            }.onDisappear { leaving?.cancel() }
    }
}
private struct BrowserJobDetails: View {
    @ObservedObject var job: BrowserJobs.Job
    let pool: BrowserJobs
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            Text(job.request).font(.headline).textSelection(.enabled)
            if let agent = job.agent { BrowserJobAgentDetails(agent: agent) }
            if job.finished { Text(job.answer).textSelection(.enabled) }
            HStack { Button("Show task tab") { pool.reveal(job) }
                if !job.finished { Button("Stop this task") { pool.cancel(job.id) } }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading) }
    }
}
private struct BrowserJobAgentDetails: View {
    @ObservedObject var agent: Agent
    @State private var reply = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result = agent.result {
                Text(result.title).font(.subheadline.bold()); if let text = result.text { Text(text) }
                ForEach(Array(result.items.enumerated()), id: \.offset) { _, item in Text(item.title + ": " + (item.subtitle ?? "")) }
            }
            if let question = agent.question {
                Text(question.text).textSelection(.enabled)
                ForEach(question.options, id: \.self) { option in Button(option) { agent.answer(option); reply = "" } }
                if question.sensitive { SecureField("Your answer", text: $reply) } else { TextField("Your answer", text: $reply) }
                Button("Answer") { agent.answer(reply); reply = "" }.disabled(reply.isEmpty)
            } else { Text(agent.narration).foregroundStyle(.secondary) }
        }
    }
}
