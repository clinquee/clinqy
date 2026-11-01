import AppKit
import SwiftUI

// MARK: - Windows

/// Spotlight-style command bar. Desktop input pauses while it owns keyboard focus.
final class CommandPanel: NSPanel {
    static let size = NSSize(width: 660, height: 460)
    private weak var agent: Agent?
    private var previousApp: NSRunningApplication?

    init(agent: Agent, voice: Voice, onMic: @escaping () -> Void, onWatch: @escaping () -> Void = {},
         onCircle: @escaping () -> Void = {}) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        self.agent = agent
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = true
        appearance = NSAppearance(named: .darkAqua)
        // Kept out of screen captures: Clinqy's screenshots and the user's screen shares show the app, not us.
        sharingType = CommandLine.arguments.contains("--ui-testing") ? .readOnly : .none
        var view = CommandView(agent: agent, voice: voice, onMic: onMic, onClose: { [weak self] in self?.orderOut(nil) })
        view.onWatch = onWatch
        view.onCircle = onCircle
        contentView = NSHostingView(rootView: view)
    }

    override var canBecomeKey: Bool { true }
    override func orderOut(_ sender: Any?) {
        let wasVisible = isVisible
        agent?.inputPanelVisible = false
        super.orderOut(sender)
        if wasVisible, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
           let previousApp, !previousApp.isTerminated { previousApp.activate() }
    }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    func showCentered() {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { previousApp = front }
        agent?.inputPanelVisible = true
        NSApp.activate(ignoringOtherApps: true)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - f.height * 0.16))
        }
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; animator().alphaValue = 1 }
    }
}

/// A small click-through status capsule at the top of the screen while Clinqy works.
final class IslandPanel: NSPanel {
    private var hideWork: DispatchWorkItem?

    init(agent: Agent, voice: Voice) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 60),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        appearance = NSAppearance(named: .darkAqua)
        sharingType = .none
        contentView = NSHostingView(rootView: IslandView(agent: agent, voice: voice))
    }

    override var canBecomeKey: Bool { false }

    func show(for seconds: TimeInterval? = nil) {
        hideWork?.cancel()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - 6))
        }
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.orderOut(nil) })
    }
}

private final class Hover: ObservableObject { @Published var on = false }

// MARK: - Review before submit

/// A form's answers shown in the command bar before a consequential submit (apply, send), waiting for
/// Submit or Edit.
@MainActor
final class ReviewCenter: ObservableObject {
    static let shared = ReviewCenter()

    struct Review: Identifiable {
        let id = UUID()
        let title: String
        let items: [(label: String, value: String)]
    }

    @Published private(set) var pending: Review?
    private var waiter: CheckedContinuation<Bool, Never>?

    fileprivate func begin(_ review: Review) async -> Bool {
        decide(false)   // only one at a time: an older review counts as not approved
        pending = review
        return await withCheckedContinuation { waiter = $0 }
    }

    func decide(_ submit: Bool, note: String? = nil) {
        UI.lastReviewNote = submit ? nil : note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        pending = nil
        let w = waiter
        waiter = nil
        w?.resume(returning: submit)
    }
}

/// UI entry points the agent calls. The app delegate wires the hooks.
@MainActor
enum UI {
    /// Brings the command bar up (set by the app delegate).
    static var present: () -> Void = {}
    /// Puts it away again after the user decided (set by the app delegate).
    static var dismiss: () -> Void = {}
    /// The agent whose run the review pauses (set by the app delegate), so the watchdog doesn't count the wait.
    static weak var agent: Agent?
    /// What the user typed instead of approving the last review ("change the notice period to 30 days"), if anything.
    static var lastReviewNote: String?

    /// Shows every answer on the form (label → value) with Submit / Edit, and waits. true = submit it;
    /// false = Edit / typed a change (see `lastReviewNote`) / the run was stopped.
    static func reviewBeforeSubmit(items: [(String, String)], title: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        let agent = agent
        let previous = agent?.phase
        if agent?.isRunning == true { agent?.phase = .waiting }
        present()
        Agent.writeLog("  review “\(title)”: waiting (\(items.count) fields)")
        let review = ReviewCenter.Review(title: title, items: items.map { (label: $0.0, value: $0.1) })
        let ok = await withTaskCancellationHandler {
            await ReviewCenter.shared.begin(review)
        } onCancel: {
            Task { @MainActor in if ReviewCenter.shared.pending?.id == review.id { ReviewCenter.shared.decide(false) } }
        }
        if let agent, agent.phase == .waiting, agent.question == nil { agent.phase = previous == .waiting ? .acting : previous ?? .acting }
        dismiss()
        Agent.writeLog("  review “\(title)”: \(ok ? "submit" : "edit")\(lastReviewNote.map { " — \($0)" } ?? "")")
        return ok
    }

