import AppKit
import CryptoKit
import AVFoundation
import Carbon
import Combine
import Speech
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var backgroundMenuItem: NSMenuItem?
    private var onboarding: OnboardingWindow?
    private var buddy: Buddy!
    private var agent: Agent!
    private var voice: Voice!
    private var cursorStateObservers = Set<AnyCancellable>()
    private struct RequestTarget {
        var app: NSRunningApplication?
        var files: [URL] = []
        var selection: String?
        var provider: Provider? = nil
    }
    private var newRequestTarget = RequestTarget()
    private var queuedNativeTargets: [UUID: RequestTarget] = [:]
    private var panel: CommandPanel!
    private var island: IslandPanel!
    private var resultPanel: ResultPanel!
    private var hotKey: HotKey?
    private var talkHotKey: PushToTalkHotKey?
    /// fn+⌃: plain dictation. Hold and speak (or tap to start, tap to stop); the words are typed where the cursor is.
    private var dictateHotKey: HotKey?
    private var dictating = false
    private var dictateStarted: Date?
    private var openMenuItem: NSMenuItem?
    private var talkMenuItem: NSMenuItem?
    private var pressedAt: Date?
    private var holdTimer: Timer?
    private var holdToTalk = false
    private let overlay = AnnotationOverlay()
    /// The current request was spoken (so a follow-up can be spoken too).
    private var voiceRun = false
    /// The mic is open for a follow-up after a finished task ("now email that to Rahul").
    private var followUpOpen = false

    func applicationWillTerminate(_ notification: Notification) {
        defer { TaskPowerAssertions.shared.shutdown() }
        // Nothing of Clinqy's hidden screen may land on the user's when it goes with the app.
        BrowserJobs.shared.shutdown()
        ChromeWorker.shared.shutdown()
        AgentScreen.quit()
        Persist.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if OnboardingWindow.isDone { showDashboard() } else { showOnboarding() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buddy = Buddy()
        agent = Agent(buddy: buddy)
        agent.enqueueNewRequest = { [weak self] text, provider in self?.enqueueNewRequest(text, provider: provider) ?? false }
        agent.dispatchBrowserTask = { [weak self] request, test, model, provider, taskID in
            guard let self else { return false }
            // Telegram dispatches its own requests to the pool and binds questions to their originating task.
            if let taskID, TaskStore.shared.record(taskID)?.source == .telegram { return false }
            let receipt = self.agent.runReceiptID
            let id = BrowserJobs.shared.submit(request, test: test, model: model, provider: provider, files: self.agent.selectedFiles,
                taskID: taskID, browser: BrowserTaskRouting.browser(in: request) ?? self.agent.targetApp.flatMap { Launcher.isBrowser($0) ? $0.cleanName : nil }, receipt: receipt)
            self.agent.runReceiptID = nil
            if id == nil {
                let message = "Couldn't queue this browser task. Check Tasks & Recovery or wait for a free queue slot."
                if let receipt { RunReceipt.write(id: receipt, ok: false, answer: message, steps: []) }
                self.buddy.bubble(message, for: 5)
            }
            return true // A failed background dispatch never falls through to native foreground input.
        }
        voice = Voice()
        Publishers.MergeMany([
            BrowserJobs.shared.objectWillChange.eraseToAnyPublisher(),
            BrowserBridge.shared.$pageCursorVisible.map { _ in () }.eraseToAnyPublisher(),
            agent.$inputPanelVisible.map { _ in () }.eraseToAnyPublisher(),
            agent.$phase.map { _ in () }.eraseToAnyPublisher()
        ]).receive(on: DispatchQueue.main).sink { [weak self] in self?.updateCursorVisibility() }.store(in: &cursorStateObservers)
        panel = CommandPanel(agent: agent, voice: voice, onMic: { [weak self] in self?.toggleMic() },
                             onWatch: { [weak self] in self?.startWatching() },
                             onCircle: { [weak self] in self?.startCircling() })
        island = IslandPanel(agent: agent, voice: voice)
        resultPanel = ResultPanel(agent: agent)
        agent.onResult = { [weak self] in
            guard let self, let result = self.agent.result else { return }
            Telegram.shared.present(result, from: self.agent)
            if !self.agent.runBackground { self.resultPanel.show() }
        }
        // Review before submit: the form's answers come up in the bar; it goes away once the user decides.
        UI.agent = agent
        UI.present = { [weak self] in self?.panel.showCentered(); self?.island.show() }
        UI.dismiss = { [weak self] in self?.panel.orderOut(nil) }
        // A plain kill (an update, a rebuild, logging out) quits like ⌘Q, so the hidden screen is emptied first.
        signal(SIGTERM, SIG_IGN)
        terminateSignal.setEventHandler { NSApp.terminate(nil) }
        terminateSignal.resume()
        // A background run's notifications: answered there, or tapped to come here.
        Notifier.start()
        Telegram.shared.agent = agent
        Telegram.shared.submitBrowserTask = { request, files, id in
            BrowserJobs.shared.submit(request, files: files, taskID: id,
                browser: BrowserTaskRouting.browser(in: request) ?? BrowserJobs.shared.running.compactMap(\.browser).first) != nil
        }
        Telegram.shared.cancelBrowserTask = { BrowserJobs.shared.cancel($0) }
        Telegram.shared.start()
        // Switching to an app whose windows are on the hidden screen gets the user a window they can see.
        Background.onBusyApp = { [weak self] text in self?.buddy.bubble(text, for: 4) }
        Background.watchSwitches()
        AgentScreenView.shared.agent = agent
        Notifier.onAnswer = { [weak self] text in self?.agent.answer(text) }
        // "Done": show the window it worked in. "Needs you": the bar, to answer.
        Notifier.onOpen = { [weak self] question in
            guard let self else { return }
            if question || self.agent.question != nil { self.panel.showCentered(); self.island.show() }
            else { AgentScreenView.shared.show() }
        }
        enableOpenAtLogin()
        _ = Self.cliToken   // written now, so the clinqy command can read it before its first link
        linkCommand()
        installEditMenu()
        dismissOnOutsideClick()
        Brain.prewarm()
        // Vectors for memory and saved runs, in the background, so no request waits on embedding them: from the
        // retrieval model when it's downloaded (fetched once, in the background, the first time), else the system's.
        let texts = Memory.facts + ReplayCache.shared.all.map(\.request)
        if TextEncoder.downloaded {
            Embedder.shared.activate(warming: texts)
        } else {
            Embedder.shared.warm(texts)
            Task.detached(priority: .utility) {
                if await TextEncoder.fetch() { Embedder.shared.activate(warming: texts) }
            }
        }
        SpeechModel.shared.prepare()
        BrowserBridge.shared.start()
        Updater.shared.onChange = { [weak self] in
            guard let item = self?.updateMenuItem else { return }
            item.title = Updater.shared.available.map { "Update to Clinqy \($0.version)…" } ?? "Check for Updates…"
        }
        Updater.shared.start()
        // First launch of a downloaded copy: walk through setup. A Mac that already has settings skips it.
        if !OnboardingWindow.isDone {
            if FileManager.default.fileExists(atPath: Config.fileURL.path) {
                UserDefaults.standard.set(true, forKey: OnboardingWindow.doneKey)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showOnboarding() }
            }
        }
        Clipboard.start()
        startScheduler()

        TaskStore.shared.onReady = { [weak self] id in
            guard let self, let item = TaskStore.shared.record(id) else { return }
            if item.background, item.source != .telegram {
                _ = BrowserJobs.shared.submit(item.request, files: item.files.map { URL(fileURLWithPath: $0) }, taskID: id, reviewed: true)
                return
            }
            guard !self.agent.isRunning else { return }
            if item.source == .telegram { Telegram.shared.startQueued(id, reviewed: true) }
            else if self.isScheduledTask(item) { self.startScheduledTask(id, reviewed: true) }
            else if TaskStore.shared.start(id, explicitlyReviewed: true) {
                self.agent.selectedFiles = item.files.map { URL(fileURLWithPath: $0) }
                self.agent.submit(item.request, background: item.background, taskID: id)
            }
        }
        agent.onStart = { [weak self] in
            guard let self else { return }
            self.setStatusIcon(running: true, background: self.agent.runBackground)
            StepUndo.shared.clear()
            // Keystrokes must reach the target app, and clicks must not land on our windows.
            self.panel.orderOut(nil)
            self.island.show()
        }
        agent.onFinish = { [weak self] answer, ok in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in self?.startNextNativeRequest() }
            UI.cancelReview()
            self.setStatusIcon(running: false)
            self.island.show(for: 4.5)
            // Stopped by the user: bring the bar back so they can say what to do differently ("no, the other one").
            if !ok, answer == "Stopped", !self.agent.isTest, !self.agent.runBackground, !self.voiceRun {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, !self.agent.isRunning, !self.panel.isVisible, !Recorder.shared.isRecording else { return }
                    self.panel.showCentered()
                }
            }
            let spoken = self.voiceRun
            self.voiceRun = false
            if spoken, ok, !self.agent.isTest { self.listenForFollowUp() }
        }
        // Paused for the user's input: bring the bar up with the question; hide it again once answered.
        agent.onQuestion = { [weak self] in
            guard let self else { return }
            // A background run asks through a notification instead: the bar would take the user's focus.
            if self.agent.runBackground { self.island.show(); return }
            if self.panel.isVisible && self.agent.newTaskMode { return }
            self.agent.newTaskMode = false
            self.panel.showCentered()
            self.island.show()
        }
        agent.onAnswered = { [weak self] in self?.panel.orderOut(nil) }
        voice.onLevel = { [weak self] level in self?.buddy.level = level }
        voice.onFinal = { [weak self] text in
            guard let self else { return }
            self.buddy.mood = .idle
            if self.dictating {
                self.dictating = false
                self.island.hide()
                self.typeDictation(text)
                return
            }
            let followUp = self.followUpOpen
            self.followUpOpen = false
            // A spoken reply to a question answers it; while working it steers; otherwise it's a new request.
            if self.agent.newTaskMode {
                if self.agent.submitNewRequest(text) { self.panel.orderOut(nil) }
            } else if self.agent.question != nil {
                self.agent.answer(text)
            } else if self.agent.isRunning {
                self.agent.addContext(text)
            } else if followUp, Router.isDismissal(text) {
                self.agent.continuation = nil
                self.island.hide()
            } else {
                self.voiceRun = true
                self.agent.submit(text)
            }
        }
        voice.onGaveUp = { [weak self] in
            guard let self else { return }
            self.followUpOpen = false
            self.dictating = false
            if !self.agent.isRunning { self.agent.continuation = nil }
            self.buddy.mood = .idle
            self.island.hide()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Clinqy")
        let menu = NSMenu()
        openMenuItem = menu.addItem(withTitle: "Open Clinqy", action: #selector(togglePanel), keyEquivalent: "")
        talkMenuItem = menu.addItem(withTitle: "Talk", action: #selector(toggleMic), keyEquivalent: "")
        menu.addItem(withTitle: "Dashboard…", action: #selector(showDashboard), keyEquivalent: "")
        menu.addItem(withTitle: "Circle Something…", action: #selector(startCircling), keyEquivalent: "")
        menu.addItem(withTitle: "Set Up Clinqy…", action: #selector(showOnboarding), keyEquivalent: "")
        menu.addItem(withTitle: "Check Permissions…", action: #selector(checkPermissions), keyEquivalent: "")
        menu.addItem(withTitle: "Edit Memory…", action: #selector(openMemory), keyEquivalent: "")
        menu.addItem(withTitle: "Applications…", action: #selector(showApplications), keyEquivalent: "")
        menu.addItem(withTitle: "Job Profile…", action: #selector(openProfile), keyEquivalent: "")
        menu.addItem(withTitle: "Tasks & Recovery…", action: #selector(showTasks), keyEquivalent: "")
        menu.addItem(withTitle: "Sign In to Worker Chrome…", action: #selector(workerLogin), keyEquivalent: "")
        menu.addItem(withTitle: "Finish Worker Chrome Sign-in", action: #selector(finishWorkerLogin), keyEquivalent: "")
        menu.addItem(withTitle: "Stats…", action: #selector(showStats), keyEquivalent: "")
        let schedules = NSMenuItem(title: "Schedules", action: nil, keyEquivalent: "")
        let schedulesMenu = NSMenu()
        schedulesMenu.delegate = self   // rebuilt each time it opens
        schedules.submenu = schedulesMenu
        menu.addItem(schedules)
        menu.addItem(withTitle: "Tidy Memory", action: #selector(tidyMemory), keyEquivalent: "")
        menu.addItem(.separator())
        let dry = menu.addItem(withTitle: "Dry Run (show, don't act)", action: #selector(toggleDryRun(_:)), keyEquivalent: "")
        dry.state = agent.dryRun ? .on : .off
        let background = menu.addItem(withTitle: "Work in the Background", action: #selector(toggleBackground(_:)), keyEquivalent: "")
        background.state = Background.always ? .on : .off
        backgroundMenuItem = background
        // The Dashboard has the same switch.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.backgroundMenuItem?.state = Background.always ? .on : .off }
        }
        background.toolTip = "Web tasks use Clinqy’s own signed-in browser tabs (or optional headless Chrome). File and supported service tasks run directly; native app tasks ask for foreground access."
        menu.addItem(withTitle: "Show Background Work", action: #selector(showBackgroundWork), keyEquivalent: "")
        menu.addItem(withTitle: "Telegram…", action: #selector(setUpTelegram), keyEquivalent: "")
        let follow = menu.addItem(withTitle: "Follow My Cursor", action: #selector(toggleFollowCursor(_:)), keyEquivalent: "")
        follow.state = buddy.followsMouse ? .on : .off
        let language = NSMenuItem(title: "Voice Language", action: nil, keyEquivalent: "")
        let languages = NSMenu()
        for (code, name) in SpeechModel.languages {
            let item = languages.addItem(withTitle: name, action: #selector(setVoiceLanguage(_:)), keyEquivalent: "")
            item.representedObject = code
            item.target = self
            item.state = SpeechModel.language == code ? .on : .off
        }
        language.submenu = languages
        menu.addItem(language)
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateMenuItem = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
        self.menu = menu

        configureHotKeys()

        if !CommandLine.arguments.contains("--background-launch"), !Permissions.allGranted {
            Permissions.requestMissing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.checkPermissions() }
        }

        if OnboardingWindow.isDone, !CommandLine.arguments.contains("--background-launch") {
            DispatchQueue.main.async { [weak self] in self?.showDashboard() }
        }
    }

    /// A secret only local programs can read (~/.config/clinqy/cli-token, owner-only). Every clinqy:// link must
    /// carry it: any web page can open a clinqy:// link, and must never be able to start tasks, answer questions
    /// ("Yes, send it") or write files.
    static let cliToken: String = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/clinqy/cli-token")
        if let saved = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), saved.count >= 32 {
            return saved
        }
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }()

    /// `clinqy://run?task=…&token=…` runs a task in whatever app is in front (used for scripting and tests).
    func application(_ application: NSApplication, open urls: [URL]) {
        let urls = urls.filter { url in
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value
            guard url.scheme == "clinqy", token == Self.cliToken else {
                Agent.writeLog("ignored a clinqy:// link without the right token (host: \(url.host ?? "?"))")
                return false
            }
            return true
        }
        for url in urls where url.host == "browser" { Task { await answerBrowserQuery(url) } }
        for url in urls where url.host == "control-cancel" {
            if let session = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "session" })?.value {
                agent.cancelControl(session: session)
            }
        }
        for url in urls where url.host == "control" { Task { await answerControlQuery(url) } }
        for url in urls where url.host == "task" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let raw = items.first(where: { $0.name == "id" })?.value, let id = UUID(uuidString: raw) else { continue }
            switch items.first(where: { $0.name == "op" })?.value {
            case "cancel": BrowserJobs.shared.cancel(id)
            case "dismiss": BrowserJobs.shared.dismiss(id)
            case "answer": BrowserJobs.shared.answer(id, text: items.first(where: { $0.name == "text" })?.value)
            default: break
            }
        }
        for url in urls where url.host == "status" { answerStatus(url) }
        for url in urls where url.host == "permissions" { askForPermissions() }
        for url in urls where url.host == "extension-install" {
            installExtension(browser: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "browser" }?.value)
        }
        for url in urls where url.scheme == "clinqy" && url.host == "reload-extension" {
            Task { Agent.writeLog("extension reloaded in \(await BrowserBridge.shared.reloadAll()) browser(s)") }
        }
        for url in urls where url.scheme == "clinqy" && url.host == "answer" {
            agent.answer(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value)
        }
        for url in urls where url.scheme == "clinqy" && url.host == "cancel" {
            if let receipt = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "receipt" })?.value {
                if !BrowserJobs.shared.cancelReceipt(receipt), agent.runReceiptID == receipt { agent.cancel() }
            } else { agent.cancel() }
        }
        // Same as the Undo button on the latest reversible step (voice, scripts, tests/run.sh).
        for url in urls where url.scheme == "clinqy" && url.host == "undo" { Task { await StepUndo.shared.undoLast(agent: agent) } }
        for url in urls where url.scheme == "clinqy" && url.host == "add" {
            agent.addContext(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value ?? "")
        }
        for url in urls where url.scheme == "clinqy" && url.host == "watch" { rememberTarget(); startWatching() }
        for url in urls where url.scheme == "clinqy" && url.host == "stop-watching" { stopWatching() }
        for url in urls where url.scheme == "clinqy" && url.host == "qa" { startQA(url) }
        for url in urls where url.scheme == "clinqy" && url.host == "workflow" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let name = items.first(where: { $0.name == "name" })?.value, let wf = Workflows.shared.named(name) else { continue }
            var params: [String: String] = [:]
            for item in items where item.name != "name" { params[item.name] = item.value ?? "" }
            rememberTarget()
            let receipt = items.first { $0.name == "id" }?.value
            if agent.isRunning {
                if let receipt { RunReceipt.write(id: receipt, ok: false, answer: "The foreground controller is busy", steps: []) }
                continue
            }
            agent.runReceiptID = receipt
            agent.runWorkflow(wf, params: params)
        }
        for url in urls where url.scheme == "clinqy" && url.host == "run" {
            guard let task = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "task" })?.value else { continue }
            rememberTarget()
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let test = items.first { $0.name == "test" }?.value == "1"
            let dry = items.first { $0.name == "dry" }?.value == "1"
            var runProvider: Provider? = nil
            if items.first(where: { $0.name == "agy" })?.value == "1" {
                runProvider = .agyCLI
            } else if items.first(where: { $0.name == "claude" })?.value == "1" {
                runProvider = .claudeCLI
            }
            let receipt = items.first { $0.name == "id" }?.value.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
            var modeProbe = task
            let explicitMode = Background.choice(&modeProbe)
            let canQueue = !dry && explicitMode != false && (explicitMode == true || Background.always || (!test && BrowserTaskRouting.isBrowserTask(task)))
            if agent.isRunning && !canQueue {
                if let receipt { RunReceipt.write(id: receipt, ok: false, answer: "The foreground controller is busy. Browser tasks can run independently; wait or stop the foreground task before another native task.", steps: []) }
                continue
            }
            agent.runReceiptID = receipt
            // Tests skip the review card unless they ask for it (tests/run.sh answers it through clinqy://answer).
            agent.reviewInTests = items.first { $0.name == "review" }?.value == "1"
            agent.saveInTests = items.first { $0.name == "save" }?.value == "1"
            agent.submit(dry ? "dry run: " + task : task, test: test, provider: runProvider)
        }
    }

    /// The authenticated URL names only an app-owned request file; callers cannot choose an output path.
    private func answerControlQuery(_ url: URL) async {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let id = items.first(where: { $0.name == "id" })?.value, UUID(uuidString: id) != nil else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clinqy/cli", isDirectory: true)
        let request = dir.appendingPathComponent(id + ".request.json")
        guard let values = try? request.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
              values.isSymbolicLink != true, (values.fileSize ?? 0) <= 200_000,
              let data = try? Data(contentsOf: request), let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Claim before the first await; duplicate URL delivery cannot execute a second request.
        try? FileManager.default.removeItem(at: request)
        guard let deadline = body["deadline"] as? Double, deadline >= Date().timeIntervalSince1970 else { return }
        let result = await agent.control(body)
        guard let response = try? JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes]) else { return }
        let file = dir.appendingPathComponent(id + ".response.json")
        do {
            try response.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { Agent.writeLog("couldn't deliver control response; inspect task state before retrying input") }
    }

    /// `clinqy://browser?cmd=page|read|url&id=…`: what's in the focused browser tab, for the `clinqy page` command
    /// (read-only). The answer goes to Application Support/Clinqy/cli/<id>.txt, which the command waits for.
    private func answerBrowserQuery(_ url: URL) async {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let id = items.first(where: { $0.name == "id" })?.value, id.range(of: #"^[A-Za-z0-9-]{1,40}$"#, options: .regularExpression) != nil
        else { return }
        let cmd = items.first { $0.name == "cmd" }?.value ?? "page"
        var out: String
        if !BrowserBridge.shared.isConnected {
            out = "ERROR: the Clinqy browser extension isn't connected (open the browser; load extension/ from the repo)"
        } else if let page = await BrowserBridge.shared.snapshot() {
            switch cmd {
            case "url": out = "\(page.title)\n\(page.url)"
            case "read":
                let r = try? await BrowserBridge.shared.perform("read", on: page, timeout: 8)
                out = "\(page.title)\n\(page.url)\n\n\((r?["text"] as? String) ?? page.text)"
            default:
                var lines = ["\(page.title)", page.url]
                if let problem = page.problem { lines.append("(can't read this page: \(problem))") }
                lines += page.elements.map { "w\($0.index) \($0.role): \($0.text)\($0.extra.isEmpty ? "" : " [\($0.extra)]")" }
                if !page.messages.isEmpty { lines.append("Messages: " + page.messages.joined(separator: " · ")) }
                if page.above + page.below > 0 { lines.append("Not shown: \(page.above) fields/buttons above, \(page.below) below") }
                if !page.text.isEmpty { lines.append("Text on screen: " + page.text) }
                out = lines.joined(separator: "\n")
            }
        } else {
            out = "ERROR: no focused browser tab (click into the browser window first)"
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clinqy/cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? out.write(to: dir.appendingPathComponent("\(id).txt"), atomically: true, encoding: .utf8)
    }

    private func updateCursorVisibility() {
        buddy.suppressed = CursorVisibility.suppressPrimary(browserCursor: BrowserBridge.shared.pageCursorVisible,
            backgroundIndicators: BrowserJobs.shared.indicators.count, foregroundRunning: agent.isRunning, inputPanelVisible: agent.inputPanelVisible)
    }

    private func beginNewRequest() {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            newRequestTarget = RequestTarget(app: front,
                files: front.bundleIdentifier == "com.apple.finder" ? AXEngine.copiedFiles(of: front) : [],
                selection: AXEngine.selectedText(of: front))
        }
        agent.newTaskMode = true
    }

    private func enqueueNewRequest(_ raw: String, provider: Provider) -> Bool {
        var request = raw
        let explicit = Background.choice(&request)
        let background = explicit != false && (explicit == true || BrowserTaskRouting.isBrowserTask(request))
        if background {
            return BrowserJobs.shared.submit(raw, provider: provider, files: newRequestTarget.files,
                browser: BrowserTaskRouting.browser(in: request) ?? newRequestTarget.app.flatMap { Launcher.isBrowser($0) ? $0.cleanName : nil }
                    ?? BrowserJobs.shared.running.compactMap(\.browser).first) != nil
        }
        if agent.isRunning {
            guard let id = TaskStore.shared.enqueue(request, files: newRequestTarget.files, source: .mac, background: false) else { return false }
            var target = newRequestTarget
            target.provider = provider
            queuedNativeTargets[id] = target
            return true
        }
        agent.targetApp = newRequestTarget.app
        agent.selectedFiles = newRequestTarget.files
        agent.selectedText = newRequestTarget.selection
        agent.continuation = nil
        agent.submit(raw, provider: provider, background: false)
        return true
    }

    private func startNextNativeRequest() {
        guard !agent.isRunning, !Recorder.shared.isRecording else { return }
        for item in TaskStore.shared.queued where !item.requiresReview && queuedNativeTargets[item.id] != nil {
            guard TaskStore.shared.start(item.id) else { continue }
            guard let target = queuedNativeTargets.removeValue(forKey: item.id) else { continue }
            agent.targetApp = target.app; agent.selectedFiles = target.files; agent.selectedText = target.selection
            agent.copied = nil; agent.annotation = nil; agent.continuation = nil
            agent.submit(item.request, provider: target.provider, background: false, taskID: item.id)
            return
        }
    }

    /// Puts the `clinqy` command on the PATH (~/.local/bin/clinqy → the copy inside the app) when it isn't there yet, so
    /// an app installed from the disk image works from terminals and coding agents too. A repo checkout's link is kept.
    private func linkCommand() {
        let fm = FileManager.default
        let link = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/clinqy")
        guard let script = Bundle.main.url(forResource: "clinqy", withExtension: nil),
              (try? fm.destinationOfSymbolicLink(atPath: link.path)).map({ fm.fileExists(atPath: $0) }) != true,
              !fm.fileExists(atPath: link.path) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil else { return }
        try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(at: link, withDestinationURL: script)
    }

    /// `clinqy://status?id=…`: this app's permissions and whether the browser extension is connected, for `Clinqy
    /// doctor` and the other setup commands (a terminal's own permissions say nothing about Clinqy's). Written to
    /// Application Support/Clinqy/cli/<id>.json.
    private func answerStatus(_ url: URL) {
        guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              id.range(of: #"^[A-Za-z0-9-]{1,40}$"#, options: .regularExpression) != nil else { return }
        var perms = Permissions.all.map { ["name": $0.name, "granted": $0.granted()] as [String: Any] }
        perms.append(["name": "Microphone", "granted": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized])
        perms.append(["name": "Speech Recognition", "granted": SFSpeechRecognizer.authorizationStatus() == .authorized])
        var status: [String: Any] = [
            "permissions": perms,
            "extension": BrowserBridge.shared.isConnected,
            "extensionFolder": extensionInstaller?.extensionFolder.path
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clinqy/extension").path,
            "provider": Provider.current.rawValue,
            "foregroundRunning": agent.isRunning,
            "backgroundLimit": BrowserJobs.shared.limit,
            "backgroundIndicators": BrowserJobs.shared.indicators.count,
            "primaryCursorSuppressed": buddy.suppressed,
            "browserCursorActive": BrowserBridge.shared.pageCursorVisible,
            "composingNewTask": agent.newTaskMode && panel.isVisible,
            "inputPanelVisible": agent.inputPanelVisible,
            "browserConnections": BrowserBridge.shared.connectedBrowserNames,
            "backgroundJobs": BrowserJobs.shared.jobs.filter { !$0.finished }.map { ["id": $0.id.uuidString, "started": $0.started, "coordinating": $0.coordinating, "phase": String(describing: $0.agent?.phase ?? .idle)] as [String: Any] },
        ]
        if extensionInstaller?.autoLoad == .gaveUp { status["extensionInstall"] = "the run ended before the extension connected" }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clinqy/cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: status) { try? data.write(to: dir.appendingPathComponent("\(id).json")) }
    }

    /// `clinqy://permissions`: macOS asks for each missing permission, and System Settings opens at the first one.
    private func askForPermissions() {
        Permissions.requestMissing()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in } }
        if let first = Permissions.all.first(where: { !$0.granted() }), let url = URL(string: first.settingsURL) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSWorkspace.shared.open(url) }
        }
    }

    /// `clinqy://extension-install?browser=…`: Clinqy loads its own extension, as "Let Clinqy do it" does in setup.
    private var extensionInstaller: OnboardingModel?

    private func installExtension(browser: String?) {
        let model = OnboardingModel()
        model.run = { [weak self] task in self?.agent.submit(task, test: true) }
        model.isRunning = { [weak self] in self?.agent.isRunning ?? false }
        if let b = browser?.lowercased(), let match = model.browsers.first(where: { $0.name.lowercased().contains(b) || $0.id.lowercased().contains(b) }) {
            model.browserID = match.id
        } else if let def = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
                  let id = Bundle(url: def)?.bundleIdentifier, model.browsers.contains(where: { $0.id == id }) {
            model.browserID = id   // the default browser, when it can load extensions
        }
        extensionInstaller = model
        model.letClinqyLoadExtension()
    }

    private let terminateSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    /// While a task runs the menu-bar icon becomes a stop button (one click stops everything).
    /// A background run gets a small menu instead (watch it or stop it): clicking the icon is how the user looks in on it.
    private var menu: NSMenu?
    private var runMenu: NSMenu?

    private func setStatusIcon(running: Bool, background: Bool = false) {
        guard let button = statusItem.button else { return }
        // A background run: blue, as the corner badge, and saying so (it's working out of sight).
        button.toolTip = running ? (background ? "Clinqy is working in the background" : "Click to stop Clinqy") : nil
        if running && background {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Clinqy (working in the background)")
            button.contentTintColor = .systemBlue
            button.action = nil
            if runMenu == nil {
                let m = NSMenu()
                m.delegate = self
                runMenu = m
            }
            statusItem.menu = runMenu
        } else if running {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Clinqy")
            button.contentTintColor = .systemRed
            statusItem.menu = nil
            button.target = self
            button.action = #selector(stopFromMenuBar)
        } else {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Clinqy")
            button.contentTintColor = nil
            button.action = nil
            statusItem.menu = menu
        }
    }

    @objc private func stopFromMenuBar() {
        if Recorder.shared.isRecording { stopWatching() } else { agent.cancel() }
    }

    // MARK: - Watch & learn

    private func startWatching() {
        panel.orderOut(nil)
        // Give the user their app back, then watch.
        if let target = agent.targetApp { target.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            Recorder.shared.start()
            self.setStatusIcon(running: true)
            self.island.show()
            self.buddy.bubble("watching…", for: 2)
        }
    }

    private func stopWatching() {
        let recording = Recorder.shared.stop()
        setStatusIcon(running: false)
        island.hide()
        panel.showCentered()
        Task { await Skills.shared.learn(from: recording) }
    }

    // MARK: - Circle to point

    /// Hides the bar, lets the user draw a loop around something, then brings the bar back with it attached.
    /// While a task runs, the circle goes in as added context instead.
    @objc func startCircling() {
        rememberTarget()
        panel.orderOut(nil)
        overlay.begin { [weak self] circled in
            guard let self else { return }
            self.agent.targetApp?.activate()
            guard let circled else { if !self.agent.isRunning { self.panel.showCentered() }; return }
            if self.agent.isRunning {
                let r = circled.rect
                self.agent.addContext("I circled this area of the screen: x \(Int(r.minX))–\(Int(r.maxX)), y \(Int(r.minY))–\(Int(r.maxY)) (screen points).")
            } else {
                self.agent.annotation = circled
                self.panel.showCentered()
            }
        }
    }

    // MARK: - QA and schedules

    /// clinqy://qa?path=<test file>|text=<inline test>&out=<report.json>[&relearn=1][&model=…][&name=…]
    private func startQA(_ url: URL) {
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                           uniquingKeysWith: { a, _ in a })
        var qaProvider: Provider? = nil
        if q["agy"] == "1" { qaProvider = .agyCLI }
        else if q["claude"] == "1" { qaProvider = .claudeCLI }
        let out = URL(fileURLWithPath: q["out"] ?? NSTemporaryDirectory() + "clinqy-qa.json")
        var name = q["name"] ?? "Inline test"
        var test = q["text"] ?? ""
        var compiled: URL
        if let path = q["path"], !path.isEmpty {
            let file = URL(fileURLWithPath: path)
            let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            // A "# Title" line names the test; everything else is the steps.
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let title = lines.first(where: { $0.hasPrefix("# ") }) { name = String(title.dropFirst(2)) }
            else { name = file.deletingPathExtension().lastPathComponent }
            test = lines.filter { !$0.hasPrefix("# ") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // Compiled scripts live next to the tests, in .clinqy/, so they can be committed with them.
            compiled = file.deletingLastPathComponent().appendingPathComponent(".clinqy")
                .appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".json")
        } else {
            let key = SHA256.hash(data: Data(test.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
            compiled = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Clinqy/qa/\(key).json")
        }
        guard !test.isEmpty else {
            Agent.writeReport(QAReport(name: name, passed: false, mode: "none", durationMs: 0, steps: [], checks: [],
                                       message: "empty test"), to: out)
            return
        }
        rememberTarget()
        agent.runQA(name: name, test: test, compiled: compiled, relearn: q["relearn"] == "1",
                    model: q["model"].flatMap { $0.isEmpty ? nil : $0 }, provider: qaProvider, report: out)
    }

    /// Durable dispatch happens before schedule acknowledgement. Every unattended run uses isolated
    /// background tools and starts without the foreground application's selection, clipboard or history.
    private var scheduler: Timer?
    private var lastScheduleIssue: String?

    private func startScheduler() {
        scheduler = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dispatchSchedules() }
        }
    }

    private func dispatchSchedules(now: Date = Date()) {
        guard !agent.isRunning, agent.question == nil, !Recorder.shared.isRecording, TaskStore.shared.active == nil else { return }
        let store = TaskStore.shared
        // A crash requires review, but a task queued by this process can still be started after a
        // previous handoff/acknowledgement failure. Never create a second occurrence to recover it.
        if let queued = store.queued.first(where: { self.isScheduledTask($0) && !$0.requiresReview }) {
            startScheduledTask(queued.id)
            return
        }
        if let dispatch = Scheduler.dispatchDue(now: now, enqueue: { item, key in
            store.enqueue(item.request, source: .mac, background: true, idempotencyKey: key)
        }) {
            Agent.writeLog("scheduled request queued: \(dispatch.item.request) (\(dispatch.item.rule.label))")
            startScheduledTask(dispatch.taskID)
            reportScheduleIssue()
            return
        }
        reportScheduleIssue()
        // Workflow occurrences use the same durable outbox/deduplication rule. Existing workflow schedules
        // retain minute-only eligibility; already queued task records survive acknowledgement failures.
        for var workflow in Workflows.shared.all {
            guard let time = workflow.schedule,
                  let occurrence = Scheduler.dailyOccurrence(time: time, now: now, lastRun: workflow.lastScheduledRun, catchUp: false) else { continue }
            let key = "workflow:" + workflow.id.uuidString.lowercased() + ":" + String(Int64(occurrence.timeIntervalSince1970))
            guard let id = store.enqueue("Workflow: " + workflow.name, source: .mac, background: true, idempotencyKey: key) else {
                reportScheduleIssue(store.storageError ?? "Scheduled workflow couldn't be saved; it remains due.")
                return
            }
            workflow.lastScheduledRun = now
            if !Workflows.shared.update(workflow) { reportScheduleIssue(Workflows.shared.storageError) }
            startScheduledTask(id)
            return
        }
    }

    private func isScheduledTask(_ item: TaskStore.Record) -> Bool {
        guard let key = item.dispatchKey else { return false }
        return key.hasPrefix("schedule:") || key.hasPrefix("schedule-now:") || key.hasPrefix("workflow:")
    }

    private func startScheduledTask(_ id: UUID, reviewed: Bool = false) {
        let store = TaskStore.shared
        guard let item = store.record(id), item.state == .queued, !item.requiresReview || reviewed else { return }
        var workflow: Workflow?
        if let key = item.dispatchKey, key.hasPrefix("workflow:") {
            let parts = key.split(separator: ":")
            workflow = parts.count > 1 ? Workflows.shared.all.first { $0.id.uuidString.lowercased() == parts[1] } : nil
            guard workflow != nil else {
                store.update(id, state: .failed, stage: "The scheduled workflow no longer exists. Create a new task.")
                return
            }
        }
        guard store.start(id, explicitlyReviewed: reviewed) else { return }
        agent.targetApp = nil
        agent.selectedText = nil
        agent.selectedFiles = []
        agent.copied = nil
        agent.annotation = nil
        agent.continuation = nil
        if let workflow { agent.runWorkflow(workflow, background: true, taskID: id) }
        else { agent.submit(item.request, background: true, taskID: id, unattended: true) }
    }

    private func reportScheduleIssue(_ issue: String? = nil) {
        let current = issue ?? Scheduler.storageError ?? Workflows.shared.storageError ?? Scheduler.lastNotice
        if let current, current != lastScheduleIssue { Agent.writeLog(current) }
        lastScheduleIssue = current
    }

    // MARK: - Hotkey

    private func hotKeyDown() {
        // While watching, ⌃⌥ stops the recording and learns from it.
        if Recorder.shared.isRecording { stopWatching(); return }
        // Summon always starts a separate request; existing work keeps its own controller and queue slot.
        guard pressedAt == nil else { return }   // key repeat
        pressedAt = Date()
        // A dedicated push-to-talk shortcut is configured: the summon chord is tap-only.
        if Config.value("TALK_HOTKEY") != nil { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pressedAt != nil else { return }
                self.holdToTalk = true
                self.beginNewRequest()
                self.rememberTarget()
                self.panel.orderOut(nil)
                self.startListening(autoStop: false)
                self.island.show()
            }
        }
    }

    /// ⌃⌥ turned out to be part of another shortcut (⌃⌥ + some key): undo anything it started.
    private func hotKeyAbandoned() {
        holdTimer?.invalidate()
        if holdToTalk {
            voice.cancel()
            island.hide()
            buddy.mood = agent.isRunning ? .acting : .idle
        }
        pressedAt = nil
        holdToTalk = false
    }

    private func hotKeyUp() {
        holdTimer?.invalidate()
        defer { pressedAt = nil; holdToTalk = false }
        guard pressedAt != nil else { return }
        if holdToTalk {
            voice.stop()
            if voice.transcript.isEmpty { island.hide(); buddy.mood = .idle }
        } else {
            togglePanel()
        }
    }

    private func configureHotKeys() {
        let summon = Config.value("HOTKEY") ?? "ctrl+alt"
        hotKey = HotKey(spec: summon, onPress: { [weak self] in self?.hotKeyDown() },
                        onRelease: { [weak self] in self?.hotKeyUp() },
                        onOtherKey: { [weak self] in self?.hotKeyAbandoned() })
        talkHotKey = Config.value("TALK_HOTKEY").flatMap { spec in
            PushToTalkHotKey(spec: spec, onPress: { [weak self] in self?.dedicatedTalkDown() },
                             onRelease: { [weak self] in self?.dedicatedTalkUp() })
        }
        let dictate = Config.value("DICTATE_HOTKEY") ?? "fn+ctrl"
        dictateHotKey = dictate.lowercased() == "off" ? nil
            : HotKey(spec: dictate, onPress: { [weak self] in self?.dictateDown() },
                     onRelease: { [weak self] in self?.dictateUp() },
                     onOtherKey: { [weak self] in self?.dictateAbandoned() })
        openMenuItem?.title = "Open Clinqy  (\(menuShortcutLabel(summon)))"
        let talkLabel = talkHotKey == nil ? menuShortcutLabel(summon) + " · hold" : menuShortcutLabel(Config.value("TALK_HOTKEY") ?? "")
        talkMenuItem?.title = "Talk  (hold \(talkLabel))"
    }

    private func menuShortcutLabel(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "control", with: "⌃")
            .replacingOccurrences(of: "ctrl", with: "⌃")
            .replacingOccurrences(of: "option", with: "⌥")
            .replacingOccurrences(of: "alt", with: "⌥")
            .replacingOccurrences(of: "shift", with: "⇧")
            .replacingOccurrences(of: "command", with: "⌘")
            .replacingOccurrences(of: "cmd", with: "⌘")
            .replacingOccurrences(of: "space", with: "Space")
            .replacingOccurrences(of: "+", with: "")
    }

    private func setHotKeysEnabled(_ enabled: Bool) {
        if !enabled {
            holdTimer?.invalidate()
            if holdToTalk {
                voice.cancel()
                island.hide()
                buddy.mood = agent.isRunning ? .acting : .idle
            }
            pressedAt = nil
            holdToTalk = false
        }
        hotKey?.enabled = enabled
        talkHotKey?.enabled = enabled
        dictateHotKey?.enabled = enabled
    }

    // MARK: - Dictation

    private func dictateDown() {
        if dictating {   // tapped on earlier: this press ends it
            dictateStarted = nil
            endDictation()
            return
        }
        guard !holdToTalk, !voice.isListening else { return }
        dictating = true
        dictateStarted = Date()
        island.show()
        startListening(autoStop: false)
    }

    /// Held: done speaking. A quick tap: keep listening hands-free until the next press.
    private func dictateUp() {
        guard dictating, let started = dictateStarted else { return }
        dictateStarted = nil
        if Date().timeIntervalSince(started) < 0.35 { return }
        endDictation()
    }

    /// Stops listening; nothing heard means nothing typed, so tidy up if no words arrive.
    private func endDictation() {
        voice.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.dictating, !self.voice.isListening else { return }
            self.dictating = false
            self.island.hide()
            self.buddy.mood = self.agent.isRunning ? .acting : .idle
        }
    }

    /// fn+⌃ was part of another shortcut (fn+⌃+arrow…): drop the dictation.
    private func dictateAbandoned() {
        guard dictating, dictateStarted != nil else { return }
        dictating = false
        dictateStarted = nil
        voice.cancel()
        island.hide()
        buddy.mood = agent.isRunning ? .acting : .idle
    }

    /// Types what was said into whatever has the keyboard focus, like the keyboard would.
    private func typeDictation(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        Agent.writeLog("dictation: typed \(words.count) characters")
        AXEngine.enter(words)
    }

    private func dedicatedTalkDown() {
        guard pressedAt == nil else { return }
        pressedAt = Date()
        beginNewRequest()
        holdToTalk = true
        rememberTarget()
        panel.orderOut(nil)
        startListening(autoStop: false)
        island.show()
    }

    private func dedicatedTalkUp() {
        guard holdToTalk else { return }
        voice.stop()
        if voice.transcript.isEmpty { island.hide(); buddy.mood = .idle }
        pressedAt = nil
        holdToTalk = false
    }

    private func startListening(autoStop: Bool) {
        buddy.mood = .listening
        voice.start(autoStop: autoStop)
    }

    /// After a spoken task, keep listening a few seconds for a follow-up that builds on it ("now email that to
    /// Rahul"), without pressing ⌃⌥ again. Silence closes the mic. FOLLOW_UP=off turns it off.
    private func listenForFollowUp() {
        guard !["off", "0", "no", "false"].contains((Config.value("FOLLOW_UP") ?? "on").lowercased()) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, !self.agent.isRunning, self.agent.question == nil, !self.voice.isListening,
                  !Recorder.shared.isRecording, !self.panel.isVisible else { return }
            self.agent.continuation = History.shared.entries.first
            self.followUpOpen = true
            self.island.show()
            self.buddy.mood = .listening
            self.voice.start(autoStop: true, giveUpAfter: 5)
        }
    }

    private func rememberTarget() {
        guard agent.question == nil, !agent.isRunning else { return }   // answering or steering, not starting anew
        let front = NSWorkspace.shared.frontmostApplication
        guard let front, front.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        agent.targetApp = front
        // Files selected in Finder ride along instead of text ("compress this", "merge these").
        agent.selectedFiles = front.bundleIdentifier == "com.apple.finder" ? AXEngine.copiedFiles(of: front) : []
        agent.copied = nil
        guard agent.selectedFiles.isEmpty else { agent.selectedText = nil; return }
        // Whatever the user had highlighted goes along with their request.
        agent.selectedText = AXEngine.selectedText(of: front)
        if agent.selectedText == nil, !Launcher.isBrowser(front) {
            agent.selectedText = AXEngine.copiedSelection(of: front)
        }
        // Nothing highlighted: something they copied a moment ago may be what "this" means.
        if agent.selectedText == nil, let c = Clipboard.recent() {
            agent.copied = .init(text: c.text, files: c.files, age: c.age)
        }
        if agent.selectedText == nil, Launcher.isBrowser(front), BrowserBridge.shared.isConnected {
            Task { [agent] in
                if let text = await BrowserBridge.shared.selection(in: front), agent?.isRunning == false { agent?.selectedText = text }
            }
        }
    }

    // MARK: - Menu actions

    /// Clicking anywhere outside the command bar puts it away, like Spotlight. Not while it's asking a question
    /// or listening (the answer is still needed). Clicks on Clinqy's own windows never reach a global monitor.
    private func dismissOnOutsideClick() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, self.agent.question == nil, ReviewCenter.shared.pending == nil,
                      !self.voice.isListening, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// A menu-bar app has no main menu, and without an Edit menu ⌘V/⌘C/⌘X/⌘A/⌘Z never reach text fields.
    /// This one is never shown; it only carries the shortcuts.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Clinqy", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Starts with the Mac by default (installed copy only), unless the user switched it off in the menu.
    private func enableOpenAtLogin() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: "openAtLoginOff"),
              SMAppService.mainApp.status != .enabled else { return }
        try? SMAppService.mainApp.register()
    }

    @objc func toggleOpenAtLogin(_ item: NSMenuItem) {
        let on = SMAppService.mainApp.status == .enabled
        do {
            if on { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            UserDefaults.standard.set(on, forKey: "openAtLoginOff")
        } catch {
            NSLog("Clinqy: open at login: \(error)")
        }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func togglePanel() {
        if panel.isVisible && agent.newTaskMode { panel.orderOut(nil); return }
        beginNewRequest()
        rememberTarget()
        island.hide()
        panel.showCentered()
    }

    @objc func toggleMic() {
        if voice.isListening { voice.stop(); return }
        rememberTarget()
        if !panel.isVisible { panel.showCentered() }
        startListening(autoStop: true)
    }

    @objc func showApplications() { agent.showApplications() }

    @objc func openProfile() { Profile.open() }

    @objc func showTasks() { TasksPanel.shared.show() }

    @objc func workerLogin() {
        guard !agent.isRunning else { buddy.bubble("Finish or stop the current task before signing in to Worker Chrome", for: 5); return }
        Task {
            do { try await ChromeWorker.shared.openLogin() }
            catch { buddy.bubble(error.localizedDescription, for: 8) }
        }
    }
    @objc func finishWorkerLogin() {
        guard !agent.isRunning else { return }
        Task { await ChromeWorker.shared.finishLogin() }
    }

    @objc func showStats() {
        agent.result = StatsCard.card
        agent.onResult()
    }

    // MARK: - Schedules menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === runMenu { return fillRunMenu(menu) }
        let items = Scheduler.all
        if let issue = Scheduler.storageError ?? Workflows.shared.storageError ?? Scheduler.lastNotice {
            let error = menu.addItem(withTitle: issue, action: nil, keyEquivalent: "")
            error.isEnabled = false
            menu.addItem(.separator())
        }
        let behavior = menu.addItem(withTitle: "Runs locally while Clinqy is open; missed runs follow each schedule's policy.", action: nil, keyEquivalent: "")
        behavior.isEnabled = false
        if items.isEmpty {
            let none = menu.addItem(withTitle: "Nothing scheduled", action: nil, keyEquivalent: "")
            none.isEnabled = false
        }
        for item in items {
            let title = "\(item.request.prefix(50))\(item.request.count > 50 ? "…" : "")  ·  \(Scheduler.describe(item))"
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(withTitle: item.policy.label, action: nil, keyEquivalent: "").isEnabled = false
            let run = sub.addItem(withTitle: "Run Now", action: #selector(runScheduleNow(_:)), keyEquivalent: "")
            run.representedObject = item.request
            run.target = self
            let remove = sub.addItem(withTitle: "Remove", action: #selector(removeSchedule(_:)), keyEquivalent: "")
            remove.representedObject = item.id
            remove.target = self
            row.submenu = sub
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let add = menu.addItem(withTitle: "New Schedule…", action: #selector(newSchedule), keyEquivalent: "")
        add.target = self
    }

    /// The background run's menu: what it's on now, watch it, stop it.
    private func fillRunMenu(_ menu: NSMenu) {
        let now = agent.question.map { "Asks: " + $0.text } ?? agent.steps.last?.text ?? "Working…"
        let status = menu.addItem(withTitle: String(now.prefix(60)) + (now.count > 60 ? "…" : ""), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Background Work", action: #selector(showBackgroundWork), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Stop", action: #selector(stopFromMenuBar), keyEquivalent: "").target = self
    }

    @objc func removeSchedule(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID else { return }
        if !Scheduler.remove(id) { reportScheduleIssue() }
    }

    @objc func runScheduleNow(_ item: NSMenuItem) {
        guard let request = item.representedObject as? String, !agent.isRunning else { return }
        guard let id = TaskStore.shared.enqueue(request, source: .mac, background: true,
                                                idempotencyKey: "schedule-now:" + UUID().uuidString) else {
            reportScheduleIssue(TaskStore.shared.storageError)
            return
        }
        startScheduledTask(id)
    }

    /// Asks for a request and when to run it ("every weekday at 9", "tomorrow 8:30", "in 20 minutes").
    @objc func newSchedule() {
        let alert = NSAlert()
        alert.messageText = "Schedule a task"
        alert.informativeText = "When: “at 9am”, “tomorrow 8:30”, “in 20 minutes”, “every weekday at 9”, “daily 18:00”, “every hour”."
        let request = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        request.placeholderString = "What should I do? e.g. check placement mail"
        let when = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        when.placeholderString = "When? e.g. every weekday at 9"
        request.frame.origin.y = 64
        when.frame.origin.y = 34
        let missed = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        missed.addItems(withTitles: Scheduler.MissedRunPolicy.allCases.map(\.label))
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 88))
        box.addSubview(request)
        box.addSubview(when)
        box.addSubview(missed)
        alert.accessoryView = box
        alert.window.initialFirstResponder = request
        alert.addButton(withTitle: "Schedule")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = request.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let done = NSAlert()
        let policy = Scheduler.MissedRunPolicy.allCases[max(0, missed.indexOfSelectedItem)]
        if let line = Scheduler.add(request: text, phrase: when.stringValue, missed: policy) {
            done.messageText = line.hasPrefix("FAILED:") ? "Schedule couldn't be saved" : "Scheduled"
            done.informativeText = line
        } else {
            done.messageText = "I couldn't read “\(when.stringValue)” as a time"
            done.informativeText = "Try “at 9am”, “tomorrow 8:30”, “in 20 minutes” or “every weekday at 9”."
        }
        done.runModal()
    }

    @objc func toggleDryRun(_ item: NSMenuItem) {
        agent.dryRun.toggle()
        item.state = agent.dryRun ? .on : .off
    }

    @objc func showBackgroundWork() { AgentScreenView.shared.show() }

    /// Connects a Telegram bot (its token from @BotFather), then pairs the user's chat with a one-time link.
    @objc func setUpTelegram() {
        let bot = Telegram.shared
        NSApp.activate(ignoringOtherApps: true)
        if bot.token != nil {
            let alert = NSAlert()
            alert.messageText = "Telegram"
            alert.informativeText = bot.chatID == nil ? "The bot is set up but no chat is paired yet."
                : "Paired: tasks you message the bot run on this Mac, in the background unless you say otherwise."
            alert.addButton(withTitle: "Pair a Chat")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Disconnect")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return pairTelegram()
            case .alertThirdButtonReturn:
                try? Config.write(["TELEGRAM_BOT_TOKEN": nil, "TELEGRAM_CHAT_ID": nil])
                bot.start()
                return
            default: return
            }
        }
        let alert = NSAlert()
        alert.messageText = "Message Clinqy from Telegram"
        alert.informativeText = "In Telegram, message @BotFather, send /newbot and follow its steps. Paste the token it gives you here. "
            + "Only the chat you pair next can give Clinqy tasks."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "123456789:AA…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        try? Config.write(["TELEGRAM_BOT_TOKEN": token, "TELEGRAM_CHAT_ID": nil])
        pairTelegram()
    }

    private func pairTelegram() {
        Task { @MainActor in
            let bot = Telegram.shared
            guard await bot.checkToken() != nil else {
                let alert = NSAlert()
                alert.messageText = "Telegram didn't accept that token"
                alert.informativeText = "Check it in @BotFather (/mybots → API Token) and try again."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                return
            }
            bot.start()
            let (code, link) = bot.pairLink()
            let alert = NSAlert()
            alert.messageText = "Pair your Telegram chat"
            alert.informativeText = "Open the bot and press Start, or send it:\n/pair \(code)\n\nThe code works for 10 minutes."
            alert.addButton(withTitle: "Open in Telegram")
            alert.addButton(withTitle: "Done")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, let link { NSWorkspace.shared.open(link) }
        }
    }

    @objc func toggleBackground(_ item: NSMenuItem) {
        Background.always.toggle()
        item.state = Background.always ? .on : .off
    }

    @objc func toggleFollowCursor(_ item: NSMenuItem) {
        buddy.followsMouse.toggle()
        item.state = buddy.followsMouse ? .on : .off
    }

    @objc func setVoiceLanguage(_ item: NSMenuItem) {
        guard let code = item.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: "voiceLanguage")
        for other in item.menu?.items ?? [] { other.state = (other.representedObject as? String) == code ? .on : .off }
        SpeechModel.shared.prepare()   // the new language's model, fetched if this Mac doesn't have it yet
    }

    @objc func tidyMemory() {
        Task {
            let report = await MemoryTidy.run() ?? "Memory is already tidy (or the tidy-up would have lost details, so it was skipped)"
            let alert = NSAlert()
            alert.messageText = "Memory"
            alert.informativeText = report
            alert.runModal()
        }
    }

    @objc func openMemory() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/clinqy/memory.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    private func sharedWindow() -> OnboardingWindow {
        if let onboarding { return onboarding }
        let window = OnboardingWindow(onFinish: { [weak self] in
            Brain.prewarm()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.panel.showCentered() }
        }, run: { [weak self] task in
            self?.agent.submit(task, test: true)
        }, isRunning: { [weak self] in
            self?.agent.isRunning ?? false
        }, providerChanged: { Brain.reloadModel() }, shortcutsChanged: { [weak self] in
            self?.configureHotKeys()
        }, captureChanged: { [weak self] capturing in
            self?.setHotKeysEnabled(!capturing)
        })
        onboarding = window
        return window
    }

    @objc func showOnboarding() { sharedWindow().presentSetup() }

    private var updateMenuItem: NSMenuItem?

    /// Installs the update the background check found, or checks now.
    @objc func checkForUpdates() {
        if let release = Updater.shared.available { Updater.shared.offer(release) }
        else { Task { await Updater.shared.check(userAsked: true) } }
    }

    @objc func showDashboard() { sharedWindow().presentDashboard() }

    @objc func checkPermissions() {
        let lines = Permissions.all.map { "\($0.granted() ? "✅" : "❌")  \($0.name): \($0.why)" }
        let alert = NSAlert()
        alert.messageText = Permissions.allGranted ? "All permissions granted" : "Clinqy needs these permissions"
        alert.informativeText = lines.joined(separator: "\n") + """


        Model: \(Provider.current.label)
        Calendars & Reminders: \(Events.hasAccess ? "✅" : "asked the first time you schedule something")

        After enabling something in System Settings, click Check Again. \
        Screen Recording may need Clinqy to be restarted.
        """
        alert.addButton(withTitle: "Check Again")
        let missing = Permissions.all.first { !$0.granted() }
        if missing != nil {
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "Done")
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Permissions.requestMissing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.checkPermissions() }
        case .alertSecondButtonReturn:
            if let missing, let url = URL(string: missing.settingsURL) {
                missing.request()
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }
}
