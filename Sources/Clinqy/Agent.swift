import AppKit
import UniformTypeIdentifiers

/// Runs a request as a conversation with one Agy session: observe the screen → Agy picks actions →
/// the buddy carries them out the way a person would (travel, point, click, type) → report → repeat.
@MainActor
final class Agent: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, acting, waiting, done, failed }

    /// Something Clinqy needs from the user before it can go on (details, a choice, a confirmation).
    struct Question: Equatable {
        let text: String
        let options: [String]
        let sensitive: Bool
    }

    struct Step: Identifiable {
        enum State { case running, ok, failed, info }
        let id = UUID()
        var text: String
        var state: State
    }

    @Published var phase: Phase = .idle
    @Published var narration = ""
    @Published var steps: [Step] = []
    @Published var input = ""
    @Published var answer = ""
    /// Set while the run is paused waiting for the user's answer.
    @Published var question: Question?
    private var answerWaiter: CheckedContinuation<String?, Never>?
    private var telegramTab: BrowserBridge.TabInfo?
    private var telegramWindow: (app: NSRunningApplication, id: CGWindowID)?
    private var telegramApprovedForm: String?
    var telegramPageURL: String? { telegramTab?.url }

    /// Captures the exact worker tab/window without selecting it or reading the user's foreground desktop.
    func telegramScreenshot() async -> Data? {
        if let context = executionContext, TaskExecution.current !== context {
            return await TaskExecution.$current.withValue(context) { await telegramScreenshot() }
        }
        guard question?.sensitive != true else { return nil }
        // Use only this agent's pinned target, including after completion. Never use another run's last tab.
        if let tab = telegramTab ?? browserTab {
            return await BrowserBridge.shared.taskScreenshot(of: tab)
        }
        guard let window = telegramWindow, !window.app.isTerminated else {
            Self.writeLog("telegram screenshot: no task tab or owned native window available")
            return nil
        }
        return await Screenshot.windowPNG(app: window.app, windowID: window.id)
    }

    /// Only an explicit Telegram Open task action reveals the pinned task on the user's Mac.
    func revealTelegramTarget() async {
        if let context = executionContext, TaskExecution.current !== context {
            await TaskExecution.$current.withValue(context) { await revealTelegramTarget() }; return
        }
        if let tab = telegramTab ?? browserTab { await BrowserBridge.shared.revealTaskTab(tab) }
        else if let window = telegramWindow, !window.app.isTerminated { await Launcher.bringToFront(window.app) }
    }

    private func rememberTelegramTarget(app: NSRunningApplication?, page: BrowserBridge.Page?, window: NativeWindowObservation? = nil) {
        guard telegramOwned || runBackground else { return }
        if let page, let id = page.tabId {
            telegramTab = .init(id: id, url: page.url, connection: page.connection)
            telegramWindow = nil
        } else if let app, !Launcher.isBrowser(app) {
            telegramTab = nil
            telegramWindow = (window ?? NativeWindowObservation.capture(app)).map { (app, $0.windowID) }
        }
    }
    /// Answers the user marked private; masked in the log.
    private var secrets: [String] = []
    var onQuestion: () -> Void = {}
    /// Output worth looking at (options, plans, prices, summaries), shown in its own card.
    @Published var result: ResultCard?
    var onResult: () -> Void = {}
    /// An earlier run the next request builds on ("Continue" in History).
    @Published var continuation: History.Entry?
    private var request = ""
    private var runResult: ResultCard?
    var onAnswered: () -> Void = {}

    /// The app the user was looking at when they summoned Clinqy.
    var targetApp: NSRunningApplication?
    /// Text the user had selected when they summoned Clinqy; sent along with the request.
    @Published var selectedText: String?
    /// An area the user circled on screen before asking; sent as a marked screenshot on the first turn.
    @Published var annotation: Annotation?
    /// Files the user had selected in Finder when they summoned Clinqy ("compress this", "merge these").
    @Published var selectedFiles: [URL] = []
    /// What the user copied in the last few minutes, when nothing was selected: "this" may mean it.
    struct Copied: Equatable { let text: String?; let files: [URL]; let age: TimeInterval }
    @Published var copied: Copied?
    /// Dry-run mode (sticky, from the command bar): the buddy shows every click and keystroke instead of doing it.
    @Published var dryRun = UserDefaults.standard.bool(forKey: "dryRun") {
        didSet { UserDefaults.standard.set(dryRun, forKey: "dryRun") }
    }
    /// This run is a dry run (the toggle, or a request starting "dry run:").
    private(set) var runDry = false
    /// This run works in the background, out of the user's way (see `Background`); its auto-continues do too.
    private(set) var runBackground = false
    var onStart: () -> Void = {}
    var onFinish: (_ answer: String, _ ok: Bool) -> Void = { _, _ in }
    /// Test mode: mirror progress to stdout with timings.
    var echo = false
    /// Test runs aren't saved to History and teach memory nothing.
    var isTest = false
    /// The run's last real step opened an app or page, so that's what the user wants to see at the end.
    private var openedLast = false
    /// A test run that still shows the review card before a form submit (answered via `clinqy://answer`).
    var reviewInTests = false
    /// A test run that still saves form answers to the job profile (tests/run.sh restores the profile after).
    var saveInTests = false

    let executionContext: TaskExecutionContext?
    var isolatedBrowserJob = false
    var runReceiptID: String?
    var imageOutputRequirement: Int?
    var deliveredImageOutputs = 0
    private var requiredImageOutputs = 0
    private var deliveredImageKeys: Set<String> = []
    private var pendingVisualImage: ImageAsset?
    private var imageCompletionBlocks = 0
    private var powerLease: UUID?
    private(set) var outputFiles: [URL] = []
    private var currentTaskDraft = ""
    private var newTaskDraft = ""
    @Published var inputPanelVisible = false
    @Published var newTaskMode = false {
        didSet {
            guard newTaskMode != oldValue else { return }
            if newTaskMode { currentTaskDraft = input; input = newTaskDraft }
            else { newTaskDraft = input; input = currentTaskDraft }
        }
    }
    var enqueueNewRequest: ((String) -> Bool)?
    @discardableResult func submitNewRequest(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, enqueueNewRequest?(text) == true else { return false }
        input = ""; newTaskMode = false
        return true
    }
    var dispatchBrowserTask: ((String, Bool, String?, Provider?, UUID?) -> Bool)?
    var parallelBrowserTasks: (([String]) async -> (ok: Bool, summary: String))?
    private(set) var completedBrowserTab: BrowserBridge.TabInfo?
    var browserTab: BrowserBridge.TabInfo? {
        if let context = executionContext { return TaskExecution.$current.withValue(context) { Background.tab ?? completedBrowserTab } }
        return Background.tab ?? completedBrowserTab
    }
    private var telegramOwned: Bool { taskRecordID.flatMap { TaskStore.shared.record($0) }?.source == .telegram }
    var shouldDispatchBrowserInput: Bool { dispatchBrowserTask != nil && BrowserTaskRouting.isBrowserTask(input) }
    private let buddy: Buddy
    private let hand: Hand
    fileprivate var task: Task<Void, Never>?
    private var session: AgySession?
    /// Owned by one run; workers never share this Agent's mutable UI context.
    private var delegation: DelegationPool?
    fileprivate var started = Date()
    /// Whether this task already opened a browser tab (so later website visits reuse it).
    private var openedTab = false
    /// Step screenshots taken with snap, for paste_snaps. A write-up spans several runs (auto-continues, and
    /// follow-ups like "where are the screenshots?" that don't read as "continue"), so ones not yet pasted are kept
    /// for a few hours whatever the next request is; each is pasted once. Every snap is also saved as a file.
    private var snaps: [(caption: String, png: Data, pasted: Bool)] = []
    private var lastSnapAt = Date.distantPast
    /// This write-up's folder of saved snaps (~/Pictures/Clinqy Screenshots/<date time>), made on the first snap.
    private var snapFolder: URL?
    /// Runs this task continued on its own after running out of steps or stalling (see `finish`).
    private var autoContinues = 0
    /// The browser tab this task opened (the only tab it may navigate in place).
    private var ownedTab: Int?
    /// The user already said yes to a confirmation in this run.
    private var userConfirmed = false
    /// Names this run's folder of click traces; `clickCount` numbers them.
    private var runID = UUID().uuidString
    private var clickCount = 0
    /// Where the run started, for the replay cache (a similar request from the same place gets these steps as a hint).
    private var startPlace: (app: String?, url: String?, title: String?) = (nil, nil, nil)
    static func isNewTabPage(_ url: String) -> Bool {
        url.isEmpty || url.hasPrefix("chrome://newtab") || url.hasPrefix("arc://newtab") || url == "about:blank"
            || url.hasPrefix("chrome://new-tab-page") || url.hasPrefix("edge://newtab") || url.hasPrefix("brave://newtab")
    }

    var isRunning: Bool { phase == .thinking || phase == .acting || phase == .waiting }

    /// What this run actually did, step by step, in a replayable form (saved as a workflow / QA script).
    var trace: [WorkflowStep] = []
    /// How the last resolved element can be found again (set whenever an action resolves its target).
    var lastTarget: WorkflowStep.Target?
    /// QA mode: the run is a UI test; checks are collected instead of asking the user anything.
    var qa: QAContext?
    /// Use a different model for this run (e.g. from `clinqy qa --model`).
    var modelOverride: String?
    /// Use a different provider for this run (e.g. from `clinqy://run?agy=1` or `clinqy://qa?agy=1`).
    var providerOverride: Provider?

    /// Things the user added while the task was running; folded into the next step.
    private var addedNotes: [String] = []
    /// The last document this run read in full, kept in history so a follow-up ("now the answers") needn't find it again.
    private var readText: String?

    /// Steer a running task: more context or a change of plan, picked up at the next step.
    func addContext(_ raw: String) {
        if let context = executionContext, TaskExecution.current !== context {
            TaskExecution.$current.withValue(context) { addContext(raw) }; return
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isRunning else { return }
        if question != nil { return answer(text) }   // waiting on a question: this is the answer
        addedNotes.append(text)
        if Router.isCorrection(text) {
            delegation?.cancelAll(reason: "User corrected the task; disregard prior worker output and delegate revised jobs", stop: false)
        }
        if !isTest, !runDry, Router.isCorrection(text) { ReplayCache.shared.corrected(request: request) }
        steps.append(Step(text: "You: \(text)", state: .info))
        input = ""
        lastProgress = Date()
        log("  + user added: \(text)")
    }

    /// Pauses for the user's answer to `text` (nil = no answer / cancelled).
    private func askUser(_ text: String, options: [String] = [], sensitive: Bool = false) async -> String? {
        if qa != nil { return options.first }   // tests run unattended: take the first (go-ahead) option
        let previous = phase
        phase = .waiting
        TaskStore.shared.update(taskRecordID, state: .waiting, stage: sensitive ? "Waiting for private input" : text)
        // Waiting on the user isn't a hang: say so in the log, and keep the buddy's bubble up until they answer.
        log("  waiting for your answer: \(sensitive ? "(hidden)" : String(text.prefix(120)))")
        // A background run comes back to the user to ask.
        if runBackground, !isolatedBrowserJob { buddy.quiet = true; buddy.goHome() }
        buddy.bubble("need your input", for: 600)
        question = Question(text: text, options: options, sensitive: sensitive)
        onQuestion()
        if runBackground, !isolatedBrowserJob { Notifier.ask(text, options: options, sensitive: sensitive) }
        if telegramOwned { Telegram.shared.ask(text, options: options, sensitive: sensitive, from: self) }
        let reply = await withCheckedContinuation { answerWaiter = $0 }
        buddy.bubble(nil)
        guard !Task.isCancelled, isRunning else { return nil }
        if runBackground, !Task.isCancelled { buddy.goAway(to: AgentScreen.bounds) }
        if !Task.isCancelled { phase = previous == .waiting ? .acting : previous }
        TaskStore.shared.update(taskRecordID, state: .running, stage: "Continuing after your answer")
        return reply
    }

    /// Consequential clicks (pay, book, send, delete…) the request didn't clearly ask for need the user's OK.
    private func confirmRisky(_ label: String) async -> Bool {
        guard !userConfirmed, let what = Safety.needsConfirmation(label: label, request: request) else { return true }
        let reply = await askUser("About to click “\(what)”. Go ahead?", options: ["Yes, go ahead", "No"])
        let yes = reply.map(Safety.isYes) ?? false
        if yes { userConfirmed = true }
        return yes
    }

    /// Before clicking a control on a web page: a form's final Submit shows the user every answer on the form and
    /// waits for Submit or Edit (instead of the plain question, so they're asked once); other consequential clicks get
    /// confirmRisky. nil = go ahead, else why not.
    private func approve(_ label: String, role: String, page: BrowserBridge.Page?) async -> String? {
        // Picking an option or ticking a box sends nothing, whatever its label says ("Send a notification to the
        // following SNS topic" is a choice in a form); only a control that acts needs the user's OK.
        guard Self.acts(role) else { return nil }
        if let page, Self.isFormSubmit(label) {
            if telegramOwned {
                guard let ok = await reviewBeforeSubmit(page) else {
                    return "Couldn't read the form for your Telegram review. Do not submit; report this and ask the user to check it on the Mac."
                }
                return ok ? nil : editedReview
            }
            if !userConfirmed, let ok = await reviewBeforeSubmit(page) { return ok ? nil : editedReview }
        }
        return await confirmRisky(label) ? nil
            : "the user said not to click \(label.prefix(40).debugDescription); stop and tell them where things stand"
    }

    /// Return can submit a web form just like clicking its final button. It needs the same review.
    private func approveReturn(_ page: BrowserBridge.Page?) async -> String? {
        guard telegramOwned, let page,
              let submit = page.elements.first(where: { Self.acts($0.role) && Self.isFormSubmit($0.text) }) else { return nil }
        return await approve(submit.text, role: submit.role, page: page)
    }

    /// A final summary that itself lists work still to do ("Steps 1–6 partly done … Still to do: …"), unless what's
    /// left needs the user (a login, a code, a confirmation link).
    /// Whether every word of `want` appears in `line` in the same order, with at most 3 other words between
    /// each pair (and at least two words wanted, so one common word never counts).
    nonisolated static func wordsInOrder(_ want: String, in line: String) -> Bool {
        let words = { (t: String) in t.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let need = words(want), have = words(line)
        guard need.count >= 2, have.count <= need.count + 8 else { return false }
        var at = -1
        for w in need {
            guard let i = have[(at + 1)...].firstIndex(of: w), at < 0 || i - at <= 4 else { return false }
            at = i
        }
        return true
    }

    /// A snap's caption as it goes in the doc: the model's own "Step 3: …" as is, otherwise numbered in order.
    nonisolated static func snapCaption(_ given: String, number: Int) -> String {
        if given.isEmpty { return "Step \(number)" }
        if given.range(of: #"(?i)^(step|task|part|q(uestion)?)\s*\d"#, options: .regularExpression) != nil { return given }
        return "Step \(number): \(given)"
    }

    /// Saves a snap as a numbered PNG in this write-up's folder, so the screenshots outlive the run and the doc.
    private func saveSnap(_ png: Data, caption: String) -> URL? {
        let fm = FileManager.default
        if snapFolder == nil {
            // ~/Pictures, not ~/Documents: Documents is privacy-protected and silently refuses an app without access.
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd HH.mm"
            let name = "Clinqy Screenshots/\(stamp.string(from: Date()))"
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clinqy/\(name)")
            snapFolder = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/\(name)"), support]
                .first { (try? fm.createDirectory(at: $0, withIntermediateDirectories: true)) != nil }
            if snapFolder == nil { log("    couldn't make a folder to save screenshots in") }
        }
        guard let folder = snapFolder else { return nil }
        let count = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".png") }.count
        let name = caption.replacingOccurrences(of: ":", with: " -")
            .replacingOccurrences(of: #"[/\\\n\r\t"*?<>|]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).prefix(80)
        let url = folder.appendingPathComponent(String(format: "%02d ", count + 1) + name + ".png")
        do {
            try png.write(to: url)
            if !outputFiles.contains(url) { outputFiles.append(url) }
            TaskStore.shared.setOutputs(taskRecordID, files: outputFiles)
            return url
        } catch {
            log("    couldn't save the screenshot to \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    private func deliverSnapshot(_ png: Data, file: URL?, caption: String) async -> ActionResult {
        guard telegramOwned, requiredImageOutputs > 0 else { return fail("Screenshot delivery must be requested in this Telegram task.") }
        do {
            let asset = try ImageAssets.decode(png, source: file?.path ?? "clinqy-screenshot:" + runID + ":" + String(snaps.count), title: caption)
            guard await Telegram.shared.deliverImage(asset, caption: caption, from: self) else { return fail("Screenshot delivery was not acknowledged; do not report it sent.") }
            if deliveredImageKeys.insert(asset.key).inserted { deliveredImageOutputs += 1 }
            return .init(ok: true, summary: "Screenshot delivered to Telegram (acknowledged)" + (file.map { "; saved at " + $0.path } ?? ""))
        } catch { return fail(error.localizedDescription) }
    }

    nonisolated static func saysUnfinished(_ say: String) -> Bool {
        let unfinished = #"(?i)\b(still to do|still need to|remaining steps?|steps? (left|remaining)|left to do|not (yet )?(done|finished|written|pasted|added)|partly done|partially (done|complete)|next,? i('ll| will)|haven't (yet )?(done|finished|captured|added|started|pasted)|remain\b(?! (the same|unchanged|open|running|available|in place))|(rest|doc|write-?up|steps?)\b[^.]{0,40}\bremains\b|stopped (there|here|at)|got through (steps? )?\d+\s*[-–]\s*\d+ of)"#
        let needsUser = #"(?i)\b(you need to|you'll need to|you have to|waiting (for|on) you|your (password|otp|code|login|approval|confirmation)|log ?in|sign ?in|confirm(ation)? (link|email)|click the (confirm|link))\b"#
        return say.range(of: unfinished, options: .regularExpression) != nil && say.range(of: needsUser, options: .regularExpression) == nil
    }

    /// Whether clicking an element of this role does something (a button, a link, a menu item), as opposed to
    /// choosing or ticking (radio, checkbox, option, tab) or focusing (a text box), which never needs a confirmation.
    nonisolated static func acts(_ role: String) -> Bool {
        let r = role.lowercased().replacingOccurrences(of: "ax", with: "", options: .anchored)
        return !["radio", "radiobutton", "checkbox", "switch", "option", "menuitemradio", "menuitemcheckbox", "tab",
                 "textbox", "textfield", "textarea", "searchfield", "combobox", "listbox", "row", "cell", "heading",
                 "statictext", "group", "radiogroup", "slider", "treeitem"].contains(r)
    }

    /// Why the step stopped when the user chose Edit on the review.
    /// "Ready to submit?" — a go-ahead for the form's Submit, not a clarifying question that merely mentions applying
    /// ("apply to the Headout role, message someone, or something else?"), which the user has to answer in words.
    private static func asksToSubmit(_ action: [String: Any]) -> Bool {
        let q = action["question"] as? String ?? ""
        let options = (action["options"] as? [String] ?? []).map { $0.lowercased() }
        if options.contains("submit"), options.contains("edit") { return true }
        guard options.count <= 2, !q.contains(" or ") else { return false }
        return q.range(of: #"(?i)(\b(ready to|shall i|should i|ok(ay)? to|go ahead( and)?|can i|want me to|confirm|good to)\b[^?]{0,40}\b(submit|apply|send)\b|^\s*(submit|apply|send)\b[^?]{0,40}\?)"#,
                       options: .regularExpression) != nil
    }

    private var localReviewNote: String?
    private var reviewNote: String? {
        get { isolatedBrowserJob ? localReviewNote : UI.lastReviewNote }
        set { if isolatedBrowserJob { localReviewNote = newValue } else { UI.lastReviewNote = newValue } }
    }
    private var editedReview: String {
        "the user chose Edit on the review" + (reviewNote.map { ": \"\($0)\". Make that change, then submit again" }
            ?? " without saying what; ask them what to change")
    }

    /// A form's final button ("Submit", "Submit application", "Send application"), not one that opens a form ("Easy Apply").
    nonisolated static func isFormSubmit(_ label: String) -> Bool {
        label.range(of: #"(?i)\bsubmit\b|^\s*(send|finish|complete) (my |the |your )?(application|form)\b"#, options: .regularExpression) != nil
    }

    /// Shows every answer on the page's form (question → answer) and waits for Submit or Edit. nil = no form here
    /// (or an unattended, dry or test run): the caller falls back to a plain confirmation.
    private func reviewBeforeSubmit(_ page: BrowserBridge.Page) async -> Bool? {
        guard qa == nil, !runDry, !isTest || reviewInTests,
              let r = try? await BrowserBridge.shared.perform("review", on: page, timeout: 8),
              let items = r["items"] as? [[String: Any]] else { return nil }
        let pairs = items.compactMap { i -> (String, String)? in
            guard let q = i["q"] as? String, !q.isEmpty else { return nil }
            return (q, i["answer"] as? String ?? "")
        }
        guard pairs.count >= (telegramOwned ? 1 : 2) else { return nil }
        reviewedForm = true
        if telegramOwned || runBackground {
            let formKey = Telegram.formKey(url: page.url, answers: pairs)
            if telegramApprovedForm == formKey { return true }
            let cards = items.compactMap { item -> ResultCard.Item? in
                guard let label = item["q"] as? String else { return nil }
                let value = item["answer"] as? String ?? ""
                return .init(title: label, subtitle: value.isEmpty ? "(empty)" : value,
                             detail: value.isEmpty && item["required"] as? Bool == true ? "⚠️ required — empty" : nil, link: nil)
            }
            let missing = r["missing"] as? [String] ?? []
            let card = ResultCard(title: "Review before submitting: " + String(page.title.prefix(70)),
                                  text: missing.isEmpty ? "Check these answers before submitting." : "Required answers missing: " + missing.joined(separator: "; "), items: cards)
            runResult = card; result = card; onResult()
            if telegramOwned { Telegram.shared.present(card, from: self) }
            let reply = await askUser("Please review the answers above. Submit this form, or tell me what to change?", options: ["Submit", "Edit"])
            guard let reply, !Task.isCancelled else { return false }
            let approve = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "submit" || Safety.isYes(reply)
            // A required field known to be empty cannot be approved by an old or generic yes.
            telegramApprovedForm = approve && missing.isEmpty ? formKey : nil
            if telegramApprovedForm != nil { userConfirmed = true; return true }
            userConfirmed = false
            reviewedForm = false
            if approve && !missing.isEmpty {
                reviewNote = "Fill the required fields: " + missing.joined(separator: "; ")
            } else if reply.lowercased() == "edit" {
                reviewNote = await askUser("What should I change in the form?")
            } else { reviewNote = reply }
            return false
        }
        let ok = await UI.reviewBeforeSubmit(items: pairs, title: String((r["title"] as? String ?? page.title).prefix(70)))
        lastProgress = Date()
        if ok { userConfirmed = true }
        return ok
    }

    /// The user's reply to the current question (nil = they declined / cancelled).
    func answer(_ text: String?) {
        if let context = executionContext, TaskExecution.current !== context {
            TaskExecution.$current.withValue(context) { answer(text) }; return
        }
        // A waiting review card takes the answer too (voice, `clinqy://answer`): "submit"/"yes" approves, anything
        // else is an edit to make first.
        if !isolatedBrowserJob, ReviewCenter.shared.pending != nil, answerWaiter == nil {
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let approve = t.range(of: #"(?i)^(submit|yes|ok|okay|go ahead|approve|send)\b"#, options: .regularExpression) != nil
            ReviewCenter.shared.decide(approve, note: approve ? nil : t)
            return
        }
        guard let waiter = answerWaiter else { return }
        answerWaiter = nil
        if telegramOwned { Telegram.shared.dismissQuestion(from: self) }
        if !isolatedBrowserJob { Notifier.clearQuestion() }
        lastProgress = Date()   // time spent answering isn't "stuck"
        question = nil
        input = ""
        onAnswered()
        if let text, !text.isEmpty { userAnswers.append(text) }
        waiter.resume(returning: text?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    init(buddy: Buddy, context: TaskExecutionContext? = nil) {
        self.executionContext = context
        self.buddy = buddy
        hand = Hand(buddy: buddy)
    }

    /// `background`: where to work when the request itself says nothing (nil: the toggle decides). Telegram passes
    /// what the user's own words said, or true, since they're not at the screen.
    private(set) var taskRecordID: UUID?

    func submit(_ raw: String, test: Bool = false, auto: Bool = false, model: String? = nil, provider: Provider? = nil,
                background preferred: Bool? = nil, taskID: UUID? = nil, unattended: Bool = false) {
        if let context = executionContext, TaskExecution.current !== context {
            TaskExecution.$current.withValue(context) { submit(raw, test: test, auto: auto, model: model, provider: provider, background: preferred, taskID: taskID, unattended: unattended) }
            return
        }
        var request = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        // "dry run: book a cab" rehearses just this request.
        var dry = dryRun
        if let r = request.range(of: #"(?i)^\(?(dry[ -]?run|rehearse|practice run)\)?[:,\s-]+"#, options: .regularExpression) {
            request.removeSubrange(r)
            dry = true
        }
        // "in the background: book a cab" works out of the user's way, "not in the background: …" in front of them;
        // saying nothing follows the toggle (or BACKGROUND_TASKS=1).
        let explicitBackground = Background.choice(&request)
        let background = unattended ? true : explicitBackground ?? preferred ?? (Background.always || (auto && runBackground))
        if !auto, !dry, (explicitBackground ?? preferred) != false, background || (!test && BrowserTaskRouting.isBrowserTask(request)),
           let dispatchBrowserTask, dispatchBrowserTask(raw, test, model, provider, taskID) {
            input = ""; selectedText = nil; selectedFiles = []; annotation = nil; copied = nil; continuation = nil
            return
        }
        guard !isRunning else { return }
        if !auto { autoContinues = 0 }
        if unattended {
            targetApp = nil; selectedText = nil; selectedFiles = []; annotation = nil; copied = nil; continuation = nil
        }
        if !test && !echo && !auto {
            let store = TaskStore.shared
            guard let id = taskID ?? store.enqueue(request, files: selectedFiles, source: .mac, background: background),
                  store.record(id)?.state == .running || store.start(id) else {
                phase = .failed
                answer = store.storageError ?? "The task couldn't start. Review Tasks & Recovery."
                return
            }
            taskRecordID = id
            guard store.addRequirements(id, RequirementExtractor.extract(request), provenance: "user request") else {
                phase = .failed
                answer = store.storageError ?? "The task couldn't record its requirements. Review Tasks & Recovery."
                return
            }
        } else if test || echo { taskRecordID = nil }
        // "continue", "also make the answers": builds on the last task, even when typed or said after the follow-up mic closed.
        if !unattended, continuation == nil, !test, let last = History.shared.entries.first,
           Date().timeIntervalSince(last.date) < (Router.isCorrection(request) ? 24 * 60 * 60 : 20 * 60), Router.isFollowUp(request) {
            continuation = last
        }
        if !test, !dry, Router.isCorrection(request), let previous = continuation {
            ReplayCache.shared.corrected(request: previous.request)
            if let original = previous.task, original != previous.request { ReplayCache.shared.corrected(request: original) }
        }
        let clear = { [weak self] in
            self?.selectedText = nil
            self?.annotation = nil
            self?.selectedFiles = []
            self?.copied = nil
            self?.continuation = nil
            self?.providerOverride = nil
            self?.modelOverride = nil
        }
        // A saved workflow that does exactly this: replay it with no model (the model only heals a broken step).
        if !isolatedBrowserJob, !unattended, !test, !dry, let match = workflowFirst(request) {
            prepare(request, test: false, background: background)
            self.modelOverride = model
            self.providerOverride = provider
            let params = (match.workflow.defaults ?? [:]).merging(match.params) { _, new in new }
            steps.append(Step(text: "Saved workflow “\(match.workflow.name.prefix(40))” — no model needed", state: .info))
            log("workflow-first: “\(match.workflow.name)” · params \(match.params)")
            let preparedRunID = runID
            task = Task {
                await replayOrHeal(match.workflow, params: params)
                if runID == preparedRunID { clear() }
            }
            return
        }
        prepare(request, test: test, dry: dry, background: background)
        self.modelOverride = model
        self.providerOverride = provider
        let preparedRunID = runID
        task = Task {
            await run(request)
            // Post-task learning may still be finishing when a follow-up starts. Don't erase its context/overrides.
            if runID == preparedRunID { clear() }
        }
    }

    /// The saved workflow to replay for this request, when that's safe to do without the model: nothing selected,
    /// copied, circled or continued that the model would need to see, and not a question or a request about "this".
    private func workflowFirst(_ request: String) -> Router.Match? {
        guard Self.workflowFirstOn, selectedText == nil, selectedFiles.isEmpty, annotation == nil, continuation == nil,
              !Self.isQuestion(request), !Router.refersToContext(request), !Safety.micInUse else { return nil }
        return Router.match(request, in: Workflows.shared.all)
    }

    /// Saved workflows and runs that worked are replayed with no model when they fit exactly (WORKFLOW_FIRST=off stops it).
    static var workflowFirstOn: Bool { !["off", "0", "no", "false"].contains((Config.value("WORKFLOW_FIRST") ?? "on").lowercased()) }

    /// Resets per-run state; shared by requests, workflow replays and QA runs.
    fileprivate func prepare(_ request: String, test: Bool, dry: Bool = false, background: Bool = false, external: Bool = false) {
        if let powerLease { TaskPowerAssertions.shared.end(powerLease) }
        powerLease = TaskPowerAssertions.shared.begin(preventDisplaySleep: !background)
        externalRun = external
        delegation?.cancelAll()
        delegation = nil
        providerOverride = nil
        modelOverride = nil
        isTest = test || echo
        if isTest { taskRecordID = nil }
        runDry = dry
        outputFiles = []
        completedBrowserTab = nil
        pendingVerification = nil
        // A continuation of the same durable task keeps its unresolved input: the barrier is rebuilt from the store
        // (its baseline text is gone, so only independent, visual-eligible or user evidence can lift it).
        if !isTest, let record = TaskStore.shared.record(taskRecordID), record.unverifiedAction != nil, let origin = record.pendingProvenance {
            pendingVerification = PendingVerification(kind: origin.kind, visualOK: origin.visualOK && origin.delivery == .delivered, startedAt: origin.startedAt,
                pageConnection: nil, tabID: origin.tabID, url: origin.url, windowID: nil, processIdentity: nil, nativeWindow: nil, beforeText: nil,
                fieldInput: false, webTarget: nil, webTargetUnique: false, nativeTarget: nil, beforeFieldValue: nil, documentID: nil)
        }
        completionEvidence = CompletionEvidence()
        if pendingVerification != nil { completionEvidence.markUnverifiedCarryover() }
        deliveredImageOutputs = 0; deliveredImageKeys = []; pendingVisualImage = nil; imageCompletionBlocks = 0
        requiredImageOutputs = telegramOwned ? (imageOutputRequirement ?? ImageRequest.count(request)) : 0
        started = Date()
        trace = []
        lastTarget = nil
        steps = []
        answer = ""
        if newTaskMode { currentTaskDraft = "" } else { input = "" }
        narration = ""
        openedTab = false
        memoryCheckedAsks = []
        lastFirst = ""
        shownFacts = []; lastPageMemory = ""; formSeen = [:]; agentEntered = []; visitedHosts = []; visitedApps = []
        pushedOn = 0; snapPushes = 0
        profileOffered = []
        turnCount = 0; fastTurnCount = 0; lookCount = 0
        modelSeconds = 0; phaseMilliseconds = [:]; firstTokenMilliseconds = nil
        reviewedForm = false
        userAnswers = []
        // Kept for a follow-up about them ("where are the screenshots?", "paste them"), not for an unrelated task.
        let aboutSnaps = request.range(of: #"(?i)\b(screenshots?|snaps?|write-?up|paste|doc|lab|steps?)\b"#, options: .regularExpression) != nil
        if continuation == nil, !aboutSnaps || Date().timeIntervalSince(lastSnapAt) > 3 * 3600 || !snaps.contains(where: { !$0.pasted }) {
            snaps = []
            snapFolder = nil
        }
        addedNotes = []
        readText = nil
        ownedTab = nil
        userConfirmed = false
        secrets = []
        runID = UUID().uuidString
        telegramTab = nil
        telegramWindow = nil
        telegramApprovedForm = nil
        clickCount = 0
        startPlace = (nil, nil, nil)
        openedLast = false
        runBackground = background
        BrowserBridge.shared.beginActivityRun()
        Background.begin(background)
        buddy.quiet = background
        // Off to work somewhere else: the buddy leaves for the screen's edge until it's done or needs the user.
        if background {
            buddy.goAway(to: AgentScreen.bounds)
            WorkingBadge.shared.show()
        }
        hand.beginRun(request: request)
        if !isTest { Task.detached(priority: .background) { Screenshot.pruneRuns() } }
        self.request = request
        runResult = nil
        phase = .thinking
        buddy.clearMark()
        onStart()
        startWatchdog()
        Replay.Recorder.shared.begin(request: request)
        Self.writeLog("=== \(dry ? "[dry run] " : "")\(background ? "[background] " : "")\(request)\(selectedText.map { " [selection: \($0.count) chars]" } ?? "")\(selectedFiles.isEmpty ? "" : " [files: \(selectedFiles.map(\.lastPathComponent).joined(separator: ", "))]")\(annotation.map { " [circled: \(Int($0.rect.width))×\(Int($0.rect.height)) at \(Int($0.rect.minX)),\(Int($0.rect.minY))]" } ?? "")")
    }

    func cancel() {
        if let context = executionContext, TaskExecution.current !== context {
            TaskExecution.$current.withValue(context) { cancel() }; return
        }
        if !isolatedBrowserJob { UI.cancelReview() }
        answer(nil)
        task?.cancel()
        controlOperation?.cancel()
        session?.close()
        if isRunning { finish(ok: false, "Stopped") }
    }

    // MARK: - Loop

    fileprivate func run(_ request: String) async {
        guard !Task.isCancelled, isRunning else { return }
        guard runBackground || AXEngine.isTrusted else {
            return finish(ok: false, "Turn on Accessibility for Clinqy in System Settings → Privacy & Security.")
        }
        buddy.mood = .thinking

        // Don't start clicking around during a call or meeting unless the user says so (or told Clinqy it's fine,
        // e.g. the remembered fact "OK to work during calls and screen sharing").
        let callsOK = Memory.facts.contains { fact in
            let f = fact.lowercased()
            return f.contains("ok to work") && (f.contains("call") || f.contains("screen shar"))
        }
        if !runBackground, Safety.micInUse, qa == nil, !callsOK {
            let reply = await askUser("You seem to be on a call (the mic is in use). Should I go ahead and use the screen?",
                                      options: ["Go ahead", "Not now"])
            guard let reply, reply.lowercased().hasPrefix("go") || Safety.isYes(reply) else {
                return finish(ok: false, "Okay, I'll wait until you're off the call")
            }
            phase = .thinking
        }

        var app = runBackground ? nil : targetApp ?? NSWorkspace.shared.frontmostApplication
        // Capture once and check known routes before allocating model sessions or building their prompts.
        // The archive query runs off the main thread alongside the first observation.
        let startupTime = ProcessInfo.processInfo.systemUptime
        let memoryStart = Date()
        async let pastContext = TaskMemory.shared.context(for: request, app: targetApp?.cleanName,
                                                          threadID: continuation.map { $0.threadID ?? $0.id })
        let firstObservation = await Observation.capture(app)
        guard !Task.isCancelled else { return }
        var routeHint = ""
        if continuation == nil, qa == nil {
            startPlace = (firstObservation.app?.cleanName, firstObservation.page?.url, firstObservation.page?.title)
            if !isTest, !runDry, selectedText == nil, selectedFiles.isEmpty, annotation == nil,
               Self.workflowFirstOn, !Self.isQuestion(request), !Router.refersToContext(request),
               let replay = ReplayCache.shared.replayable(request: request, app: firstObservation.app?.cleanName,
                                                         url: firstObservation.page?.url, title: firstObservation.page?.title) {
                log("replay-first: exact repeat — \(replay.steps.count) steps, no model session needed")
                steps.append(Step(text: "Done this before — replaying the known steps", state: .info))
                await replayOrHeal(replay, params: [:])
                return
            }
            if let hint = ReplayCache.shared.hint(request: request, app: firstObservation.app?.cleanName,
                                                   url: firstObservation.page?.url, title: firstObservation.page?.title) {
                routeHint = hint
                log("replay hint offered")
            }
        }
        let historyContext = await pastContext
        recordPhase("startup_observation_and_retrieval", since: startupTime)
        guard !Task.isCancelled else { return }
        log("startup: observation + task memory \(Int(Date().timeIntervalSince(memoryStart) * 1000)) ms · \(historyContext.count) context chars")

        let session: AgySession
        do { session = try Brain.session(model: modelOverride, provider: providerOverride) } catch { return finish(ok: false, error.localizedDescription) }
        self.session = session
        defer { session.close() }

        let sourceCache = SourceCache()
        defer { Task { await sourceCache.cancelAll() } }
        let workerModel = Config.value("DELEGATE_MODEL") ?? FastLane.model ?? session.sessionModel
        let workersEnabled = !["off", "0", "false", "no"].contains((Config.value("DELEGATION") ?? "on").lowercased())
        let pool = DelegationPool(concurrency: Int(Config.value("DELEGATE_CONCURRENCY") ?? "3") ?? 3,
                                  timeout: min(300, max(10, Double(Config.value("DELEGATE_TIMEOUT") ?? "90") ?? 90))) { job, dependencies in
            try await DelegationWorker.run(job, dependencies: dependencies, parent: request,
                                           provider: session.sessionProvider, model: workerModel,
                                           effort: Config.value("DELEGATE_EFFORT") ?? "low", sources: sourceCache)
        }
        delegation = workersEnabled ? pool : nil
        defer {
            pool.cancelAll()
            if delegation === pool { delegation = nil }
        }

        var message = intro(request) + routeHint + historyContext
        message += workersEnabled
            ? "\nParallel delegation available: up to \(pool.concurrency) independent worker sessions, model \(workerModel). Split substantial independent research/analysis/drafting/review work with delegate, then continue your own work. Use collect(wait:true) when only worker results remain. Small tasks should stay direct."
            : "\nParallel delegation is disabled; carry out this task directly."
        let fast = FastLane(intro: message, leadModel: modelOverride ?? Brain.model, provider: session.sessionProvider)
        if let helper = fast.helperRoute { log("  \(helper)") }
        defer { fast.close() }
        message += fast.leadNote
        if let open = TaskStore.shared.record(taskRecordID)?.openRequirements, !open.isEmpty {
            message += "\n\nRequirements recorded from the request (exact; each stays open until its own evidence exists):\n"
                + open.map { "- \($0.kind.rawValue): \($0.text)" }.joined(separator: "\n")
        }
        var wantsLook = false
        var completionBlocks = 0
        var failures = 0
        var lastSignature = ""
        var repeats = 0, sameRuns = 0
        // Loops already met with "change method" (a loop that comes back after that stops the run).
        var escalated: Set<String> = []
        var askedForAnswer = false
        var lastScreen = ""
        // What the model was last shown, so later turns can say only what changed (see screenText).
        var shown: Observation?
        var lastFullTurn = 0, lookedLastTurn = false
        let maxTurns = 80

        for turn in 0..<maxTurns {   // long forms take 30+ turns
            guard !Task.isCancelled, isRunning else { return }
            let updates = pool.drainResults()
            if !updates.isEmpty {
                message += "\n" + updates
                steps.append(Step(text: updates, state: .info))
                log("delegation: worker results delivered to lead")
            }
            if turn == maxTurns - 10 {
                message += "\n(\(turn) of \(maxTurns) steps used. If the current approach isn't getting closer, change it now. "
                    + "A long task that is making progress just carries on in a new run when these run out, so don't finish early "
                    + "for that; finish only if it truly can't be done. Before the steps run out, paste any snaps not yet in the doc.)"
            }
            let observeStart = Date()
            let obs: Observation
            if turn == 0 { obs = firstObservation } else { obs = await Observation.capture(app) }
            guard !Task.isCancelled, isRunning else { return }
            rememberTelegramTarget(app: obs.app, page: obs.page, window: obs.nativeWindow)
            let observeMs = Int(Date().timeIntervalSince(observeStart) * 1000)
            if observeMs > 400 { log("  observe: \(observeMs) ms") }
            // Know-how saved for the site or app the task is in now, the first time it gets there.
            let host = obs.page.map { Memory.bareHost($0.url) }.flatMap { $0.isEmpty ? nil : $0 }
            if let host { visitedHosts.insert(host) }
            if let name = obs.app?.cleanName { visitedApps.insert(name) }
            let notes = Memory.scoped(app: obs.app?.cleanName, host: host).filter { !shownFacts.contains($0) }
            if !notes.isEmpty {
                shownFacts.formUnion(notes)
                message += "\nNotes you saved for \(host ?? obs.app?.cleanName ?? "this app") (how to work it; follow them here):\n"
                    + notes.map { "- \($0)" }.joined(separator: "\n")
                log("  memory: \(notes.count) note\(notes.count == 1 ? "" : "s") for \(host ?? obs.app?.cleanName ?? "?")")
            }
            if let page = obs.page, let host { trackForm(page, host: host) }
            // Facts that answer this page's fields (or its subject), shown with it, so no recall turn is needed.
            if let page = obs.page {
                let labels = page.elements.filter { $0.editable || $0.dropdown || $0.question != nil }
                    .flatMap { [$0.question, $0.placeholder, $0.editable ? $0.text : nil].compactMap { $0 } }
                    + [page.title] + page.headings.prefix(6)
                let signature = labels.joined(separator: "\u{1}")
                if signature != lastPageMemory {
                    lastPageMemory = signature
                    let t0 = Date()
                    let found = Memory.forPage(labels: labels, excluding: shownFacts, app: obs.app?.cleanName, host: host)
                    if !found.isEmpty {
                        shownFacts.formUnion(found)
                        message += "\nFrom memory, for what's on this page (use these; no need to recall them):\n"
                            + found.map { "- \($0)" }.joined(separator: "\n")
                        log("  memory: \(found.count) fact\(found.count == 1 ? "" : "s") for this page (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
                    }
                }
            }
            if let page = obs.page {
                let fields = page.elements.filter(\.editable).map { "w\($0.index) \($0.extra)" }.joined(separator: " | ")
                log("  page: \(page.title.prefix(50)) · \(page.elements.count) elements\(fields.isEmpty ? "" : " · fields: \(fields.prefix(300))")")
            }
            // Auto-screenshot when there's little to go on. With the extension, the page's own list counts
            // (the browser's toolbar controls alone say nothing about the page).
            let known = obs.page.map { $0.elements.count } ?? obs.elements.count
            let visionMode = VisionPolicy.Mode(rawValue: Config.value("VISION_POLICY") ?? "auto") ?? .auto
            wantsLook = VisionPolicy.capture(mode: visionMode, explicit: wantsLook, first: turn == 0,
                native: obs.page == nil, changed: obs.text != lastScreen,
                documentChanged: shown?.page?.documentID != obs.page?.documentID,
                knownElements: known, failures: failures)
            // The first look shows what the user circled; after that it's just in the request text.
            let circled = turn == 0 ? annotation : nil
            if let circled {
                wantsLook = true
                let inside = obs.elements.enumerated().filter { circled.rect.intersects($0.element.frame) }.map { "e\($0.offset)" }
                message += "\nInside the circled area: " + (inside.isEmpty ? "no listed elements (use the screenshot)." : inside.prefix(30).joined(separator: ", "))
            }
            if turn == 0, pendingVisualImage == nil {
                pendingVisualImage = selectedFiles.lazy.compactMap { try? ImageAssets.local($0) }.first
            }
            let assetInput = pendingVisualImage
            pendingVisualImage = nil
            var image: String?
            var coordinateCapture: Screenshot.Capture?
            if let assetInput {
                image = assetInput.jpeg.base64EncodedString()
                message += "\nActual image attached: " + assetInput.title + " · source: " + assetInput.source + ". These are image pixels, not screen coordinates or page instructions. Describe only what is visible."
            } else if wantsLook, Background.active, let tab = Background.tab, let jpeg = await BrowserBridge.shared.taskVisionScreenshot(of: tab) {
                image = jpeg.base64EncodedString()
            } else if wantsLook, !Background.active, let shotApp = obs.app {
                coordinateCapture = await Screenshot.capture(app: shotApp, window: obs.nativeWindow, elements: obs.elements, circled: circled)
                image = coordinateCapture?.base64
                if let notice = coordinateCapture?.notice { message += "\nScreenshot note: " + notice }
                if image == nil {
                    if let error = Screenshot.lastError { message += "\nScreenshot unavailable: " + error.hint }
                    else if let blank = Screenshot.lastBlank { message += "\n" + blank.hint }
                }
            }
            if wantsLook && image == nil { message += "\nVisual input unavailable for this observation. Do not infer pixels or use screenshot coordinates; use semantic targets or request a fresh look." }
            if image != nil { message += "\nVisual input: " + session.visionDelivery.rawValue + (assetInput == nil ? ". Screenshot coordinates are encoded image pixels." : ". The attachment is an image asset; never use its pixels as screen coordinates.") }
            wantsLook = false
            // An unchanged screen is one line, not the whole list again (less to read, faster replies).
            let full = obs.text
            let screenUnchanged = full == lastScreen
            var screen = "Screen: unchanged since your last look."
            if !screenUnchanged || image != nil {
                // The whole list when the model may not have the last one in mind: the first turn, a screenshot (its
                // boxes carry e-ids), the turn after one, a failed step, another app or window, the fast helper's
                // turns, and every 6th turn; otherwise only what changed since.
                let fresh = turn == 0 || image != nil || lookedLastTurn || failures > 0 || turn - lastFullTurn >= 6
                    || !fast.leadHasContinuity
                screen = fresh ? full : Self.screenText(obs, since: shown) ?? full
                if screen == full { lastFullTurn = turn } else { log("  screen: changes only (\(screen.count) of \(full.count) chars)") }
            }
            lastScreen = full
            shown = obs
            lookedLastTurn = image != nil
            if image != nil, assetInput == nil { lastVisualAt = Date() }
            // Anything the user added mid-task comes first: it can change the plan.
            if !addedNotes.isEmpty {
                message = "The user added while you were working (take it into account; it may change the plan):\n"
                    + addedNotes.map { "- \($0)" }.joined(separator: "\n") + "\n\n" + message
                addedNotes = []
            }
            // The closing line keeps replies to the bare JSON: without it half of them open with a tool-call tag first
            // (still parsed, but slower and wasted output).
            let turnText = message + "\n\n" + screen + (image != nil && assetInput == nil ? "\n(Screenshot attached: red boxes are tagged with the same e<N> ids.\(circled != nil ? " The yellow loop is what the user circled." : ""))" : "")
                + "\n\nReply with the JSON object only, starting with {"

            guard !Task.isCancelled, isRunning else { return }
            phase = .thinking
            buddy.mood = .thinking
            let t0 = Date()
            var context = ActionContext(app: obs.app, elements: obs.elements, fingerprint: obs.fingerprint,
                                        page: obs.page, webArea: obs.webArea)
            context.seen = obs.page
            context.identity = obs.app.flatMap(AXEngine.identity(of:))
            context.nativeWindow = obs.nativeWindow
            context.coordinateCapture = coordinateCapture
            // The reply streams in: its first action starts as soon as it's written, while the model writes the rest
            // (a batch's first step no longer waits for the whole reply). EARLY_START=off turns it off.
            let (partials, sink) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let sent = message, failed = failures, shot = image
            let stream: @Sendable (String) -> Void = { text in _ = sink.yield(text) }
            let partial = Self.earlyStartOn ? stream : nil
            let measuredRunID = runID
            let replying = Task { @MainActor () throws -> String in
                let modelStart = ProcessInfo.processInfo.systemUptime
                defer {
                    if self.runID == measuredRunID { self.modelSeconds += ProcessInfo.processInfo.systemUptime - modelStart }
                    sink.finish()
                }
                return try await fast.reply(to: turnText, message: sent, image: shot, failures: failed, lead: session, partial: partial)
            }
            var early: (action: [String: Any], result: ActionResult, target: WorkflowStep.Target?)?
            for await text in partials {
                if firstTokenMilliseconds == nil { firstTokenMilliseconds = Date().timeIntervalSince(t0) * 1_000 }
                guard let first = Brain.firstAction(inPartial: text) else { continue }
                if Self.startsEarly(first), Self.canonical(first) != lastFirst, addedNotes.isEmpty, !Task.isCancelled {
                    phase = .acting
                    buddy.mood = .acting
                    log("  early start: \(FastLane.brief(first)) (while the model writes the rest; committed prefix, read-only class)")
                    lastTarget = nil
                    let result = await perform(first, context: &context)
                    early = (first, result, lastTarget)
                }
                break
            }
            let reply: String
            do { reply = try await withTaskCancellationHandler { try await replying.value } onCancel: { replying.cancel() } } catch {
                if Task.isCancelled { return }
                return finish(ok: false, error.localizedDescription)
            }
            if Task.isCancelled { return }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log("turn \(turn) · \(ms) ms · \(fast.tag)\(reply.prefix(300))")
            Replay.Recorder.shared.turn(reply: reply, ms: ms)
            turnCount += 1
            if fast.tag.hasPrefix("fast") { fastTurnCount += 1 }
            if image != nil { lookCount += 1 }

            guard let json = Brain.json(from: reply) else {
                message = "Your last reply wasn't a JSON object. Reply with JSON only."
                    + (early.map { "\n(Its first step already ran: \(FastLane.brief($0.action)) → \($0.result.summary))" } ?? "")
                continue
            }
            let say = (json["say"] as? String) ?? ""
            // A bare action ({"do":"ask",…}) instead of the wrapper is still a clear intent.
            let actions = (json["actions"] as? [[String: Any]]) ?? (json["do"] is String ? [json] : [])
            let isDone = json["done"] as? Bool == true
            // The model saw the last failure and chose to do nothing (usually to finish): that's its answer to it,
            // so it no longer blocks finishing. Without this a failed step before a plain "done" loops to the step cap.
            if actions.isEmpty { failures = 0 }
            if !say.isEmpty, !isDone {
                narration = say
                TaskStore.shared.update(taskRecordID, stage: journalText(say), completedSteps: steps.filter { $0.state == .ok }.count)
            }

            // A loop is the same actions three times with nothing changing (scrolling on through a page isn't one);
            // turns with no actions (thinking, finishing) never are. The first time, the actions aren't run again:
            // the model is told to change method, with a screenshot. Only the same loop after that stops the run.
            // The same step while the screen keeps changing is progress (Next through a wizard, pages of results):
            // only a long run of it (12) counts, and the step cap bounds the rest.
            let signature = actions.map { "\($0)" }.joined()
            let same = !actions.isEmpty && signature == lastSignature
            sameRuns = same ? sameRuns + 1 : 0
            repeats = same && (screenUnchanged || failures > 0) ? repeats + 1 : 0
            lastSignature = signature
            if !actions.isEmpty, escalated.contains(signature) && repeats >= 1 || ((repeats >= 2 || sameRuns >= 12) && escalated.count >= 2) {
                return finish(ok: false, "I kept trying the same thing, so I stopped")
            }
            if repeats >= 2 || sameRuns >= 12 {
                let why = repeats >= 2 ? "3× with nothing changing" : "\(sameRuns + 1)×"
                escalated.insert(signature)
                repeats = 0; sameRuns = 0
                wantsLook = true
                log("  loop: same actions \(why) — asking for another method")
                steps.append(Step(text: "Same step repeated — trying another way", state: .info))
                message = "Your last reply repeated the same actions again (\(actions.map(FastLane.brief).joined(separator: ", "))) "
                    + "and they aren't getting anywhere, so they were NOT run again. That approach failed: don't send it again. "
                    + "Use a different method, in this order: the keyboard (tab/shift+tab to reach the control, space or return to press it, "
                    + "arrows in lists, esc to close a popup), then the other id for it (its e-id from Accessibility instead of the w-id, or "
                    + "the reverse), then click by x/y on the screenshot attached now. If the goal can't be reached, finish with done:true and say what's blocking."
                    + (early.map { " (Only its first step had already started: \(FastLane.brief($0.action)) → \($0.result.summary))" } ?? "")
                continue
            }

            if !actions.isEmpty {
                phase = .acting
                buddy.mood = .acting
            }
            var results: [String] = []
            // Part of the batch didn't run because the page changed under it (not a failure, but not finished either).
            var cutShort = false
            // The action started early is this batch's first step; if the final reply doesn't start with it after all,
            // the model still hears that it ran.
            let earlyIsFirst = early.map { e in actions.first.map { Self.canonical($0) == Self.canonical(e.action) } ?? false } ?? false
            if let e = early, !earlyIsFirst {
                results.append("(already done while you were writing: \(FastLane.brief(e.action)) → \(e.result.summary))")
                if !e.result.ok { failures += 1 }
            }
            lastFirst = actions.first.map(Self.canonical) ?? ""
            for (i, action) in actions.enumerated() {
                guard !Task.isCancelled else { return }
                // The user added something mid-batch: the rest of this plan may be outdated, re-plan first.
                if !addedNotes.isEmpty {
                    results.append("(stopped before step \(i + 1): the user added something — see above)")
                    break
                }
                lastTarget = nil
                var action = action
                let kind = (action["do"] as? String ?? "").lowercased()
                // click/type/open_* already wait for the screen to settle; a wait stacked on top is mostly dead time.
                if kind == "wait", i > 0,
                   ["click", "type", "open_url", "open_app", "key"].contains(actions[i - 1]["do"] as? String ?? ""),
                   (action["ms"] as? Int ?? 600) > 1000 {
                    action["ms"] = 1000
                }
                // The ids the model gave point into the page list it was shown; if the page was listed again since
                // (a field appeared or went away), use the same element's id in the current list — never a neighbour's.
                if Self.isWebRef(action["id"]), let seen = context.seen, let now = context.page {
                    guard let n = Self.webIndex(action["id"]), let id = Self.rematch(n, from: seen, to: now) else {
                        let was = Self.webIndex(action["id"]).flatMap { n in seen.elements.first { $0.index == n } }
                        results.append("\(i + 1). (not done: the page changed after the steps above, and \(action["id"] ?? "?")"
                                       + "\(was.map { " (\($0.role) \($0.text.prefix(40).debugDescription))" } ?? "") isn't there anymore; "
                                       + "the rest of this batch was skipped — the fresh page is below)")
                        cutShort = true
                        break
                    }
                    if id != n {
                        log("    w\(n) is now w\(id) (the page re-listed)")
                        action["id"] = "w\(id)"
                    }
                }
                let result: ActionResult
                if i == 0, earlyIsFirst, let e = early {
                    result = e.result
                    lastTarget = e.target   // so the step is recorded with the element it acted on
                } else {
                    result = await perform(action, context: &context)
                }
                if result.ok, !runDry { record(action) }
                // Opening something was only a step if more work followed in it (see `keepsFrontApp`).
                if result.ok, ["click", "type", "key", "choose", "upload", "scroll", "applescript", "fill", "autofill"].contains((action["do"] as? String ?? "").lowercased()) {
                    openedLast = false
                }
                if case .look = result.effect { wantsLook = true }
                results.append("\(i + 1). \(result.summary)")
                if !result.ok { failures += 1; break }
                failures = 0
                // A click or key that brought another app forward (a link opening the browser, a share sheet): the rest
                // of the batch was planned for the old screen, so stop here; the next turn looks at the new app.
                // (In a background run what's in front is the user's doing, never a handoff.)
                if ["click", "key", "type"].contains(kind), !runDry, !Background.active, i + 1 < actions.count, let current = context.app,
                   let other = AXEngine.handoff(from: current), other.bundleIdentifier != Bundle.main.bundleIdentifier {
                    log("    \(other.cleanName ?? "another app") came to the front")
                    results.append("(\(other.cleanName ?? "another app") came to the front, so the rest of this batch was skipped — its screen is below)")
                    context.app = other
                    cutShort = true
                    break
                }
                // Forms re-render as they're filled (LinkedIn adds and drops fields): before the next step by w-id, list
                // the page again so it lands on the element the model meant, not whatever now sits at that index.
                if ["type", "choose", "click", "upload", "autofill"].contains(kind), context.page != nil, !runDry,
                   actions[(i + 1)...].contains(where: { Self.isWebRef($0["id"]) }) {
                    await relist(&context)
                }
            }
            if !isRunning { return }
            app = context.app
            let workerUpdates = pool.drainResults()
            if !workerUpdates.isEmpty {
                results.append(workerUpdates)
                steps.append(Step(text: workerUpdates, state: .info))
            }
            // Never declare success while assigned work is still outstanding. Await completions without burning
            // model turns, then let the lead reconcile the results rather than returning a pre-written answer.
            if isDone, failures == 0, pool.hasPending {
                phase = .thinking
                narration = "Waiting for \(pool.pendingCount) delegated task(s)"
                lastProgress = Date()
                let heartbeat = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(10)) } catch { return }
                        self?.lastProgress = Date()
                    }
                }
                let collected = await pool.collect(wait: true, timeout: 300)
                heartbeat.cancel()
                guard !Task.isCancelled else { return }
                steps.append(Step(text: "Delegated work:\n" + collected, state: .info))
                message = "Results:\n" + results.joined(separator: "\n") + "\nDelegated worker results:\n" + collected
                    + "\nReview these results before finishing. If jobs remain, collect with wait:true; don't duplicate their work."
                continue
            }
            if isDone, failures == 0, !workerUpdates.isEmpty || actions.contains(where: { ($0["do"] as? String) == "collect" }) {
                message = "Results:\n" + results.joined(separator: "\n")
                    + "\nReview the collected worker evidence and produce the combined answer before finishing."
                continue
            }
            if isDone, actions.isEmpty, failures > 0 || TaskCompletionPolicy.reportsFailure(say) {
                finish(ok: false, say.isEmpty ? "The last action failed; the task was not completed." : say)
                return
            }
            // A final reply may carry last actions; finish once they ran (unless one failed).
            if isDone, failures == 0, !addedNotes.isEmpty || cutShort {
                message = "Results:\n" + results.joined(separator: "\n")
                    + (cutShort ? "\n(You were about to finish, but not all of your last steps ran.)" : "\n(You were about to finish, but the user added something.)")
                continue
            }
            // A question answered with a status label ("Your roll number") instead of the answer: ask once for the answer.
            if isDone, failures == 0, !askedForAnswer, Self.isQuestion(request), Self.looksLikeLabel(say) {
                askedForAnswer = true
                message = (results.isEmpty ? "" : "Results:\n" + results.joined(separator: "\n") + "\n")
                    + "Your final say (\"\(say)\") is a label, not the answer. The user asked a question: finish again with done:true "
                    + "and a say that contains the answer itself, as a full sentence (e.g. \"Your roll number is 1601…\")."
                continue
            }
            // Screenshots taken for a write-up but never put in the doc are lost work: paste them before finishing.
            let unpasted = snaps.filter { !$0.pasted }.count
            if isDone, failures == 0, unpasted > 0, snapPushes < 2, TaskCompletionPolicy.requestsWriteUp(request) {
                snapPushes += 1
                let prefix = results.isEmpty ? "" : "Results:\n\(results.joined(separator: "\n"))\n"
                let verb = unpasted == 1 ? " is" : "s are"
                message = "\(prefix)You were about to finish, but \(unpasted) screenshot\(verb) not in the write-up doc yet. "
                    + "Go to the doc (open_app its browser, switch to its tab, or open_url https://docs.new if there is none), "
                    + "click at the end of the document body, key cmd+down, then paste_snaps; check with look that they went in. "
                    + "Then carry on with any steps of the task that remain; finish only when everything is done."
                continue
            }
            // The verdict reads the whole reply: a short say ("Step 6 captured") often comes with prose after the JSON
            // that says how much is left.
            if isDone, failures == 0, pushedOn < 3, Self.saysUnfinished(say) || Self.saysUnfinished(String(reply.suffix(1500))) {
                pushedOn += 1
                log("  not done yet: “\(say.prefix(80))” — carrying on")
                message = (results.isEmpty ? "" : "Results:\n" + results.joined(separator: "\n") + "\n")
                    + "You were about to finish, but your own summary says work remains (\"\(say.prefix(200))\"). The user wants the "
                    + "whole task done without having to say continue: do the remaining steps now. Finish only when everything is "
                    + "done, or when something truly needs the user (say exactly what)."
                continue
            }
            if isDone, failures == 0, let pendingVerification {
                completionBlocks += 1
                if completionBlocks >= 3 {
                    finish(ok: false, "The last action (" + pendingVerification.kind + ") remains unverified. Check its task window before retrying; it was not repeated.")
                    return
                }
                message = "The \(pendingVerification.kind) input was delivered but its outcome is unverified. Do not repeat it or claim completion. Use {\"do\":\"verify\",\"text\":\"<expected confirmation actually visible>\"}, or verify a current url, field value/id, or changed saved-file path. A closed dialog or generic visual change is insufficient. Read first if needed."
                continue
            }
            if isDone, !runDry, deliveredImageOutputs < requiredImageOutputs {
                imageCompletionBlocks += 1
                if imageCompletionBlocks >= 3 {
                    finish(ok: false, "Delivered \(deliveredImageOutputs) of \(requiredImageOutputs) requested images. " + say); return
                }
                message = "The user requested actual image delivery. Only \(deliveredImageOutputs)/\(requiredImageOutputs) images have acknowledged Telegram delivery. Use images to discover real sources, then image with index and send:true. Descriptions and URLs do not fulfill this request. If delivery is blocked, report that failure honestly."
                continue
            }
            if isDone, failures == 0, !runDry, completionEvidence.needsVerification {
                message = "Before claiming the task is complete, independently verify its final result with a verify action: expected visible text, exact URL, a field value/id, or saved-file path (with contains for expected file contents). Check the user's actual objective after the last edit. Process exit zero, a delivered gesture, or your own done:true is not completion evidence. Do not repeat an input to obtain evidence."
                continue
            }
            if isDone, failures == 0 {
                finish(ok: true, say.isEmpty ? "Done" : say)
                if !runDry, !isTest {
                    // Credit the remembered facts this run put to work, so they rank higher next time.
                    let output = (steps.map(\.text) + trace.compactMap(\.text) + [say]).joined(separator: "\n")
                    Memory.noteUsed(Memory.used(among: shownFacts, output: output, apps: visitedApps, hosts: visitedHosts))
                }
                if !runDry { await learn(from: session) }
                return
            }
            if actions.isEmpty { results.append("(no actions taken)") }
            message = "Results:\n" + results.joined(separator: "\n")
        }
        finish(ok: false, "Ran out of steps, so I stopped. Last done: \(steps.last?.text ?? "nothing"). Check the screen before retrying.")
    }

    /// Questions already checked against memory before asking (each once, so a real ask then goes through).
    private var memoryCheckedAsks: Set<String> = []
    /// The last turn's first action (canonical JSON): the same one again isn't started early, since a repeat may be
    /// a loop the turn's checks stop.
    private var lastFirst = ""

    /// Streamed replies start their first action before the model has finished writing (EARLY_START=off stops it).
    static var earlyStartOn: Bool { !["off", "0", "no", "false"].contains((Config.value("EARLY_START") ?? "on").lowercased()) }

    /// Steps worth starting while the model is still writing: ones that act on the screen, not questions, waits,
    /// looks or anything sent outside the screen (email, shell, scripts, schedules).
    /// Only actions without lasting consequence may start from a reply prefix: the final reply can still change the plan
    /// (a different target, an invalid envelope) and an input already delivered cannot be retracted. Clicks, typing,
    /// keys, choices, uploads and autofill wait for the complete, validated reply.
    nonisolated static func startsEarly(_ action: [String: Any]) -> Bool {
        ["scroll", "read", "review"].contains((action["do"] as? String ?? "").lowercased())
            && ActionContract.validate(action) == nil
    }

    nonisolated static func canonical(_ action: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: BrowserNavigation.normalizedAction(action), options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "\(action)"
    }

    /// Memory facts this run was shown (up front, as notes for a site or app, or recalled): the ones the run then used
    /// rank higher next time.
    private var shownFacts: Set<String> = []
    /// The page labels memory was last matched against (so an unchanged page isn't matched again).
    private var lastPageMemory = ""
    /// Form fields seen this run (by site and field: question, first and latest value), and the values the agent itself
    /// entered, so that afterwards the answers the user typed in by hand can be kept (see `learnFromForms`).
    private var formSeen: [String: FormField] = [:]
    private var agentEntered: Set<String> = []
    private struct FormField { let question: String; let first: String; var last: String }
    /// Sites and apps this run worked in (for crediting scoped notes, and telling learning where it was).
    private var visitedHosts: Set<String> = [], visitedApps: Set<String> = []
    /// Times this run was told to carry on after finishing with work left (see `saysUnfinished`).
    private var pushedOn = 0
    /// Times this run was sent back to paste screenshots it took before finishing.
    private var snapPushes = 0
    /// Questions the profile already answered this run (the next time the model asks one, it's asked for real).
    private var profileOffered: Set<String> = []
    /// This run's numbers for runs.jsonl: model turns, turns the fast helper took, screenshots sent.
    private var turnCount = 0, fastTurnCount = 0, lookCount = 0
    private var modelSeconds = 0.0
    private var phaseMilliseconds: [String: Double] = [:]
    private var firstTokenMilliseconds: Double?
    private func recordPhase(_ name: String, since start: TimeInterval) {
        phaseMilliseconds[name, default: 0] += (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    /// One JSON line per run in ~/Library/Logs/Clinqy/runs.jsonl (`clinqy stats` sums them up).
    private func recordStats(ok: Bool, answer: String) {
        var row: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: started), "request": String(request.prefix(160)), "ok": ok,
            "stopped": !ok && answer == "Stopped", "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
            "turns": turnCount, "fast_turns": fastTurnCount, "screenshots": lookCount,
            "vision_policy": Config.value("VISION_POLICY") ?? "auto", "vision_delivery": session?.visionDelivery.rawValue ?? "unknown",
            "goal_verified": !completionEvidence.needsVerification,
            "steps": steps.count, "failed_steps": steps.filter { $0.state == .failed }.count, "app": targetApp?.cleanName ?? "",
        ]
        row["model_seconds"] = modelSeconds
        row["phase_ms"] = phaseMilliseconds
        if let firstTokenMilliseconds { row["first_token_ms"] = firstTokenMilliseconds }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = Self.logURL.deletingLastPathComponent().appendingPathComponent("runs.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
    /// What the user typed in answer to questions this run (their own words, unlike anything read on screen).
    private var userAnswers: [String] = []

    /// The application tracker in the result card (menu: Applications…).
    func showApplications() {
        let card = Applications.card
        result = card
        onResult()
    }
    private var reviewedForm = false

    /// Reads every answer on the page's form and shows it as a card: question → answer, empty required ones flagged.
    private func reviewForm(_ page: BrowserBridge.Page) async -> ActionResult {
        let line = begin("Review the form")
        guard let r = try? await BrowserBridge.shared.perform("review", on: page, timeout: 8),
              let items = r["items"] as? [[String: Any]], !items.isEmpty else { return end(line, fail("no form fields found on this page")) }
        reviewedForm = true
        let missing = r["missing"] as? [String] ?? []
        let cards = items.map { i -> ResultCard.Item in
            let q = i["q"] as? String ?? "?", a = i["answer"] as? String ?? ""
            let flag = a.isEmpty ? (i["required"] as? Bool == true ? "⚠️ required — empty" : "(empty)") : nil
            return ResultCard.Item(title: q, subtitle: a.isEmpty ? nil : a, detail: flag, link: nil)
        }
        let messages = r["messages"] as? [String] ?? []
        let note = (missing.isEmpty ? "All required questions are answered." : "⚠️ \(missing.count) required unanswered: " + missing.joined(separator: "; "))
            + (messages.isEmpty ? "" : "\nPage says: " + messages.joined(separator: " · "))
        let card = ResultCard(title: "Check before submitting: \(String((r["title"] as? String ?? "form").prefix(50)))", text: note, items: cards)
        runResult = card
        result = card
        onResult()
        let summary = items.map { "- \($0["q"] as? String ?? "?"): \(($0["answer"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(empty)")" }.joined(separator: "\n")
        return end(line, .init(ok: true, summary: "review shown to the user. \(note)\n\(summary)"))
    }

    /// Fills every visible field, dropdown and radio group the job profile answers, in this one action (each still a
    /// real, checked type / choose / click), and tells the model what's left. Never submits anything.
    private func autofill(context: inout ActionContext) async -> ActionResult {
        guard let page = context.page else { return fail("autofill needs a web page") }
        let profile = Profile.current
        let plan = FormFill.plan(page) { Profile.answer(for: $0, in: profile) }
        log("  autofill: \(plan.steps.count) to fill, \(plan.open.count) open")
        var filled: [String] = [], failed: [String] = []
        for step in plan.steps {
            guard !Task.isCancelled, addedNotes.isEmpty else { break }
            var action = step.action
            // Forms re-render as they're filled: aim at the same field in the latest listing.
            if let n = Self.webIndex(action["id"]), let now = context.page {
                guard let id = Self.rematch(n, from: page, to: now) else { failed.append("\(step.question) (the field went away)"); continue }
                action["id"] = "w\(id)"
            }
            lastTarget = nil
            let r = await perform(action, context: &context)
            if r.ok {
                filled.append("\(step.question) → \(step.answer.prefix(60))")
                if !runDry { record(action) }
            } else {
                failed.append("\(step.question): \(r.summary.replacingOccurrences(of: "FAILED: ", with: "").prefix(120))")
            }
            if context.page != nil, !runDry { await relist(&context) }
        }
        var summary = filled.isEmpty ? "nothing on screen that the profile answers" : "filled \(filled.count) from the profile:\n"
            + filled.map { "- \($0)" }.joined(separator: "\n")
        if !failed.isEmpty { summary += "\ncouldn't fill (do these yourself):\n" + failed.map { "- \($0)" }.joined(separator: "\n") }
        if !plan.open.isEmpty {
            summary += "\nnot in the profile (fill from memory/resume, or ask the user once; remember_answer what they say):\n"
                + plan.open.map { "- \($0)" }.joined(separator: "\n")
        }
        if plan.uploads > 0 { summary += "\n\(plan.uploads) upload field\(plan.uploads == 1 ? "" : "s") here: upload the resume yourself." }
        if let now = context.page, now.below > 0 { summary += "\n\(now.below) more fields/buttons below: scroll, then autofill again." }
        // A partial fill is still progress; only "nothing done and something broke" is a failure.
        return filled.isEmpty && !failed.isEmpty ? fail(summary) : .init(ok: true, summary: summary)
    }

    /// Requests whose point is what ends up on screen ("open Spotify", "show me my calendar", "search …"): the app
    /// they end in stays in front instead of the user's previous one coming back.
    nonisolated static func keepsFrontApp(_ request: String) -> Bool {
        request.range(of: #"(?i)^\s*(please |can you |could you )?(open|launch|start|switch to|go to|take me to|show( me)?|play|search|find|look up|google|navigate|bring up|pull up)\b"#,
                      options: .regularExpression) != nil
    }

    /// A request that may lead to an application form (where the job-application profile applies).
    static func mayMeetForms(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(appl(y|ication)|job|internship|intern|form|fill|resume|cv|role|position|opening|hiring|linkedin|naukri|greenhouse|lever|workday)"#,
                   options: .regularExpression) != nil
    }

    /// "Submit with your resume attached?", "Should I go ahead?": asks for a decision, not for details.
    nonisolated static func isConfirmation(_ text: String) -> Bool {
        // Only the question itself: "(I won't submit the form yet)" after it isn't what's being asked.
        let question = text.firstIndex(of: "?").map { String(text[...$0]) } ?? text
        // "What/Who should I put for …?" asks for a detail, not for a go-ahead.
        if question.range(of: #"(?i)\b(what|which|who|whom|where|when|how much|how many)\b.*\bshould i (put|enter|use|write|fill|type|say|give|choose|select|answer|add|list|mention)\b"#,
                          options: .regularExpression) != nil { return false }
        return question.range(of: #"(?i)\b(submit(?:ting)?|approv(?:e|al)|proceed|send it|should i|shall i|go ahead|ready to|confirm|okay to|ok to)\b"#, options: .regularExpression) != nil
    }

    /// The profile's answer to an ask that's a single form question it covers, as (question, answer).
    static func profileAnswer(for action: [String: Any]) -> (String, String)? {
        guard let q = action["question"] as? String, !isConfirmation(q), action["sensitive"] as? Bool != true,
              q.filter({ $0 == "?" }).count <= 1 else { return nil }
        // Only the question itself: a side remark after it ("…? I'll enter your name as …") isn't what's asked.
        let asked = q.firstIndex(of: "?").map { String(q[...$0]) } ?? q
        guard let a = Profile.answer(for: asked) else { return nil }
        // A multiple-choice question takes the profile's answer only when it is one of the choices.
        let options = (action["options"] as? [String] ?? []).map { $0.lowercased() }
        if !options.isEmpty, !options.contains(where: { $0.contains(a.lowercased()) || a.lowercased().contains($0) }) { return nil }
        return (q, a)
    }

    /// A question for the user's own details (name, email, phone, college…), which memory may already hold.
    nonisolated static func asksForPersonalDetails(_ question: String) -> Bool {
        // Confirmations ("Submit with your resume attached?") aren't requests for details.
        if isConfirmation(question) { return false }
        // "your (full) name", "your phone number": the detail right after "your" — not any "you … name" in a sentence
        // ("Which session did you attend? (I'll use the name …)" asks for a choice, not for a detail).
        return question.range(of: #"(?i)\byour\s+(\w+\s+){0,2}?(name|e-?mail|phone|mobile|number|college|university|cgpa|gpa|degree|graduat\w*|linkedin|github|portfolio|address|city|gender|birth|dob|age|skills?|stack|experience|resume|cv)\b"#,
                       options: .regularExpression) != nil
    }

    /// "What is…?", "tell me…", "who/where/when/which/how…" — requests that want information back.
    static func isQuestion(_ request: String) -> Bool {
        let r = request.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if r.hasSuffix("?") { return true }
        return r.range(of: #"^(so |and |ok |okay )?(what|what's|whats|who|who's|where|when|which|how|tell me|do you know|remind me)\b"#,
                       options: .regularExpression) != nil
    }

    /// A short title with nothing in it ("Your roll number", "Found it"): no digits, no verb like "is", few words.
    static func looksLikeLabel(_ say: String) -> Bool {
        let words = say.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= 5, !say.contains(where: \.isNumber), !say.contains("@") else { return words.isEmpty }
        let verbs: Set<String> = ["is", "are", "was", "were", "it's", "isn't", "can't", "don't", "no", "not", "yes", "has", "have"]
        return !words.contains { verbs.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
    }

    private func trackForm(_ page: BrowserBridge.Page, host: String) {
        // A form, not a chat or search box: a few fields on the page.
        let fields = page.elements.filter { $0.editable || $0.dropdown }
        guard fields.count >= 3 else { return }
        for el in fields {
            guard let q = (el.question ?? el.placeholder ?? (el.text.isEmpty ? nil : el.text))?
                    .trimmingCharacters(in: .whitespacesAndNewlines), q.count >= 3, q.count <= 200 else { continue }
            let key = host + "|" + (el.key.isEmpty ? q : el.key)
            let v = (el.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if formSeen[key] == nil { formSeen[key] = FormField(question: q, first: v, last: v) } else { formSeen[key]!.last = v }
        }
    }

    nonisolated static func squashValue(_ v: String) -> String { v.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Never kept from a form: secrets and codes, and free text that isn't an answer about the user.
    private static let notAnAnswer = #"(?i)\b(password|passcode|otp|one[- ]time|code|pin|cvv|cvc|card|expiry|captcha|ssn|aadhaar|pan|search|message|comment|chat|reply|compose|note|caption|tweet|post|subject|body|cover letter|description|why)\b"#

    /// Answers the user typed into a form by hand during the run (a field that changed, to a value the agent didn't
    /// enter): kept in the application profile like answers they give when asked, so the next form that asks gets
    /// them filled. Only short answers to plain questions, never secrets, and nothing already known.
    private func learnFromForms() {
        guard qa == nil, Self.mayMeetForms(request) || !formSeen.isEmpty else { return }
        let known = (Memory.facts + [Profile.promptBlock]).joined(separator: "\n").lowercased()
        var kept = 0
        for f in formSeen.values.sorted(by: { $0.question < $1.question }) where kept < 15 {
            let v = f.last
            guard !v.isEmpty, v != f.first, v.count <= 160, !v.hasPrefix("••"),
                  !agentEntered.contains(Self.squashValue(v)),
                  f.question.range(of: Self.notAnAnswer, options: .regularExpression) == nil,
                  v.range(of: #"(?i)^(select|choose|--|please select|pick)"#, options: .regularExpression) == nil,
                  Profile.answer(for: f.question) != v,
                  v.count < 4 || !known.contains(v.lowercased()) else { continue }
            guard Profile.remember(question: f.question, answer: v) else { log("🧠 couldn't save the form answer for “\(f.question.prefix(70))” (profile write failed)"); continue }
            kept += 1
            log("🧠 learned from the form: “\(f.question.prefix(70))” → \(v.prefix(60))")
        }
    }

    /// After a task, keep anything lasting it revealed about the user (people, preferences, usual apps and
    /// places) and know-how for the sites and apps it worked in, so next time is faster. The model sees only the
    /// facts closest to this task (not the whole memory) and answers with edits — add, update, remove — so memory
    /// stays one clean line per thing instead of piling up near-duplicates. Runs in the background once the user
    /// already has their answer.
    private func learn(from session: AgySession) async {
        guard !Task.isCancelled, !isTest else { return }
        learnFromForms()
        let about = ([request] + steps.suffix(25).map(\.text) + [answer]).joined(separator: "\n")
        let near = Memory.relevant(to: about, app: targetApp?.cleanName, limit: 30).facts
        let places = (visitedHosts.sorted() + visitedApps.sorted()).joined(separator: ", ")
        let prompt = """
        The task is finished. Update what you remember from what this task revealed. Worth keeping: lasting facts \
        about the user — people and where to reach them (which app/chat), preferences (seats, airlines, food, tone), \
        usual apps, home/work city, frequent places, accounts or usernames — and know-how for a site or app that \
        cost you steps here and would save them next time (where something lives, a trick that worked, the name an \
        app must be opened with). Never passwords, card numbers, OTPs, one-off details, job applications (the \
        application tracker holds those) or what merely happened to be on screen.
        Explicit user corrections override older inferred facts. Keep their scope: a change for this task is not \
        a permanent preference unless the user says so. Update the old fact rather than adding a contradiction.
        Places this task worked in: \(places.isEmpty ? "(none)" : places)
        Related things you already remember (numbered):
        \(near.isEmpty ? "(nothing yet)" : near.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        Reply with JSON only: {"ops":[…]}, each op one of
          {"add":"<short fact>","scope":"site:<host>" | "app:<App name>" | null}   something new; scope only for know-how that matters just there
          {"update":<n>,"to":"<fact n, corrected or with the new detail>"}         fact n changed or gained a detail
          {"remove":<n>,"why":"<what this task showed>"}                            fact n is no longer true
        {"ops":[]} if nothing is new.
        """
        guard let reply = try? await session.send(prompt), let json = Brain.json(from: reply) else { return }
        var ops = json["ops"] as? [[String: Any]] ?? []
        if let legacy = json["facts"] as? [String] { ops += legacy.map { ["add": $0] } }
        let line = { (v: Any?) -> String? in
            guard let t = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count < 240 else { return nil }
            return t
        }
        let fact = { (v: Any?) -> String? in
            guard let n = (v as? NSNumber)?.intValue ?? Int(v as? String ?? ""), n >= 1, n <= near.count else { return nil }
            return near[n - 1]
        }
        var removed = 0
        Memory.performBatch {
            for op in ops {
                if let new = line(op["add"]) {
                    if let known = Memory.nearDuplicate(of: new) {
                        log("🧠 already known: \(known.prefix(80))")
                        continue
                    }
                    guard Memory.add(new, scope: Memory.Scope(op["scope"] as? String)) else { log("🧠 couldn't save to memory (write failed): \(new.prefix(80))"); continue }
                    log("🧠 remembered: \(new)\((op["scope"] as? String).map { " [\($0)]" } ?? "")")
                } else if let old = fact(op["update"]), let new = line(op["to"]), new != old {
                    // A rewrite keeps every email, link and number unless it's clearly the same fact with a new value.
                    let sameSubject = Set(Memory.words(old).map(Memory.stem)).intersection(Memory.words(new).map(Memory.stem)).count >= 2
                    guard MemoryTidy.safe(before: [old], after: [new], removed: []) || sameSubject && !Memory.details(new).isEmpty else {
                        log("🧠 update skipped (it would drop details): \(old.prefix(60))")
                        continue
                    }
                    if Memory.update(old, to: new) { log("🧠 updated: \(old) → \(new)") }
                } else if let old = fact(op["remove"]), removed < 2, !Memory.isProfile(old) {
                    // The old line stays in the log, so a wrong removal can be put back.
                    if Memory.remove(old, why: (op["why"] as? String).map { String($0.prefix(120)) }) {
                        removed += 1
                        log("🧠 forgot (\((op["why"] as? String ?? "superseded").prefix(60))): \(old)")
                    }
                }
            }
        }
        await MemoryTidy.runIfDue()
    }

    private func intro(_ request: String) -> String {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.cleanName)
        let date = Date().formatted(date: .complete, time: .shortened)
        var text = """
        Request: \(request)
        User: \(NSFullUserName()) · \(date)
        Running apps: \(running.joined(separator: ", "))
        Default browser: \(Launcher.defaultBrowserName ?? "unknown")
        """
        if parallelBrowserTasks != nil {
            text += "\nThis request explicitly asks for independent browser work in parallel. Before opening pages, split it into one complete goal per tab/task with {\"do\":\"parallel_browser\",\"tasks\":[\"first goal\",\"second goal\",\"third goal\"]}. Preserve the user's constraints in each goal. Children get separate browser tabs, models and verification, and can ask their own login questions. Only split genuinely independent goals; do not split dependent steps. The coordinator collects actual child results and finishes the group. Do not open each site sequentially yourself."
        }
        if telegramOwned {
            text += "\nThe user is talking to you through Telegram. Ask for missing input with ask; they can answer remotely. "
                + "Use short, concrete say messages describing the current stage. For forms and applications, use review after filling each page "
                + "and before finishing, so the user gets the actual field labels and answers. Use show for structured output. "
                + "Distinguish filled, waiting for approval, submitted and confirmed in the final answer. Include what changed, what remains, "
                + "and any confirmation number or result link that you actually saw. Never claim submission from filling alone. The execution mode was selected before starting; do not ask a second mode-selection question. Use tools in the selected mode; the runtime handles any unsupported action. CAPTCHA or login handoffs require the user to open the task on their Mac and finish the check themselves; keep the task paused until they explicitly report it is done."
        }
        if requiredImageOutputs > 0 {
            text += "\nThis task requires \(requiredImageOutputs) actual image output(s) to Telegram. Use images to discover source addresses, image to inspect actual pixels, then image with send:true. A text description or link is not delivery. Preserve this requirement in every parallel child goal. Never claim success without acknowledged media delivery."
        }
        if runBackground {
            text += Background.usesExtension
                ? "\nBackground web tasks use only Clinqy's own inactive tabs in the user's signed-in browser through the extension. Existing website sessions are shared with that profile. Never read or act on the user's other tabs. Browser password prompts or security dialogs may require the user. "
                : "\nBackground mode uses a separate headless Chrome process and profile. Worker sign-ins are separate; ask the user to sign in through the Worker Chrome menu if needed. "
            text += "Use open_url to open a task tab. "
                + "Prefer files, PDF, media and supported service actions without opening apps. "
                + "No Finder, native app input, clipboard, arbitrary shell or AppleScript is permitted in background mode. "
                + "Use ask for missing input. Native-only work requires an explicit switch to foreground."

        }
        // A write-up carried over from the last run: say what's already captured, so the model neither re-snaps old
        // tabs nor thinks there's nothing to paste.
        if !snaps.isEmpty {
            let waiting = snaps.filter { !$0.pasted }
            let pending = waiting.isEmpty ? ")" : "; not pasted yet: " + waiting.map { $0.caption.prefix(60).debugDescription }.joined(separator: ", ") + " — paste_snaps puts them in)"
            let saved = snapFolder.map { "; saved in \($0.path)" } ?? ""
            let last = snaps.last!.caption.prefix(80).debugDescription
            text += "\nWrite-up screenshots so far in this task: \(snaps.count) (\(snaps.count - waiting.count) already pasted in the doc\(pending)\(saved). Last captioned: \(last)."
        }
        if let selected = selectedText, !selected.isEmpty {
            text += "\nSelected text (the user highlighted this before asking; \"this\", \"it\", \"that\" usually mean it):\n\"\"\"\n\(selected.prefix(4000))\n\"\"\""
        }
        if !selectedFiles.isEmpty {
            text += "\nFiles selected in Finder (\"this\", \"these\", \"it\" usually mean them):\n" + selectedFiles.map { "- \($0.path)" }.joined(separator: "\n")
        } else if !runBackground, let app = targetApp, let doc = AXEngine.documentURL(of: app), doc.isFileURL {
            text += "\nFile open in \(app.cleanName ?? "the front app"): \(doc.path)"
        }
        // Only when the request points at it: a copied password or key shouldn't ride along with every request.
        if selectedText == nil, selectedFiles.isEmpty, let copied,
           Router.refersToContext(request) || request.range(of: #"(?i)\b(clipboard|copied|paste|pasted)\b"#, options: .regularExpression) != nil {
            let when = Clipboard.describeAge(copied.age)
            if let t = copied.text {
                text += "\nClipboard (the user copied this \(when); nothing is selected, so \"this\", \"it\", \"that\" usually mean it — "
                    + "but only if the request fits it, e.g. \"translate this\", \"reply to this\", \"add this to my tracker\"):\n\"\"\"\n\(t.prefix(4000))\n\"\"\""
            }
            if !copied.files.isEmpty {
                text += "\nFiles on the clipboard (copied \(when); \"this\"/\"these\" may mean them):\n" + copied.files.map { "- \($0.path)" }.joined(separator: "\n")
            }
        }
        if runDry {
            text += "\nDRY RUN: the user wants to see what you'd do without anything happening. Clicks, typing, keys, choosing, "
                + "uploads, emails, file/calendar changes and scripts are only shown on screen, not done — the screen won't change "
                + "after them. Opening apps/websites, scrolling, reading and looking do happen. Plan the whole task as if each "
                + "shown step worked, go as far as you can, then finish with done:true and a short summary of the plan."
        }
        if let circled = annotation {
            let r = circled.rect
            text += "\nThe user circled an area on screen before asking (\"this\", \"here\", \"that\" usually mean it): "
                + "x \(Int(r.minX))–\(Int(r.maxX)), y \(Int(r.minY))–\(Int(r.maxY)) in screen points. It's the yellow loop on the first screenshot."
        }
        if let earlier = continuation {
            if let task = earlier.task, task != earlier.request {
                text += "\n\nThe task this is all part of (the user's own instructions, still in force until everything is done):\n\(task)"
            }
            text += """

            This continues an earlier task (\(earlier.date.formatted(date: .abbreviated, time: .shortened))):
            Earlier request: \(earlier.request)
            What happened: \(earlier.steps.suffix(12).joined(separator: "; "))
            Earlier result: \(earlier.answer)\(earlier.result.map { "\nEarlier output: \($0.plain.prefix(1500))" } ?? "")
            """
            if let doc = earlier.readText {
                text += "\nThe document the earlier task read (use this; don't open it again unless it's cut off):\n\(doc)"
            }
            if !earlier.ok {
                text += "\nThe earlier task didn't finish. Pick up where it stopped (check what's already on screen, e.g. a half-typed message) instead of starting over."
            }
        }
        let skills = Skills.shared.promptText
        if !skills.isEmpty {
            text += "\nSkills the user taught you (follow the matching one's steps when a request fits; ask for any missing parameters):\n" + skills
            if let hint = Router.skillHint(request, names: Skills.shared.all.map(\.name)) {
                text += "\n(This request looks like the skill “\(hint)”: use its steps unless it clearly doesn't fit.)"
            }
        }
        // Only the memory that matters for this request (plus core facts); the rest is one recall away.
        let context = [request, targetApp?.cleanName ?? "", selectedText ?? "", continuation?.request ?? ""].joined(separator: " ")
        let (facts, omitted) = Memory.relevant(to: context, app: targetApp?.cleanName)
        shownFacts.formUnion(facts)
        let profile = facts.filter(Memory.isProfile), other = facts.filter { !Memory.isProfile($0) }
        text += "\nThe user's profile (their own details: fill forms with these and never ask for them; the latest line wins if two disagree):\n"
            + "- Full name: \(NSFullUserName())\n" + profile.map { "- \($0)" }.joined(separator: "\n")
        if !other.isEmpty { text += "\nOther things you remember about the user:\n" + other.map { "- \($0)" }.joined(separator: "\n") }
        if omitted > 0 { text += "\n(\(omitted) more remembered facts not shown — use recall if you need something about the user that isn't here.)" }
        // The job-application profile, for requests that may meet a form (it's long, and nothing else needs it).
        if Self.mayMeetForms(context) {
            let jobProfile = Profile.promptBlock
            if !jobProfile.isEmpty { text += "\n" + jobProfile }
        }
        return text
    }

    // MARK: - Actions

    struct ActionContext {
        var app: NSRunningApplication?
        var elements: [UIElementInfo]
        var fingerprint: Int
        /// The live web page (via the browser extension) and where its viewport is on screen.
        var page: BrowserBridge.Page?
        var webArea: CGRect?
        /// Page fields typed into this turn (index → text), re-checked because browser autofill can change them later.
        var typedFields: [(Int, String)] = []
        /// The page list the model's w-ids refer to (what it was shown this turn); `page` may be a newer listing.
        var seen: BrowserBridge.Page?
        /// The app's process as scanned: a pid alone can be reused by a relaunch.
        var identity: AXEngine.ProcessIdentity?
        var nativeWindow: NativeWindowObservation?
        var coordinateCapture: Screenshot.Capture?
    }

    struct ActionResult {
        enum Effect { case none, look }
        let outcome: ActionOutcome
        let summary: String
        var effect: Effect = .none
        var ok: Bool { outcome.isConfirmed }
        init(ok: Bool, summary: String, effect: Effect = .none) {
            self.init(outcome: ok ? .confirmed : .failed, summary: summary, effect: effect)
        }
        init(outcome: ActionOutcome, summary: String, effect: Effect = .none) {
            self.outcome = outcome; self.summary = summary; self.effect = effect
        }
    }

    /// Direct host-agent control uses the same executor and safety checks as standalone tasks, without
    /// starting an inner model. Requests are serialized across awaits and observations are single use.
    func control(_ body: [String: Any]) async -> [String: Any] {
        if let why = ControlProtocol.validateRequest(body) { return Self.controlError(why) }
        guard !controlBusy else { return Self.controlError("Another control request is in flight") }
        controlBusy = true
        defer { controlBusy = false; controlOperation = nil }
        let operation = Task { await self.executeControl(body) }
        controlOperation = operation
        return await operation.value
    }

    func cancelControl(session: String) {
        guard controlLease?.session == session else { return }
        cancel()
    }

    private static func controlError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func renewControlExpiry() {
        controlExpiry?.cancel()
        controlExpiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            guard let self, self.controlLease != nil else { return }
            if self.controlBusy { self.renewControlExpiry(); return }
            self.finish(ok: false, "External control session expired. Inspect the application before starting another task.")
        }
    }

    private func executeControl(_ body: [String: Any]) async -> [String: Any] {
        let op = body["op"] as? String ?? "observe"
        if op == "observe", body["session"] == nil {
            guard !isRunning else { return Self.controlError("Clinqy is busy; finish the current task or release its control session") }
            guard let goal = body["task"] as? String, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  goal.utf8.count <= 8000 else { return Self.controlError("Start observe with the user's task (up to 8000 bytes)") }
            guard AXEngine.isTrusted else { return Self.controlError("Clinqy needs Accessibility permission") }
            guard let record = TaskStore.shared.enqueue(goal, files: [], source: .mac, background: false), TaskStore.shared.start(record) else {
                return Self.controlError("Couldn't save external task state")
            }
            taskRecordID = record
            prepare(goal, test: false, dry: false, background: false, external: true)
            controlLease = ControlLease()
            controlContext = nil
        }
        guard let lease = controlLease else { return Self.controlError("No control session; start with observe and a task") }
        // Only initial observe can omit the session; all later operations must present it.
        let session = body["session"] as? String ?? (op == "observe" && controlContext == nil ? lease.session : "")
        guard lease.accepts(session: session) else { return Self.controlError("Wrong or expired control session") }
        renewControlExpiry()
        lastProgress = Date()
        if op == "release" {
            let complete = body["complete"] as? Bool == true
            if complete && (pendingVerification != nil || completionEvidence.needsVerification) {
                return Self.controlError("The final outcome is unverified. Observe and verify before completing, or release with complete:false to stop.")
            }
            finish(ok: complete, complete ? "External task result verified" : "External task stopped; inspect any unverified outcome before retrying")
            return ["content": [["type": "text", "text": complete ? "Completed" : "Released without claiming completion"]], "isError": false]
        }
        if op == "observe" {
            let obs: Observation
            if var context = controlContext {
                let pinned = context.page.map { BrowserBridge.TabInfo(id: $0.tabId ?? -1, url: $0.url, connection: $0.connection) }
                await refresh(&context)
                if let pinned {
                    guard let page = await BrowserBridge.shared.snapshot(of: pinned) else { return Self.controlError("The task tab is unavailable; it was not replaced by another tab") }
                    context.page = page
                }
                obs = Observation(app: context.app, elements: context.elements, fingerprint: context.fingerprint,
                    page: context.page, webArea: context.webArea, nativeWindow: context.nativeWindow)
            } else { obs = await Observation.capture(targetApp) }
            guard !Task.isCancelled, isRunning, obs.app != nil else { return Self.controlError("No target application is available") }
            var context = ActionContext(app: obs.app, elements: obs.elements, fingerprint: obs.fingerprint, page: obs.page, webArea: obs.webArea)
            context.seen = obs.page; context.nativeWindow = obs.nativeWindow
            context.identity = obs.app.flatMap(AXEngine.identity(of:))
            var image: String?
            let activeTab = obs.page == nil ? nil : await BrowserBridge.shared.activeTab(in: obs.app)
            let imageMatchesPage = obs.page == nil || (activeTab?.id == obs.page?.tabId && activeTab?.connection == obs.page?.connection)
            if body["image"] as? Bool != false, imageMatchesPage, let app = obs.app {
                context.coordinateCapture = await Screenshot.capture(app: app, window: obs.nativeWindow, elements: obs.elements)
                image = context.coordinateCapture?.base64
            }
            guard !Task.isCancelled, isRunning else { return Self.controlError("Stopped") }
            let token = controlLease!.observe()
            renewControlExpiry()
            controlContext = context
            var state: [String: Any] = ["session": lease.session, "observation": token, "expiresInSeconds": 120,
                "screen": obs.text, "pendingVerification": pendingVerification?.kind ?? "", "needsGoalVerification": completionEvidence.needsVerification,
                "imageAvailable": image != nil, "coordinateSpace": "annotated image pixels; browser gestures use w-ids"]
            if let note = context.coordinateCapture?.notice { state["imageNotice"] = note }
            if image == nil, body["image"] as? Bool != false, let error = Screenshot.lastError { state["imageError"] = error.hint }
            if let capture = context.coordinateCapture { state["imageWidth"] = capture.imageSize.width; state["imageHeight"] = capture.imageSize.height }
            let encoded = (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
            var content: [[String: Any]] = [["type": "text", "text": encoded]]
            if let image { content.append(["type": "image", "mimeType": "image/jpeg", "data": image]) }
            phase = .acting
            return ["content": content, "structuredContent": state, "isError": false]
        }
        guard op == "act" || op == "verify" || op == "wait", var action = body["action"] as? [String: Any] else {
            return Self.controlError("Use observe, act, verify, wait or release")
        }
        if op != "act" { action["do"] = op }
        if let why = ControlProtocol.validate(action) { return Self.controlError(why) }
        guard let token = body["observation"] as? String, var context = controlContext,
              controlLease?.consume(token) == true else { return Self.controlError("Stale or already consumed observation; observe before acting") }
        if !["verify", "wait", "read", "look", "open_app", "open_url"].contains(action["do"] as? String ?? "") {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.app?.processIdentifier else {
                return Self.controlError("The foreground application changed; observe and return to the target before input")
            }
            if let page = context.page {
                let active = await BrowserBridge.shared.activeTab(in: context.app)
                guard active?.id == page.tabId, active?.connection == page.connection else {
                    return Self.controlError("The active tab changed; return to the observed task tab before input")
                }
            }
        }
        // Reset broad confirmation reuse for each host action. Normal approval/review still runs in execute.
        userConfirmed = false; reviewedForm = false
        phase = .acting
        let result = await perform(action, context: &context)
        guard !Task.isCancelled, controlLease != nil, isRunning else { return Self.controlError("Stopped; inspect the actual outcome before retrying") }
        controlLease?.touch()
        renewControlExpiry()
        controlContext = context
        phase = .acting
        let state: [String: Any] = ["session": session, "delivery": result.outcome.delivery.rawValue,
            "status": result.outcome.status.rawValue, "summary": result.summary, "needsGoalVerification": completionEvidence.needsVerification,
            "pendingVerification": pendingVerification?.kind ?? "", "observeBeforeNextAction": true]
        let encoded = (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? result.summary
        return ["content": [["type": "text", "text": encoded]], "structuredContent": state,
                "isError": result.outcome.status == .failed || result.outcome.status == .refused]
    }

    /// An input may have landed despite a timeout. Keep it unresolved until an explicit independent check succeeds.
    private struct PendingVerification {
        let kind: String
        /// A fresh screenshot may resolve this (ordinary UI input with known delivery on a non-consequential control).
        var visualOK = false
        let startedAt: Date
        let pageConnection: ObjectIdentifier?
        let tabID: Int?
        let url: String?
        let windowID: CGWindowID?
        let processIdentity: AXEngine.ProcessIdentity?
        let nativeWindow: NativeWindowObservation?
        let beforeText: String?
        let fieldInput: Bool
        let webTarget: BrowserBridge.PageElement?
        let webTargetUnique: Bool
        let nativeTarget: UIElementInfo?
        let beforeFieldValue: String?
        let documentID: String?
    }
    private var pendingVerification: PendingVerification?
    /// When the model last received a screenshot of the task (visual evidence is only valid after the pending input).
    private var lastVisualAt = Date.distantPast
    /// Inputs whose effect is ordinary UI state, so a fresh screenshot may resolve them. Submissions, scripts, saves and
    /// deletions (unknown delivery of something irreversible) need independent or user evidence.
    static let visualResolvable: Set<String> = ["click", "hover", "double_click", "right_click", "drag", "scroll"]
    private var completionEvidence = CompletionEvidence()
    private var controlLease: ControlLease?
    private var controlContext: ActionContext?
    private var controlBusy = false
    private var externalRun = false
    private var coordinatingBrowserJobs = false
    private var controlOperation: Task<[String: Any], Never>?
    private var controlExpiry: Task<Void, Never>?
    /// Set immediately before input dispatch, including calls whose acknowledgement may be lost.
    private var inputDeliveryStarted = false
    private static let observationActions: Set<String> = ["images", "image", "verify", "read", "look", "wait", "extract", "recall", "ask", "show", "point", "mark", "scroll", "assert", "review", "think"]
    private static let browserRecoveryActions: Set<String> = ["click", "type", "choose", "fill", "hover", "right_click", "double_click", "drag", "scroll", "read", "extract", "verify", "tab", "look", "snap", "wait", "upload", "autofill", "review"]

    fileprivate func perform(_ action: [String: Any], context: inout ActionContext) async -> ActionResult {
        while inputPanelVisible && !runBackground && question == nil {
            guard !Task.isCancelled, isRunning else { return .init(outcome: .refused, summary: "Stopped") }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, isRunning else { return .init(outcome: .refused, summary: "Stopped") }
        let kind = (action["do"] as? String ?? "").lowercased()
        // Arguments the dispatcher would ignore or reinterpret are refused before any checkpoint or input: what the
        // model asked for must be exactly what runs (and exactly how it is classified for completion evidence).
        if let why = ActionContract.validate(action) {
            return .init(outcome: .refused, summary: "NOT RUN: " + why + ". Nothing was sent.", effect: .none)
        }
        if runBackground && !runDry {
            // A transient snapshot failure must not strand the run: re-adopt the task's own tab (never another tab).
            if context.page == nil || !BrowserBridge.shared.ownsBackgroundPage(context.page), let tab = Background.tab,
               ["click", "type", "choose", "fill", "key", "scroll", "verify", "read", "look", "hover", "double_click", "right_click", "drag"].contains(kind),
               let page = await BrowserBridge.shared.snapshot(of: tab), BrowserBridge.shared.ownsBackgroundPage(page) {
                context.page = page
                context.webArea = page.estimatedArea
            }
            if kind == "ask", let question = action["question"] as? String,
               question.range(of: #"(?i)\b(switch|change|continue|use|run|move)\b.{0,60}\b(foreground|normal mode)\b"#, options: .regularExpression) != nil {
                return .init(outcome: .refused, summary: "Execution mode is controlled by Clinqy, not by a prose question. Try the required tool; Clinqy will handle foreground permission if it is unsupported. Do not ask another mode-selection question.")
            }
            if case .attention(let reason) = BackgroundPolicy.route(action, hasWorkerPage: BrowserBridge.shared.ownsBackgroundPage(context.page), allowTabDiscovery: BrowserBridge.shared.allowsExistingTabDiscovery) {
                if isolatedBrowserJob, kind == "key" {
                    return .init(outcome: .refused, summary: reason + " No shortcut was sent. Recover with open_url to navigate or create an owned task tab, tab actions to manage your own tabs, or a page field id to type. Do not ask the user to perform a browser navigation shortcut.", effect: .look)
                }
                if isolatedBrowserJob, Self.browserRecoveryActions.contains(kind) {
                    log("  browser recovery: " + reason)
                    return .init(outcome: .refused, summary: reason + " No input was sent. Take a fresh look at your owned task tab and use its current w<number> element ids, never text labels as ids. If navigation is still loading, wait and look again; verify the resulting URL before continuing pending input. Recover using browser tools without asking the user for foreground access.", effect: .look)
                }
                TaskStore.shared.update(taskRecordID, state: .needsAttention, stage: reason)
                if isolatedBrowserJob {
                    let reply = await askUser(reason + " This browser task will not take over your desktop. Open its task card to handle anything that needs you.", options: ["I've handled it in the task tab", "Stop this task"])
                    if reply == "Stop this task" || Task.isCancelled { cancel(); return fail("Stopped") }
                    await refresh(&context)
                    return .init(outcome: .refused, summary: "Foreground fallback was refused. Inspect the owned browser page and continue with browser tools only.", effect: .look)
                }
                let reply = await askUser(reason + " You can continue this task in foreground mode, or stop it.", options: ["Keep background mode", "Continue in foreground", "Stop task"])
                guard !Task.isCancelled else { return fail("Stopped") }
                if reply == "Continue in foreground" {
                    runBackground = false
                    if let powerLease { TaskPowerAssertions.shared.update(powerLease, preventDisplaySleep: true) }
                    Background.end()
                    context = ActionContext(elements: [], fingerprint: 0)
                    TaskStore.shared.update(taskRecordID, state: .running, stage: "Continuing in foreground", background: false)
                } else {
                    if reply == "Stop task" { cancel() }
                    return fail(reason + " Use an API action or an owned Chrome page.")
                }
            }
        }
        if kind == "parallel_browser" {
            guard pendingVerification == nil, let launch = parallelBrowserTasks,
                  let tasks = action["tasks"] as? [String], !tasks.isEmpty, tasks.count <= 32,
                  tasks.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 8000 }) else {
                return .init(outcome: .refused, summary: "Parallel browser jobs are allowed only for an explicitly parallel request; provide 1–32 independent task strings.")
            }
            coordinatingBrowserJobs = true
            defer { coordinatingBrowserJobs = false }
            let outcome = await launch(tasks)
            if !Task.isCancelled { finish(ok: outcome.ok, outcome.summary) }
            return .init(ok: outcome.ok, summary: outcome.summary)
        }
        let inspectingTab = kind == "tab" && ["list", "look", "read", "switch"].contains(action["op"] as? String ?? "list")
        if let pendingVerification, !Self.observationActions.contains(kind), !inspectingTab, !runDry {
            return .init(outcome: .refused, summary: "NOT REPEATED: \(pendingVerification.kind) has an unverified outcome. Read the current state, then resolve it with ONE of: "
                + "verify text/url/value+id/path (independent evidence); "
                + (pendingVerification.visualOK
                    ? "after a fresh look, {\"do\":\"verify\",\"visual\":\"what the screenshot shows\"} (recorded as visual-only evidence, for content the page text cannot expose such as a cross-origin iframe); " : "")
                + "{\"do\":\"verify\",\"user_confirms\":\"what should now be true\"} to ask the user. Do not repeat the input, and do not ask the user to reset anything: those are the only routes.", effect: .look)
        }
        // A real run always has a durable record; without one no side effect may start (fail closed, never run untracked).
        if taskRecordID == nil, !isTest, qa == nil, !runDry, !Self.observationActions.contains(kind) {
            cancel(); return fail("This run has no durable task record, so no action was taken. Start the task again from the task list.")
        }
        guard !Task.isCancelled else { return fail("Stopped") }
        let checkpointStart = ProcessInfo.processInfo.systemUptime
        guard TaskStore.shared.beginAction(taskRecordID, kind: kind) else { cancel(); return fail("Couldn't save the task checkpoint") }
        let priorPage = context.page
        let priorNativeWindow = context.nativeWindow
        let priorWindow = priorNativeWindow?.windowID
        let priorIdentity = context.nativeWindow?.identity
        let priorWebTarget = Self.webIndex(action["id"]).flatMap { index in priorPage?.elements.first { $0.index == index } }
        let priorWebUnique = priorWebTarget.map { target in
            priorPage?.elements.filter { $0.role == target.role && $0.text == target.text && $0.question == target.question }.count == 1
        } ?? false
        let priorNativeTarget = (action["id"] as? String).flatMap { AXEngine.lookup($0, in: context.elements) }
        let beforeFieldValue: String?
        if let target = priorWebTarget, let page = priorPage {
            beforeFieldValue = (try? await BrowserBridge.shared.perform("value", on: page, ["index": target.index]))?["value"] as? String
        } else { beforeFieldValue = priorNativeTarget.flatMap { Self.axValue($0.element) } }
        let priorText: String?
        if !Self.observationActions.contains(kind), let page = priorPage,
           let read = try? await BrowserBridge.shared.perform("read", on: page) {
            priorText = (read["title"] as? String ?? "") + "\n" + (read["text"] as? String ?? "") + "\n"
                + context.elements.map { $0.label + " " + ($0.value ?? "") }.joined(separator: "\n")
        } else if !Self.observationActions.contains(kind), priorPage == nil {
            // OCR is part of the baseline too: canvas text absent from AX must not become false "new" evidence.
            let axText = context.elements.map { $0.label + " " + ($0.value ?? "") }.joined(separator: "\n")
            if let app = context.app, let window = context.nativeWindow,
               let ocr = await Reader.ocr(app, window: window) { priorText = axText + "\n" + ocr }
            else { priorText = nil }
        } else { priorText = nil }
        recordPhase("checkpoint", since: checkpointStart)
        let actionStart = ProcessInfo.processInfo.systemUptime
        let actionStarted = Date()
        inputDeliveryStarted = false
        var result = await execute(action, context: &context)
        recordPhase("action", since: actionStart)
        guard !Task.isCancelled, isRunning else { return .init(outcome: .refused, summary: "Stopped") }
        if !result.ok, result.outcome.status == .failed, inputDeliveryStarted {
            result = .init(outcome: .uncertain, summary: "UNVERIFIED: input may have been applied before the error. " + result.summary + " Read and verify before retrying.", effect: .look)
        }
        if result.ok, !runDry, kind == "type", action["submit"] as? Bool != true, let expected = action["text"] as? String {
            var actual: String?
            if let page = context.page {
                if let target = priorWebTarget, page.documentID == priorPage?.documentID {
                    actual = (try? await BrowserBridge.shared.perform("value", on: page, ["index": target.index]))?["value"] as? String
                } else if priorWebTarget == nil {
                    actual = (try? await BrowserBridge.shared.perform("activeValue", on: page))?["value"] as? String
                }
            } else if let target = priorNativeTarget { actual = Self.axValue(target.element) }
            else if let app = context.app, let field = Self.focusedElement(of: app) { actual = Self.axValue(field) }
            if actual != expected {
                result = .init(outcome: .unverified, summary: "UNVERIFIED: text input was sent, but the exact resulting field value has not been established. Read and verify the targeted field before repeating it.", effect: .look)
            } else {
                TaskStore.shared.satisfyRequirement(taskRecordID, kind: .exactValue, matching: expected, evidence: "exact field readback after typing")
            }
        }
        // Return, Save and deletion keys have no application acknowledgement in the input API.
        let keys = (action["keys"] as? String ?? "").lowercased()
        let submitting = kind == "type" && action["submit"] as? Bool == true
        let scriptInput = kind == "shell" || kind == "applescript"
        let riskyKey = kind == "key" && (keys.contains("return") || keys.contains("enter") || keys.contains("delete") || keys.contains("backspace") || keys == "cmd+s" || keys == "command+s")
        if result.ok, !runDry, submitting || riskyKey || scriptInput {
            result = .init(outcome: .unverified, summary: "UNVERIFIED: " + result.summary + ". Input was sent once. Verify the intended application outcome before repeating it.", effect: .look)
        }
        if result.outcome.needsVerification {
            let label = priorWebTarget?.text ?? priorNativeTarget?.label ?? ""
            let consequentialTarget = Self.isFormSubmit(label) || Safety.needsConfirmation(label: label, request: request) != nil
            pendingVerification = PendingVerification(kind: kind,
                visualOK: Self.visualResolvable.contains(kind) && result.outcome.delivery == .delivered && !consequentialTarget,
                startedAt: actionStarted, pageConnection: priorPage?.connection,
                tabID: priorPage?.tabId, url: priorPage?.url, windowID: priorWindow, processIdentity: priorIdentity, nativeWindow: priorNativeWindow, beforeText: priorText,
                fieldInput: ["type", "fill", "choose"].contains(kind) && (!submitting || !result.ok),
                webTarget: priorWebTarget, webTargetUnique: priorWebUnique, nativeTarget: priorNativeTarget, beforeFieldValue: beforeFieldValue, documentID: priorPage?.documentID)
        }
        // Screenshot-only resolution lifts the repeat barrier but is never the independent final check.
        if action["visual"] == nil || kind != "verify" {
            completionEvidence.record(kind: kind, outcome: result.outcome, op: action["op"] as? String ?? "")
        }
        let provenance = pendingVerification.map {
            TaskStore.PendingProvenance(kind: $0.kind, startedAt: $0.startedAt, url: $0.url, tabID: $0.tabID, visualOK: $0.visualOK, delivery: result.outcome.delivery)
        }
        let checkpointEnd = ProcessInfo.processInfo.systemUptime
        guard TaskStore.shared.endAction(taskRecordID, kind: kind, outcome: result.outcome, completedSteps: steps.filter { $0.state == .ok }.count,
                                         provenance: result.outcome.needsVerification ? provenance : nil) else {
            cancel(); return fail("Couldn't persist the action outcome. Check the real application state before retrying.")
        }
        recordPhase("checkpoint", since: checkpointEnd)
        return result
    }

    private func execute(_ action: [String: Any], context: inout ActionContext) async -> ActionResult {
        await followWatching()
        let kind = (action["do"] as? String ?? "").lowercased()
        if runDry, let shown = await rehearse(kind, action, context: &context) { return shown }
        for key in ["text", "option", "value"] where ["type", "choose", "autofill", "fill"].contains(kind) {
            if let v = action[key] as? String { agentEntered.insert(Self.squashValue(v)) }
        }
        if let fields = action["fields"] as? [[String: Any]] {
            for f in fields { for v in f.values { if let v = v as? String { agentEntered.insert(Self.squashValue(v)) } } }
        }
        // Options the target cannot honour are refused, never dropped (a right/double/modified click must not become a plain one).
        if kind == "click", case .success(let options) = ClickOptions.parse(action), !options.isPlain,
           Self.isWebRef(action["id"]) || context.page != nil && action["id"] == nil || action["text"] is String || runBackground {
            return .init(outcome: .refused, summary: "UNSUPPORTED: button, count, modifiers and duration_ms apply to native clicks by e-id or screenshot x/y in foreground mode. Use right_click or double_click for page elements, or click without options. Nothing was sent.")
        }
        if kind == "type", let raw = action["mode"] as? String, raw.lowercased() != "replace",
           Self.isWebRef(action["id"]) || context.page != nil || runBackground || action["submit"] as? Bool == true {
            return .init(outcome: .refused, summary: "UNSUPPORTED: type mode insert/append works on a native focused field without submit (use key return afterwards). Web pages and background runs only replace the field's text. Nothing was sent.")
        }
        if kind == "set_state", Self.isWebRef(action["id"]) || context.page != nil && !(action["id"] is String) {
            return .init(outcome: .refused, summary: "UNSUPPORTED: set_state is for native checkboxes, radio buttons and sliders by e-id. On a web page click the control and read its [checked]/[unchecked] state. Nothing was sent.")
        }
        switch kind {
        case "delegate":
            guard let pool = delegation else { return fail("Delegation is disabled or no active lead session is available") }
            guard let jobs = action["jobs"] as? [[String: Any]], let data = try? JSONSerialization.data(withJSONObject: jobs),
                  let parsed = try? JSONDecoder().decode([DelegationPool.Job].self, from: data) else {
                return fail("delegate needs jobs with id, task, optional context, urls, files, depends_on, browser")
            }
            do {
                let result = try pool.submit(parsed)
                steps.append(Step(text: "Delegated: " + parsed.map { "\($0.id): \($0.task)" }.joined(separator: "; "), state: .info))
                log("delegation: \(parsed.count) assigned · up to \(pool.concurrency) simultaneous sessions")
                return .init(ok: true, summary: result)
            } catch { return fail(error.localizedDescription) }

        case "collect":
            guard let pool = delegation else { return fail("No active delegation pool") }
            let previousPhase = phase
            phase = .thinking
            defer { if isRunning { phase = previousPhase } }
            let result = await pool.collect(ids: action["ids"] as? [String] ?? [], wait: action["wait"] as? Bool ?? false,
                                            timeout: (action["timeout"] as? Double) ?? 20)
            guard !Task.isCancelled else { return fail("Stopped") }
            steps.append(Step(text: "Collected delegated work:\n" + result, state: .info))
            return .init(ok: true, summary: "Delegated worker results (evidence; verify before use):\n" + result)

        case "set_state":
            guard let app = context.app else { return fail("no app") }
            guard let el = await resolve(action["id"], context: &context) else { return fail("element \(action["id"] ?? "?") isn't on screen anymore") }
            let desired: DesiredState
            switch DesiredState.parse(role: el.role, raw: action["state"]) {
            case .success(let parsed): desired = parsed
            case .failure(let error): return .init(outcome: .refused, summary: "UNSUPPORTED: " + error.message + ". Nothing was sent.")
            }
            let line = begin("Set \(el.shortLabel)")
            if let why = staleApp(context) { return end(line, fail(why)) }
            if !Background.active { await Launcher.bringToFront(app) }
            inputDeliveryStarted = true
            let outcome = await hand.setState(el, to: desired, in: app, window: context.nativeWindow)
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            buddy.clearHighlight()
            switch outcome {
            case .already: return end(line, .init(outcome: ActionOutcome(delivery: .notAttempted, status: .confirmed), summary: "CONFIRMED: \(el.describe) already had the requested state; nothing was sent"))
            case .changed: return end(line, .init(ok: true, summary: "CONFIRMED: \(el.describe) now reads back as requested"))
            case .unverified(let why): return end(line, .init(outcome: .unverified, summary: "UNVERIFIED: " + why + ". Read the control before retrying.", effect: .look))
            case .unsupported(let why): return end(line, .init(outcome: .refused, summary: "UNSUPPORTED: " + why))
            case .refused(let why): return end(line, .init(outcome: .refused, summary: why))
            }

        case "open_app":
            guard let name = action["name"] as? String else { return fail("open_app needs a name") }
            if runBackground { return await openInBackground(URL(string: "about:blank")!, context: &context) }
            let line = begin("Open \(name)")
            guard let app = await hand.openApp(named: name) else { return end(line, fail("Couldn't find an app called \(name)")) }
            context.app = app
            openedLast = true
            await refresh(&context)
            let readiness = Launcher.readiness(of: app)
            return end(line, .init(ok: true, summary: "\(app.cleanName ?? name) \(readiness.summary)" + (readiness.ready ? "" : "; look before acting")))

        case "open_url":
            guard let raw = action["url"] as? String,
                  let url = URL(string: raw.contains("://") ? raw : "https://\(raw)") else { return fail("bad url") }
            let line = begin("Go to \(url.host ?? raw)")
            // Already there: nothing to open (in a QA test the page is always loaded fresh).
            if qa != nil, let page = context.page, page.url.hasPrefix(url.absoluteString) || url.absoluteString.hasPrefix(page.url),
               let tab = await currentTab(context.app) {
                await BrowserBridge.shared.tabCommand("navigate", on: tab, ["url": url.absoluteString])
                try? await Task.sleep(for: .milliseconds(1200))
                await refresh(&context)
                return end(line, .init(ok: true, summary: "reloaded \(url.absoluteString)"))
            }
            if qa == nil, let page = context.page, let host = url.host?.replacingOccurrences(of: "www.", with: ""),
               page.url.contains(host), url.path.count <= 1 || page.url.contains(url.path) {
                return end(line, .init(ok: true, summary: "already on \(page.url)"))
            }
            if Background.active {
                return end(line, await openInBackground(url, context: &context))
            }
            let bridge = BrowserBridge.shared
            let connectedBrowser = context.app.flatMap { Launcher.isBrowser($0) && bridge.isConnected($0) ? $0 : nil }
                ?? (context.app.map(Launcher.isBrowser) != true ? NSWorkspace.shared.runningApplications.first {
                    $0.cleanName == Launcher.defaultBrowserName && bridge.isConnected($0)
                } : nil)
            if let browser = connectedBrowser {
                let before = await currentTab(browser)
                let reuse = before.map { Self.isNewTabPage($0.url) || ($0.id == ownedTab && URL(string: $0.url)?.host == url.host) } ?? false
                do {
                    let opened = try await bridge.openForegroundTab(url, in: browser, reusing: reuse ? before : nil,
                                                                  operationID: runID + ":" + BrowserNavigation.key(url.absoluteString))
                    ownedTab = opened.id
                    context.app = browser
                    openedTab = true
                    openedLast = true
                    await Launcher.bringToFront(browser)
                    for _ in 0..<15 {
                        if let page = await bridge.snapshot(of: opened), page.ready != "loading", !Self.isNewTabPage(page.url) {
                            adopt(page, into: &context)
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                    await refresh(&context)
                    registerNavigationUndo(line, label: "Leave \(url.host ?? raw)", closing: reuse ? nil : opened.id, app: browser)
                    return end(line, .init(ok: true, summary: "opened \(url.absoluteString) in tab \(opened.id) of \(browser.cleanName ?? "the browser")"))
                } catch {
                    return end(line, .init(outcome: .uncertain, summary: "The browser open could not be confirmed. No second tab was opened. Take a fresh look before retrying. " + error.localizedDescription, effect: .look))
                }
            }
            // Without an extension, open once through native input. Never create a second tab based only on
            // an old active-tab observation or a page that has not finished navigating.
            // Ask this browser, not whichever one has the extension too (Arc and Chrome both connected).
            let before = context.app.map(Launcher.isBrowser) == true ? await currentTab(context.app) : nil
            let emptyTab = before.map { Self.isNewTabPage($0.url) } ?? false
            // Each site gets its own tab ("open github and wikipedia" = two tabs); staying on the same site in our
            // own tab (youtube.com → a YouTube search) reuses it.
            let host = { (u: String) in (URL(string: u)?.host ?? "").replacingOccurrences(of: "www.", with: "") }
            let sameSite = before.map { host($0.url) == host(url.absoluteString) && !host($0.url).isEmpty } ?? false
            let reuse = before != nil && (emptyTab || (before?.id == ownedTab && sameSite))
            let browser = await hand.openURL(url, current: context.app, newTab: !reuse)
            openedTab = true
            if let before, let after = await currentTab(browser ?? context.app) {
                log("    tab: \(reuse ? "reused" : "new") · before #\(before.id) \(before.url.prefix(50)) · now #\(after.id)")
                if after.id != before.id || reuse { ownedTab = after.id }
            }
            context.app = browser ?? NSWorkspace.shared.frontmostApplication
            await refresh(&context)
            openedLast = true
            registerNavigationUndo(line, label: "Leave \(url.host ?? raw)", closing: reuse ? nil : ownedTab, app: context.app)
            return end(line, .init(ok: true, summary: "opened \(url.absoluteString) in \(context.app?.cleanName ?? "the browser")"))

        case "hover", "right_click", "double_click", "drag":
            return await pointerGesture(action, context: &context)

        case "click" where Self.isWebRef(action["id"]):
            guard let (el, rect) = await liveWebTarget(action["id"], &context), let page = context.page else { return fail(goneMessage(action["id"])) }
            let line = begin("Click \(el.text.prefix(32))")
            let consequential = Self.isFormSubmit(el.text) || Safety.needsConfirmation(label: el.text, request: request) != nil
            if let why = await approve(el.text, role: el.role, page: page) { return end(line, .init(outcome: .refused, summary: why)) }
            if !Background.active, let app = context.app { await Launcher.bringToFront(app) }
            let state = { (try? await BrowserBridge.shared.perform("state", on: page, ["index": el.index]))?["sig"] as? String }
            let before = await state()
            var point = CGPoint(x: rect.midX, y: rect.midY)
            var viewport: CGPoint?
            var hittable = false
            if let spot = try? await BrowserBridge.shared.perform("locate", on: page, ["index": el.index]),
               let web = context.webArea, spot["hit"] as? Bool == true, spot["still"] as? Bool == true,
               let px = (spot["px"] as? NSNumber)?.doubleValue, let py = (spot["py"] as? NSNumber)?.doubleValue,
               page.viewport.width > 0, page.viewport.height > 0 {
                point = CGPoint(x: web.minX + px * web.width / page.viewport.width, y: web.minY + py * web.height / page.viewport.height)
                viewport = CGPoint(x: px, y: py)
                hittable = web.contains(point)
            }
            let host = Clicks.host(page.url)
            let method: String
            // Choose one route before delivery. An unchanged screen or timeout never authorizes another click.
            if Background.active, let viewport, hittable {
                method = "cdp"
            } else if !Background.active, hittable, !Clicks.prefersScript(host),
                      Hand.hitMismatch(at: point, pid: context.app?.processIdentifier ?? 0, window: context.nativeWindow?.element) == nil {
                method = "mouse"
            } else { method = "script" }
            do {
                if method == "mouse" {
                    traceClick(point, in: context.app)
                    if let why = await hand.click(at: point, pid: context.app?.processIdentifier, window: context.nativeWindow) {
                        return end(line, .init(outcome: .refused, summary: why))
                    }
                } else if method == "cdp", let viewport {
                    _ = try await pageMutation("cdpClick", on: page, ["x": viewport.x, "y": viewport.y, "index": el.index])
                } else {
                    _ = try await pageMutation("click", on: page, ["index": el.index])
                }
            } catch {
                return end(line, .init(outcome: .uncertain, summary: "UNVERIFIED: the click may have been applied. Read the page and verify the intended result before retrying. " + error.localizedDescription, effect: .look))
            }
            var outcome = ActionOutcome.unverified
            for attempt in 0..<5 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(150)) }
                outcome = ActionOutcome.browserClick(before: before, after: await state(), consequential: consequential)
                if outcome.isConfirmed { break }
            }
            log(Clicks.line(kind: "web", place: host, method: method, worked: outcome.isConfirmed, tries: 1))
            buddy.clearHighlight()
            if consequential { StepUndo.shared.clear() }
            let summary = "clicked \(el.role) \(el.text.prefix(60).debugDescription) on the page"
            if outcome.isConfirmed { return end(line, .init(outcome: outcome, summary: summary + " (target state or navigation confirmed)")) }
            return end(line, .init(outcome: outcome, summary: "UNVERIFIED: " + summary + ". Input was sent once; its intended outcome has not been established. Read the page, then verify the expected confirmation, URL or field value. Do not repeat the click.", effect: .look))

        case "application":
            // The application tracker: find before applying, record after filling/sending.
            let op = (action["op"] as? String ?? "find").lowercased()
            let company = (action["company"] as? String) ?? "", role = (action["role"] as? String) ?? ""
            let link = action["url"] as? String
            if op == "find" || op == "check" {
                let query = (action["query"] as? String) ?? [company, role, link ?? ""].joined(separator: " ")
                let hits = Applications.find(query)
                return .init(ok: true, summary: hits.isEmpty ? "no earlier application matches \(query.debugDescription)"
                             : "already in the tracker:\n" + hits.map { "- " + Applications.describe($0) }.joined(separator: "\n"))
            }
            if op == "list" || op == "show" {
                let card = Applications.card
                runResult = card
                result = card
                onResult()
                steps.append(Step(text: "Showed \(card.title)", state: .info))
                return .init(ok: true, summary: "tracker shown to the user:\n" + card.plain.prefix(3000))
            }
            guard !company.isEmpty else { return fail("application record needs company (and role)") }
            let summary = Applications.record(company: company, role: role, url: link, status: (action["status"] as? String) ?? "",
                                              resume: action["resume"] as? String, notes: action["notes"] as? String)
            steps.append(Step(text: "Tracked: \(company) — \(role)", state: .info))
            return .init(ok: true, summary: summary)

        case "upload" where context.page != nil:
            // Straight into the page's upload field (no Mac file picker): the extension builds the file from its bytes.
            // A site with its own upload button (no field until it's clicked) gets the file through that button's
            // request for one; failing that, the Mac file picker it opens is driven like a person would.
            guard let path = (action["file"] ?? action["path"]) as? String else { return fail("upload needs file") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url) else { return fail("can't read \(url.path)") }
            guard data.count < 15_000_000 else { return fail("\(url.lastPathComponent) is too big to upload this way (\(data.count / 1_000_000) MB)") }
            var target: (BrowserBridge.PageElement, CGRect)?
            if Self.isWebRef(action["id"]) {
                guard let found = await liveWebTarget(action["id"], &context) else { return fail(goneMessage(action["id"])) }
                target = found
            }
            let page = context.page!
            let index = target?.0.index ?? -1
            let line = begin("Upload \(url.lastPathComponent)")
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let args: [String: Any] = ["index": index, "name": url.lastPathComponent, "type": type, "data": data.base64EncodedString()]
            var why = ""
            do {
                let r = try await pageMutation("upload", on: page, args, timeout: 20)
                guard r["ok"] as? Bool == true else { return end(line, fail("the page didn't take the file")) }
                try? await Task.sleep(for: .milliseconds(800))   // sites upload/parse it (Greenhouse fills fields from a resume)
                return end(line, .init(ok: true, summary: "attached \(url.lastPathComponent) to the upload field (now holds: \((r["files"] as? [String] ?? []).joined(separator: ", ")))"))
            } catch {
                why = error.localizedDescription
                guard why.contains("this page has no file upload field") else {
                    return end(line, .init(outcome: .uncertain, summary: "UNVERIFIED: the attachment may have been applied. Read the page before retrying. " + why, effect: .look))
                }
                // This specific driver error occurs before file assignment or any click, so one alternative is safe.
                inputDeliveryStarted = false
            }
            guard let (el, _) = target else {
                return end(line, fail("\(why) — give the id of the site's upload button (upload goes through it), or click it if it opens its own picker (Google Forms uses Google Drive)"))
            }
            if let r = try? await pageMutation("uploadVia", on: page, args, timeout: 20), r["ok"] as? Bool == true {
                try? await Task.sleep(for: .milliseconds(800))
                log("    upload: through the page's own button")
                return end(line, .init(ok: true, summary: "attached \(url.lastPathComponent) through \(el.text.prefix(40).debugDescription) (now holds: \((r["files"] as? [String] ?? []).joined(separator: ", ")))"))
            }
            return end(line, .init(outcome: .uncertain, summary: "UNVERIFIED: the upload button was used once, but its result could not be confirmed. Read the page or picker before choosing another action.", effect: .look))

        case "review" where context.page != nil:
            return await reviewForm(context.page!)

        case "autofill" where context.page != nil:
            return await autofill(context: &context)

        case "choose" where Self.isWebRef(action["id"]):
            // A dropdown in one step: open it with a real click (type to filter if it's a search box), find the
            // option by its text, click it, then check the field shows it. Works for native selects, Google Forms
            // listboxes and React-style comboboxes (Greenhouse, Lever…).
            guard let want = (action["option"] ?? action["text"]) as? String, !want.isEmpty else { return fail("choose needs option") }
            guard let (el, rect) = await liveWebTarget(action["id"], &context), let page = context.page, let app = context.app else { return fail(goneMessage(action["id"])) }
            let line = begin("Choose “\(want.prefix(40))”")
            if !Background.active { await Launcher.bringToFront(app) }
            await buddy.travel(to: CGPoint(x: rect.midX, y: rect.midY), framing: rect)
            let current = { (try? await BrowserBridge.shared.perform("chosen", on: page, ["index": el.index]))?["value"] as? String ?? "" }
            if el.role == "select" {
                do {
                    let r = try await pageMutation("fill", on: page, ["index": el.index, "text": want])
                    buddy.clearHighlight()
                    return end(line, .init(ok: true, summary: "chose \((r["value"] as? String ?? want).debugDescription) in the dropdown"))
                } catch { return end(line, fail(error.localizedDescription)) }
            }
            if AXEngine.similar(await current(), want) {
                buddy.clearHighlight()
                return end(line, .init(ok: true, summary: "\(want.debugDescription) was already chosen"))
            }
            if let why = await webClick(CGPoint(x: rect.midX, y: rect.midY), context, index: el.index) { return end(line, fail(why)) }
            if el.editable {
                // A search-as-you-type box: typing narrows the list to the option.
                try? await Task.sleep(for: .milliseconds(150))
                guard await pageType(want, page: page, app: app) else { return end(line, fail("Couldn’t type into the owned page; no desktop fallback was used")) }
            }
            var option: [String: Any]?
            var lastError: Error?
            let optionDeadline = ProcessInfo.processInfo.systemUptime + 4
            repeat {
                guard !Task.isCancelled else { return end(line, fail("Stopped")) }
                let remaining = optionDeadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { break }
                do { option = try await BrowserBridge.shared.perform("findOption", on: page, ["text": want, "index": el.index], timeout: min(1, remaining)) }
                catch { lastError = error; break }
                if option?["found"] as? Bool == true { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return end(line, fail("Stopped")) }
            } while ProcessInfo.processInfo.systemUptime < optionDeadline
            if option?["found"] as? Bool != true, let lastError { log("    findOption: \(lastError.localizedDescription)") }
            let picked: String
            if let option, option["found"] as? Bool == true,
               let token = option["pointToken"] as? String, let frame = option["pointFrame"] {
                do { _ = try await pageMutation("clickOption", on: page, ["pointToken": token, "pointFrame": frame]) }
                catch { return end(line, fail("The option selection may have applied. " + error.localizedDescription)) }
                picked = option["text"] as? String ?? want
                log(Clicks.line(kind: "option", place: Clicks.host(page.url), method: "mouse", worked: true, tries: 1))
            } else if let viaKeys = await chooseWithKeys(want, el: el, page: page) {
                // No list the page shows as options (or not the one wanted): the arrow keys walk the dropdown's choices.
                picked = viaKeys
                log(Clicks.line(kind: "option", place: Clicks.host(page.url), method: "key", worked: true, tries: 2))
            } else {
                await pagePress("esc", page)
                log(Clicks.line(kind: "option", place: Clicks.host(page.url), method: "none", worked: false, tries: 2))
                let seen = (option?["options"] as? [String]) ?? []
                return end(line, fail("no option like \(want.debugDescription)\(seen.isEmpty ? " appeared" : "; the options are: " + seen.joined(separator: " | "))"))
            }
            try? await Task.sleep(for: .milliseconds(350))
            let now = await current()
            buddy.clearHighlight()
            // Options often carry a description the field doesn't show (".5 vCPU Min: 1 GB Max: 4 GB" → ".5 vCPU"):
            // the field showing the option's start, or what was asked for, is the right pick.
            let shows = now.lowercased().trimmingCharacters(in: .whitespaces)
            if now.isEmpty { return end(line, .init(outcome: .unverified, summary: "UNVERIFIED: selected \(picked.debugDescription), but its field value could not be read back. Verify that exact field before continuing.", effect: .look)) }
            if !AXEngine.similar(now, picked), !shows.contains(picked.lowercased()),
               !picked.lowercased().hasPrefix(shows), !AXEngine.similar(now, want) {
                return end(line, fail("clicked \(picked.debugDescription) but the field shows \(now.debugDescription)"))
            }
            return end(line, .init(ok: true, summary: "chose \(picked.debugDescription)\(now.isEmpty ? "" : " (field shows \(now.debugDescription))")"))

        case "type" where Self.isWebRef(action["id"]):
            guard let text = action["text"] as? String else { return fail("type needs text") }
            guard let (el, rect) = await liveWebTarget(action["id"], &context), let page = context.page, let app = context.app
            else { return fail(goneMessage(action["id"])) }
            let line = begin("Type “\(text.prefix(40))”")
            if !Background.active { await Launcher.bringToFront(app) }
            await buddy.travel(to: CGPoint(x: rect.midX, y: rect.midY), framing: rect)
            buddy.click()
            if el.role == "select" {
                // Dropdown: choose the option directly (typing into a native select is unreliable).
                do {
                    let r = try await pageMutation("fill", on: page, ["index": el.index, "text": text])
                    // Confirm the page really holds the new choice before calling it done.
                    let now = (try? await BrowserBridge.shared.perform("value", on: page, ["index": el.index]))?["value"] as? String
                    log("    dropdown: fill → \(r["value"] ?? "nil") · now \(now ?? "nil")")
                    buddy.clearHighlight()
                    return end(line, .init(ok: true, summary: "chose \((r["value"] as? String ?? text).debugDescription) in the dropdown"))
                } catch { return end(line, fail(error.localizedDescription)) }
            }
            // Keep the browser's autocomplete list from opening over the field, then click into it for real
            // like a person (a real click also closes any popup still open from the previous field).
            _ = try? await BrowserBridge.shared.perform("prepare", on: page, ["index": el.index])
            if let why = await webClick(CGPoint(x: rect.midX, y: rect.midY), context, index: el.index) { return end(line, fail(why)) }
            try? await Task.sleep(for: .milliseconds(150))
            // It must be *this* field that has the caret (not just any text box, e.g. the previous one);
            // keys anywhere else would trigger page shortcuts or land in the wrong field.
            let isActive = { (try? await BrowserBridge.shared.perform("isActive", on: page, ["index": el.index]))?["active"] as? Bool == true }
            var ready = await isActive()
            if !ready {
                _ = try? await BrowserBridge.shared.perform("focus", on: page, ["index": el.index])
                try? await Task.sleep(for: .milliseconds(100))
                ready = await isActive()
            }
            if !ready {
                // Still no caret: set the text directly on the field.
                guard let r = try? await pageMutation("fill", on: page, ["index": el.index, "text": text]) else {
                    return end(line, fail("\(el.text.prefix(30)) isn't a text box"))
                }
                if action["submit"] as? Bool == true {
                    if let why = await approveReturn(page) { return end(line, fail(why)) }
                    let now = (try? await BrowserBridge.shared.perform("value", on: page, ["index": el.index]))?["value"] as? String
                    if let held = submitBlocked(expected: text, actual: now) { buddy.clearHighlight(); return end(line, held) }
                    if let lost = await submitPress(page) { buddy.clearHighlight(); return end(line, lost) }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                buddy.clearHighlight()
                return end(line, .init(ok: true, summary: "set \((r["value"] as? String ?? text).prefix(60).debugDescription) in \(el.role) \(el.text.prefix(40).debugDescription)\(action["submit"] as? Bool == true ? " and pressed Return" : "")"))
            }
            // Type it like a person; if the page didn't take the keys, set it the way frameworks notice.
            // Start from an empty field (it may hold autofill or old text); keystrokes then type the rest.
            let old = (try? await BrowserBridge.shared.perform("value", on: page, ["index": el.index]))?["value"] as? String ?? ""
            if !old.isEmpty {
                _ = try? await pageMutation("fill", on: page, ["index": el.index, "text": ""])
            }
            let active = try? await BrowserBridge.shared.perform("activeValue", on: page)
            let isCode = active?["code"] as? Bool ?? false
            buddy.setTyping(true)
            guard await pageType(text, page: page, app: app, codeEditor: isCode) else { return end(line, fail("Couldn’t type into the owned page; no desktop fallback was used")) }
            buddy.setTyping(false)
            // A password field took secure input: never set it behind the user's back either.
            if let why = hand.refusal { return end(line, fail(why)) }
            // Keys queue up in the browser; wait until the field shows them before moving on (or focus could
            // move to the next field while this one's last keys are still in flight).
            var value: String?
            for _ in 0..<12 {
                value = (try? await BrowserBridge.shared.perform("value", on: page, ["index": el.index]))?["value"] as? String
                if let v = value, AXEngine.similar(v, text) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // (A code editor's field isn't its text: setting it would corrupt the editor.)
            if !isCode, let value, !AXEngine.similar(value, text) || value.count > text.count + 3 {
                _ = try? await pageMutation("fill", on: page, ["index": el.index, "text": text])
            }
            // Browser autofill can rewrite fields filled a moment ago (e.g. focusing a password box refills the
            // username): put back anything that changed.
            context.typedFields.removeAll { $0.0 == el.index }
            context.typedFields.append((el.index, text))
            let previous = context.typedFields.filter { $0.0 != el.index }
            let batch: [String: Any]? = previous.isEmpty ? [:] : ((try? await BrowserBridge.shared.perform("values", on: page, ["indices": previous.map { $0.0 }]))?["values"] as? [String: Any])
            var values = batch ?? [:]
            if batch == nil { // Older installed extensions remain safe until reloaded.
                for (index, _) in previous {
                    guard !Task.isCancelled else { return end(line, fail("Stopped")) }
                    values[String(index)] = (try? await BrowserBridge.shared.perform("value", on: page, ["index": index]))?["value"]
                }
            }
            for (index, expected) in previous {
                let now = values[String(index)] as? String
                if let now, now.trimmingCharacters(in: .whitespaces) != expected {
                    _ = try? await pageMutation("fill", on: page, ["index": index, "text": expected])
                }
            }
            if action["submit"] as? Bool == true {
                if let why = await approveReturn(page) { return end(line, fail(why)) }
                let now = (try? await BrowserBridge.shared.perform("value", on: page, ["index": el.index]))?["value"] as? String
                if !isCode, let held = submitBlocked(expected: text, actual: now) { buddy.clearHighlight(); return end(line, held) }
                try? await Task.sleep(for: .milliseconds(120))
                if let lost = await submitPress(page) { buddy.clearHighlight(); return end(line, lost) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            buddy.clearHighlight()
            if action["submit"] as? Bool != true, line < steps.count {
                let index = el.index
                StepUndo.shared.register(step: steps[line].id, kind: .text, label: old.isEmpty ? "Clear “\(el.text.prefix(30))”" : "Put back the earlier text in “\(el.text.prefix(30))”") {
                    // The page changed when the text went in, so the snapshot taken before is stale by design: look again, and
                    // restore only if the same field still holds exactly what this step typed.
                    do {
                        guard let tabID = page.tabId,
                              let fresh = await BrowserBridge.shared.snapshot(of: .init(id: tabID, url: page.url, connection: page.connection)) else {
                            Agent.writeLog("  ↩ undo text: the page is no longer available"); return false
                        }
                        let current = (try await BrowserBridge.shared.perform("value", on: fresh, ["index": index]))["value"] as? String
                        guard current == text || current?.hasSuffix(text) == true else {
                            Agent.writeLog("  ↩ undo text: the field no longer holds what was typed; left unchanged"); return false
                        }
                        _ = try await self.pageMutation("fill", on: fresh, ["index": index, "text": old]); return true
                    } catch { Agent.writeLog("  ↩ undo text: page refused the restore: \(error)"); return false }
                }
            }
            let editor = (active?["editorKind"] as? String).map { " (a \($0) code editor: it may re-indent)" } ?? ""
            return end(line, .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into \(el.role) \(el.text.prefix(40).debugDescription)\(editor)\(action["submit"] as? Bool == true ? " and pressed Return" : "")"))

        case "type" where action["id"] == nil && context.page != nil:
            guard let text = action["text"] as? String, let page = context.page, let app = context.app else { return fail("type needs text") }
            let line = begin("Type “\(text.prefix(40))”")
            if !Background.active { await Launcher.bringToFront(app) }
            let before = try? await BrowserBridge.shared.perform("activeValue", on: page)
            // (In a background run the keys go to the run's tab whatever has focus there: the rest of the Mac is the user's.)
            if Background.active, before?["editable"] as? Bool != true { return end(line, fail("No editable field is focused in the task tab. Click a listed field first.")) }
            guard before?["editable"] as? Bool == true || Background.active else {
                let result = await typeOutsidePage(text, submit: action["submit"] as? Bool == true, app: app,
                                                   pageFocused: before?["hasFocus"] as? Bool ?? false, context: &context)
                buddy.clearHighlight()
                return end(line, result)
            }
            if let existing = before?["value"] as? String, !existing.isEmpty {
                if Background.active { await pagePress("cmd+a", page) } else {
                    AXEngine.targetPid = app.processIdentifier
                    AXEngine.selectAll()
                    AXEngine.targetPid = nil
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            let editor = before?["editorKind"] as? String
            buddy.setTyping(true)
            if Background.active {
                guard await pageType(text, page: page, app: app) else { return end(line, fail("Couldn’t type into the owned page; no desktop fallback was used")) }
            } else {
                AXEngine.targetPid = app.processIdentifier
                // Document editors (Google Docs) take the caret into an iframe: paste the whole text at once there.
                if before?["frame"] as? Bool == true { AXEngine.paste(text) }
                else { await hand.enterText(text, codeEditor: before?["code"] as? Bool ?? false) }
                AXEngine.targetPid = nil
            }
            buddy.setTyping(false)
            if let why = hand.refusal { return end(line, fail(why)) }
            if let value = (try? await BrowserBridge.shared.perform("activeValue", on: page))?["value"] as? String,
               !AXEngine.similar(value, text) || value.count > text.count + 3 {
                let r = try? await pageMutation("fillActive", on: page, ["text": text])
                // A code editor can't be set directly (it would corrupt it): what it shows is the result.
                if r?["skipped"] as? Bool == true, let shows = r?["value"] as? String, !Self.editorShows(shows, text) {
                    buddy.clearHighlight()
                    return end(line, fail("the \(editor ?? "code") editor shows \(shows.prefix(200).debugDescription), not the text typed "
                                          + "(auto-indent or auto-closed brackets?). Fix what differs rather than typing it all again"))
                }
            }
            if action["submit"] as? Bool == true {
                if let why = await approveReturn(page) { return end(line, fail(why)) }
                let now = (try? await BrowserBridge.shared.perform("activeValue", on: page))?["value"] as? String
                if editor == nil, let held = submitBlocked(expected: text, actual: now) { buddy.clearHighlight(); return end(line, held) }
                try? await Task.sleep(for: .milliseconds(120))
                if let lost = await submitPress(page) { buddy.clearHighlight(); return end(line, lost) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            buddy.clearHighlight()
            let into = editor.map { "the focused code editor (\($0))" } ?? "the focused field"
            return end(line, .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into \(into)\(action["submit"] as? Bool == true ? " and pressed Return" : "")"))

        case "point" where Self.isWebRef(action["id"]), "mark" where Self.isWebRef(action["id"]):
            guard let (el, rect) = webTarget(action["id"], context) else { return fail("page element \(action["id"] ?? "?") not found; look again") }
            let line = begin("Show \(el.text.prefix(32))")
            await buddy.mark(rect, label: action["label"] as? String)
            hand.lingerBeforeHome = 3.5
            return end(line, .init(ok: true, summary: "marked it on screen with a circle and arrow"))

        case "scroll" where context.page != nil:
            if case .success(let plan) = ScrollPlan.parse(action), plan.direction == .left || plan.direction == .right || !plan.isDefault {
                return .init(outcome: .refused, summary: "UNSUPPORTED: page scrolling only moves up or down by a screenful; left/right, unit and amount apply to native windows. Nothing was sent.")
            }
            let up = (action["dir"] as? String)?.lowercased() == "up"
            let line = begin("Scroll \(up ? "up" : "down")")
            if let web = context.webArea { await buddy.travel(to: CGPoint(x: web.midX, y: web.midY)) }
            do { _ = try await BrowserBridge.shared.perform("scroll", on: context.page!, ["dy": up ? -600 : 600]) }
            catch {
                // The command may have reached the page before the error: not success, and no blind repeat.
                return end(line, .init(outcome: InputDelivery.pageScroll(error: error), summary: "FAILED: the page scroll did not complete (" + error.localizedDescription + "). It was not reported as done; read the page to see where it is."))
            }
            try? await Task.sleep(for: .milliseconds(450))
            return end(line, .init(ok: true, summary: "scrolled \(up ? "up" : "down")"))

        case "read":
            // Best source first: the web page, the document file behind the window (PDF, Word…), a PDF open in
            // the browser, and finally recognising the text on screen (scans, images, anything else).
            let line = begin("Read")
            var text: String?
            var source = ""
            let short = { (t: String?) in (t?.count ?? 0) < 80 }
            // A specific file (e.g. the user's resume from memory), read without opening it.
            if let path = action["path"] as? String {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard let fileText = await Reader.fileText(url) else {
                    let sandboxed = url.path.contains("/Library/Containers/") || url.path.contains("/Library/Group Containers/")
                    return end(line, fail("couldn't read \(path)" + (sandboxed ? " — it's inside another app's sandbox, which can't be read or copied by path. Open it in Preview and use read with no path (it copies all its text)" : "")))
                }
                readText = "\(url.lastPathComponent):\n\(fileText)"
                return end(line, .init(ok: true, summary: "text of \(url.lastPathComponent):\n\(fileText)"))
            }
            if let page = context.page, !page.url.lowercased().hasSuffix(".pdf"), page.url.hasPrefix("http") || page.url.hasPrefix("file") {
                text = (try? await BrowserBridge.shared.perform("read", on: page))?["text"] as? String
                source = "the web page"
            }
            if short(text), let page = context.page, let url = URL(string: page.url),
               url.pathExtension.lowercased() == "pdf" || page.url.contains(".pdf") {
                text = await Reader.fileText(url)
                source = "the PDF \(url.lastPathComponent)"
            }
            if !Background.active, short(text), let app = context.app, let doc = await Reader.documentText(of: app) {
                text = doc.text
                source = "the document \(doc.name)"
            }
            // A document whose file is out of reach (a PDF from WhatsApp's sandbox opened in Preview): copy all its text
            // instead of reading it a screenful at a time.
            if !Background.active, short(text), let app = context.app,
               app.bundleIdentifier == "com.apple.Preview" || AXEngine.documentURL(of: app) != nil {
                if !Background.active { await Launcher.bringToFront(app) }
                if let all = AXEngine.copiedAll(of: app), !short(all) {
                    text = String(all.prefix(12_000))
                    source = "the document (all its text)"
                }
            }
            if !Background.active, short(text), let app = context.app, let seen = await Reader.ocr(app) {
                text = seen
                source = "the screen (text recognition)"
            }
            guard let text, !text.isEmpty else { return end(line, fail("couldn't read any text here; try look")) }
            if !source.hasPrefix("the screen") { readText = "\(source):\n\(text)" }
            return end(line, .init(ok: true, summary: "text from \(source):\n\(text)"))

        case "click" where action["id"] == nil && action["x"] == nil && action["text"] is String:
            // By the text it shows, found on the window with text recognition: for apps whose buttons and rows the
            // Accessibility tree doesn't show (WhatsApp, Electron and Catalyst apps, canvases), steadier than x/y guesses.
            guard let app = context.app, let want = (action["text"] as? String)?.trimmingCharacters(in: .whitespaces), !want.isEmpty else {
                return fail("click needs an id, a text or x/y")
            }
            let line = begin("Click “\(want.prefix(32))”")
            if let why = staleApp(context) { return end(line, fail(why)) }
            if let why = await approve(want, role: "button", page: context.page) { return end(line, fail(why)) }
            if !Background.active { await Launcher.bringToFront(app) }
            guard let captured = await Screenshot.capture(app: app, window: context.nativeWindow, elements: context.elements),
                  let boxes = await Reader.textBoxes(captured, want: want) else { return end(line, fail("can't read the exact observed window; look again (Screen Recording permission?)")) }
            let key = { (t: String) in t.lowercased().folding(options: .diacriticInsensitive, locale: nil).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            let w = key(want)
            // Exactly that text first, then a line that holds it as words; top to bottom, left to right.
            var hits = boxes.filter { key($0.text) == w }
            if hits.isEmpty {
                hits = boxes.filter { (" " + key($0.text) + " ").contains(" " + w + " ") }
            }
            hits.sort { abs($0.rect.minY - $1.rect.minY) > 6 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
            // The same spot found twice (the part and its whole line): keep one.
            var spots: [(text: String, rect: CGRect)] = []
            for h in hits where !spots.contains(where: { $0.rect.intersects(h.rect) }) { spots.append(h) }
            guard spots.count <= 1 || action["nth"] != nil else { return end(line, fail("multiple text targets match; choose an explicit nth from a fresh observation")) }
            let nth = max(1, (action["nth"] as? NSNumber)?.intValue ?? 1)
            guard spots.count >= nth else {
                let near = boxes.map(\.text).filter { AXEngine.similar($0, want) }.prefix(5)
                return end(line, fail("no text \(want.debugDescription) on the window\(near.isEmpty ? "" : "; similar: " + near.map(\.debugDescription).joined(separator: ", "))"))
            }
            let spot = spots[nth - 1]
            let point = CGPoint(x: spot.rect.midX, y: spot.rect.midY)
            await buddy.travel(to: point, framing: spot.rect)
            let scale = captured.pointScale
            let imageX = (point.x - captured.window.frame.minX) / scale.width
            let imageY = (point.y - captured.window.frame.minY) / scale.height
            guard await captured.validatedScreenPoint(x: imageX, y: imageY) != nil else {
                return end(line, fail("the text target changed after recognition; look again"))
            }
            traceClick(point, in: app)
            let fingerprint = await AXEngine.fingerprintAsync(of: app)
            if let why = await hand.click(at: point, pid: app.processIdentifier, window: context.nativeWindow) { return end(line, fail(why)) }
            let didChange = await changed(app, from: fingerprint, ms: 600)
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            buddy.clearHighlight()
            log(Clicks.line(kind: "text", place: app.cleanName ?? "", method: "real", worked: didChange, tries: 1))
            let more = spots.count > nth ? " (\(spots.count) places show it; this was #\(nth) from the top — add \"nth\" for another)" : ""
            return end(line, .init(outcome: .unverified, summary: "UNVERIFIED: clicked the text \(spot.text.debugDescription)\(more). Verify the intended application outcome.", effect: .look))

        case "click" where action["id"] == nil:
            // By position on the last screenshot, for things with no element (canvas, custom-drawn UI, text links).
            guard let x = (action["x"] as? NSNumber)?.doubleValue, let y = (action["y"] as? NSNumber)?.doubleValue,
                  let p = await context.coordinateCapture?.validatedScreenPoint(x: x, y: y) else { return fail("click needs an id, or fresh x/y on an unchanged observed window") }
            let line = begin("Click")
            if let why = staleApp(context) { return end(line, fail(why)) }
            if !Background.active, let app = context.app { await Launcher.bringToFront(app) }
            traceClick(p, in: context.app)
            if case .success(let options) = ClickOptions.parse(action), !options.isPlain {
                guard let pid = context.app?.processIdentifier, let window = context.coordinateCapture?.window else { return end(line, fail("click options need the observed window; look again")) }
                inputDeliveryStarted = true
                if let why = await hand.click(at: p, options: options, pid: pid, window: window) { return end(line, .init(outcome: .refused, summary: why)) }
                try? await Task.sleep(for: .milliseconds(450))
                if let app = context.app { context.fingerprint = await AXEngine.fingerprintAsync(of: app) }
                return end(line, .init(outcome: .unverified, summary: "UNVERIFIED: \(options.button.rawValue) click ×\(options.count)\(options.modifiers.isEmpty ? "" : " with modifiers")\(options.holdMilliseconds > 0 ? " held \(options.holdMilliseconds) ms" : "") at (\(Int(x)), \(Int(y))) was sent once. Verify the intended application outcome.", effect: .look))
            }
            if let why = await hand.click(at: p, pid: context.app?.processIdentifier, window: context.coordinateCapture?.window) { return end(line, fail(why)) }
            try? await Task.sleep(for: .milliseconds(450))
            if let app = context.app { context.fingerprint = await AXEngine.fingerprintAsync(of: app) }
            return end(line, .init(outcome: .unverified, summary: "UNVERIFIED: clicked at (\(Int(x)), \(Int(y))) on the observed window. Verify the intended application outcome.", effect: .look))

        case "click":
            guard let app = context.app else { return fail("no app") }
            guard let el = await resolve(action["id"], context: &context) else { return fail("element \(action["id"] ?? "?") isn't on screen anymore") }
            let line = begin("Click \(el.shortLabel)")
            if let why = staleApp(context) { return end(line, fail(why)) }
            if let why = await approve(el.label, role: el.role, page: nil) { return end(line, fail(why)) }
            if !Background.active { await Launcher.bringToFront(app) }
            traceClick(el.center, in: app)
            if case .success(let options) = ClickOptions.parse(action), !options.isPlain {
                guard let window = context.nativeWindow, el.observationID == window.id else { return end(line, fail("click options need the element's observed window; look again")) }
                inputDeliveryStarted = true
                if let why = await hand.click(at: el.center, options: options, pid: app.processIdentifier, window: window) { return end(line, .init(outcome: .refused, summary: why)) }
                let moved = await changed(app, from: context.fingerprint, ms: 600)
                context.fingerprint = await AXEngine.fingerprintAsync(of: app)
                buddy.clearHighlight()
                return end(line, .init(outcome: .unverified, summary: "UNVERIFIED: \(options.button.rawValue) click ×\(options.count) on \(el.describe) was sent once\(moved ? " (the screen changed)" : ""). Verify the intended application outcome.", effect: .look))
            }
            if let why = await hand.click(el, in: app, fingerprint: context.fingerprint, window: context.nativeWindow) { return end(line, fail(why)) }
            let didChange = await changed(app, from: context.fingerprint, ms: 600)
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            log(Clicks.line(kind: "ax", place: app.cleanName ?? "", method: hand.lastMethod, worked: didChange, tries: hand.lastMethod == "real" ? 2 : 1))
            buddy.clearHighlight()
            if Self.isFormSubmit(el.label) || Safety.needsConfirmation(label: el.label, request: request) != nil {
                StepUndo.shared.clear()   // sent: putting back what was typed into it would only confuse
            } else if el.role == "AXCheckBox" || el.role == "AXSwitch", line < steps.count {
                let element = el.element
                StepUndo.shared.register(step: steps[line].id, kind: .toggle, label: "Click “\(el.shortLabel)” back") {
                    await Task.detached { AXEngine.axPress(element) }.value
                }
            }
            let toggle = ["AXCheckBox", "AXSwitch", "AXRadioButton"].contains(el.role)
            let now = AXEngine.elements(of: app, window: context.nativeWindow).first { CFEqual($0.element, el.element) }?.value
            let confirmed = toggle && el.value != nil && now != nil && now != el.value
            return end(line, .init(outcome: ActionOutcome(delivery: hand.lastClickUncertain ? .unknown : .delivered, status: confirmed ? .confirmed : .unverified),
                summary: (confirmed ? "CONFIRMED: " : "UNVERIFIED: ") + "clicked \(el.describe)" + (confirmed ? " (target value changed)" : ". Verify the intended application outcome."), effect: confirmed ? .none : .look))

        case "type":
            guard let app = context.app else { return fail("no app") }
            guard let text = action["text"] as? String else { return fail("type needs text") }
            let submit = action["submit"] as? Bool ?? false
            let line = begin("Type “\(text.prefix(40))”")
            if !Background.active { await Launcher.bringToFront(app) }
            if let why = staleApp(context) { return end(line, fail(why)) }
            guard let observedWindow = context.nativeWindow, observedWindow.staleness(includeContent: true) == nil else {
                return end(line, fail("the native window changed before text input; look again"))
            }
            var target = "the focused field"
            if action["id"] != nil {
                guard let el = await resolve(action["id"], context: &context) else { return end(line, fail("element \(action["id"] ?? "?") isn't on screen anymore")) }
                if let why = await hand.focus(el, in: app, window: context.nativeWindow) { return end(line, fail(why)) }
                guard observedWindow.staleness(includeContent: true) == nil else {
                    return end(line, fail("the native target changed while focusing it; look again"))
                }
                target = el.describe
            }
            // What the field held, to put back on undo (never for a password field).
            let field = Self.focusedElement(of: app)
            guard let field, observedWindow.containsElement(field) else {
                return end(line, fail("the focused field belongs to another window; look again"))
            }
            let old = Safety.isSecureField(field) ? nil : Self.axValue(field)
            if let raw = action["mode"] as? String, let mode = TextEditMode(rawValue: raw.lowercased()), mode != .replaceAll {
                inputDeliveryStarted = true
                switch hand.place(text, mode: mode, in: app) {
                case .done(let note):
                    context.fingerprint = await AXEngine.fingerprintAsync(of: app)
                    buddy.clearHighlight()
                    return end(line, .init(ok: true, summary: "CONFIRMED: \(mode.rawValue) in \(target): " + note))
                case .unverified(let why): return end(line, .init(outcome: .unverified, summary: "UNVERIFIED: " + why + ". Read the field before retrying.", effect: .look))
                case .unsupported(let why): return end(line, .init(outcome: .refused, summary: "UNSUPPORTED: " + why + ". The field was not changed; use type with the default replace mode if replacing is acceptable."))
                case .refused(let why): return end(line, .init(outcome: .refused, summary: why))
                }
            }
            inputDeliveryStarted = true
            guard await hand.type(text, in: app) else {
                return end(line, fail(hand.refusal ?? "the text didn't land in \(target) (field shows \((AXEngine.focusedValueShown(of: app) ?? "nothing").prefix(60).debugDescription))"))
            }
            if !submit, let old, line < steps.count {
                StepUndo.shared.register(step: steps[line].id, kind: .text, label: old.isEmpty ? "Clear \(target)" : "Put back the earlier text in \(target)") {
                    AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, old as CFString) == .success
                }
            }
            if submit {
                try? await Task.sleep(for: .milliseconds(120))
                let held = Safety.isSecureField(field) ? nil : Self.axValue(field)
                if let blocked = submitBlocked(expected: text, actual: held, unreadable: Safety.isSecureField(field)) { return end(line, blocked) }
                guard hand.press("return") else { return end(line, .init(outcome: .uncertain, summary: "UNVERIFIED: Return may not have been delivered (" + (hand.refusal ?? "press failed") + "). Read and verify before retrying.", effect: .look)) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            buddy.clearHighlight()
            return end(line, .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into \(target)\(submit ? " and pressed Return" : "")"))

        case "key":
            guard let keys = action["keys"] as? String else { return fail("key needs keys") }
            let line = begin("Press \(keys)")
            if keys.lowercased().range(of: #"(?:^|[+ ])(return|enter)(?:$|[+ ])"#, options: .regularExpression) != nil,
               let why = await approveReturn(context.page) { return end(line, fail(why)) }
            if !Background.active, let app = context.app { await Launcher.bringToFront(app) }
            if context.page == nil {
                guard let app = context.app, let window = context.nativeWindow,
                      window.staleness(includeContent: true) == nil,
                      let selected = AXEngine.selectedWindow(of: app), window.containsElement(selected) else {
                    return end(line, fail("the native key target changed since the observation; look again"))
                }
            }
            guard await pagePress(keys, context.page) else { return end(line, fail(hand.refusal ?? "couldn't press \(keys)")) }
            var didChange = false
            if !Background.active, let app = context.app {
                didChange = await changed(app, from: context.fingerprint, ms: 450)
                context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            }
            return end(line, .init(ok: true, summary: "pressed \(keys)\(didChange ? "" : " (no visible change)")"))

        case "scroll":
            guard let app = context.app else { return fail("no app") }
            // Direction, unit and amount are honoured or refused, never ignored (desktop agent: ScrollPlan).
            let plan: ScrollPlan
            switch ScrollPlan.parse(action) {
            case .success(let parsed): plan = parsed
            case .failure(let error): return fail(error.message)
            }
            let line = begin("Scroll \(plan.direction.rawValue)")
            if let why = await hand.scroll(plan, in: app, window: context.nativeWindow) { return end(line, fail(why)) }
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            return end(line, .init(ok: true, summary: "scrolled \(plan.direction.rawValue)" + (plan.isDefault ? "" : " \(Int(plan.amount)) \(plan.unit.rawValue)")))

        case "applescript":
            guard let script = action["script"] as? String else { return fail("applescript needs script") }
            let line = begin("Run a script")
            // Closing a document without saving throws away the user's unsaved work: only on their word.
            if script.range(of: #"(?i)\bsaving\s+no\b"#, options: .regularExpression) != nil, !userConfirmed {
                let reply = await askUser("This closes a document without saving — any unsaved changes in it would be lost. Go ahead?",
                                          options: ["Yes, discard them", "No, keep the document"])
                guard reply.map(Safety.isYes) ?? false || reply?.lowercased().hasPrefix("yes") == true else {
                    return end(line, fail("the user said not to close it without saving. To undo a script's changes, press cmd+z "
                                          + "(once per change) in the document instead; never close it unsaved"))
                }
            }
            // Before a script deletes or replaces content in a document, its file (as last saved) is copied aside.
            let backup = Self.destructive(script) ? await DocBackup.save(forScript: script) : nil
            if let backup { log("    backed up \(backup.lastPathComponent) before the script") }
            // In a background run nothing comes forward: `activate` would put the app in front of the user.
            let quiet = Background.active ? script
                .replacingOccurrences(of: #"(?im)^(\s*)activate\s*$"#, with: "$1launch", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\bto activate\b"#, with: "to launch", options: .regularExpression) : script
            inputDeliveryStarted = true
            let r = await Shell.run("/usr/bin/osascript", ["-e", quiet], timeout: 280)
            Background.sweep()
            log("    script result (\(r.status)): \(r.output.prefix(600))")
            let saved = backup.map { "\n(The document as last saved was copied to \($0.path) first.)" } ?? ""
            return end(line, .init(ok: r.status == 0, summary: (r.status == 0 ? "AppleScript ok\(r.output.isEmpty ? "" : ": \(r.output.prefix(1500))")" : "AppleScript failed: \(r.output.prefix(400))") + saved))

        case "shell":
            guard let cmd = action["cmd"] as? String else { return fail("shell needs cmd") }
            let line = begin("Look something up")
            // A glob that matches nothing stays as typed (so `ls a/*.pem b/*.pem` still lists what exists) instead of
            // zsh aborting the whole line with "no matches found".
            // No pager: git log/diff would otherwise wait on `less` until the timeout. In a background run, `open` opens
            // things without bringing their app forward (the run's sweep then moves the window to the hidden screen).
            let run = Background.active ? Self.openQuietly(cmd) : cmd
            inputDeliveryStarted = true
            let r = await Shell.run("/bin/zsh", ["-lc", "setopt no_nomatch 2>/dev/null\nexport GIT_PAGER=cat PAGER=cat\n" + run], timeout: 20)
            Background.sweep()
            let hint = r.status == 0 ? "" : Self.shellHint(r.output)
            return end(line, .init(ok: r.status == 0, summary: "exit \(r.status)\(r.output.isEmpty ? "" : ": \(r.output.prefix(2000))")\(hint)"))

        case "pdf":
            // iLovePDF-style jobs, done in the background with PDFKit; no app opens.
            guard let op = (action["op"] as? String)?.lowercased() else { return fail("pdf needs op") }
            let paths = (action["files"] as? [String]) ?? (action["file"] as? String).map { [$0] } ?? []
            let files = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let line = begin("PDF: \(op.replacingOccurrences(of: "_", with: " ")) \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")")
            do {
                return end(line, .init(ok: true, summary: try await Pdf.run(op, files: files, options: action)))
            } catch {
                return end(line, fail(error.localizedDescription))
            }

        case "media":
            // Video/audio jobs with AVFoundation: no time limit, and progress keeps the watchdog from stopping long exports.
            guard let op = (action["op"] as? String)?.lowercased() else { return fail("media needs op") }
            let paths = (action["files"] as? [String]) ?? (action["file"] as? String).map { [$0] } ?? []
            let files = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let title = "Video: \(op.replacingOccurrences(of: "_", with: " ")) \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")"
            let line = begin(title)
            do {
                let summary = try await Media.run(op, files: files, options: action) { [weak self] p in
                    guard let self, line < self.steps.count else { return }
                    self.lastProgress = Date()
                    self.steps[line].text = "\(title) · \(Int(p * 100))%"
                }
                if line < steps.count { steps[line].text = title }
                return end(line, .init(ok: true, summary: summary))
            } catch {
                return end(line, fail(error.localizedDescription))
            }

        case "email":
            // Sent by the Mail app in the background (draft:true opens it for the user to review instead).
            let list = { (key: String) in (action[key] as? [String]) ?? (action[key] as? String).map { [$0] } ?? [] }
            let to = list("to"), cc = list("cc")
            let files = list("files").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            guard !to.isEmpty, to.allSatisfy({ $0.contains("@") }) else { return fail("email needs to: real email addresses (recall or ask for them)") }
            if let missing = files.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) { return fail("no such file: \(missing.path)") }
            let draft = action["draft"] as? Bool ?? false
            let subject = (action["subject"] as? String) ?? files.first?.deletingPathExtension().lastPathComponent ?? ""
            // An address the user never gave (not in their request, what they selected, their answers or memory) may
            // come from a page or email trying to steer Clinqy: always confirm those, whatever the request said.
            let known = ([request, selectedText ?? ""] + userAnswers + Memory.facts).joined(separator: "\n").lowercased()
            let strangers = (to + cc).filter { !known.contains($0.lowercased()) }
            if !draft, !strangers.isEmpty {
                let reply = await askUser("Send this to \(strangers.joined(separator: ", "))? That address came from what I read, not from you.",
                                          options: ["Yes, send it", "No"])
                guard let reply, Safety.isYes(reply) else { return fail("the user didn't confirm sending to \(strangers.joined(separator: ", ")); don't send it") }
                userAnswers.append(strangers.joined(separator: " "))
            }
            if !draft, !(await confirmRisky("Send email")) { return fail("the user said not to send it") }
            let line = begin("\(draft ? "Draft" : "Email") \(to.joined(separator: ", "))\(files.isEmpty ? "" : " · \(files.count) attachment\(files.count == 1 ? "" : "s")")")
            let r = await Mailer.send(to: to, cc: cc, subject: subject, body: (action["body"] as? String) ?? "", attachments: files, draft: draft)
            return end(line, r.ok ? .init(ok: true, summary: draft ? "draft open in Mail for the user to review" : "sent from Mail to \(to.joined(separator: ", "))")
                                  : fail("Mail couldn't send: \(r.message.prefix(300))"))

        case "point", "mark":
            // Mark an element, or a spot on the last screenshot (for things without an element).
            var rect: CGRect?
            var name = "that"
            if action["id"] != nil {
                guard let el = await resolve(action["id"], context: &context) else { return fail("element \(action["id"] ?? "?") isn't on screen anymore") }
                rect = el.frame
                name = el.shortLabel
            } else if let x = (action["x"] as? NSNumber)?.doubleValue, let y = (action["y"] as? NSNumber)?.doubleValue,
                      let p = context.coordinateCapture?.screenPoint(x: x, y: y) {
                let w = (action["w"] as? NSNumber)?.doubleValue ?? 36, h = (action["h"] as? NSNumber)?.doubleValue ?? 36
                let scale = context.coordinateCapture?.pointScale ?? CGSize(width: 1, height: 1)
                rect = CGRect(x: p.x - w * scale.width / 2, y: p.y - h * scale.height / 2, width: w * scale.width, height: h * scale.height)
            }
            guard let rect else { return fail("point needs an id, or x/y on the last screenshot") }
            let line = begin("Show \(name)")
            await buddy.mark(rect, label: action["label"] as? String)
            hand.lingerBeforeHome = 3.5
            return end(line, .init(ok: true, summary: "marked it on screen with a circle and arrow"))

        case "ask" where (telegramOwned || (!reviewedForm && !userConfirmed)) && context.page != nil && Self.asksToSubmit(action):
            // "Ready to submit?" is answered by the review: every answer on the form, with Submit or Edit.
            reviewedForm = true   // local review shown once; Telegram edits can require another review
            let line = begin("Review before submitting")
            guard let ok = await reviewBeforeSubmit(context.page!) else { return await perform(action, context: &context) }   // no form: just ask
            return end(line, ok ? .init(ok: true, summary: "the user checked every answer on the form and approved submitting: submit now, without asking again")
                                : fail(editedReview))

        case "ask" where qa == nil && !profileOffered.contains(action["question"] as? String ?? "") && Self.profileAnswer(for: action) != nil:
            // Standard application answers (CTC, notice period, links…) and earlier form answers are in the profile.
            // Once per question: if it doesn't fit, asking again goes through.
            let (q, a) = Self.profileAnswer(for: action)!
            profileOffered.insert(q)
            log("  profile answers “\(q.prefix(60))”")
            return .init(ok: false, summary: "NOT ASKED — the job-application profile already answers this: \(q) → \(a). Use it.")

        case "ask" where !Self.isConfirmation(action["question"] as? String ?? "") && !memoryCheckedAsks.contains(action["question"] as? String ?? ""):
            // Before bothering the user, look in memory (once per question): each part of the question is matched like
            // a form field ("your 10th and 12th details: board, percentage" → the school marks fact), and a question
            // for their own details also gets a full search. Facts already shown don't stop it: the model saw them.
            // So asking straight away costs one turn whether memory has it or not (recall, then ask, costs two).
            let q = action["question"] as? String ?? ""
            memoryCheckedAsks.insert(q)
            let parts = [q] + q.components(separatedBy: CharacterSet(charactersIn: ",;:?()\n")).filter { $0.count >= 3 }
            var hits = Memory.forPage(labels: parts, excluding: shownFacts, app: context.app?.cleanName,
                                      host: context.page.map { Memory.bareHost($0.url) }, limit: 8)
            if hits.isEmpty, Self.asksForPersonalDetails(q) { hits = Array(Memory.search(q).prefix(15)) }
            guard !hits.isEmpty else { return await perform(action, context: &context) }
            shownFacts.formUnion(hits)
            log("  memory answers the question (\(hits.count) fact\(hits.count == 1 ? "" : "s")) — not asked")
            return .init(ok: false, summary: "NOT ASKED — you already remember this about the user (use it, and ask only for what's truly missing):\n"
                         + hits.map { "- \($0)" }.joined(separator: "\n"))

        case "ask" where qa != nil:
            return fail("this is an unattended test — nobody can answer; assert the missing information as a failed check and finish")

        case "verify":
            return await verify(action, context: &context)

        case "assert":
            // QA: the model's verdict on an expectation, kept as a deterministic "text is visible" check.
            let text = (action["text"] as? String) ?? ""
            let pass = action["pass"] as? Bool ?? false
            let note = (action["note"] as? String) ?? ""
            let line = begin("Check “\(text.prefix(50))”")
            qa?.checks.append(.init(text: text, pass: pass, note: note))
            buddy.signal(pass)
            return end(line, .init(ok: true, summary: "recorded check: \(pass ? "PASS" : "FAIL") \(text)"))

        case "ask":
            guard let text = action["question"] as? String, !text.isEmpty else { return fail("ask needs a question") }
            let options = (action["options"] as? [String]) ?? []
            let sensitive = action["sensitive"] as? Bool ?? false
            let line = begin("Ask: \(text.prefix(60))")
            let reply = await askUser(text, options: options, sensitive: sensitive)
            guard let reply, !reply.isEmpty, !Task.isCancelled else {
                return end(line, fail("the user didn't answer; stop here and say what's still needed"))
            }
            if sensitive { secrets.append(reply) } else { log("  user answered: \(reply.prefix(200))") }
            if !options.isEmpty, Safety.isYes(reply) { userConfirmed = true }
            // An answer to an application form's question is kept for the next application that asks it (never a code).
            if !sensitive, !isTest || saveInTests, qa == nil, context.page != nil, Self.mayMeetForms(request), !Self.isConfirmation(text),
               text.range(of: #"(?i)\b(otp|code|password|passcode|pin|cvv)\b"#, options: .regularExpression) == nil,
               reply.count < 300, !Safety.isYes(reply) {
                if !Profile.remember(question: text, answer: reply) { log("🧠 couldn't save the answer to “\(text.prefix(60))” (profile write failed)") }
            }
            phase = .acting
            buddy.mood = .acting
            if !runBackground, let app = context.app { await Launcher.bringToFront(app) }
            return end(line, .init(ok: true, summary: sensitive ? "the user supplied the private input" : "the user answered: \(reply)"))

        case "show":
            guard let card = ResultCard(action: action) else { return fail("show needs text or items") }
            steps.append(Step(text: "Showed: \(card.title)", state: .info))
            runResult = card
            result = card
            onResult()
            return .init(ok: true, summary: "shown to the user on screen")

        case "recall":
            let query = (action["query"] as? String) ?? ""
            let line = begin("Recall \(query.prefix(40))")
            let hits = Memory.search(query)
            shownFacts.formUnion(hits.prefix(5))
            // What memory used to say, too: earlier wordings of a hit, and dropped lines that match.
            let changes = Memory.history
            var lines = hits.map { hit -> String in
                let was = Memory.earlier(hit, in: changes)
                return "- \(hit)" + (was.isEmpty ? "" : " (earlier: " + was.map { "“\($0)”" }.joined(separator: "; ") + ")")
            }
            let live = Set(Memory.facts)
            let gone = Memory.searchHistory(query).filter { c in c.new == nil && !live.contains(c.old) }
            if !gone.isEmpty {
                lines.append("No longer true (forgotten):")
                lines += gone.map { "- \($0.old) (\($0.why), \($0.at.formatted(date: .abbreviated, time: .omitted)))" }
            }
            let past = await TaskMemory.shared.context(for: query, app: context.app?.cleanName)
            if !past.isEmpty { lines.append(past) }
            return end(line, .init(ok: true, summary: lines.isEmpty ? "nothing remembered about that"
                                   : "remembered:\n" + lines.joined(separator: "\n")))

        case "dictionary":
            // The app's own scripting vocabulary, for an applescript fallback.
            guard let app = context.app, Scripting.isScriptable(app) else { return fail("this app isn't scriptable") }
            let line = begin("Check \(app.cleanName ?? "the app")'s scripting")
            guard let dict = await Scripting.dictionary(for: app) else { return end(line, fail("couldn't read its dictionary")) }
            return end(line, .init(ok: true, summary: dict))

        case "look":
            return .init(ok: true, summary: "screenshot attached next turn", effect: .look)

        case "think":
            guard let question = action["question"] as? String, !question.isEmpty else { return fail("think needs a question") }
            let line = begin("Think it through")
            return end(line, await think(question))

        case "wait" where action["for"] is String:
            return await waitFor(action["for"] as! String, gone: action["gone"] as? Bool == true,
                                 // Up to 2 minutes: a deploy or a database coming up is one long wait, not ten turns of 30 s ones.
                                 seconds: min(120, max(1, (action["seconds"] as? NSNumber)?.doubleValue ?? (action["timeout"] as? NSNumber)?.doubleValue ?? 10)), context: &context)

        case "wait" where Background.active:
            let ms = min(5000, max(0, action["ms"] as? Int ?? 600))
            try? await Task.sleep(for: .milliseconds(ms))
            return .init(ok: true, summary: "Waited \(ms) ms")

        case "wait":
            let ms = min(5000, (action["ms"] as? Int) ?? 600)
            guard let app = context.app, ms >= 1500 else {
                try? await Task.sleep(for: .milliseconds(ms))
                if let app = context.app { context.fingerprint = await AXEngine.fingerprintAsync(of: app) }
                return .init(ok: true, summary: "waited \(ms) ms")
            }
            // Most long waits are "let it load": they end once it has — the screen changed and then held still for
            // 0.8 s. A screen that never changes gets the full wait (then it's for something outside, like an email).
            let started = Date()
            var last = await AXEngine.fingerprintAsync(of: app)
            var changed = false, stillSince = Date()
            while Date().timeIntervalSince(started) * 1000 < Double(ms), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let now = await AXEngine.fingerprintAsync(of: app)
                if now != last { changed = true; stillSince = Date(); last = now }
                else if changed, Date().timeIntervalSince(stillSince) >= 0.8 { break }
            }
            context.fingerprint = last
            let waited = Int(Date().timeIntervalSince(started) * 1000)
            return .init(ok: true, summary: waited < ms - 200 ? "waited \(waited) ms (the screen settled)" : "waited \(ms) ms")

        case "snap":
            if Background.active {
                guard let tab = Background.tab, let png = await BrowserBridge.shared.taskScreenshot(of: tab) else { return fail("Worker screenshot unavailable") }
                let caption = Self.snapCaption(action["caption"] as? String ?? "", number: snaps.count + 1)
                snaps.append((caption, png, false)); lastSnapAt = Date()
                let file = saveSnap(png, caption: caption)
                if action["send"] as? Bool == true { return await deliverSnapshot(png, file: file, caption: caption) }
                return .init(ok: true, summary: "Worker screenshot saved" + (file.map { " to " + $0.path } ?? ""))
            }
            // A step screenshot for a write-up: copied like ⌃⌘⇧4 (clipboard only, no file) and kept for paste_snaps.
            guard let app = context.app else { return fail("no app to screenshot") }
            let given = ((action["caption"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let caption = Self.snapCaption(given, number: snaps.count + 1)
            let line = begin("Screenshot: \(caption.prefix(40))")
            if !Background.active { await Launcher.bringToFront(app) }   // a window half under another app shows the other app in the shot
            try? await Task.sleep(for: .milliseconds(600))   // let the last step (a tab switch, a page load) finish drawing
            guard let png = await Screenshot.windowPNG(app: app) else { return end(line, fail("couldn't capture the window (Screen Recording permission?)")) }
            snaps.append((caption, png, false))
            lastSnapAt = Date()
            if snaps.count > 80 { snaps.removeFirst(snaps.count - 80) }
            let file = saveSnap(png, caption: caption)
            if action["send"] as? Bool == true { return end(line, await deliverSnapshot(png, file: file, caption: caption)) }
            let board = NSPasteboard.general
            board.clearContents()
            board.setData(png, forType: .png)
            let waiting = snaps.filter { !$0.pasted }.count
            return end(line, .init(ok: true, summary: "screenshot taken (\(caption.prefix(60).debugDescription)), copied"
                + (file.map { " and saved to \($0.path)" } ?? "") + (TaskCompletionPolicy.requestsWriteUp(request) ? "; \(waiting) not pasted into the doc yet" : "; use image with this saved path and send:true to deliver it when requested")))

        case "paste_snaps":
            // Into the document that has the caret: each caption, then its screenshot, in order.
            guard let app = context.app else { return fail("no app") }
            let todo = snaps.indices.filter { !snaps[$0].pasted }
            guard !todo.isEmpty else {
                return fail(snaps.isEmpty ? "no screenshots taken yet; use snap first" : "all \(snaps.count) screenshots are already pasted; snap new steps first")
            }
            let line = begin("Paste \(todo.count) screenshots")
            if !Background.active { await Launcher.bringToFront(app) }
            // Only items delivered start to finish are marked pasted; a stop leaves the rest (and any lone caption) known.
            let report = await hand.pasteSnaps(todo.map { (snaps[$0].caption, snaps[$0].png) }, in: app)
            for k in report.inserted { snaps[todo[k]].pasted = true }
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            if report.inserted.count < todo.count {
                let lone = report.partial.map { "; the caption \(snaps[todo[$0]].caption.prefix(40).debugDescription) went in without its picture, check the document" } ?? ""
                return end(line, fail("pasted \(report.inserted.count) of \(todo.count) screenshots; stopped because \(report.stopped ?? "delivery was interrupted")\(lone). "
                    + "The rest are not marked pasted; look at the document before using paste_snaps again"))
            }
            return end(line, .init(ok: true, summary: "delivered \(todo.count) captioned screenshots where the caret was ("
                + "\(snaps[todo.first!].caption.prefix(40).debugDescription) … \(snaps[todo.last!].caption.prefix(40).debugDescription))"
                + "; the app does not let Clinqy read the document back, so look to confirm"
                + (snapFolder.map { "; all of them are also saved in \($0.path)" } ?? "")))

        case "remember":
            guard let fact = action["fact"] as? String else { return fail("remember needs fact") }
            guard Memory.add(fact, scope: Memory.Scope(action["scope"] as? String)) else {
                return fail("the fact was NOT saved: Clinqy's memory file could not be written. Do not tell the user it was remembered")
            }
            steps.append(Step(text: "Remembered: \(fact)", state: .info))
            return .init(ok: true, summary: "saved")

        case "images":
            guard let page = context.page else { return fail("Open a browser page before listing images.") }
            let line = begin("List page images")
            do {
                let raw = try await BrowserBridge.shared.perform("images", on: page)
                let images = raw["images"] as? [[String: Any]] ?? []
                let text = images.enumerated().map { index, item in
                    "image \(index + 1): \(item["alt"] as? String ?? "(no label)") · \(item["width"] ?? 0)×\(item["height"] ?? 0) · \(item["visible"] as? Bool == true ? "visible" : "below viewport") · \(item["url"] as? String ?? "")"
                }.joined(separator: "\n")
                return end(line, .init(ok: true, summary: "Article images in document order (navigation, ads and tiny icons excluded):\n" + (text.isEmpty ? "No supported images found. Scroll to load lazy content and try again." : text)))
            } catch { return end(line, fail(error.localizedDescription)) }
        case "image":
            let line = begin(action["send"] as? Bool == true ? "Send image" : "Inspect image")
            do {
                let asset: ImageAsset
                if let path = action["path"] as? String {
                    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
                    guard ImageAssets.authorizedLocal(url, inputs: selectedFiles + outputFiles) else { throw ImageAssets.failure("Use an exact image path attached to this task.") }
                    asset = try ImageAssets.local(url)
                } else {
                    guard let page = context.page else { throw ImageAssets.failure("Open a task page first.") }
                    let raw = try await BrowserBridge.shared.perform("images", on: page)
                    let images = raw["images"] as? [[String: Any]] ?? []
                    let index = (action["index"] as? Int ?? 1) - 1
                    guard images.indices.contains(index), let source = images[index]["url"] as? String else { throw ImageAssets.failure("Image index unavailable. Use images to read the current list.") }
                    let title = images[index]["alt"] as? String ?? page.title
                    do { asset = try await ImageAssets.remote(source, title: title) }
                    catch {
                        guard let tabID = page.tabId,
                              let live = await BrowserBridge.shared.snapshot(of: .init(id: tabID, url: page.url, connection: page.connection)),
                              let documentID = page.documentID, live.documentID == documentID, live.url == page.url,
                              let current = try? await BrowserBridge.shared.perform("images", on: live),
                              let same = (current["images"] as? [[String: Any]])?.first(where: { $0["url"] as? String == source }),
                              let rect = same["rect"] as? [String: Any],
                              let x = rect["x"] as? Double, let y = rect["y"] as? Double,
                              let width = rect["width"] as? Double, let height = rect["height"] as? Double,
                              let shot = await BrowserBridge.shared.taskScreenshot(of: .init(id: tabID, url: page.url, connection: page.connection)) else { throw error }
                        asset = try ImageAssets.renderedCrop(shot, rect: CGRect(x: x, y: y, width: width, height: height), viewport: live.viewport, source: source, title: title)
                    }
                }
                pendingVisualImage = asset
                if action["send"] as? Bool == true {
                    guard telegramOwned, requiredImageOutputs > 0 else { throw ImageAssets.failure("Image delivery requires a Telegram task that explicitly asks for images.") }
                    if !deliveredImageKeys.contains(asset.key) {
                        guard await Telegram.shared.deliverImage(asset, caption: action["caption"] as? String ?? asset.title, from: self) else {
                            throw ImageAssets.failure("Photo delivery was not acknowledged. Do not claim it was sent or retry blindly; ask the user to inspect the chat.")
                        }
                        deliveredImageKeys.insert(asset.key); deliveredImageOutputs += 1
                    }
                    return end(line, .init(ok: true, summary: "Actual photo delivered to Telegram (acknowledged), source: " + asset.source))
                }
                return end(line, .init(ok: true, summary: "Actual image pixels attached to your next observation. Source: " + asset.source + ". Use image with send:true to deliver it when requested; reading is not delivery."))
            } catch { return end(line, fail(error.localizedDescription)) }

        case "extract":
            // Structured data out of the page's tables, a CSV, or a document/screen's text for the model to structure.
            let line = begin("Extract data")
            if let path = (action["path"] ?? action["file"]) as? String {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                if ["csv", "tsv"].contains(url.pathExtension.lowercased()), let sample = Tables.readSample(url) {
                    return end(line, .init(ok: true, summary: "\(url.lastPathComponent): \(sample.rows.count) rows\(sample.truncated ? " (excerpt; more data not shown)" : "")\n"
                        + sample.rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")))
                }
                guard let text = await Reader.fileText(url) else { return end(line, fail("couldn't read \(path)")) }
                return end(line, .init(ok: true, summary: "text of \(url.lastPathComponent) (pick out the rows/fields yourself):\n\(text.prefix(12000))"))
            }
            if let page = context.page {
                let tables = (try? await BrowserBridge.shared.perform("tables", on: page, timeout: 8))?["tables"] as? [[String: Any]] ?? []
                if !tables.isEmpty {
                    return end(line, .init(ok: true, summary: "\(tables.count) table\(tables.count == 1 ? "" : "s") on \(page.title.prefix(60).debugDescription):\n"
                        + Tables.describe(tables).prefix(15000)))
                }
                let text = (try? await BrowserBridge.shared.perform("read", on: page))?["text"] as? String ?? page.text
                return end(line, .init(ok: true, summary: "no tables on the page; its text (pick out the rows yourself):\n\(text.prefix(12000))"))
            }
            if !Background.active, let app = context.app, let doc = await Reader.documentText(of: app) {
                return end(line, .init(ok: true, summary: "text of \(doc.name) (pick out the rows/fields yourself):\n\(doc.text.prefix(12000))"))
            }
            if !Background.active, let app = context.app, let seen = await Reader.ocr(app) {
                return end(line, .init(ok: true, summary: "text on screen (pick out the rows yourself):\n\(seen.prefix(12000))"))
            }
            return end(line, fail("nothing to extract from here; give path, or open the page/file first"))

        case "table":
            // Rows written out: a CSV file, a new Numbers/Excel document, or the clipboard for pasting into cells.
            guard let raw = action["rows"] as? [[Any]], !raw.isEmpty else { return fail("table needs rows: [[\"header\", …], [\"value\", …]]") }
            let rows = raw.map { $0.map { v in (v as? String) ?? (v as? NSNumber)?.stringValue ?? (v is NSNull ? "" : "\(v)") } }
            let to = (action["to"] as? String ?? "csv").lowercased()
            let line = begin("Table → \(to) (\(rows.count) rows)")
            do {
                let summary = try await Tables.save(rows, to: to, path: action["path"] as? String, title: action["title"] as? String,
                                                    append: action["append"] as? Bool ?? false)
                if to == "numbers" || to == "excel" {
                    try? await Task.sleep(for: .milliseconds(1200))
                    context.app = Background.active ? Background.app : NSWorkspace.shared.frontmostApplication
                    await refresh(&context)
                }
                return end(line, .init(ok: true, summary: summary))
            } catch { return end(line, fail(error.localizedDescription)) }

        case "event", "calendar":
            let op = (action["op"] as? String ?? "create").lowercased()
            let line = begin(op == "create" || op == "add" ? "Calendar: \((action["title"] as? String ?? "event").prefix(40))" : "Calendar: \(op)")
            if op == "delete" || op == "remove", !(await confirmRisky("Delete event")) { return end(line, fail("the user said not to delete it")) }
            do { return end(line, .init(ok: true, summary: try await Events.event(action))) }
            catch { return end(line, fail(error.localizedDescription)) }

        case "reminder":
            let op = (action["op"] as? String ?? "create").lowercased()
            let line = begin(op == "create" || op == "add" ? "Reminder: \((action["title"] as? String ?? "").prefix(40))" : "Reminders: \(op)")
            do { return end(line, .init(ok: true, summary: try await Events.reminder(action))) }
            catch { return end(line, fail(error.localizedDescription)) }

        case "files":
            return await files(action)

        case "tab":
            return await tab(action, context: &context)

        case "menu":
            guard let path = action["path"] as? String, let app = context.app else { return fail("menu needs path (\"File > Export…\") and an app in front") }
            let line = begin("Menu: \(path.prefix(40))")
            if let why = staleApp(context) { return end(line, fail(why)) }
            if !Background.active { await Launcher.bringToFront(app) }
            let r = await Task.detached { AXEngine.pressMenu(path, in: app) }.value
            try? await Task.sleep(for: .milliseconds(300))
            await refresh(&context)
            if r.uncertain { return end(line, .init(outcome: .uncertain, summary: "UNVERIFIED: " + r.note, effect: .look)) }
            return end(line, r.ok ? .init(ok: true, summary: r.note) : fail(r.note))

        case "window":
            guard let app = context.app else { return fail("no app") }
            let op = (action["op"] as? String ?? "").lowercased()
            let num = { (k: String) in (action[k] as? NSNumber)?.doubleValue }
            let what: AXEngine.WindowAction
            switch op {
            case "move":
                guard let x = num("x"), let y = num("y") else { return fail("window move needs x and y (screen points)") }
                what = .move(CGPoint(x: x, y: y))
            case "resize":
                guard let w = num("w") ?? num("width"), let h = num("h") ?? num("height") else { return fail("window resize needs w and h") }
                what = .resize(CGSize(width: w, height: h))
            case "minimize": what = .minimize
            case "restore": what = .restore
            case "fullscreen": what = .fullscreen(action["on"] as? Bool ?? true)
            case "close": what = .close
            case "raise": what = .raise
            default: return fail("window op: move, resize, minimize, restore, fullscreen, close or raise")
            }
            let line = begin("Window: \(op)")
            if let why = staleApp(context) { return end(line, fail(why)) }
            let title = action["title"] as? String
            let r = await Task.detached { AXEngine.window(what, in: app, titled: title) }.value
            await refresh(&context)
            return end(line, r.ok ? .init(ok: true, summary: r.note) : fail(r.note))

        case "schedule":
            guard let task = action["request"] as? String, !task.isEmpty, let when = action["when"] as? String else {
                return fail("schedule needs request and when")
            }
            let line = begin("Schedule: \(task.prefix(40))")
            guard let summary = Scheduler.add(request: task, phrase: when) else {
                return end(line, fail("couldn't read \(when.debugDescription) as a time; say it like \"at 9am\", \"tomorrow 8:30\", "
                                      + "\"in 20 minutes\", \"every weekday at 9\" or \"every hour\""))
            }
            return end(line, .init(ok: true, summary: summary + " (Clinqy runs it then, if the Mac is awake)"))

        case "remember_answer":
            guard let q = action["question"] as? String, let a = action["answer"] as? String, !q.isEmpty, !a.isEmpty else {
                return fail("remember_answer needs question and answer")
            }
            if !isTest || saveInTests {
                guard Profile.remember(question: q, answer: a) else {
                    return fail("the answer was NOT saved: the profile file could not be written (or the answer was refused). Do not tell the user it was saved")
                }
            }
            steps.append(Step(text: "Saved answer: \(q.prefix(40))", state: .info))
            return .init(ok: true, summary: "saved for future forms")

        default:
            return fail("unknown action \(kind.debugDescription)")
        }
    }

    /// Why acting on the app the model saw would be wrong now: it quit, or its pid belongs to a new process.
    private func staleApp(_ context: ActionContext) -> String? {
        guard let id = context.identity, !AXEngine.isSameProcess(id) else { return nil }
        return "\(context.app?.cleanName ?? "the app") quit or restarted since the last look; look again"
    }

    /// Marks where a click is about to land on the latest screenshot (runs/<run>/step<N>.jpg), for chasing misclicks.
    private func traceClick(_ point: CGPoint, in app: NSRunningApplication?) {
        guard !isTest, !runDry, let app else { return }
        clickCount += 1
        let (n, id) = (clickCount, runID)
        Task { await Screenshot.saveClickTrace(app: app, point: point, step: n, runID: id) }
    }

    /// Undo for a step that navigated: close the tab it opened, else go back in the tab.
    private func registerNavigationUndo(_ line: Int, label: String, closing tab: Int?, app: NSRunningApplication?) {
        guard !runDry, line < steps.count else { return }
        StepUndo.shared.register(step: steps[line].id, kind: .navigation, label: label) {
            let bridge = BrowserBridge.shared
            if let tab { return (try? await bridge.closeTab(tab, in: app)) != nil }
            guard let current = await bridge.activeTab(in: app) else { return false }
            return await bridge.tabCommand("goBack", on: current, ["tabId": current.id]) != nil
        }
    }

    /// The app's focused element (to read, or later restore, a native field's text).
    private static func focusedElement(of app: NSRunningApplication) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// Finder jobs without Finder: Spotlight search, listing, renaming/moving (undoable), sorting a folder, trash.
    private func files(_ action: [String: Any]) async -> ActionResult {
        let op = (action["op"] as? String ?? "find").lowercased()
        let path = { (s: String) in URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        let list = { (key: String) in ((action[key] as? [String]) ?? (action[key] as? String).map { [$0] } ?? []).map(path) }
        let folder = (action["folder"] as? String).map(path)
        switch op {
        case "find", "search":
            let query = action["query"] as? String
            let line = begin("Find files\(query.map { ": \($0.prefix(30))" } ?? "")")
            let hits = await Files.find(query: query, kind: action["kind"] as? String, from: action["from"] as? String,
                                        days: (action["days"] as? NSNumber)?.intValue, folder: folder,
                                        limit: min(50, (action["limit"] as? NSNumber)?.intValue ?? 20))
            return end(line, .init(ok: true, summary: hits.isEmpty ? "no files match (try fewer words, another kind, or more days)"
                                   : "\(hits.count) files, newest first:\n" + hits.map(Files.describe).joined(separator: "\n")))

        case "list":
            guard let folder else { return fail("files list needs folder") }
            let line = begin("List \(folder.lastPathComponent)")
            do { return end(line, .init(ok: true, summary: try Files.list(folder, sort: (action["sort"] as? String ?? "date").lowercased(), limit: 60))) }
            catch { return end(line, fail(error.localizedDescription)) }

        case "rename", "move":
            var pairs: [(URL, URL)] = []
            if op == "rename" {
                for r in action["renames"] as? [[String: Any]] ?? [] {
                    guard let from = (r["from"] as? String).map(path), let to = r["to"] as? String, !to.isEmpty else { continue }
                    pairs.append((from, to.contains("/") ? path(to) : from.deletingLastPathComponent().appendingPathComponent(to)))
                }
            } else {
                guard let dest = (action["to"] as? String).map(path) else { return fail("files move needs to (a folder)") }
                pairs = list("files").map { ($0, dest.appendingPathComponent($0.lastPathComponent)) }
            }
            guard !pairs.isEmpty else { return fail(op == "rename" ? "files rename needs renames: [{\"from\": path, \"to\": new name}]" : "files move needs files") }
            let line = begin("\(op == "rename" ? "Rename" : "Move") \(pairs.count) file\(pairs.count == 1 ? "" : "s")")
            do {
                let (done, skipped) = try Files.apply(pairs)
                return end(line, .init(ok: !done.isEmpty, summary: "\(op == "rename" ? "renamed" : "moved") \(done.count): "
                    + done.prefix(30).map { "\($0.0.lastPathComponent) → \($0.1.path)" }.joined(separator: "; ")
                    + (skipped.isEmpty ? "" : ". Skipped: " + skipped.joined(separator: "; ")) + ". (files undo puts them back)"))
            } catch { return end(line, fail(error.localizedDescription)) }

        case "organize", "sort", "tidy":
            let target = folder ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let apply = action["apply"] as? Bool ?? false
            let line = begin("\(apply ? "Sort" : "Plan sorting") \(target.lastPathComponent)")
            do {
                let plan = try Files.organizePlan(target)
                guard !plan.isEmpty else { return end(line, .init(ok: true, summary: "nothing to sort in \(target.path)")) }
                let groups = Dictionary(grouping: plan) { $0.1.deletingLastPathComponent().lastPathComponent }
                    .map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
                guard apply else {
                    return end(line, .init(ok: true, summary: "plan for \(target.path) (\(plan.count) files into subfolders): \(groups). "
                                           + "Nothing moved yet — confirm with the user, then files organize with apply:true."))
                }
                let (done, skipped) = try Files.apply(plan)
                return end(line, .init(ok: true, summary: "sorted \(done.count) files in \(target.path) into \(groups)"
                                       + (skipped.isEmpty ? "" : ". Skipped: " + skipped.prefix(10).joined(separator: "; ")) + ". (files undo puts them back)"))
            } catch { return end(line, fail(error.localizedDescription)) }

        case "undo":
            let line = begin("Undo the last file changes")
            do { return end(line, .init(ok: true, summary: try Files.undo())) } catch { return end(line, fail(error.localizedDescription)) }

        case "trash", "delete":
            let urls = list("files")
            guard !urls.isEmpty else { return fail("files trash needs files") }
            let line = begin("Move \(urls.count) to Trash")
            guard await confirmRisky("Move to Trash") else { return end(line, fail("the user said not to delete them")) }
            return end(line, .init(ok: true, summary: await Files.trash(urls)))

        case "reveal", "show":
            let urls = list("files").filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return fail("files reveal needs files that exist") }
            let line = begin("Show in Finder")
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return end(line, .init(ok: true, summary: "selected \(urls.count) in a Finder window"))

        default:
            return fail("files op: find, list, rename, move, organize, undo, trash or reveal")
        }
    }

    /// Browser tabs: list them, bring one to the front, close one Clinqy opened, or read one without switching to it.
    private func tab(_ action: [String: Any], context: inout ActionContext) async -> ActionResult {
        let op = (action["op"] as? String ?? "list").lowercased()
        let id = (action["id"] as? NSNumber)?.intValue ?? (action["id"] as? String).flatMap { Int($0.filter(\.isNumber)) }
        let bridge = BrowserBridge.shared
        guard bridge.isConnected else {
            return fail(Background.active ? "The background browser connection is unavailable."
                : "Tab ids are unavailable without a browser connection. Continue in foreground using observed e-ids or look and screenshot coordinates, open_url, and browser key shortcuts. No extension installation is needed for basic foreground control.")
        }
        let app = context.app.flatMap { Launcher.isBrowser($0) ? $0 : nil }
        if op != "list", id == nil { return fail("tab \(op) needs id (from tab list)") }
        do {
            switch op {
            case "list":
                let tabs = try await bridge.tabs(in: app)
                return .init(ok: true, summary: tabs.isEmpty ? "no tabs" : "tabs in the front window:\n" + BrowserBridge.describe(tabs))
            case "switch" where Background.active:
                let line = begin("Switch tab")
                guard let conn = Background.tab?.connection else { return end(line, fail("you have no tab of your own yet; open_url opens one")) }
                guard let page = await bridge.snapshot(tab: id!, in: app) else { return end(line, fail("That tab does not belong to this task or is unavailable")) }
                Background.tab = BrowserBridge.TabInfo(id: id!, url: page.url, connection: conn)
                await refresh(&context)
                return end(line, .init(ok: true, summary: "working on tab \(id!) now (in the background): \(context.page?.title.prefix(80) ?? "")"))
            case "switch":
                let line = begin("Switch tab")
                try await bridge.switchTab(id!, in: app)
                try? await Task.sleep(for: .milliseconds(400))
                await refresh(&context)
                return end(line, .init(ok: true, summary: "tab \(id!) is in front: \(context.page?.title.prefix(80) ?? "")"))
            case "close":
                let line = begin("Close tab")
                try await bridge.closeTab(id!, in: app)
                try? await Task.sleep(for: .milliseconds(300))
                await refresh(&context)
                return end(line, .init(ok: true, summary: "closed tab \(id!)"))
            case "look", "read":
                let line = begin("Read another tab")
                guard let page = await bridge.snapshot(tab: id!, in: app) else { return end(line, fail("couldn't read tab \(id!)")) }
                return end(line, .init(ok: true, summary: "tab \(id!) (read only — switch to it to act on it): \(page.title)\nURL: \(page.url)\n"
                                       + Observation.pageList(page) + (page.text.isEmpty ? "" : "\nText on screen: \(page.text.prefix(4000))")))
            default:
                return fail("tab op: list, switch, close or look")
            }
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// Waits until `text` shows (or, with gone, stops showing) in the page's text, the window's elements or title,
    /// polling cheaply; text recognition on the screen is the last resort, every few polls. "Gone" must hold on two
    /// checks at least half a second apart: pages re-render, and a spinner that blinks out for a frame isn't done.
    private func waitFor(_ text: String, gone: Bool, seconds: Double, context: inout ActionContext) async -> ActionResult {
        let want = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty, let app = context.app else { return fail("wait needs for:\"<text>\" and an app in front") }
        let line = begin(gone ? "Wait for “\(text.prefix(30))” to go" : "Wait for “\(text.prefix(30))”")
        let started = Date()
        if context.page == nil {
            return end(line, await watchFor(text, gone: gone, seconds: seconds, app: app, context: &context))
        }
        // A long wait is progress, not a stuck step (a slow final text recognition included).
        let beat = Task { [weak self] in
            while !Task.isCancelled {
                self?.lastProgress = Date()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { beat.cancel() }
        // The page itself wakes us the moment the text shows (or goes): no ¼-second polling. Text in embedded frames,
        // the window's own controls and pictures of text aren't seen there, so a miss still gets the checks below
        // (quickly: the time is spent). An extension without waitText just falls through to them.
        if let page = context.page,
           let r = try? await BrowserBridge.shared.perform("waitText", on: page, ["text": text, "gone": gone, "ms": Int(seconds * 1000)],
                                                           timeout: seconds + 3),
           r["met"] as? Bool == true {
            await refresh(&context)
            let took = String(format: "%.1f", Date().timeIntervalSince(started))
            return end(line, .init(ok: true, summary: "\(text.debugDescription) \(gone ? "is gone" : "shows") (after \(took) s)"))
        }
        var goneSince: Date?
        while true {
            guard !Task.isCancelled else { return end(line, fail("cancelled")) }
            // The page's own text is enough while polling; text recognition on a whole browser window takes
            // seconds, so it's only the last word (at the timeout, or to confirm a "gone").
            let useOCR = Date().timeIntervalSince(started) >= seconds
            let seen = await Self.shows(want, app: app, page: context.page, ocr: useOCR)
            if gone {
                if seen { goneSince = nil }
                else if let since = goneSince, Date().timeIntervalSince(since) >= 0.5 {
                    // Settled: one last look with text recognition, which also sees pictures of text.
                    if !(await Self.shows(want, app: app, page: context.page, ocr: true)) { break }
                    goneSince = nil
                } else if goneSince == nil { goneSince = Date() }
            } else if seen { break }
            if Date().timeIntervalSince(started) >= seconds, goneSince == nil {   // (a pending "gone" gets its re-check)
                await refresh(&context)
                // Most misses are the wording ("Application sent" for "Application submitted"): show what's closest.
                var near = ""
                if !gone, let page = context.page, let r = try? await BrowserBridge.shared.perform("read", on: page) {
                    let close = Self.closest(to: text, in: (r["title"] as? String ?? "") + "\n" + (r["text"] as? String ?? ""))
                    // "Policy created" vs "Policy lab7-ecr created.": the same words in order, with a name between, is the
                    // message that was meant.
                    if let hit = close.first(where: { Self.wordsInOrder(text, in: $0) }) {
                        return end(line, .init(ok: true, summary: "“\(hit.prefix(80))” shows (what \(text.debugDescription) meant)"))
                    }
                    if !close.isEmpty { near = "; closest on the page: " + close.map { "“\($0)”" }.joined(separator: ", ") }
                }
                return end(line, fail("after \(Int(seconds)) s \(text.debugDescription) \(gone ? "still shows" : "hasn't appeared")\(near); look at what's there instead"))
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await refresh(&context)
        let took = String(format: "%.1f", Date().timeIntervalSince(started))
        return end(line, .init(ok: true, summary: "\(text.debugDescription) \(gone ? "is gone" : "shows") (after \(took) s)"))
    }

    /// Up to three lines of `text` sharing the most words with `want` (at least a third of them), for a wait that missed.
    nonisolated static func closest(to want: String, in text: String) -> [String] {
        let words = { (s: String) in Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }) }
        let target = words(want)
        guard !target.isEmpty else { return [] }
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "·" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 && $0.count <= 160 }
        var seen = Set<String>()
        return lines.compactMap { line -> (String, Double)? in
            let share = Double(words(line).intersection(target).count) / Double(target.count)
            return share >= 0.34 ? (line, share) : nil
        }.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0.lowercased()).inserted }.prefix(3).map { String($0.prefix(80)) }
    }

    /// waitFor outside a web page: the app's own Accessibility notifications wake the check (Watch), so nothing is
    /// re-read on a timer. A "gone" must still hold half a second later; text recognition is the last word either way.
    private func watchFor(_ text: String, gone: Bool, seconds: Double, app: NSRunningApplication,
                          context: inout ActionContext) async -> ActionResult {
        let started = Date()
        // Watch can sit quietly for the whole timeout: that's waiting, not a stuck step.
        let beat = Task { [weak self] in
            while !Task.isCancelled {
                self?.lastProgress = Date()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { beat.cancel() }
        var met = false
        let scope = context.nativeWindow?.element   // the observed window, not any window of the app
        while !Task.isCancelled {
            let left = seconds - Date().timeIntervalSince(started)
            guard left > 0 else { break }
            guard await Watch.until(app: app, text: text, gone: gone, timeout: left, window: scope) else { break }
            if !gone { met = true; break }
            try? await Task.sleep(for: .milliseconds(500))
            if !Watch.contains(pid: app.processIdentifier, text.lowercased(), window: scope) { met = true; break }
        }
        if Task.isCancelled { return fail("cancelled") }
        // Pictures of text (and apps that don't publish their text) only show to text recognition.
        let onScreen = { (await Reader.ocr(app))?.lowercased().contains(text.lowercased()) ?? false }
        if !met, !gone { met = await onScreen() } else if met, gone, await onScreen() { met = false }
        await refresh(&context)
        guard met else {
            return fail("after \(Int(seconds)) s \(text.debugDescription) \(gone ? "still shows" : "hasn't appeared"); look at what's there instead")
        }
        return .init(ok: true, summary: "\(text.debugDescription) \(gone ? "is gone" : "shows") (after \(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
    }

    /// Whether the text shows in the page (title, listed elements, text) or the app's window, or — with ocr — on screen.
    private static func shows(_ want: String, app: NSRunningApplication, page: BrowserBridge.Page?, ocr: Bool) async -> Bool {
        if let page, let r = try? await BrowserBridge.shared.perform("read", on: page),
           ((r["title"] as? String ?? "") + "\n" + (r["text"] as? String ?? "")).lowercased().contains(want) { return true }
        if Background.active { return false }
        let scan = await AXEngine.scan(app)
        if scan.window.lowercased().contains(want) || scan.focused.lowercased().contains(want)
            || scan.elements.contains(where: { $0.label.lowercased().contains(want) }) { return true }
        return ocr ? (await Reader.ocr(app))?.lowercased().contains(want) ?? false : false
    }

    /// What a failed shell step's error means and what to do instead (the raw zsh/cp messages led to retries).
    static func shellHint(_ output: String) -> String {
        if output.contains("/Library/Containers/") || output.contains("/Library/Group Containers/"),
           output.contains("Operation not permitted") || output.contains("Permission denied") {
            return "\n→ That file is inside another app's sandbox (~/Library/Containers), which can't be read or copied by path. "
                + "Open it in its app and read with no path (in Preview, read copies all its text), or have the app save/export a copy "
                + "to ~/Downloads and use that."
        }
        if output.contains("no matches found") || (output.contains("No such file or directory") && output.contains("*")) {
            return "\n→ The pattern matched no files. Check the folder exists and what's in it (ls -la \"<folder>\"), or search with "
                + "files find (name words + kind) instead of guessing a folder."
        }
        if output.contains("No such file or directory") {
            return "\n→ Check the path: quote paths with spaces (\"~/Downloads/resume stuff/a.pdf\" won't expand ~ inside quotes — "
                + "use \"$HOME/Downloads/resume stuff/a.pdf\"), and ls the folder or use files find to get the exact name."
        }
        return ""
    }

    /// Dry run: instead of acting, mark the target and say what would happen. nil = this action is safe to really do
    /// (opening, scrolling, reading, asking, anything that only looks).
    private func rehearse(_ kind: String, _ action: [String: Any], context: inout ActionContext) async -> ActionResult? {
        let lookOnly: Set<String> = ["delegate", "collect", "open_app", "open_url", "scroll", "look", "read", "wait", "recall", "dictionary", "ask", "show", "think",
                                     "point", "mark", "review", "assert", "extract"]
        let readOps: [String: Set<String>] = ["event": ["list", "find", "search", "free", "busy"], "calendar": ["list", "find", "search", "free", "busy"],
                                              "reminder": ["list"], "files": ["find", "search", "list", "reveal", "show"],
                                              "application": ["find", "check", "list", "show"], "pdf": ["info"], "media": ["info"],
                                              "tab": ["list", "look", "read"]]
        let op = (action["op"] as? String ?? "").lowercased()
        if lookOnly.contains(kind) || readOps[kind]?.contains(op) == true { return nil }
        if kind == "files", op == "organize" || op == "sort" || op == "tidy", action["apply"] as? Bool != true { return nil }   // only plans

        let text = (action["text"] as? String).map { "“\($0.prefix(40))”" } ?? ""
        var what: String
        switch kind {
        case "click": what = "click"
        case "type": what = "type \(text)"
        case "choose": what = "choose “\((action["option"] as? String ?? "").prefix(40))”"
        case "upload": what = "upload \(((action["file"] as? String) ?? "").split(separator: "/").last ?? "a file")"
        case "key": what = "press \(action["keys"] as? String ?? "?")"
        case "email": what = "email \((action["to"] as? [String] ?? []).joined(separator: ", "))"
        case "event", "calendar": what = "add “\(action["title"] as? String ?? "")” to the calendar at \(action["start"] as? String ?? "?")"
        case "reminder": what = "\(op.isEmpty ? "add" : op) reminder “\(action["title"] as? String ?? "")”"
        case "table": what = "write \((action["rows"] as? [Any])?.count ?? 0) rows to \(action["to"] as? String ?? "csv")"
        case "applescript", "shell": what = "run a \(kind == "shell" ? "command" : "script")"
        default: what = "\(kind)\(op.isEmpty ? "" : " \(op)")"
        }
        var rect: CGRect?
        var name: String?
        if action["id"] != nil {
            if Self.isWebRef(action["id"]), let (el, r) = webTarget(action["id"], context) { rect = r; name = el.text }
            else if !Self.isWebRef(action["id"]), let el = await resolve(action["id"], context: &context) { rect = el.frame; name = el.shortLabel }
            else { return fail("element \(action["id"] ?? "?") isn't on screen") }
        } else if kind == "click", let x = (action["x"] as? NSNumber)?.doubleValue, let y = (action["y"] as? NSNumber)?.doubleValue,
                  let p = context.coordinateCapture?.screenPoint(x: x, y: y) {
            rect = CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36)
        } else if kind == "click", let shown = action["text"] as? String {
            name = shown
        }
        let target = name.map { " · \($0.prefix(30))" } ?? ""
        let line = begin("Would \(what)\(target)")
        if let rect {
            await buddy.mark(rect, label: String(("would " + what).prefix(24)))
            try? await Task.sleep(for: .milliseconds(700))   // long enough to see each one
        } else {
            buddy.bubble("would \(what)", for: 2)
            try? await Task.sleep(for: .milliseconds(500))
        }
        hand.lingerBeforeHome = 3.5
        return end(line, .init(ok: true, summary: "DRY RUN — not done: would \(what)\(target). The screen didn't change; plan the next step as if it had worked."))
    }

    static func isWebRef(_ ref: Any?) -> Bool { (ref as? String)?.lowercased().hasPrefix("w") == true }

    /// A page element by its w-id, with its rect on screen.
    private func webTarget(_ ref: Any?, _ context: ActionContext) -> (BrowserBridge.PageElement, CGRect)? {
        guard let page = context.page, let web = context.webArea, let ref = ref as? String,
              let n = Int(ref.dropFirst()), let el = page.elements.first(where: { $0.index == n }) else { return nil }
        let sx = web.width / page.viewport.width, sy = web.height / page.viewport.height
        let rect = CGRect(x: web.minX + el.rect.minX * sx, y: web.minY + el.rect.minY * sy,
                          width: el.rect.width * sx, height: el.rect.height * sy)
        lastTarget = .init(kind: "web", role: el.role, label: el.text)
        return (el, rect.intersection(web).isNull ? rect : rect.intersection(web))
    }

    /// Semantic browser targets are revalidated by the driver immediately before delivery. Native
    /// coordinates refer to the exact annotated screenshot, never global screen coordinates.
    private func pointerGesture(_ action: [String: Any], context: inout ActionContext) async -> ActionResult {
        guard let raw = action["do"] as? String, let kind = PointerGesture.Kind(rawValue: raw) else { return fail("unknown gesture") }
        let line = begin(raw.replacingOccurrences(of: "_", with: " "))
        if Self.isWebRef(action["id"]) {
            guard let (element, sourceRect) = await liveWebTarget(action["id"], &context), let page = context.page else {
                return end(line, fail("gesture target is stale; observe again"))
            }
            if kind != .hover, let why = await approve(element.text, role: element.role, page: page) {
                return end(line, .init(outcome: .refused, summary: why))
            }
            // The driver resolves both endpoints again, including embedded-frame provenance.
            var args: [String: Any] = ["gesture": raw, "index": element.index]
            var destinationRect: CGRect?
            if kind == .drag {
                guard let ref = action["to_id"], let (destination, rect) = await liveWebTarget(ref, &context) else {
                    return end(line, fail("drag needs a current to_id in the same browser page"))
                }
                args["toIndex"] = destination.index
                destinationRect = rect
            }
            if Background.active {
                do { _ = try await pageMutation("cdpGesture", on: page, args) }
                catch { return end(line, .init(outcome: .uncertain, summary: "Gesture may have been delivered: " + error.localizedDescription, effect: .look)) }
            } else {
                // Debugger input is reserved for owned background tabs. Personal foreground tabs keep
                // native hit-checked input, with endpoint geometry checked against the live DOM first.
                guard let app = context.app, let window = context.nativeWindow, let web = context.webArea,
                      page.viewport.width > 0, page.viewport.height > 0 else { return end(line, fail("No observed foreground browser window")) }
                func point(_ index: Int, rect: CGRect) async -> CGPoint? {
                    guard let spot = try? await BrowserBridge.shared.perform("locate", on: page, ["index": index, "reveal": false]),
                          spot["hit"] as? Bool == true, spot["still"] as? Bool == true,
                          let x = (spot["px"] as? NSNumber)?.doubleValue, let y = (spot["py"] as? NSNumber)?.doubleValue else { return nil }
                    let p = CGPoint(x: web.minX + x * web.width / page.viewport.width, y: web.minY + y * web.height / page.viewport.height)
                    return rect.insetBy(dx: -2, dy: -2).contains(p) && web.contains(p) ? p : nil
                }
                let destination: CGPoint?
                if let index = args["toIndex"] as? Int, let rect = destinationRect { destination = await point(index, rect: rect) }
                else { destination = nil }
                guard kind != .drag || destination != nil, let source = await point(element.index, rect: sourceRect),
                      let plan = PointerGesture(kind: kind, start: .init(x: source.x, y: source.y), end: destination.map { .init(x: $0.x, y: $0.y) }) else {
                    return end(line, fail("Gesture endpoints moved or are covered; observe again"))
                }
                await Launcher.bringToFront(app)
                inputDeliveryStarted = true
                if let why = await hand.gesture(plan, in: app, window: window) { return end(line, fail(why)) }
            }
        } else {
            guard !Background.active, let app = context.app, let window = context.nativeWindow else {
                return end(line, fail("native gestures require an observed foreground window"))
            }
            var start: CGPoint?, destination: CGPoint?
            if let ref = action["id"], let el = await resolve(ref, context: &context) {
                if kind != .hover, let why = await approve(el.label, role: el.role, page: nil) { return end(line, .init(outcome: .refused, summary: why)) }
                start = el.center
            } else if action["id"] == nil, let x = (action["x"] as? NSNumber)?.doubleValue, let y = (action["y"] as? NSNumber)?.doubleValue {
                start = await context.coordinateCapture?.validatedScreenPoint(x: x, y: y)
            }
            if kind == .drag {
                if let ref = action["to_id"], !Self.isWebRef(ref), let el = await resolve(ref, context: &context) { destination = el.center }
                else if action["to_id"] == nil, let x = (action["to_x"] as? NSNumber)?.doubleValue, let y = (action["to_y"] as? NSNumber)?.doubleValue {
                    destination = await context.coordinateCapture?.validatedScreenPoint(x: x, y: y)
                }
                guard destination != nil else { return end(line, fail("drag needs a fresh to_id or screenshot to_x/to_y")) }
            }
            guard let start, let plan = PointerGesture(kind: kind, start: .init(x: start.x, y: start.y),
                                                      end: destination.map { .init(x: $0.x, y: $0.y) }) else {
                return end(line, fail("gesture needs a current id or fresh screenshot x/y"))
            }
            await Launcher.bringToFront(app)
            inputDeliveryStarted = true
            if let why = await hand.gesture(plan, in: app, window: window) { return end(line, fail(why)) }
        }
        return end(line, .init(outcome: .unverified, summary: "UNVERIFIED: " + raw + " input sent once. Observe and verify its intended result before more input.", effect: .look))
    }

    /// A stale or uncheckable reference is not permission to substitute another control.
    private func liveWebTarget(_ ref: Any?, _ context: inout ActionContext) async -> (BrowserBridge.PageElement, CGRect)? {
        guard let target = webTarget(ref, context), let page = context.page else { return nil }
        guard let result = try? await BrowserBridge.shared.perform("alive", on: page, ["index": target.0.index]),
              result["ok"] as? Bool == true else {
            await relist(&context)
            log("    target is stale or could not be validated; requesting a fresh choice")
            return nil
        }
        return target
    }

    /// Picks a dropdown's option with the keyboard, as a person would when the list can't be clicked: focus it, then
    /// arrow down through the choices until the highlighted one matches, and press Return. The choice's text, or nil
    /// (the dropdown doesn't follow the arrow keys, or the end of the list came first).
    private func chooseWithKeys(_ want: String, el: BrowserBridge.PageElement, page: BrowserBridge.Page) async -> String? {
        guard (try? await BrowserBridge.shared.perform("focusFor", on: page, ["index": el.index]))?["focused"] as? Bool == true else { return nil }
        var last = "", repeats = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        for k in 0..<60 {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            await pagePress("down", page)
            try? await Task.sleep(for: .milliseconds(70))
            guard let r = try? await BrowserBridge.shared.perform("activeOption", on: page, ["index": el.index, "want": want], timeout: min(1, max(0.1, deadline - ProcessInfo.processInfo.systemUptime))) else { return nil }
            let text = r["text"] as? String ?? ""
            if text.isEmpty { if k >= 2 { return nil }; continue }   // nothing highlights: not a keyboard list
            if ((r["score"] as? NSNumber)?.doubleValue ?? 0) >= 0.5 {
                await pagePress("return", page)
                return text
            }
            repeats = text == last ? repeats + 1 : 0
            if repeats >= 2 { return nil }   // the bottom of the list
            last = text
        }
        return nil
    }

    /// The last way to upload: click the site's button for real, and when the Mac's Open panel comes up, go to the
    /// file with cmd+shift+g like a person would. nil = no panel opened.
    private func uploadThroughPicker(_ file: URL, at point: CGPoint, app: NSRunningApplication, window: NativeWindowObservation?) async -> ActionResult? {
        if Background.active { return nil }   // the Mac's Open panel can't be worked out of the user's way
        guard let window, await hand.click(at: point, pid: app.processIdentifier, window: window) == nil else { return nil }
        let panelUp = { Self.dialogInFront(app) || (Self.systemFocus().map { $0.pid != app.processIdentifier } ?? false) }
        var up = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            if panelUp() { up = true; break }
        }
        guard up else { return nil }
        log("    upload: through the Mac file picker")
        try? await Task.sleep(for: .milliseconds(300))
        hand.press("cmd+shift+g")
        try? await Task.sleep(for: .milliseconds(600))
        AXEngine.paste(file.path)
        try? await Task.sleep(for: .milliseconds(300))
        hand.press("return")   // go to the file
        try? await Task.sleep(for: .milliseconds(900))
        hand.press("return")   // open it
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(200))
            if !panelUp() {
                try? await Task.sleep(for: .milliseconds(600))
                return .init(ok: true, summary: "chose \(file.lastPathComponent) in the Mac file picker the site opened (check the page shows it)")
            }
        }
        return .init(ok: false, summary: "FAILED: the Mac file picker is still open after going to \(file.path); look at it (the file may be greyed out "
                     + "because the site doesn't accept that type)")
    }

    private func goneMessage(_ ref: Any?) -> String {
        "page element \(ref ?? "?") isn't on the page any more and nothing like it is listed now (the page changed); look again"
    }

    /// A background run the user came to watch (its window in front): the buddy works there as in any run. Once
    /// they go back to their own work, it goes back off to the screen's edge.
    private func followWatching() async {
        if isolatedBrowserJob { buddy.quiet = true; return }
        guard Background.active, question == nil else { return }
        buddy.quiet = true
        return
    }

    /// The page the run works on: its own tab in a background run (none until it opens one), else the browser's
    /// focused tab.
    static func pageSnapshot(_ app: NSRunningApplication) async -> BrowserBridge.Page? {
        guard Background.active else { return await BrowserBridge.shared.snapshot(for: app) }
        guard let tab = Background.tab else { return nil }
        return await BrowserBridge.shared.snapshot(of: tab)
    }

    /// The tab the run is on: its own tab in a background run, else the focused one.
    private func currentTab(_ app: NSRunningApplication?) async -> BrowserBridge.TabInfo? {
        guard Background.active else { return await BrowserBridge.shared.activeTab(in: app) }
        guard let tab = Background.tab else { return nil }
        let url = await BrowserBridge.shared.tabCommand("tabInfo", on: tab, ["tabId": tab.id])?["url"] as? String
        return BrowserBridge.TabInfo(id: tab.id, url: url ?? tab.url, connection: tab.connection)
    }

    /// open_url in a background run: Clinqy's own inactive tab. The same site stays in
    /// the tab it's in; another site gets a new tab there, so the earlier one can still be read.
    private func openInBackground(_ url: URL, context: inout ActionContext) async -> ActionResult {
        let bridge = BrowserBridge.shared
        let previousURL = Background.tab?.url
        if let tab = Background.tab,
           Self.isNewTabPage(tab.url) || (URL(string: tab.url)?.host == url.host && url.host != nil) {
            guard await bridge.tabCommand("navigate", on: tab, ["url": url.absoluteString]) != nil else { return fail("The task browser disconnected; reconnect it before continuing") }
        } else {
            guard let opened = await bridge.backgroundTab(url.absoluteString) else { return fail("Couldn't open a task tab. Connect the Clinqy extension in your signed-in browser, or select headless mode in Background settings.") }
            Background.tab = opened.tab
            Background.app = opened.browser
            ownedTab = opened.tab.id
        }
        context.app = Background.app ?? ChromeWorker.shared.app ?? NSRunningApplication.current
        guard let tab = Background.tab, await bridge.waitForNavigation(on: tab, to: url.absoluteString, previous: previousURL) else {
            return fail(Task.isCancelled ? "Stopped" : "Task browser navigation didn't become ready within its deadline")
        }
        openedTab = true
        await refresh(&context)
        guard context.page != nil else { return fail("Worker page couldn't be read. Your desktop was not used.") }
        return .init(ok: true, summary: "Opened \(url.absoluteString) in Clinqy’s own \(Background.usesExtension ? "browser tab" : "headless Chrome tab")")
    }

    static func backgroundBrowser() async -> NSRunningApplication? {
        do { try await ChromeWorker.shared.start(); return ChromeWorker.shared.app }
        catch { writeLog(error.localizedDescription); return nil }
    }

    /// In a Chromium profile picker, presses the profile card with the user's name (full or first). False if there's
    /// no picker or no card that's clearly theirs.
    private static func pickOwnProfile(_ app: NSRunningApplication) -> Bool {
        let full = NSFullUserName().lowercased(), first = full.split(separator: " ").first.map(String.init) ?? full
        // The picker is a web page: Chromium lists its buttons ("Open Amrit profile") once enhanced UI is on.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let buttons = AXEngine.elements(of: app, limit: 400).filter { $0.role == "AXButton" }
        guard buttons.contains(where: { $0.label.lowercased().contains("guest mode") }) else { return false }
        let profile = { (e: UIElementInfo) -> String? in
            guard let r = e.label.range(of: #"(?i)^open (.+) profile"#, options: .regularExpression) else { return nil }
            return String(e.label[r]).lowercased().replacingOccurrences(of: "open ", with: "").replacingOccurrences(of: " profile", with: "")
        }
        guard let mine = buttons.first(where: { profile($0) == full }) ?? buttons.first(where: { profile($0) == first })
                ?? buttons.first(where: { profile($0).map { $0.hasPrefix(first) } ?? false }) else { return false }
        writeLog("    profile picker in \(app.cleanName ?? "the browser"): opening \(mine.label.prefix(40).debugDescription)")
        return AXEngine.axPress(mine.element)
    }

    /// `open x` → `open -g x` (unless it says otherwise): opens without bringing the app forward.
    nonisolated static func openQuietly(_ cmd: String) -> String {
        cmd.replacingOccurrences(of: #"(^|[;&|(]\s*|\n\s*)open\s+(?!-g\b)"#, with: "$1open -g ", options: .regularExpression)
    }

    /// A script that removes or replaces a document's content (worth a backup of the document first).
    nonisolated static func destructive(_ script: String) -> Bool {
        script.range(of: #"(?i)\b(delete|clear|remove|replace|set (the )?content|set text of)\b"#, options: .regularExpression) != nil
            && script.range(of: #"(?i)\b(document|paragraph|range|selection|text of)\b"#, options: .regularExpression) != nil
    }

    /// Clicks a spot on the page: a real click, or in a background run a trusted click sent to the run's tab.
    private func webClick(_ point: CGPoint, _ context: ActionContext, index: Int? = nil) async -> String? {
        guard Background.active else {
            let refusal = await hand.click(at: point, pid: context.app?.processIdentifier, window: context.nativeWindow)
            if refusal == nil { inputDeliveryStarted = true }
            return refusal
        }
        guard let page = context.page, let web = context.webArea, web.width > 0, web.height > 0 else { return "no page to click on; look again" }
        await buddy.travel(to: point)
        buddy.click()
        let x = (point.x - web.minX) * page.viewport.width / web.width, y = (point.y - web.minY) * page.viewport.height / web.height
        var arguments: [String: Any] = ["x": x, "y": y]
        if let index { arguments["index"] = index }
        do { _ = try await pageMutation("cdpClick", on: page, arguments); return nil }
        catch { return error.localizedDescription }
    }

    /// Record that a browser mutation was dispatched even if its reply is lost. Never turn a timeout into
    /// permission to repeat an input whose application effect is unknown.
    private func pageMutation(_ command: String, on page: BrowserBridge.Page, _ arguments: [String: Any] = [:], timeout: Double = 4) async throws -> [String: Any] {
        inputDeliveryStarted = true
        return try await BrowserBridge.shared.perform(command, on: page, arguments, timeout: timeout)
    }

    /// Types into the page's focused field: keystrokes to the browser, or in a background run text sent to the run's tab.
    private func pageType(_ text: String, page: BrowserBridge.Page, app: NSRunningApplication, codeEditor: Bool = false) async -> Bool {
        if Background.active {
            return (try? await pageMutation("cdpType", on: page, ["text": text])) != nil
        }
        inputDeliveryStarted = true
        AXEngine.targetPid = app.processIdentifier
        await hand.enterText(text, codeEditor: codeEditor)
        AXEngine.targetPid = nil
        return hand.refusal == nil
    }

    /// Presses keys: as usual, or in a background run on a page, sent to the run's tab (the keyboard is the user's).
    @discardableResult
    private func pagePress(_ keys: String, _ page: BrowserBridge.Page?) async -> Bool {
        guard Background.active else {
            let delivered = hand.press(keys)
            if delivered { inputDeliveryStarted = true }
            return delivered
        }
        guard let page, BrowserBridge.shared.ownsBackgroundPage(page) else { return false }
        if let why = Safety.blockedChord(keys, request: request) {
            log("    \(why)")
            return false
        }
        return (try? await pageMutation("cdpKey", on: page, ["keys": keys])) != nil
    }

    private func refresh(_ context: inout ActionContext) async {
        defer { if context.page == nil { BrowserBridge.shared.useNativeCursor() } }
        defer { rememberTelegramTarget(app: context.app, page: context.page, window: context.nativeWindow) }
        if Background.active {
            context.elements = []; context.fingerprint = 0
            context.nativeWindow = nil; context.coordinateCapture = nil
            context.page = nil; context.webArea = nil
            if let tab = Background.tab, let page = await BrowserBridge.shared.snapshot(of: tab) { adopt(page, into: &context); context.webArea = page.estimatedArea }
            return
        }
        guard let app = context.app else { return }
        let expectsDOM = Launcher.isBrowser(app) && BrowserBridge.shared.isConnected(app)
        let pinned = controlLease != nil ? context.page.flatMap { page in page.tabId.map { BrowserBridge.TabInfo(id: $0, url: page.url, connection: page.connection) } } : nil
        async let scanning = AXEngine.scan(app, browserDOM: expectsDOM)
        var page: BrowserBridge.Page?
        if expectsDOM { page = pinned != nil ? await BrowserBridge.shared.snapshot(of: pinned!) : await Self.pageSnapshot(app) }
        var scan = await scanning
        if expectsDOM, page == nil || page?.problem != nil { scan = await AXEngine.scan(app) }
        context.elements = scan.elements
        context.fingerprint = scan.fingerprint
        context.identity = AXEngine.identity(of: app)
        context.nativeWindow = scan.nativeWindow
        context.coordinateCapture = nil
        if let page {
            adopt(page, into: &context)
            context.webArea = await Observation.webFrame(app, page: page) ?? page.estimatedArea
        } else { context.page = nil }

    }

    /// Lists the page again mid-turn (cheaper than a full refresh: no Accessibility scan).
    private func relist(_ context: inout ActionContext) async {
        guard let app = context.app, let old = context.page else { return }
        let next = controlLease != nil && old.tabId != nil
            ? await BrowserBridge.shared.snapshot(of: .init(id: old.tabId!, url: old.url, connection: old.connection))
            : await Self.pageSnapshot(app)
        guard let page = next else { return }
        if Self.signatures(old) != Self.signatures(page) {
            log("    page re-listed: \(old.elements.count) → \(page.elements.count) elements")
        }
        adopt(page, into: &context)
    }

    /// A new listing replaces the extension's index list, so the fields typed this turn move to their new indices.
    private func adopt(_ page: BrowserBridge.Page, into context: inout ActionContext) {
        if let old = context.page {
            context.typedFields = context.typedFields.compactMap { index, text in Self.rematch(index, from: old, to: page).map { ($0, text) } }
        }
        context.page = page
    }

    static func webIndex(_ ref: Any?) -> Int? {
        guard let ref = ref as? String, isWebRef(ref) else { return nil }
        return Int(ref.dropFirst())
    }

    /// What identifies a page element across listings: the extension's key (role, name, question, frame — the same
    /// thing its stable ids follow), else role, name and question. Never its value.
    static func signature(_ el: BrowserBridge.PageElement) -> String {
        if !el.key.isEmpty { return el.key }
        var q = ""
        if el.extra.hasPrefix("in “"), let close = el.extra.range(of: "”") { q = String(el.extra[..<close.upperBound]) }
        return "\(el.role)|\(el.text)|\(q)"
    }

    static func signatures(_ page: BrowserBridge.Page) -> [String] { page.elements.map(signature) }

    /// The index in `now` of the element listed as `index` in `seen`: the same index if it's still the same element
    /// (the usual case: the extension keeps ids stable), else a unique current identity (nil = stale or ambiguous;
    /// the batch then stops before the step instead of the extension failing it as "isn't on the page now").
    static func rematch(_ index: Int, from seen: BrowserBridge.Page, to now: BrowserBridge.Page) -> Int? {
        guard seen.connection == now.connection, seen.tabId == now.tabId, seen.url == now.url,
              let documentID = seen.documentID, documentID == now.documentID,
              let snapshotID = seen.snapshotID, now.snapshotID != nil,
              let old = seen.elements.first(where: { $0.index == index }) else { return nil }
        return TargetResolution.unique(index: index, identity: signature(old),
            candidates: now.elements.map { .init(index: $0.index, identity: signature($0)) }, stableIndex: snapshotID == now.snapshotID)
    }

    /// Whether the page list alone shows what the model needs after these actions (a trailing look adds nothing):
    /// the browser is still in front with a readable page, and every step so far stayed inside the page.
    private static func pageListSuffices(_ context: ActionContext, after prior: ArraySlice<[String: Any]>) -> Bool {
        guard let page = context.page, page.problem == nil, page.elements.count >= 6,
              Background.active || NSWorkspace.shared.frontmostApplication?.processIdentifier == context.app?.processIdentifier else { return false }
        let inPage: Set<String> = ["scroll", "wait", "review", "read", "extract", "recall", "remember", "show", "application", "autofill"]
        return prior.allSatisfy { isWebRef($0["id"]) || inPage.contains(($0["do"] as? String ?? "").lowercased()) }
    }

    /// The screen as changes since `before` (what the model was shown last turn), or nil when it has to be listed in
    /// full: another app or window, another page or tab, ids that moved, or too much changed to read as a diff.
    static func screenText(_ obs: Observation, since before: Observation?) -> String? {
        // In a browser the window title is the page's, so the page diff alone decides (it refuses another tab or address).
        guard let before, let app = obs.app, before.app?.processIdentifier == app.processIdentifier,
              before.window == obs.window || (obs.page != nil && before.page != nil),
              before.dialog?.title == obs.dialog?.title else { return nil }
        if let page = obs.page {
            guard let prev = before.page, let diff = BrowserBridge.diff(previous: prev, current: page) else { return nil }
            return obs.render(pageDiff: diff)
        }
        guard before.page == nil, let diff = ScreenDiff.listingUpdate(from: before.elements, to: obs.elements) else { return nil }
        return obs.render(elementsDiff: diff)
    }

    /// Native handles stay scoped to their observed window. Never replace a dead handle by a nearby control.
    private func resolve(_ ref: Any?, context: inout ActionContext) async -> UIElementInfo? {
        guard context.app != nil, let ref = ref as? String,
              let wanted = AXEngine.lookup(ref, in: context.elements), staleApp(context) == nil,
              let nativeWindow = context.nativeWindow, nativeWindow.staleness(includeContent: true) == nil,
              wanted.windowID == nativeWindow.windowID, wanted.observationID == nativeWindow.id,
              let frame = AXEngine.liveFrame(of: wanted.element), frame.width > 2, frame.height > 2 else { return nil }
        lastTarget = .init(kind: "ax", role: wanted.role, label: wanted.label)
        return UIElementInfo(id: wanted.id, role: wanted.role, label: wanted.label, frame: frame, element: wanted.element,
                             ref: wanted.ref, value: wanted.value, inDialog: wanted.inDialog,
                             observationID: wanted.observationID, windowID: wanted.windowID)
    }

    /// `type` with no id while no page text box has the caret: the keys belong to something the page can't see.
    /// A native text field (a sheet, the address bar, the file picker's "Go to folder" box, which lives in a helper
    /// process) takes them through the system and is checked through Accessibility; a focused page control that
    /// isn't a text box (a listbox, a date part, an editor surface) or a dialog in front takes plain keystrokes, as a
    /// person's typing would. With nothing focused at all it fails, rather than set off the page's key shortcuts.
    private func typeOutsidePage(_ text: String, submit: Bool, app: NSRunningApplication, pageFocused: Bool,
                                 context: inout ActionContext) async -> ActionResult {
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        // A sheet opened by the step before (cmd+shift+g) takes a moment to take focus.
        var focus = Self.systemFocus()
        for _ in 0..<8 where !(focus.map { textRoles.contains($0.role) } ?? false) {
            try? await Task.sleep(for: .milliseconds(80))
            focus = Self.systemFocus()
        }
        let pressed = submit ? " and pressed Return" : ""
        let send = { [hand] (pid: pid_t?) async in
            AXEngine.targetPid = pid
            if text.count > 80 { AXEngine.paste(text) } else { await hand.enterText(text) }
            if submit {
                try? await Task.sleep(for: .milliseconds(120))
                AXEngine.pressReturn()
                try? await Task.sleep(for: .milliseconds(500))
            }
            AXEngine.targetPid = nil
        }
        defer { buddy.setTyping(false) }
        if let f = focus, textRoles.contains(f.role) {
            // Keys for a helper process's panel go through the system stream; the browser's own fields get them directly.
            let own = f.pid == app.processIdentifier
            buddy.setTyping(true)
            if !(Self.axValue(f.element) ?? "").isEmpty {
                AXEngine.targetPid = own ? app.processIdentifier : nil
                AXEngine.selectAll()
                AXEngine.targetPid = nil
                try? await Task.sleep(for: .milliseconds(60))
            }
            await send(own ? app.processIdentifier : nil)
            // Keys that went astray: set the field's value directly (native fields accept that).
            if !submit, let now = Self.axValue(f.element), !AXEngine.similar(now, text) {
                AXUIElementSetAttributeValue(f.element, kAXValueAttribute as CFString, text as CFString)
            }
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            return .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into the focused \(f.role.dropFirst(2)) "
                         + "(\(own ? "outside the page" : "a system dialog"))\(pressed)")
        }
        // A page control that isn't a text box has focus: type-ahead keys are what it takes.
        if pageFocused, let page = await Self.pageSnapshot(app),
           let el = page.elements.first(where: { $0.extra.range(of: #"(^| )focused( |$)"#, options: .regularExpression) != nil }) {
            adopt(page, into: &context)
            buddy.setTyping(true)
            await send(app.processIdentifier)
            return .init(ok: true, summary: "sent the keys \(text.prefix(60).debugDescription) to the focused \(el.role) \(el.text.prefix(40).debugDescription) "
                         + "(not a text box, so the result isn't checked)\(pressed)")
        }
        // The page lost focus to a dialog or sheet with no text field focused (a file picker's list): typing is what a
        // person would do there ("/" or "~" opens its Go-to-folder box; letters jump to a file).
        if !pageFocused, Self.dialogInFront(app) || (focus.map { $0.pid != app.processIdentifier } ?? false) {
            buddy.setTyping(true)
            await send(nil)
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            return .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into the dialog in front (no text field in it had focus; "
                         + "check it took)\(pressed)")
        }
        return fail("nothing here can take the text: no text box on the page or in a dialog has focus. Type with the field's id, "
                    + "or click the field first (look if it isn't listed)")
    }

    /// The element with keyboard focus anywhere on the Mac (it can belong to a helper process, like the file picker,
    /// which neither the page nor the browser's own tree shows). Never Clinqy's own windows.
    private static func systemFocus() -> (element: AXUIElement, role: String, pid: pid_t)? {
        let system = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = ref as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return (element, role as? String ?? "", pid)
    }

    /// The field still shows what was just typed into it (so a Return meant to send it didn't).
    private static func stillHolds(_ field: AXUIElement, _ text: String) -> Bool {
        guard let value = axValue(field)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
        return AXEngine.similar(value, text)
    }

    /// A chat window's Send button (WhatsApp, Messages, Slack…): only there does a box that kept its text mean unsent.
    private static func sendButton(in app: NSRunningApplication) -> UIElementInfo? {
        AXEngine.elements(of: app).first {
            $0.role == "AXButton" && $0.label.range(of: #"(?i)^\s*send(\s+message)?\s*$"#, options: .regularExpression) != nil
        }
    }

    private static func axValue(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Whether the app's front window is a dialog, or has a sheet over it (Open/Save panels, alerts).
    private static func dialogInFront(_ app: NSRunningApplication) -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        func get(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
            var ref: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success ? ref : nil
        }
        guard let w = get(root, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else { return false }
        let window = w as! AXUIElement
        if ["AXDialog", "AXSystemDialog", "AXFloatingWindow"].contains(get(window, kAXSubroleAttribute) as? String ?? "") { return true }
        let children = get(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.contains { get($0, kAXRoleAttribute) as? String == "AXSheet" }
    }

    private func changed(_ app: NSRunningApplication, from fingerprint: Int, ms: Int) async -> Bool {
        for _ in 0..<max(1, ms / 60) {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(60))
            if await AXEngine.fingerprintAsync(of: app) != fingerprint { return true }
        }
        return false
    }

    // MARK: - Progress

    /// Return is the one input with no application acknowledgement: the field must already hold exactly the typed text.
    private func submitBlocked(expected: String, actual: String?, unreadable: Bool = false) -> ActionResult? {
        guard !SubmitReadback.allows(expected: expected, actual: actual, unreadable: unreadable) else { return nil }
        return .init(outcome: .unverified, summary: "UNVERIFIED: the text was typed but Return was NOT pressed, because the field reads "
            + (actual.map { $0.prefix(80).debugDescription } ?? "unreadable") + " instead of the exact text. Fix the field, verify its value, then submit.", effect: .look)
    }

    /// Why a Return press is not known to have been delivered.
    private func submitPress(_ page: BrowserBridge.Page) async -> ActionResult? {
        if await pagePress("return", page) { return nil }
        return .init(outcome: InputDelivery.returnPress(delivered: false), summary: "UNVERIFIED: pressing Return may not have been delivered. Read the page and verify before retrying.", effect: .look)
    }

    /// A model's claim of success is not evidence: execute its explicit postcondition against current state.
    private func verify(_ action: [String: Any], context: inout ActionContext) async -> ActionResult {
        let line = begin("Verify outcome")
        if let claim = action["user_confirms"] as? String { return end(line, await resolveByUser(claim)) }
        if let claim = action["visual"] as? String { return end(line, resolveByVisual(claim)) }
        if let pending = pendingVerification, let connection = pending.pageConnection, let tabID = pending.tabID,
           let page = await BrowserBridge.shared.snapshot(of: .init(id: tabID, url: pending.url ?? "", connection: connection)) {
            context.page = page
            if Background.active { Background.tab = .init(id: tabID, url: page.url, connection: connection) }
        }
        let originalPage = context.page
        let originalNative = (action["id"] as? String).flatMap { AXEngine.lookup($0, in: context.elements) }
        let seconds = min(15, max(0, (action["seconds"] as? NSNumber)?.doubleValue ?? 2))
        let deadline = Date().addingTimeInterval(seconds)
        var evidence: String?
        var urlUnchanged = false
        repeat {
            guard !Task.isCancelled else { return end(line, fail("Stopped")) }
            await refresh(&context)
            if let pending = pendingVerification, action["path"] == nil {
                if let connection = pending.pageConnection {
                    guard context.page?.connection == connection, context.page?.tabId == pending.tabID else {
                        return end(line, fail("verification is looking at a different browser tab; return to the task tab and read its outcome"))
                    }
                } else if pending.windowID != nil {
                    guard let current = context.nativeWindow, pending.nativeWindow?.containsVerificationWindow(current) == true else {
                        return end(line, fail("verification is looking at a different native window; return to the original task window or its attached sheet. If it cannot be inspected, the outcome needs your review."))
                    }
                }
            }
            if let path = action["path"] as? String {
                evidence = SavedFileEvidence.check(path: path, since: pendingVerification?.startedAt ?? started,
                                                    contains: action["contains"] as? String,
                                                    sha256: action["sha256"] as? String,
                                                    minBytes: (action["min_bytes"] as? NSNumber)?.intValue)
            } else if let expected = action["url"] as? String, !expected.isEmpty {
                // An unchanged URL is not evidence that the pending input did anything.
                switch URLEvidence.evaluate(expected: expected, current: context.page?.url, pendingURL: pendingVerification?.url, hasPending: pendingVerification != nil) {
                case .confirmed: evidence = "current URL is " + expected
                case .unchangedSincePending: urlUnchanged = true
                case .notReached: break
                }
            } else if let expected = action["value"] as? String, let ref = action["id"] {
                if Self.isWebRef(ref), let originalPage, let page = context.page,
                   let originalIndex = Self.webIndex(ref), let currentIndex = Self.rematch(originalIndex, from: originalPage, to: page),
                   let (el, _) = await liveWebTarget("w\(currentIndex)", &context),
                   let result = try? await BrowserBridge.shared.perform("value", on: page, ["index": el.index]),
                   result["value"] as? String == expected {
                    if let pending = pendingVerification {
                        let unique = page.elements.filter { $0.role == el.role && $0.text == el.text && $0.question == el.question }.count == 1
                        let same = pending.webTargetUnique && unique && pending.documentID == page.documentID
                            && pending.webTarget.map { Self.signature($0) == Self.signature(el) } == true
                        if VerificationEvidence.changedValue(before: pending.beforeFieldValue, after: result["value"] as? String,
                                                             expected: expected, sameTarget: same, fieldInput: pending.fieldInput) {
                            evidence = "the targeted field changed to " + expected
                        }
                    } else { evidence = "field value matches " + expected }
                }
                else if !Self.isWebRef(ref), let originalNative,
                        let el = context.elements.first(where: { CFEqual($0.element, originalNative.element) }),
                        el.role == originalNative.role, el.label == originalNative.label,
                        Self.axValue(el.element) == expected {
                    if let pending = pendingVerification {
                        let same = pending.nativeTarget.map { CFEqual($0.element, el.element) } == true
                        if VerificationEvidence.changedValue(before: pending.beforeFieldValue, after: Self.axValue(el.element),
                                                             expected: expected, sameTarget: same, fieldInput: pending.fieldInput) {
                            evidence = "the targeted field changed to " + expected
                        }
                    } else { evidence = "field value matches " + expected }
                }
            } else if let text = action["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var actual: String?
                if let page = context.page {
                    if let result = try? await BrowserBridge.shared.perform("read", on: page) {
                        actual = (result["title"] as? String ?? "") + "\n" + (result["text"] as? String ?? "")
                        // The host may inspect a pinned task tab while another tab is active. Native
                        // toolbar/menu evidence must never come from that unrelated active page.
                        let active = await BrowserBridge.shared.activeTab(in: context.app)
                        if active?.id == page.tabId, active?.connection == page.connection {
                            actual = (actual ?? "") + "\n" + context.elements.map { $0.label + " " + ($0.value ?? "") }.joined(separator: "\n")
                        }
                    }
                } else if let app = context.app, let window = context.nativeWindow, window.staleness() == nil {
                    actual = context.elements.map { $0.label + " " + ($0.value ?? "") }.joined(separator: "\n")
                    if actual.map({ VerificationEvidence.appears(text, in: $0) }) != true {
                        actual = await Reader.ocr(app, window: window)
                    }
                }
                if actual.map({ VerificationEvidence.appears(text, in: $0) }) == true,
                   pendingVerification == nil || VerificationEvidence.newText(text, before: pendingVerification?.beforeText, after: actual) {
                    evidence = "new visible confirmation: " + text
                }
            } else { return end(line, fail("verify requires text, an exact url, value with id, a saved-file path, visual (after a fresh look) or user_confirms")) }
            if evidence != nil { break }
            if Date() >= deadline { break }
            try? await Task.sleep(for: .milliseconds(250))
        } while true
        guard let evidence else {
            if urlUnchanged {
                return end(line, fail("the URL is still \(action["url"] as? String ?? "") — the same as before the pending input, so it is not evidence that the input did anything. Verify page text, a field value, a saved file, or use visual / user_confirms."))
            }
            return end(line, fail("the expected outcome is not confirmed. Read the current state; do not repeat an uncertain submission."))
        }
        guard TaskStore.shared.confirmAction(taskRecordID, evidence: evidence) else {
            cancel(); return end(line, fail("couldn't persist the verification result"))
        }
        pendingVerification = nil
        if action["path"] != nil { TaskStore.shared.satisfyRequirement(taskRecordID, kind: .deliverable, evidence: evidence) }
        if let expected = action["value"] as? String { TaskStore.shared.satisfyRequirement(taskRecordID, kind: .exactValue, matching: expected, evidence: evidence) }
        return end(line, .init(outcome: .confirmed, summary: "CONFIRMED: " + evidence))
    }

    /// Explicit user resolution of an uncertain effect: the answer is the evidence and its provenance is recorded.
    private func resolveByUser(_ claim: String) async -> ActionResult {
        let trimmed = claim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 400 else { return fail("user_confirms needs a short statement of what should now be true") }
        let pendingKind = pendingVerification?.kind ?? TaskStore.shared.record(taskRecordID)?.unverifiedAction
        let reply = await askUser("Clinqy couldn't confirm this itself" + (pendingKind.map { " after \($0)" } ?? "") + ": " + trimmed + " Is that true right now?",
                                  options: ["Yes, that happened", "No, it did not happen"])
        guard !Task.isCancelled else { return fail("Stopped") }
        guard let reply else { return fail("no answer from the user; the outcome is still unverified") }
        if reply.lowercased().hasPrefix("yes") {
            guard TaskStore.shared.confirmAction(taskRecordID, evidence: "user confirmed: " + trimmed) else {
                cancel(); return fail("couldn't persist the verification result")
            }
            pendingVerification = nil
            completionEvidence.record(kind: "verify", outcome: .confirmed)
            return .init(outcome: .confirmed, summary: "CONFIRMED by the user: " + trimmed)
        }
        if reply.lowercased().hasPrefix("no") {
            // The user reports the effect is absent, so a single retry is no longer a duplicate of an unknown delivery.
            guard TaskStore.shared.resolveAction(taskRecordID, evidence: "user reported no effect: " + trimmed) else {
                cancel(); return fail("couldn't persist the verification result")
            }
            pendingVerification = nil
            return fail("the user reports it did NOT happen: " + trimmed + ". The earlier input had no effect; you may try a different approach.")
        }
        return fail("the user's answer was not a clear yes or no (\(reply.prefix(80).debugDescription)); the outcome is still unverified")
    }

    /// A screenshot taken after the pending input can resolve an ordinary UI input whose effect text cannot expose.
    /// This is recorded as visual-only evidence and never counts as the final completion check.
    private func resolveByVisual(_ claim: String) -> ActionResult {
        let trimmed = claim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 400 else { return fail("visual needs a short description of what the screenshot shows") }
        guard let pending = pendingVerification else { return fail("nothing is waiting for verification; visual is only for resolving an uncertain input") }
        guard pending.visualOK else {
            return fail("\(pending.kind) can't be resolved from a screenshot alone (submissions, scripts, saves, deletions and unknown deliveries need text/url/value/path evidence or user_confirms)")
        }
        guard lastVisualAt > pending.startedAt else { return fail("no screenshot has been taken since \(pending.kind); send {\"do\":\"look\"} first and describe only what it shows") }
        guard TaskStore.shared.confirmAction(taskRecordID, evidence: "visual-only (screenshot after the input): " + trimmed) else {
            cancel(); return fail("couldn't persist the verification result")
        }
        pendingVerification = nil
        return .init(outcome: .confirmed, summary: "Resolved by screenshot (visual-only, not independent evidence): " + trimmed + ". Verify the final result with text, url, value, path or user_confirms before finishing.")
    }

    private func fail(_ why: String) -> ActionResult { .init(ok: false, summary: "FAILED: \(why)") }

    /// Whether a code editor's rendered text matches what was typed. Editors draw only the lines on screen, wrap long
    /// lines (the wrap points read as line breaks) and the read is cut at 400 characters, so the part shown just has to
    /// be a piece of the typed text, ignoring spacing and line breaks.
    static func editorShows(_ shows: String, _ typed: String) -> Bool {
        let squash = { (s: String) in s.filter { !$0.isWhitespace } }
        var seen = squash(shows), want = squash(typed)
        if seen.isEmpty { return want.isEmpty }
        // The read can stop mid-line: drop its last few characters before comparing.
        if shows.count >= 400 { seen = String(seen.dropLast(min(8, seen.count / 2))) }
        if want.contains(seen) { return true }
        // Auto-closed brackets or quotes add a character or two; otherwise it's the old loose check.
        return AXEngine.similar(shows, typed) && seen.count <= want.count + 3
    }

    /// Hands a hard problem (an algorithm, maths, tricky logic) to a stronger model with more reasoning effort, in a
    /// fresh one-off session: THINK_MODEL (default opus) at THINK_EFFORT (default high). It gets the user's request,
    /// the text last read and the agent's question, but not the screen.
    private func think(_ question: String) async -> ActionResult {
        let model = Config.value("THINK_MODEL") ?? "opus"
        let effort = Config.value("THINK_EFFORT") ?? "high"
        let system = """
        You are the expert a computer-use agent consults when a step needs real thinking. Work the problem out \
        carefully and check your answer (trace the examples and edge cases; for code, mind the limits and overflow). \
        Reply with the answer the agent can use directly: when code is asked for, the complete program in one block, \
        compact, with no commentary inside it, then at most two lines on the approach. No tool calls.
        """
        var prompt = "The user asked: \(request)\n\n"
        if let readText { prompt += "What's on screen (last read):\n\(readText.prefix(20_000))\n\n" }
        prompt += "The agent asks:\n\(question)"
        log("  think: \(model) at \(effort) effort")
        // A long think is progress, not a stuck step: keep the watchdog quiet while it runs (up to 10 minutes).
        let heartbeat = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { return }
                self?.lastProgress = Date()
            }
        }
        defer { heartbeat.cancel() }
        let thinkStarted = Date()
        do {
            let session = try AgySession(system: system, model: model, effort: effort)
            defer { session.close() }
            let reply = try await withTaskCancellationHandler {
                try await session.send(prompt)
            } onCancel: { session.close() }
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return fail("the stronger model gave no answer") }
            log("  think: answered in \(Int(Date().timeIntervalSince(thinkStarted))) s (\(text.count) chars)")
            return .init(ok: true, summary: "the stronger model's answer:\n\(text)")
        } catch {
            return fail("couldn't reach the stronger model (\(model)): \(error.localizedDescription)")
        }
    }

    private func journalText(_ text: String) -> String {
        var clean = Secrets.mask(text)
        for secret in secrets where secret.count >= 3 { clean = clean.replacingOccurrences(of: secret, with: "••••") }
        return clean
    }

    private func begin(_ text: String) -> Int {
        var text = text
        for secret in secrets where secret.count >= 3 { text = text.replacingOccurrences(of: secret, with: "••••") }
        steps.append(Step(text: text, state: .running))
        narration = text
        TaskStore.shared.update(taskRecordID, stage: text)
        log("  → \(text)")
        return steps.count - 1
    }

    private func end(_ index: Int, _ result: ActionResult) -> ActionResult {
        if index < steps.count { steps[index].state = result.ok ? .ok : result.outcome.needsVerification ? .info : .failed }
        if !result.ok { log("    ✗ \(result.summary)") }
        return result
    }

    fileprivate func finish(ok: Bool, _ text: String) {
        if let context = executionContext, TaskExecution.current !== context {
            TaskExecution.$current.withValue(context) { finish(ok: ok, text) }; return
        }
        guard isRunning else { return }
        delegation?.cancelAll()
        if let powerLease { TaskPowerAssertions.shared.end(powerLease); self.powerLease = nil }
        let missingImages = !runDry && text != "Stopped" && deliveredImageOutputs < requiredImageOutputs
        let unresolved = pendingVerification?.kind ?? TaskStore.shared.record(taskRecordID)?.unverifiedAction
        let openNeeds = TaskStore.shared.record(taskRecordID)?.openRequirements.filter { $0.kind == .deliverable && ($0.text.hasPrefix("~") || $0.text.hasPrefix("/")) } ?? []
        let noted = ok && !runDry && !openNeeds.isEmpty && text != "Stopped"
            ? text + " (Not evidenced yet: " + openNeeds.prefix(3).map { String($0.text.prefix(60)) }.joined(separator: "; ") + ")" : text
        let text = missingImages ? "Image delivery incomplete (\(deliveredImageOutputs)/\(requiredImageOutputs) acknowledged). " + noted : ok && unresolved != nil ? "Outcome needs checking: \(unresolved!). " + noted
            : ok && !runDry && completionEvidence.needsVerification ? "Final task outcome was not independently verified. " + noted : noted
        let ok = ok && !TaskCompletionPolicy.reportsFailure(text) && !missingImages && unresolved == nil && (runDry || !completionEvidence.needsVerification)
        providerOverride = nil
        modelOverride = nil
        controlLease = nil; controlContext = nil
        controlExpiry?.cancel(); controlExpiry = nil
        phase = ok ? .done : .failed
        narration = text
        answer = text
        buddy.mood = ok ? .success : .failure
        let linger = hand.lingerBeforeHome
        hand.lingerBeforeHome = 0
        let back = runBackground ? (ok ? "Done — " + text : text).replacingOccurrences(of: "\n", with: " ") : nil
        DispatchQueue.main.asyncAfter(deadline: .now() + linger + 0.35) { [buddy] in
            buddy.goHome()
            buddy.mood = .idle
            // Back from a background run: say what came of it beside the user's pointer.
            if let back { buddy.bubble(back, for: 5) }
        }
        log(ok ? "✓ \(text)" : "✗ \(text)")
        // Long answers are easier to read in the result card than in the status bar.
        if ok, runResult == nil, text.count > 140 {
            runResult = ResultCard(title: String(request.prefix(60)), text: text, items: [])
            result = runResult
            onResult()
        }
        hand.keepFrontApp = openedLast || Self.keepsFrontApp(request)
        hand.endRun()
        let wasBackground = Background.active
        completedBrowserTab = Background.tab
        BrowserBridge.shared.endActivityRun()
        Background.end()
        buddy.quiet = false
        buddy.confine = nil
        WorkingBadge.shared.hide()
        Replay.Recorder.shared.end(ok: ok)
        if !isTest { recordStats(ok: ok, answer: text) }
        if !isTest {
            let freshWork = delegation?.hasJobs == true
            if freshWork { ReplayCache.shared.corrected(request: request) }
            // A run that worked becomes a hint for similar requests from the same place; one that was offered a hint
            // and failed counts against it.
            if ok, !runDry, !freshWork, !trace.isEmpty, !request.hasPrefix("Workflow:"), !request.hasPrefix("Correction for") {
                ReplayCache.shared.record(request: request, trace: trace, app: startPlace.app ?? targetApp?.cleanName,
                                          url: startPlace.url, title: startPlace.title, redact: secrets)
            } else {
                ReplayCache.shared.outcome(ok: ok)
            }
        }
        if !isTest { History.shared.add(.init(date: started, request: runDry ? "Dry run: \(request)" : runBackground ? "In the background: \(request)" : request, answer: text, ok: ok,
                                 steps: steps.map(\.text), app: targetApp?.cleanName, result: runResult,
                                 trace: trace.isEmpty ? nil : trace, readText: readText.map { String($0.prefix(8_000)) },
                                 task: continuation.map { $0.task ?? $0.request },
                                 threadID: continuation.map { $0.threadID ?? $0.id }, parentID: continuation?.id,
                                 requiresFreshWork: delegation?.hasJobs == true)) }
        if !isTest, let problem = History.shared.saveError { log("⚠️ history: " + problem) }
        session = nil
        onFinish(text, ok)
        // Out of steps or stalled on one step isn't the end of the task: carry on by itself (a few times), with the
        // history as context, instead of waiting for the user to type "continue". Only Stop really stops.
        // A run that got real work done (a long lab, a big form) keeps going longer than one that's flailing.
        let progressed = steps.filter { $0.state == .ok }.count >= 10
        let limit = progressed ? 12 : 3
        let continues = !isolatedBrowserJob && !externalRun && !ok && !isTest && !runDry && qa == nil && autoContinues < limit
            && (text.hasPrefix("Ran out of steps") || text.hasPrefix("I got stuck on"))
        // A background run tells the user when it's through (not at a pause it carries on from by itself).
        if wasBackground, !isolatedBrowserJob, !isTest, !continues { Notifier.finished(request: request, answer: text, ok: ok, result: runResult) }
        if !continues, let receipt = runReceiptID {
            RunReceipt.write(id: receipt, ok: ok, answer: text, steps: steps.map(\.text))
            runReceiptID = nil
        }
        if !continues { TaskStore.shared.finish(taskRecordID, ok: ok, answer: journalText(text)) }
        if !continues, telegramOwned || !isolatedBrowserJob { Telegram.shared.finished(answer: text, ok: ok, result: runResult, from: self) }
        if continues {
            autoContinues += 1
            log("auto-continue \(autoContinues)/\(limit) after: \(text.prefix(60))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.isRunning else { return }
                self.submit("continue", auto: true)
            }
        }
    }

    /// Last time the run made progress; a watchdog stops runs stuck on one step.
    private var lastProgress = Date()
    private var watchdog: Timer?

    private func startWatchdog() {
        lastProgress = Date()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { timer.invalidate(); return }
                if self.externalRun || self.coordinatingBrowserJobs || (self.inputPanelVisible && !self.runBackground) { return } // User input, child agents and external leases own their wait time.
                // A model reply with a screenshot and a long history can take well over 30 s; that's slow, not stuck.
                let limit: TimeInterval = self.phase == .thinking ? 180 : 30
                guard self.phase != .waiting, Date().timeIntervalSince(self.lastProgress) > limit else { return }
                let step = self.phase == .thinking ? "waiting for the model's reply" : self.steps.last?.text ?? "a step"
                self.log("watchdog: no progress for \(Int(limit)) s on \(step)")
                self.task?.cancel()
                self.session?.close()
                self.finish(ok: false, "I got stuck on “\(step)” and stopped")
            }
        }
    }

    fileprivate func log(_ text: String) {
        lastProgress = Date()
        var text = text
        for secret in secrets where secret.count >= 3 { text = text.replacingOccurrences(of: secret, with: "••••") }
        let line = String(format: "[%6.2fs] ", Date().timeIntervalSince(started)) + text
        if echo { print(line); fflush(stdout) }
        Self.writeLog(line)
    }

    /// Every run is also written to ~/Library/Logs/Clinqy/agent.log (for debugging and tests).
    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clinqy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent.log")
    }()

    static func writeLog(_ line: String) {
        guard let data = (Secrets.mask(line) + "\n").data(using: .utf8) else { return }
        // Keep one old log (agent.log.1) once this one passes 5 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size]) as? Int, size > 5_000_000 {
            let old = logURL.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: logURL, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - Observation

struct Observation {
    let app: NSRunningApplication?
    let elements: [UIElementInfo]
    let fingerprint: Int
    var page: BrowserBridge.Page? = nil
    var webArea: CGRect? = nil
    var window = ""
    var focused = ""
    var dialog: (kind: String, title: String)? = nil
    var nativeWindow: NativeWindowObservation? = nil

    /// Everything, as listed on a turn that shows the whole screen.
    @MainActor var text: String { render() }

    /// The screen for the model. `elementsDiff` / `pageDiff` stand in for the element or page list when the model
    /// still has the previous one in context (changes since then, ids unchanged).
    @MainActor
    func render(elementsDiff: String? = nil, pageDiff: String? = nil) -> String {
        guard let app else { return "No app is frontmost." }
        // With the page covered by the extension, list only the browser's own controls from Accessibility.
        let controls = elements.filter { e in webArea.map { !$0.contains(CGPoint(x: e.frame.midX, y: e.frame.midY)) } ?? true }
        let list = AXEngine.listing(controls, budget: 8000)
        var text = """
        Frontmost app: \(app.cleanName ?? "?")\(Launcher.isBrowser(app) ? " (browser)" : "")\(Scripting.isScriptable(app) && !Launcher.isBrowser(app) ? " (scriptable)" : "")
        Window: \(window.isEmpty ? "(none)" : window)
        """
        if let dialog { text += "\nDialog: a \(dialog.kind) is open\(dialog.title.isEmpty ? "" : ": “\(dialog.title)”") — its controls are listed first" }
        text += "\nFocused: \(focused)\n"
        if let elementsDiff {
            text += "Element changes since your last look (e-ids unchanged; + new, - gone, ~ changed):\n\(elementsDiff.isEmpty ? "(none)" : elementsDiff)"
        } else {
            text += "\(page != nil ? "Browser controls" : "Elements"):\n\(list.isEmpty ? "(none readable — ask to look)" : list)"
        }
        if let page {
            text += "\n\nWeb page (via extension; use w-ids for anything on the page): \(page.title)\nURL: \(page.url)\n"
                + "Scroll: \(Int(page.scrollY)) of \(Int(page.scrollMax))"
            if let pageDiff {
                text += "\nPage changes since your last look (w-ids unchanged; + new, - gone, ~ changed):\n\(pageDiff.isEmpty ? "(none)" : pageDiff)"
            } else {
                text += (page.headings.isEmpty ? "" : "\nHeadings: " + page.headings.joined(separator: " | "))
                    + "\n" + Self.pageList(page)
                if !page.messages.isEmpty { text += "\nMessages on the page: " + page.messages.map { "“\($0)”" }.joined(separator: " · ") }
            }
            if page.above + page.below > 0 { text += "\nNot shown (scroll to reach): \(page.above) fields/buttons above, \(page.below) below." }
            if let panes = BrowserBridge.paneSummary(page) { text += "\nScrolled out of view \(panes)." }
            if !page.text.isEmpty { text += "\nText on screen: \(page.text)" }
            if page.ready == "loading" { text += "\n(The page is still loading.)" }
            if let problem = page.problem { text += "\n(Couldn't read the page: \(problem). Use look and click by position, or read.)" }
        } else if Launcher.isBrowser(app) {
            text += "\n(Foreground browser control: use the Accessibility e-ids above for page controls, or look and screenshot coordinates if needed. Use read for text, open_url for navigation, and key for browser shortcuts. The extension is optional; continue this task without requesting its installation.)"
        }
        return text
    }

    /// A page's element list, as the model reads it.
    static func pageList(_ page: BrowserBridge.Page) -> String {
        let items = page.elements.map { "w\($0.index) \($0.role): \($0.text)\($0.extra.isEmpty ? "" : " [\($0.extra)]")" }
        return "Page elements (visible part):\n" + (items.isEmpty ? "(none)" : items.joined(separator: "\n"))
    }

    @MainActor private static var webFrames: [pid_t: (CGRect, CGSize, CGRect)] = [:]
    @MainActor static func webFrame(_ app: NSRunningApplication, page: BrowserBridge.Page) async -> CGRect? {
        guard let bounds = AXEngine.windowFrame(of: app) else { return nil }
        if let cached = webFrames[app.processIdentifier], cached.0 == bounds, cached.1 == page.viewport { return cached.2 }
        let frame = await Task.detached(priority: .userInitiated) { AXEngine.webAreaFrame(of: app) }.value
        if let frame {
            if webFrames.count > 32 { webFrames.removeAll() }
            webFrames[app.processIdentifier] = (bounds, page.viewport, frame)
        }
        return frame
    }

    /// Reads the frontmost app's UI off the main thread, so the buddy never stutters while we look.
    @MainActor
    static func capture(_ preferred: NSRunningApplication?) async -> Observation {
        if Background.active {
            let page: BrowserBridge.Page?
            if let tab = Background.tab { page = await BrowserBridge.shared.snapshot(of: tab) } else { page = nil }
            return Observation(app: Background.app ?? ChromeWorker.shared.app ?? NSRunningApplication.current, elements: [], fingerprint: 0, page: page, webArea: page?.estimatedArea)
        }
        let front = NSWorkspace.shared.frontmostApplication
        // A background run looks at its own app, never at what the user has in front.
        let app = Background.active ? preferred ?? Background.app
            : (front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front) ?? preferred
        guard let app else { return Observation(app: nil, elements: [], fingerprint: 0) }
        // The Accessibility scan, the page listing and the page's frame don't depend on each other: all at once
        // (in a browser that's the slowest two overlapping instead of adding up).
        let expectsDOM = Launcher.isBrowser(app) && BrowserBridge.shared.isConnected(app)
        async let scanning = AXEngine.scan(app, browserDOM: expectsDOM)

        // In a browser with the extension: the real page, element by element.
        var page: BrowserBridge.Page?
        var webArea: CGRect?
        if Launcher.isBrowser(app), BrowserBridge.shared.isConnected {
            page = await Agent.pageSnapshot(app)
            // Still arriving (or nothing listed yet on a page that isn't blocked): give it a moment, once.
            if let p = page, p.ready == "loading" || (p.elements.isEmpty && p.problem == nil) {
                try? await Task.sleep(for: .milliseconds(700))
                page = await Agent.pageSnapshot(app) ?? page
            }
            if let p = page { webArea = await webFrame(app, page: p) ?? p.estimatedArea }
            if webArea == nil { page = nil }
        }
        var scan = await scanning
        if expectsDOM, page == nil || page?.problem != nil { scan = await AXEngine.scan(app) }
        return Observation(app: app, elements: scan.elements, fingerprint: scan.fingerprint, page: page, webArea: webArea,
                           window: scan.window, focused: scan.focused, dialog: scan.dialog, nativeWindow: scan.nativeWindow)
    }
}

extension AXEngine {
    struct Scan: @unchecked Sendable {
        let elements: [UIElementInfo]
        let fingerprint: Int
        let window: String
        let focused: String
        var dialog: (kind: String, title: String)?
        let nativeWindow: NativeWindowObservation?
    }

    static func scan(_ app: NSRunningApplication, browserDOM: Bool = false) async -> Scan {
        await Task.detached(priority: .userInitiated) {
            enableManualAccessibility(app)
            let focus = focusSummary(of: app)
            let nativeWindow = NativeWindowObservation.capture(app)
            let elements = nativeWindow.map { AXEngine.elements(of: app, window: $0, limit: 150, excludingWebContent: browserDOM) } ?? []
            return Scan(elements: elements, fingerprint: browserDOM ? 0 : fingerprint(of: app),
                        window: focus.window, focused: focus.focused, dialog: dialog(of: app), nativeWindow: nativeWindow)
        }.value
    }

    static func fingerprintAsync(of app: NSRunningApplication) async -> Int {
        await Task.detached(priority: .userInitiated) { fingerprint(of: app) }.value
    }
}

extension UIElementInfo {
    var shortLabel: String { String(label.prefix(32)) }
    var describe: String { "\(role.dropFirst(2)) \(label.prefix(60).debugDescription)" }
}

extension NSRunningApplication {
    var cleanName: String? { localizedName?.replacingOccurrences(of: "\u{200E}", with: "") }
}


// MARK: - Workflows: record, replay without a model, heal with one

struct QAContext {
    struct Check: Codable { let text: String; let pass: Bool; let note: String }
    let name: String
    var checks: [Check] = []
}

/// What a QA run produced (written as JSON for the `clinqy qa` command).
struct QAReport: Codable {
    let name: String
    let passed: Bool
    /// "replay" (no model), "learned" (first run, model), "healed" (replay fixed by the model)
    let mode: String
    let durationMs: Int
    let steps: [String]
    let checks: [QAContext.Check]
    let message: String
}

extension Agent {
    /// Adds a successful action to the trace in a replayable form.
    fileprivate func record(_ action: [String: Any]) {
        guard let kind = (action["do"] as? String)?.lowercased(),
              ["open_app", "open_url", "click", "type", "key", "scroll", "applescript", "assert"].contains(kind) else { return }
        var step = WorkflowStep(action: kind == "assert" ? "expect" : kind)
        step.name = action["name"] as? String
        step.url = action["url"] as? String
        step.text = action["text"] as? String
        step.keys = action["keys"] as? String
        step.dir = action["dir"] as? String
        step.script = action["script"] as? String
        step.submit = action["submit"] as? Bool
        if action["id"] != nil { step.target = lastTarget }
        if kind == "assert", action["pass"] as? Bool != true { return }   // only checks that held become expectations
        if kind == "click", step.target == nil { return }                 // position clicks can't be replayed reliably
        trace.append(step)
    }

    /// Replays a saved workflow with no model; if a step breaks, the model finishes the job and the workflow is updated.
    func runWorkflow(_ workflow: Workflow, params given: [String: String] = [:], background: Bool = false, taskID: UUID? = nil) {
        guard !isRunning else { return }
        let params = (workflow.defaults ?? [:]).merging(given) { _, new in new }
        guard let id = taskID ?? TaskStore.shared.enqueue("Workflow: \(workflow.name)", source: .mac, background: background),
              TaskStore.shared.record(id)?.state == .running || TaskStore.shared.start(id) else {
            phase = .failed
            answer = TaskStore.shared.storageError ?? "The workflow couldn't start. Review Tasks & Recovery."
            return
        }
        taskRecordID = id
        if background { targetApp = nil; selectedText = nil; selectedFiles = []; annotation = nil; copied = nil; continuation = nil }
        prepare("Workflow: \(workflow.name)", test: false, background: background)
        task = Task { await replayOrHeal(workflow, params: params) }
    }

    /// Runs a UI test: replays its compiled script (no model) or learns it (first run / --relearn), then writes a report.
    func runQA(name: String, test: String, compiled: URL, relearn: Bool, model: String?, provider: Provider? = nil, report out: URL) {
        guard !isRunning else {
            Self.writeReport(QAReport(name: name, passed: false, mode: "none", durationMs: 0, steps: [], checks: [],
                                      message: "Clinqy is busy with another task"), to: out)
            return
        }
        prepare("QA: \(name)", test: true)
        qa = QAContext(name: name)
        modelOverride = model
        providerOverride = provider
        buddy.qaMode = true
        let started = Date()
        task = Task {
            var mode = "learned"
            if !relearn, let data = try? Data(contentsOf: compiled),
               let saved = try? JSONDecoder.iso8601.decode(Workflow.self, from: data) {
                mode = await replayOrHeal(saved, params: [:], qaTest: test) ? "healed" : "replay"
            } else {
                await run(Self.qaPrompt(name: name, test: test))
            }
            let finishedOK = phase == .done
            let checks = qa?.checks ?? []
            let passed = finishedOK && !checks.contains { !$0.pass }
            // Keep (or refresh) the compiled script when this run went through with the model.
            if finishedOK, mode != "replay", !trace.isEmpty {
                // A replay must start from the test's own page, freshly loaded: if the model skipped "Go to" because
                // the page was already open, the script would run on whatever an earlier test left behind.
                var steps = trace
                if let first = test.range(of: #"(?im)^\s*(?:go to|open|visit|navigate to)\s+(https?://\S+)"#, options: .regularExpression),
                   let url = test[first].range(of: #"https?://\S+"#, options: .regularExpression).map({ String(test[first][$0]) }),
                   steps.first?.action != "open_url" {
                    steps.insert(WorkflowStep(action: "open_url", url: url), at: 0)
                }
                let wf = Workflow(name: name, summary: "QA test", params: [], steps: steps, created: Date())
                try? FileManager.default.createDirectory(at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder.iso8601.encode(wf).write(to: compiled, options: .atomic)
            }
            Self.writeReport(QAReport(name: name, passed: passed, mode: mode, durationMs: Int(Date().timeIntervalSince(started) * 1000),
                                      steps: steps.map(\.text), checks: checks, message: answer), to: out)
            buddy.qaMode = false
            qa = nil
            modelOverride = nil
            providerOverride = nil
        }
    }

    static func writeReport(_ report: QAReport, to url: URL) {
        try? JSONEncoder.iso8601.encode(report).write(to: url, options: .atomic)
    }

    static func qaPrompt(name: String, test: String) -> String {
        """
        QA TEST “\(name)”. You are an automated UI tester. Carry out these steps exactly as written, in order:
        \(test)

        For every line that states an expectation (Expect / Check / Verify / Should…), look at the screen and report it
        with {"do":"assert","text":"<the expected text, as it would literally appear on screen>","pass":true|false,"note":"<what you saw>"}.
        Prefer exact on-screen text (a heading, label, value, title or URL), so the check can be repeated automatically.
        Nobody is watching: never ask anything. If a step can't be done, assert it as failed with a note, then finish.
        Finish with done:true and a one-line verdict.
        """
    }

    /// Returns true if the model had to step in.
    @discardableResult
    fileprivate func replayOrHeal(_ workflow: Workflow, params: [String: String], qaTest: String? = nil) async -> Bool {
        guard runBackground || AXEngine.isTrusted else { finish(ok: false, "Turn on Accessibility for Clinqy."); return false }
        guard !Safety.screenLocked else { finish(ok: false, "The Mac is locked — unlock it and run again"); return false }
        var app = runBackground ? nil : targetApp ?? NSWorkspace.shared.frontmostApplication
        phase = .acting
        buddy.mood = .acting
        log("replay “\(workflow.name)” · \(workflow.steps.count) steps, no model")
        for (i, step) in workflow.steps.enumerated() {
            guard !Task.isCancelled else { return false }
            if !addedNotes.isEmpty {
                return await heal(workflow, from: i, reason: "the user added guidance; apply it before taking another saved step", params: params, qaTest: qaTest)
            }
            narration = step.summary
            if step.action == "expect" {
                let want = step.action(params: params, id: nil)["text"] as? String ?? ""
                var pass = false
                for _ in 0..<5 {
                    if await Self.textVisible(want, app: app) { pass = true; break }
                    try? await Task.sleep(for: .milliseconds(600))
                }
                steps.append(Step(text: "Check “\(want.prefix(50))”", state: pass ? .ok : .failed))
                log("  \(pass ? "✓" : "✗") expect \(want)")
                // A recorded expectation is a text check on the live screen after the steps before it: independent evidence.
                if pass { completionEvidence.record(kind: "verify", outcome: .confirmed) }
                buddy.signal(pass)
                if qa != nil {
                    qa?.checks.append(.init(text: want, pass: pass, note: pass ? "" : "not visible on screen"))
                    trace.append(step)
                    continue
                }
                if !pass { return await heal(workflow, from: i, reason: "expected “\(want)” isn't on screen", params: params, qaTest: qaTest) }
                continue
            }
            // Find the step's target on the current screen (UIs load at their own pace: retry a little).
            var obs = await Observation.capture(app)
            var id: String?
            if let target = step.target {
                for attempt in 0..<5 {
                    if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)); obs = await Observation.capture(app) }
                    id = Self.find(target, in: obs)
                    if id != nil { break }
                }
                guard id != nil else {
                    return await heal(workflow, from: i, reason: "couldn't find \(target.role) “\(target.label)”", params: params, qaTest: qaTest)
                }
            }
            if !addedNotes.isEmpty {
                return await heal(workflow, from: i, reason: "the user added guidance while the screen was loading", params: params, qaTest: qaTest)
            }
            var context = ActionContext(app: obs.app, elements: obs.elements, fingerprint: obs.fingerprint,
                                        page: obs.page, webArea: obs.webArea)
            context.identity = obs.app.flatMap(AXEngine.identity(of:))
            context.nativeWindow = obs.nativeWindow
            lastTarget = nil
            let result = await perform(step.action(params: params, id: id), context: &context)
            guard result.ok else { return await heal(workflow, from: i, reason: result.summary, params: params, qaTest: qaTest) }
            trace.append(step)
            app = context.app
        }
        if var updated = Workflows.shared.all.first(where: { $0.id == workflow.id }) {
            updated.runs += 1
            Workflows.shared.update(updated)
        }
        finish(ok: true, qa != nil ? "Test finished (replayed, no model)" : "Done: \(workflow.name)")
        return false
    }

    /// A step broke: the model finishes from there, and the workflow is saved with the fixed steps.
    private func heal(_ workflow: Workflow, from index: Int, reason: String, params: [String: String], qaTest: String?) async -> Bool {
        guard !Task.isCancelled, isRunning else { return false }
        log("  heal from step \(index + 1): \(reason)")
        steps.append(Step(text: "Step \(index + 1) changed (\(reason.prefix(60))) — adapting", state: .info))
        let remaining = workflow.steps[index...].enumerated().map { "\($0.offset + 1). \($0.element.summary)" }.joined(separator: "\n")
        var request = """
        You're continuing the saved workflow “\(workflow.name)”. Steps before this point already ran. It got stuck at: \
        \(workflow.steps[index].summary) — \(reason). Finish it from there, adapting to what's on screen now. Remaining steps:
        \(remaining)
        """
        if !params.isEmpty { request += "\nValues: " + params.map { "\($0.key) = \($0.value)" }.joined(separator: ", ") }
        if let qaTest { request = Self.qaPrompt(name: qa?.name ?? workflow.name, test: qaTest) + "\n\n" + request }
        phase = .thinking
        await run(request)
        // Only keep the healed version if it still does the whole job (a model that gave up mustn't shrink it).
        let doneSteps = workflow.steps.prefix(index).filter { $0.action != "expect" }.count
        let enough = trace.count > doneSteps && Double(trace.count) >= Double(workflow.steps.count) * 0.6
        if phase == .done, qa == nil, enough, var healed = Workflows.shared.all.first(where: { $0.id == workflow.id }) {
            healed.steps = trace
            healed.healedAt = Date()
            healed.runs += 1
            Workflows.shared.update(healed)
            log("  workflow updated with the fixed steps")
        }
        return true
    }

    /// A replay target must resolve uniquely with its exact role and label; ambiguity returns control to the model.
    static func find(_ target: WorkflowStep.Target, in obs: Observation) -> String? {
        let want = target.label.lowercased()
        if target.kind == "web", let page = obs.page {
            let hits = page.elements.filter { $0.role == target.role && $0.text.lowercased() == want }
            return hits.count == 1 ? "w\(hits[0].index)" : nil
        }
        let hits = obs.elements.indices.filter { obs.elements[$0].role == target.role && obs.elements[$0].label.lowercased() == want }
        return hits.count == 1 ? "e\(hits[0])" : nil
    }

    /// Deterministic check: does this text appear on screen (page text, element labels, window title)?
    static func textVisible(_ text: String, app: NSRunningApplication?) async -> Bool {
        let want = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty, let app else { return false }
        let obs = await Observation.capture(app)
        if obs.text.lowercased().contains(want) { return true }
        if let page = obs.page {
            if page.title.lowercased().contains(want) || page.url.lowercased().contains(want) { return true }
            if let r = try? await BrowserBridge.shared.perform("read", on: page), (r["text"] as? String ?? "").lowercased().contains(want) { return true }
        }
        return (await Reader.ocr(app))?.lowercased().contains(want) ?? false
    }
}