    /// Resolves a waiting review as not approved (the run stopped).
    static func cancelReview() {
        if ReviewCenter.shared.pending != nil { ReviewCenter.shared.decide(false) }
    }
}

/// Which failed run's "fix it" chip the user dismissed.
private final class FixState: ObservableObject { @Published var dismissed: UUID? }

// MARK: - Design tokens

private enum DS {
    static let corner: CGFloat = 22
    static let hairline = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)

    static func color(_ mood: Buddy.Mood) -> Color { Color(nsColor: Palette.color(for: mood)) }
}

extension Agent.Phase {
    var mood: Buddy.Mood {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .acting: return .acting
        case .waiting: return .idle
        case .done: return .success
        case .failed: return .failure
        }
    }
}

// MARK: - Orb

/// Tracks whether the window hosting a view is on screen, so animations can pause while it's hidden or covered
/// (Clinqy keeps its panels around ordered out, and a TimelineView in one keeps drawing otherwise).
struct OnScreen: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Probe { Probe { visible = $0 } }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        private let changed: (Bool) -> Void
        private var observer: NSObjectProtocol?
        init(_ changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { report(false); return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                              object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { self?.report(window?.occlusionState.contains(.visible) == true) }
            }
            report(window.occlusionState.contains(.visible))
        }

        private func report(_ on: Bool) { DispatchQueue.main.async { [changed] in changed(on) } }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// The living dot, an Apple Watch–style "breathe" flower: six petals bloom out and back,
/// faster while working, swelling with your voice; tinted by mood (teal/cyan when idle).
private struct Orb: View {
    let mood: Buddy.Mood
    var level: CGFloat = 0
    var size: CGFloat = 26
    @State private var onScreen = true

    var body: some View {
        // The slow idle breath doesn't need display rate, and nothing at all while its window is hidden.
        let busy = mood == .thinking || mood == .acting || mood == .listening
        TimelineView(.animation(minimumInterval: busy ? 1.0 / 30.0 : 1.0 / 20.0, paused: !onScreen)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let busy = mood == .thinking || mood == .acting
            let period = busy ? 1.4 : 3.0
            // 0 → 1 → 0 with ease-in-out, like the original keyframes.
            let bloom = CGFloat(0.5 - 0.5 * cos(t.truncatingRemainder(dividingBy: period) / period * 2 * .pi))
            let open = mood == .listening ? max(bloom, min(1, level * 1.6)) : bloom
            let (a, b) = colors
            let petal = size * 0.42
            ZStack {
                ForEach(0..<6, id: \.self) { i in
                    let angle = Double(i) * .pi / 3
                    Circle()
                        .fill((i.isMultiple(of: 2) ? a : b).opacity(0.7))
                        .frame(width: petal, height: petal)
                        .scaleEffect(0.45 + 0.75 * open)
                        .offset(x: cos(angle) * size * 0.3 * open, y: sin(angle) * size * 0.3 * open)
                        .blendMode(.plusLighter)
                }
            }
            .rotationEffect(.radians(t * (busy ? 1.2 : 0.15) + Double(open) * .pi / 3))
            .shadow(color: a.opacity(0.35 + 0.45 * open), radius: 2 + 6 * open)
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.35), value: mood)
        }
        .background(OnScreen(visible: $onScreen))
    }

    private var colors: (Color, Color) {
        if mood == .idle {
            return (Color(red: 0.18, green: 0.83, blue: 0.75), Color(red: 0.13, green: 0.83, blue: 0.93))
        }
        let base = DS.color(mood)
        return (base, Color(NSColor(base).blended(withFraction: 0.35, of: .white) ?? NSColor(base)))
    }
}

// MARK: - Command bar

struct CommandView: View {
    @ObservedObject var agent: Agent
    @ObservedObject var voice: Voice
    @ObservedObject private var skills = Skills.shared
    @StateObject private var skillsTab = Hover()
    /// Starts Watch & Learn (set by the app delegate).
    var onWatch: () -> Void = {}
    /// Lets the user circle something on screen (set by the app delegate).
    var onCircle: () -> Void = {}
    @StateObject private var historyTab = Hover()
    @ObservedObject private var speech = SpeechModel.shared
    @ObservedObject private var review = ReviewCenter.shared
    @ObservedObject private var undo = StepUndo.shared
    @ObservedObject private var history = History.shared
    @StateObject private var fix = FixState()
    let onMic: () -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    private let suggestions = [
        ("bubble.left.fill", "Say good morning to mom on WhatsApp"),
        ("play.rectangle.fill", "Play lo-fi beats on YouTube"),
        ("moon.fill", "Turn on dark mode"),
        ("note.text", "Make a note: buy milk, eggs, bread"),
    ]

    private var mood: Buddy.Mood { voice.isListening ? .listening : agent.phase.mood }

    /// The run that just failed or was stopped, which the next thing typed corrects ("no, click the other one").
    private var fixable: History.Entry? {
        // Something newly selected or circled is a new task about it, not a correction of the last run.
        guard !agent.newTaskMode, !agent.isRunning, agent.question == nil, review.pending == nil, agent.phase == .failed,
              agent.selectedText == nil, agent.selectedFiles.isEmpty, agent.annotation == nil,
              let last = history.entries.first, !last.ok, last.id != fix.dismissed,
              Date().timeIntervalSince(last.date) < 30 * 60, !last.request.hasPrefix("Dry run:") else { return nil }
        return last
    }

    /// Continues the failed run with its history plus the user's correction.
    private func submitFix(_ entry: History.Entry, _ text: String) {
        let correction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correction.isEmpty else { return }
        fix.dismissed = entry.id
        agent.continuation = entry
        agent.submit("Correction for “\(Self.originalRequest(entry.request).prefix(120))”: \(correction)")
    }

    /// The request a chain of corrections started from: "Correction for “Correction for “X”: a”: b" → "X", so
    /// correcting again doesn't wrap it once more (earlier corrections are in the continued run's history).
    private static func originalRequest(_ request: String) -> String {
        let prefix = "Correction for “"
        guard request.hasPrefix(prefix) else { return request }
        var rest = Substring(request)
        while rest.hasPrefix(prefix) { rest = rest.dropFirst(prefix.count) }
        if let end = rest.range(of: "”: ") { rest = rest[..<end.lowerBound] }
        return String(rest)
    }

    private func submitInput() {
        if agent.newTaskMode { if agent.submitNewRequest(agent.input) { onClose() } }
        else if review.pending != nil { review.decide(false, note: agent.input); agent.input = "" }
        else if agent.question != nil { agent.answer(agent.input) }
        else if agent.isRunning { agent.addContext(agent.input); onClose() }
        else if let entry = fixable { submitFix(entry, agent.input) }
        else { agent.submit(agent.input) }
    }

    private var placeholder: String {
        if agent.newTaskMode { return "New task — starts when a slot is free…" }
        if review.pending != nil { return "Type a change, or click Submit" }
        if agent.question != nil { return "Your answer" }
        if agent.isRunning { return "Add to this task or change the plan…" }
        if fixable != nil { return "What should I do differently? e.g. “no, click the other one”" }
        return agent.dryRun ? "What should I show you? (dry run)" : "What should I do?"
    }

    var body: some View {
        VStack(spacing: 0) {
            if agent.newTaskMode || agent.isRunning {
                HStack {
                    Text(agent.newTaskMode ? "New task" : "Current task").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.secondary)
                    Spacer()
                    Button(agent.newTaskMode ? "Current task" : "New task") { agent.newTaskMode.toggle() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(DS.secondary)
                }.padding(.horizontal, 18).padding(.top, 12)
            }
            VStack(spacing: 0) {
                if let r = review.pending, !agent.newTaskMode {
                    ReviewCard(review: r, onSubmit: { review.decide(true) },
                               onEdit: { review.decide(false, note: agent.input); agent.input = "" })
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let entry = fixable {
                    ContextChip(icon: "wrench.and.screwdriver", text: "Didn't finish: \(entry.request) — tell me what to do differently") { fix.dismissed = entry.id }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .transition(.opacity)
                }
                if let q = agent.question, !agent.newTaskMode {
                    QuestionCard(question: q) { agent.answer($0) }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let earlier = agent.continuation, !agent.isRunning {
                    ContextChip(icon: "arrow.turn.down.right", text: "Continuing: \(earlier.request)") { agent.continuation = nil }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                }
                if let selected = agent.selectedText, !agent.isRunning {
                    SelectionChip(text: selected) { agent.selectedText = nil }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .transition(.opacity)
                }
                if !agent.selectedFiles.isEmpty, !agent.isRunning {
                    ContextChip(icon: "doc.on.doc", text: agent.selectedFiles.count == 1 ? agent.selectedFiles[0].lastPathComponent
                                : "\(agent.selectedFiles.count) files · " + agent.selectedFiles.map(\.lastPathComponent).joined(separator: ", ")) { agent.selectedFiles = [] }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .transition(.opacity)
                }
                if let copied = agent.copied, agent.selectedText == nil, agent.selectedFiles.isEmpty, !agent.isRunning {
                    ContextChip(icon: "doc.on.clipboard", text: "Copied \(Clipboard.describeAge(copied.age)) · "
                                + (copied.text.map { $0.replacingOccurrences(of: "\n", with: " ") }
                                   ?? copied.files.map(\.lastPathComponent).joined(separator: ", "))) { agent.copied = nil }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .transition(.opacity)
                }
                if let circled = agent.annotation, !agent.isRunning {
                    ContextChip(icon: "lasso", text: "Circled area · \(Int(circled.rect.width))×\(Int(circled.rect.height))") { agent.annotation = nil }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .transition(.opacity)
                }
                bar
                if showBody {
                    Rectangle().fill(DS.hairline).frame(height: 1)
                    content
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                footer
            }
            .background(
                RoundedRectangle(cornerRadius: DS.corner, style: .continuous)
                    .fill(Color(white: 0.09))
            )
            .overlay(RoundedRectangle(cornerRadius: DS.corner, style: .continuous).strokeBorder(DS.hairline))
            .clipShape(RoundedRectangle(cornerRadius: DS.corner, style: .continuous))
            .padding(24)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showBody)
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: agent.steps.count)
            Spacer(minLength: 0)
        }
        .frame(width: CommandPanel.size.width, height: CommandPanel.size.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in focused = true }
    }

    private var showBody: Bool {
        if agent.newTaskMode { return historyTab.on || skillsTab.on || voice.isListening || voice.isTranscribing || voice.error != nil }
        return historyTab.on || skillsTab.on || skills.isLearning || skills.lastError != nil || voice.isTranscribing || speech.statusText != nil || !agent.steps.isEmpty || !agent.answer.isEmpty || voice.isListening || voice.error != nil || agent.input.isEmpty
    }

    private var bar: some View {
        HStack(spacing: 14) {
            Orb(mood: mood, level: voice.level)
            ZStack(alignment: .leading) {
                if voice.isListening {
                    Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(voice.transcript.isEmpty ? DS.tertiary : DS.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .contentTransition(.opacity)
                } else if let q = agent.question, q.sensitive, !agent.newTaskMode {
                    SecureField("", text: $agent.input, prompt: Text("Type it here (kept private)").foregroundStyle(DS.tertiary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(DS.text)
                        .focused($focused)
                        .onSubmit { agent.answer(agent.input) }
                } else {
                    TextField("", text: $agent.input, prompt: Text(placeholder).foregroundStyle(DS.tertiary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(DS.text)
                        .focused($focused)
                        .onSubmit(submitInput)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if agent.newTaskMode {
                IconButton(symbol: voice.isListening ? "waveform" : "mic.fill", tint: DS.secondary, action: onMic)
                IconButton(symbol: "arrow.up", tint: .white, action: submitInput)
            } else if review.pending != nil {
                IconButton(symbol: "stop.fill", tint: .white) { agent.cancel() }
            } else if agent.question != nil {
                IconButton(symbol: voice.isListening ? "waveform" : "mic.fill",
                           tint: voice.isListening ? DS.color(.listening) : DS.secondary, action: onMic)
                    .symbolEffect(.variableColor.iterative, isActive: voice.isListening)
                    .help("Answer by voice")
                IconButton(symbol: "arrow.up", tint: .white) { agent.answer(agent.input) }
            } else if agent.isRunning {
                IconButton(symbol: "stop.fill", tint: .white) { agent.cancel() }
            } else {
                IconButton(symbol: voice.isListening ? "waveform" : "mic.fill",
                           tint: voice.isListening ? DS.color(.listening) : DS.secondary, action: onMic)
                    .symbolEffect(.variableColor.iterative, isActive: voice.isListening)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    @ViewBuilder private var content: some View {
        if skillsTab.on && agent.question == nil && !voice.isListening {
            SkillsView(onRun: { skill in
                skillsTab.on = false
                agent.submit("Use the skill “\(skill.name)”.")
            }, onRunWorkflow: { wf in
                skillsTab.on = false
                onClose()
                agent.runWorkflow(wf)
            })
        } else if historyTab.on && agent.question == nil && !voice.isListening {
            HistoryView(
                onContinue: { entry in
                    agent.continuation = entry
                    historyTab.on = false
                },
                onRunAgain: { entry in
                    historyTab.on = false
                    agent.submit(entry.request)
                },
                onShowResult: { entry in
                    agent.result = entry.result
                    agent.onResult()
                })
        } else {
            mainContent
        }
    }

    @ViewBuilder private var mainContent: some View {
        if skills.isLearning {
            Label("Learning what you showed me…", systemImage: "graduationcap").font(.system(size: 13))
                .foregroundStyle(DS.secondary).symbolEffect(.pulse)
        } else if let error = skills.lastError {
            Label(error, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(DS.secondary)
        } else if let error = History.shared.saveError {
            Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(DS.secondary)
        }
        if let status = speech.statusText, agent.steps.isEmpty {
            Label(status, systemImage: "waveform.badge.plus").font(.system(size: 12)).foregroundStyle(DS.tertiary)
                .padding(.bottom, 4)
        }
        if voice.isTranscribing {
            Label("Transcribing…", systemImage: "waveform").font(.system(size: 13)).foregroundStyle(DS.secondary)
                .symbolEffect(.variableColor.iterative)
        } else if let error = voice.error {
            Label(error, systemImage: "mic.slash").font(.system(size: 13)).foregroundStyle(DS.secondary)
        } else if voice.isListening {
            Waveform(level: voice.level).frame(height: 26)
        } else if agent.steps.isEmpty && agent.answer.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggestions, id: \.1) { icon, text in
                    SuggestionRow(icon: icon, text: text) { agent.submit(text) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                if !agent.answer.isEmpty {
                    Text(agent.answer)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DS.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                }
                let visible = agent.steps.suffix(7)
                if let last = undo.last, !visible.contains(where: { $0.id == last.id }),
                   let step = agent.steps.last(where: { $0.id == last.id }) {
                    StepRow(step: step, undoLabel: last.label, undoBusy: undo.busy) { Task { await undo.undoLast(agent: agent) } }
                }
                ForEach(visible) { step in
                    if let last = undo.last, last.id == step.id {
                        StepRow(step: step, undoLabel: last.label, undoBusy: undo.busy) { Task { await undo.undoLast(agent: agent) } }
                    } else {
                        StepRow(step: step)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Hint(keys: "⌃⌥", text: "open")
            Hint(keys: "hold ⌃⌥", text: "talk")
            Spacer()
            Button { agent.dryRun.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: agent.dryRun ? "eye.fill" : "eye").font(.system(size: 11))
                    Text("Dry run").font(.system(size: 11))
                }
                .foregroundStyle(agent.dryRun ? Color(nsColor: Palette.accent) : DS.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dry run: Clinqy points at everything it would click and type, without doing it")
            Button(action: onCircle) {
                HStack(spacing: 4) {
                    Image(systemName: "lasso").font(.system(size: 11))
                    Text("Circle").font(.system(size: 11))
                }
                .foregroundStyle(DS.tertiary)
            }
            .buttonStyle(.plain)
            .help("Circle something on screen to point Clinqy at it")
            Button(action: onWatch) {
                HStack(spacing: 4) {
                    Circle().fill(Color.red.opacity(0.85)).frame(width: 7, height: 7)
                    Text("Watch & learn").font(.system(size: 11))
                }
                .foregroundStyle(DS.tertiary)
            }
            .buttonStyle(.plain)
            .help("Show Clinqy how to do something: it watches, then learns it as a skill")
            Button { withAnimation(.easeOut(duration: 0.15)) { skillsTab.on.toggle(); historyTab.on = false } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "graduationcap").font(.system(size: 11))
                    Text(skillsTab.on ? "Back" : "Skills").font(.system(size: 11))
                }
                .foregroundStyle(skillsTab.on ? DS.text : DS.tertiary)
            }
            .buttonStyle(.plain)
            Button { withAnimation(.easeOut(duration: 0.15)) { historyTab.on.toggle(); skillsTab.on = false } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
                    Text(historyTab.on ? "Back" : "History").font(.system(size: 11))
                }
                .foregroundStyle(historyTab.on ? DS.text : DS.tertiary)
            }
            .buttonStyle(.plain)
            Hint(keys: "esc", text: "close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.03))
    }
}

/// What Clinqy needs from the user, with quick-choice buttons.
private struct QuestionCard: View {
    let question: Agent.Question
    let onChoose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: question.sensitive ? "lock.fill" : "questionmark.bubble.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Palette.accent))
                Text(question.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !question.options.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(question.options, id: \.self) { option in
                        ChoiceButton(text: option) { onChoose(option) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Every answer on the form, label → value, before a consequential submit.
private struct ReviewCard: View {
    let review: ReviewCenter.Review
    let onSubmit: () -> Void
    let onEdit: () -> Void

    private var emptyCount: Int { review.items.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Palette.accent))
                Text(review.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(2)
                Spacer(minLength: 6)
                Text(emptyCount > 0 ? "\(review.items.count) fields · \(emptyCount) empty" : "\(review.items.count) fields")
                    .font(.system(size: 11)).foregroundStyle(emptyCount > 0 ? DS.color(.failure) : DS.tertiary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(review.items.enumerated()), id: \.offset) { _, item in
                        ReviewRow(label: item.label, value: item.value.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(maxHeight: 170)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
            HStack(spacing: 6) {
                ChoiceButton(text: "Submit", action: onSubmit)
                ChoiceButton(text: "Edit", action: onEdit)
                Text("or type a change and press return").font(.system(size: 11)).foregroundStyle(DS.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReviewRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DS.secondary)
                .lineLimit(2)
                .frame(width: 190, alignment: .leading)
            Text(value.isEmpty ? "(empty)" : value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(value.isEmpty ? DS.color(.failure) : DS.text)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ChoiceButton: View {
    let text: String
    let action: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(hover.on ? 0.16 : 0.09)))
                .overlay(Capsule().strokeBorder(Color(nsColor: Palette.accent).opacity(hover.on ? 0.7 : 0.3)))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

/// Lays children out left to right, wrapping onto new lines.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Context riding along with the next request (an earlier run being continued).
private struct ContextChip: View {
    let icon: String
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(nsColor: Palette.accent))
            Text(text).font(.system(size: 12)).foregroundStyle(DS.secondary).lineLimit(1).truncationMode(.tail)
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.tertiary) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The text the user had selected, riding along with the request.
private struct SelectionChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.secondary)
            Text(text.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 12))
                .foregroundStyle(DS.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(text.count) chars").font(.system(size: 10)).foregroundStyle(DS.tertiary)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IconButton: View {
    let symbol: String
    let tint: Color
    let action: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(hover.on ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.on)
    }
}

private struct SuggestionRow: View {
    let icon: String
    let text: String
    let action: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(DS.tertiary).frame(width: 18)
                Text(text).font(.system(size: 14)).foregroundStyle(hover.on ? DS.text : DS.secondary)
                Spacer()
                Image(systemName: "return").font(.system(size: 11)).foregroundStyle(DS.tertiary).opacity(hover.on ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover.on ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.on)
    }
}

private struct StepRow: View {
    let step: Agent.Step
    /// Set on the latest step that can be reversed: shows an Undo button.
    var undoLabel: String? = nil
    var undoBusy = false
    var onUndo: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                switch step.state {
                case .running: ProgressView().controlSize(.mini).scaleEffect(0.8)
                case .ok: Image(systemName: "checkmark").foregroundStyle(DS.secondary)
                case .failed: Image(systemName: "xmark").foregroundStyle(DS.color(.failure))
                case .info: Image(systemName: "sparkle").foregroundStyle(DS.color(.thinking))
                }
            }
            .font(.system(size: 10, weight: .bold))
            .frame(width: 14)
            Text(step.text)
                .font(.system(size: 13))
                .foregroundStyle(step.state == .running ? DS.text : DS.secondary)
                .lineLimit(1)
            if let onUndo, let undoLabel {
                Spacer(minLength: 6)
                Button(action: onUndo) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .bold))
                        Text(undoBusy ? "Undoing…" : "Undo").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(DS.text)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .disabled(undoBusy)
                .help(undoLabel)
            }
        }
        .transition(.opacity.combined(with: .offset(y: 6)))
    }
}

private struct Hint: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(DS.tertiary)
    }
}

private struct Waveform: View {
    let level: CGFloat
    @State private var onScreen = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !onScreen)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<36, id: \.self) { i in
                    let angle: Double = t * 7.0 + Double(i) * 0.45
                    let wave: CGFloat = CGFloat((sin(angle) + 1.0) / 2.0)
                    let barH: CGFloat = 3.0 + (4.0 + level * 22.0) * wave
                    Capsule()
                        .fill(DS.color(.listening).opacity(0.85))
                        .frame(width: 3, height: barH)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(OnScreen(visible: $onScreen))
    }
}

// MARK: - Island

struct IslandView: View {
    @ObservedObject var agent: Agent
    @ObservedObject var voice: Voice
    @ObservedObject private var review = ReviewCenter.shared

    private var text: String {
        if voice.isListening { return voice.transcript.isEmpty ? (voice.isFollowUp ? "Anything else? I'm listening…" : "Listening…") : voice.transcript }
        if Recorder.shared.isRecording { return "Watching you… do the task, then ⌃⌥ or ⏹ to stop" }
        if voice.isTranscribing { return "Transcribing…" }
        if let q = agent.question { return "Needs your input: \(q.text)" }
        if let r = review.pending { return "Check before I submit: \(r.title)" }
        return agent.narration.isEmpty ? "Thinking…" : agent.narration
    }

    var body: some View {
        HStack(spacing: 10) {
            Orb(mood: voice.isListening ? .listening : agent.phase.mood, level: voice.level, size: 16)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .truncationMode(voice.isListening ? .head : .tail)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: text)
            if agent.isRunning {
                Text(agent.runDry ? "dry run · ⏹ to stop" : "⌃⌥ to add · ⏹ to stop").font(.system(size: 11)).foregroundStyle(DS.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(DS.hairline))
        .frame(width: 560, height: 60)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Result card

/// Floating card on the right that shows what a task produced (options, plans, summaries).
/// Clickable (links, copy, close) but never takes focus from the app being used.
final class ResultPanel: NSPanel {
    static let size = NSSize(width: 420, height: 620)

    init(agent: Agent) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        appearance = NSAppearance(named: .darkAqua)
        sharingType = .none
        contentView = NSHostingView(rootView: ResultView(agent: agent, onClose: { [weak self] in self?.hide() }))
    }

    override var canBecomeKey: Bool { false }

    func show() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.maxX - frame.width - 12, y: f.maxY - frame.height - 12))
        }
        if !isVisible { alphaValue = 0; orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = 1 }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.orderOut(nil) })
    }
}

struct ResultView: View {
    @ObservedObject var agent: Agent
    let onClose: () -> Void
    @StateObject private var copiedFlag = Hover()

    var body: some View {
        VStack(spacing: 0) {
            if let card = agent.result {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(nsColor: Palette.accent))
                        Text(card.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text).lineLimit(2)
                        Spacer(minLength: 8)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(card.plain, forType: .string)
                            copiedFlag.on = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedFlag.on = false }
                        } label: {
                            Image(systemName: copiedFlag.on ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(DS.secondary).help("Copy")
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(DS.secondary).help("Close")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    Rectangle().fill(DS.hairline).frame(height: 1)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if let text = card.text, !text.isEmpty {
                                Text(Self.markdown(text))
                                    .font(.system(size: 13))
                                    .foregroundStyle(DS.text)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.bottom, card.items.isEmpty ? 0 : 4)
                            }
                            ForEach(card.items) { item in ResultItemRow(item: item) }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 540)
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.6)))
                )
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.hairline))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(12)
            }
            Spacer(minLength: 0)
        }
        .frame(width: ResultPanel.size.width, height: ResultPanel.size.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct ResultItemRow: View {
    let item: ResultCard.Item
    @StateObject private var hover = Hover()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                if let sub = item.subtitle { Text(sub).font(.system(size: 12)).foregroundStyle(DS.secondary) }
            }
            Spacer(minLength: 8)
            if let detail = item.detail {
                Text(detail).font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(nsColor: Palette.accent))
                    .multilineTextAlignment(.trailing)
            }
            if item.link != nil {
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover.on ? 0.09 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture { if let link = item.link, let url = URL(string: link) { NSWorkspace.shared.open(url) } }
        .textSelection(.enabled)
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var history = History.shared
    let onContinue: (History.Entry) -> Void
    let onRunAgain: (History.Entry) -> Void
    let onShowResult: (History.Entry) -> Void

    var body: some View {
        if history.entries.isEmpty {
            Text("Nothing yet — your requests will show up here.")
                .font(.system(size: 13)).foregroundStyle(DS.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(history.entries.prefix(60)) { entry in
                        HistoryRow(entry: entry, onContinue: { onContinue(entry) }, onRunAgain: { onRunAgain(entry) },
                                   onShowResult: entry.result == nil ? nil : { onShowResult(entry) },
                                   onDelete: { history.remove(entry) })
                    }
                }
            }
            .frame(maxHeight: 250)
        }
    }
}

private struct HistoryRow: View {
    let entry: History.Entry
    let onContinue: () -> Void
    let onRunAgain: () -> Void
    let onShowResult: (() -> Void)?
    let onDelete: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.ok ? "checkmark.circle" : "xmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(entry.ok ? DS.secondary : DS.color(.failure))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.request).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.text).lineLimit(1)
                Text(entry.answer).font(.system(size: 12)).foregroundStyle(DS.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if hover.on {
                HStack(spacing: 4) {
                    if let onShowResult { SmallButton(title: "Result", action: onShowResult) }
                    if entry.ok, let wf = Workflow.from(entry) {
                        SmallButton(title: "Save workflow") { Workflows.shared.add(wf) }
                            .help("Replay this exactly, without the model: \(wf.steps.count) steps")
                    }
                    SmallButton(title: "Continue", action: onContinue)
                    SmallButton(title: "Run again", action: onRunAgain)
                    Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(DS.tertiary)
                }
            } else {
                Text(entry.date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11)).foregroundStyle(DS.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hover.on ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
    }
}

private struct SmallButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.text)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Skills

struct SkillsView: View {
    @ObservedObject var skills = Skills.shared
    @ObservedObject var workflows = Workflows.shared
    let onRun: (Skills.Skill) -> Void
    var onRunWorkflow: (Workflow) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !workflows.all.isEmpty {
                Text("WORKFLOWS · replay without the model").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.tertiary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(workflows.all) { wf in
                            WorkflowRow(workflow: wf, onRun: { onRunWorkflow(wf) }, onDelete: { workflows.remove(wf) })
                        }
                    }
                }
                .frame(maxHeight: 130)
                Text("SKILLS · learned by watching").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.tertiary)
            }
            skillList
        }
    }

    @ViewBuilder private var skillList: some View {
        if skills.all.isEmpty {
            Text("No skills yet. Click “Watch & learn”, do the task yourself, then press ⌃⌥ to stop — I'll learn it.")
                .font(.system(size: 13)).foregroundStyle(DS.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(skills.all) { skill in
                        SkillRow(skill: skill, onRun: { onRun(skill) }, onDelete: { skills.remove(skill) })
                    }
                }
            }
            .frame(maxHeight: 250)
        }
    }
}

private struct SkillRow: View {
    let skill: Skills.Skill
    let onRun: () -> Void
    let onDelete: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "graduationcap").font(.system(size: 12)).foregroundStyle(Color(nsColor: Palette.accent)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.text).lineLimit(1)
                Text(skill.summary + (skill.parameters.isEmpty ? "" : " · asks for " + skill.parameters.joined(separator: ", ")))
                    .font(.system(size: 12)).foregroundStyle(DS.tertiary).lineLimit(2)
                if hover.on {
                    Text(skill.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
                        .font(.system(size: 11)).foregroundStyle(DS.secondary).padding(.top, 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if hover.on {
                HStack(spacing: 4) {
                    SmallButton(title: "Run", action: onRun)
                    Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(DS.tertiary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hover.on ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
    }
}


private struct WorkflowRow: View {
    let workflow: Workflow
    let onRun: () -> Void
    let onDelete: () -> Void
    @StateObject private var hover = Hover()

    private var subtitle: String {
        let schedulePart = workflow.schedule.map { " · daily \($0)" } ?? ""
        let paramsPart = workflow.params.isEmpty ? "" : " · inputs: " + workflow.params.joined(separator: ", ")
        return "\(workflow.steps.count) steps · run \(workflow.runs)×" + schedulePart + paramsPart
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bolt.horizontal.circle").font(.system(size: 12)).foregroundStyle(Color(nsColor: Palette.accent)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.name).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.text).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12)).foregroundStyle(DS.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if hover.on {
                HStack(spacing: 4) {
                    SmallButton(title: "Run", action: onRun)
                    SmallButton(title: workflow.schedule == nil ? "Daily…" : "Schedule…") { Self.schedule(workflow) }
                    Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(DS.tertiary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hover.on ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
    }

    /// Asks for a daily time ("09:00"), or clears the schedule.
    @MainActor static func schedule(_ workflow: Workflow) {
        let alert = NSAlert()
        alert.messageText = "Run “\(workflow.name)” every day at…"
        alert.informativeText = "24-hour time, like 09:00. Leave empty to turn the schedule off."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = workflow.schedule ?? "09:00"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        var updated = workflow
        if value.isEmpty { updated.schedule = nil }
        else if value.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil { updated.schedule = value }
        else { return }
        Workflows.shared.update(updated)
    }
}
