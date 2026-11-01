import AppKit
import AVFoundation
import Speech
import SwiftUI

// MARK: - Window

/// First-run setup: pick what drives Clinqy (a CLI you're logged into, an API key or a local model), grant the
/// permissions, load the browser extension (by hand, or Clinqy does it), learn the keys, optionally connect coding
/// agents, then try ⌃⌥. Shown on the first launch of a downloaded copy, and any time from the menu (Set Up Clinqy…).
final class OnboardingWindow: NSWindow, NSWindowDelegate {
    static let doneKey = "onboardingDone"
    static let stepKey = "onboardingStep"
    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    private var onFinish: () -> Void = {}
    private let model: OnboardingModel
    private let dashboardModel: DashboardModel
    private var visibilityObserver: NSObjectProtocol?

    /// `run` hands a task to the agent (for "Let Clinqy do it"); `isRunning` says whether one is still going.
    init(onFinish: @escaping () -> Void, run: @escaping (String) -> Void, isRunning: @escaping () -> Bool,
         providerChanged: @escaping () -> Void, shortcutsChanged: @escaping () -> Void,
         captureChanged: @escaping (Bool) -> Void) {
        let setup = OnboardingModel()
        model = setup
        dashboardModel = DashboardModel(providerChanged: providerChanged, shortcutsChanged: shortcutsChanged,
                                        captureChanged: captureChanged, providerSetup: { [weak setup] in
            setup?.refreshConfiguration()
            setup?.step = .model
            setup?.showingDashboard = false
        })
        Brand.registerFonts()
        super.init(contentRect: NSRect(origin: .zero, size: OnboardingView.size),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        self.onFinish = onFinish
        title = "Set up Clinqy"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        minSize = NSSize(width: OnboardingView.size.width, height: OnboardingView.size.height)
        isReleasedWhenClosed = false
        delegate = self
        backgroundColor = .windowBackgroundColor
        model.destinationChanged = { [weak self] showing in
            self?.title = showing ? "Clinqy Dashboard" : "Set up Clinqy"
        }
        model.finish = { [weak self] in self?.complete() }
        model.run = run
        model.isRunning = isRunning
        // Out of the way while Clinqy works on screen, back when it's done.
        model.hideWindow = { [weak self] in self?.orderOut(nil) }
        model.showWindow = { [weak self] in self?.present() }
        model.windowVisible = { [weak self] in self?.occlusionState.contains(.visible) == true }
        dashboardModel.windowVisible = model.windowVisible
        visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                    object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.updatePolling() }
        }
        let hosting = NSHostingView(rootView: OnboardingView(model: model, dashboardModel: dashboardModel))
        hosting.sizingOptions = []   // don't grow the window by the title bar's height
        contentView = hosting
        // The content runs under the transparent title bar, so the whole window is the view's size.
        setFrame(NSRect(origin: frame.origin, size: OnboardingView.size), display: false)
        center()
    }

    func presentSetup() {
        model.refreshConfiguration()
        model.showingDashboard = false
        present()
    }

    func presentDashboard() {
        model.showingDashboard = true
        dashboardModel.refresh(settings: true)
        present()
    }

    func present() {
        // A menu-bar app has no Dock icon; give it one while the window is open so it can't get lost.
        NSApp.setActivationPolicy(.regular)
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func complete() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        close()
        onFinish()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    deinit { if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) } }
}

// MARK: - Model

/// The ways to drive Clinqy that setup offers, in the order shown.
enum ModelChoice: String, CaseIterable, Identifiable {
    case claude, agy, codex, anthropic, openai, gemini, openrouter, ollama, compatible
    var id: String { rawValue }

    var provider: Provider {
        switch self {
        case .claude: return .claudeCLI
        case .agy: return .agyCLI
        case .codex: return .codexCLI
        case .anthropic: return .anthropic
        case .openai: return .openai
        case .gemini: return .gemini
        case .openrouter: return .openrouter
        case .ollama: return .ollama
        case .compatible: return .compatible
        }
    }

    enum Group: String { case cli = "Use a CLI you're logged into", api = "Use an API key", local = "Use a local model" }
    var group: Group {
        switch self {
        case .claude, .agy, .codex: return .cli
        case .anthropic, .openai, .gemini, .openrouter: return .api
        case .ollama, .compatible: return .local
        }
    }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .agy: return "Antigravity CLI (agy)"
        case .codex: return "Codex CLI"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .openrouter: return "OpenRouter"
        case .ollama: return "Ollama"
        case .compatible: return "OpenAI-compatible server"
        }
    }

    var subtitle: String {
        switch self {
        case .claude: return "Your Claude login. No key needed."
        case .agy: return "Your Google login. No key needed."
        case .codex: return "Your ChatGPT login. No key needed."
        case .anthropic: return "Claude models with your API key."
        case .openai: return "GPT models with your API key."
        case .gemini: return "Gemini models with your API key."
        case .openrouter: return "Any model on OpenRouter."
        case .ollama: return "A vision model running on this Mac."
        case .compatible: return "Groq, LM Studio, Together, vLLM…"
        }
    }

    /// The env key that holds this choice's API key.
    var keyName: String? {
        switch self {
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openai: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        case .openrouter: return "OPENROUTER_API_KEY"
        case .compatible: return "OPENAI_COMPATIBLE_API_KEY"
        default: return nil
        }
    }

    var keyHint: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .gemini: return "AIza…"
        case .openrouter: return "sk-or-…"
        default: return "Optional"
        }
    }

    var keyURL: String? {
        switch self {
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .openai: return "https://platform.openai.com/api-keys"
        case .gemini: return "https://aistudio.google.com/apikey"
        case .openrouter: return "https://openrouter.ai/keys"
        default: return nil
        }
    }

    /// How to install the CLI, and how to log in once it's there.
    var install: (command: String?, docs: String, login: String)? {
        switch self {
        case .claude: return ("curl -fsSL https://claude.ai/install.sh | bash", "https://claude.com/claude-code", "claude")
        case .agy: return (nil, "https://antigravity.google/docs/cli/overview", "agy")
        case .codex: return ("npm install -g @openai/codex", "https://github.com/openai/codex", "codex login")
        default: return nil
        }
    }

    static func from(_ p: Provider) -> ModelChoice {
        allCases.first { $0.provider == p } ?? .claude
    }
}

enum TestState: Equatable {
    case idle, running, passed(String), failed(String)
}

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, model, permissions, browser, keys, agents, done
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .model: return "Choose a model"
            case .permissions: return "Permissions"
            case .browser: return "Browser extension"
            case .keys: return "The keys"
            case .agents: return "Coding agents"
            case .done: return "Try it"
            }
        }
    }

    private let persistProgress: Bool
    @Published var showingDashboard = false {
        didSet { destinationChanged(showingDashboard); updatePolling() }
    }
    var destinationChanged: (Bool) -> Void = { _ in }
    @Published var step: Step {
        didSet {
            if persistProgress { UserDefaults.standard.set(step.rawValue, forKey: OnboardingWindow.stepKey) }
        }
    }
    @Published var choice: ModelChoice {
        didSet {
            guard oldValue != choice else { return }
            // Each provider keeps its own key draft: one service's key is never saved under another's name.
            drafts.stash(apiKey, for: oldValue.rawValue)
            apiKey = drafts.draft(for: choice.rawValue, saved: choice.keyName.flatMap { Config.value($0) })
            drafts.beginTest()   // a test still running for the old provider must not report on this one
            test = .idle
        }
    }
    private var drafts = ConnectionDrafts()
    @Published var apiKey = ""
    @Published var localModel: String
    @Published var baseURL: String
    @Published var test: TestState = .idle
    /// Bumped every second while setup is open, so live statuses (CLI found, permission granted, extension
    /// connected) refresh without the user clicking anything.
    @Published var tick = 0
    @Published var agentStatus: [String: String] = [:]
    @Published var commandStatus = ""
    var finish: () -> Void = {}
    var run: (String) -> Void = { _ in }
    var isRunning: () -> Bool = { false }
    var hideWindow: () -> Void = {}
    var showWindow: () -> Void = {}
    /// The setup window is on screen (it's kept around closed); the once-a-second redraw only matters then.
    var windowVisible: () -> Bool = { true } { didSet { updatePolling() } }
    /// "Let Clinqy do it" for the extension: idle, working (window hidden), or how it ended.
    enum AutoLoad: Equatable { case idle, working, done, gaveUp }
    @Published var autoLoad: AutoLoad = .idle { didSet { updatePolling() } }
    @Published var browserID = ""
    private var autoStarted: Date?
    private var timer: Timer?
    private var savedConfiguration: [String] = []

    init(persistProgress: Bool = true) {
        self.persistProgress = persistProgress
        step = Step(rawValue: UserDefaults.standard.integer(forKey: OnboardingWindow.stepKey)) ?? .welcome
        let current = Provider.current
        choice = ModelChoice.from(current)
        localModel = Config.value("LOCAL_MODEL") ?? "qwen3-vl"
        baseURL = Config.value("OPENAI_BASE_URL") ?? ""
        if let name = ModelChoice.from(current).keyName { apiKey = Config.value(name) ?? "" }
        savedConfiguration = [choice.rawValue, apiKey, localModel, baseURL]
        browserID = browsers.first?.id ?? ""
        updatePolling()
    }

    /// Setup checks stop with the hidden page; extension auto-loading still needs its completion watcher.
    func updatePolling() {
        let needed = (windowVisible() && !showingDashboard) || autoLoad == .working
        guard needed != (timer != nil) else { return }
        guard needed else { timer?.invalidate(); timer = nil; return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.windowVisible() { self.tick += 1 }
                self.watchAutoLoad()
            }
        }
        timer?.tolerance = 0.2
    }

    deinit { timer?.invalidate() }

    func next() { if let s = Step(rawValue: step.rawValue + 1) { step = s } }
    func back() { if let s = Step(rawValue: step.rawValue - 1) { step = s } }

    // ── Model ──

    func cliPath(_ c: ModelChoice) -> String? { c.provider.cliPath }

    /// What the settings file should say for the current choice. Keys for other services are left alone,
    /// so switching back later doesn't mean pasting them again.
    private var settings: [String: String?] {
        var s: [String: String?] = ["PROVIDER": choice.provider.rawValue, "USE_AGY": choice == .agy ? "1" : nil]
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = choice.keyName, !key.isEmpty { s[name] = key }
        if choice == .ollama || choice == .compatible {
            s["LOCAL_MODEL"] = localModel.trimmingCharacters(in: .whitespaces)
            let url = baseURL.trimmingCharacters(in: .whitespaces)
            s["OPENAI_BASE_URL"] = url.isEmpty ? (choice == .ollama ? "http://localhost:11434/v1" : nil) : url
        }
        return s
    }

    var canSave: Bool {
        switch choice.group {
        case .cli: return cliPath(choice) != nil
        case .api: return !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .local: return !localModel.trimmingCharacters(in: .whitespaces).isEmpty
                && (choice == .ollama || !baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    func refreshConfiguration() {
        guard [choice.rawValue, apiKey, localModel, baseURL] == savedConfiguration else { return }
        drafts.reset()
        choice = ModelChoice.from(Provider.current)
        apiKey = choice.keyName.flatMap { Config.value($0) } ?? ""
        localModel = Config.value("LOCAL_MODEL") ?? "qwen3-vl"
        baseURL = Config.value("OPENAI_BASE_URL") ?? ""
        savedConfiguration = [choice.rawValue, apiKey, localModel, baseURL]
    }

    func save() {
        do {
            try Config.write(settings)
            savedConfiguration = [choice.rawValue, apiKey, localModel, baseURL]
        } catch {
            test = .failed("Couldn't save settings: \(error.localizedDescription)")
        }
    }

    /// Saves the choice and sends one real request through it, the same way a task would.
    func runTest() {
        save()
        if case .failed = test { return }
        let generation = drafts.beginTest()
        test = .running
        let provider = choice.provider
        let modelID = Brain.defaultModel(for: provider)
        Task {
            do {
                let reply = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        let s = try AgySession(system: "You are checking a connection. Reply with exactly one word: OK.",
                                               model: modelID, provider: provider)
                        defer { s.close() }
                        return try await s.send("Reply with OK.")
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 90_000_000_000)
                        throw NSError(domain: "Clinqy", code: 1, userInfo: [NSLocalizedDescriptionKey:
                            "No reply after 90 seconds. Check that you're logged in, or that the server is running."])
                    }
                    let first = try await group.next() ?? ""
                    group.cancelAll()
                    return first
                }
                let short = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
                guard drafts.accepts(generation) else { return }
                test = .passed("It answered: “\(short)”")
            } catch {
                guard drafts.accepts(generation) else { return }
                test = .failed(error.localizedDescription)
            }
        }
    }

    /// Opens Terminal with a command typed and run, through a throwaway .command file (no Automation prompt).
    func runInTerminal(_ command: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-setup-\(UUID().uuidString.prefix(6)).command")
        let script = "#!/bin/zsh -l\necho '\\$ \(command.replacingOccurrences(of: "'", with: "'\\''"))'\n\(command)\necho\necho 'Done. You can close this window and go back to Clinqy.'\n"
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    // ── Permissions ──

    struct Perm: Identifiable {
        let id: String
        let why: String
        let granted: () -> Bool
        let request: () -> Void
        let settingsURL: String
    }

    let perms: [Perm] = Permissions.all.map { p in
        Perm(id: p.name, why: p.why, granted: p.granted, request: p.request, settingsURL: p.settingsURL)
    } + [
        Perm(id: "Microphone", why: "Hold ⌃⌥ and talk",
             granted: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
             request: { AVCaptureDevice.requestAccess(for: .audio) { _ in } },
             settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"),
        Perm(id: "Speech Recognition", why: "A live preview of what you're saying",
             granted: { SFSpeechRecognizer.authorizationStatus() == .authorized },
             request: { SFSpeechRecognizer.requestAuthorization { _ in } },
             settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"),
    ]

    func open(_ p: Perm) {
        p.request()
        if let url = URL(string: p.settingsURL) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSWorkspace.shared.open(url) }
        }
    }

    /// Screen Recording only takes effect in a fresh process. Setup picks up where it left off.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // ── Browser ──

    struct Browser: Identifiable {
        let id: String
        let name: String
        let page: String
    }

    let browsers = [
        Browser(id: "com.google.Chrome", name: "Chrome", page: "chrome://extensions"),
        Browser(id: "company.thebrowser.Browser", name: "Arc", page: "arc://extensions"),
        Browser(id: "com.brave.Browser", name: "Brave", page: "brave://extensions"),
        Browser(id: "com.microsoft.edgemac", name: "Edge", page: "edge://extensions"),
    ].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }

    /// A stable copy of the bundled extension, outside the app, so updating the app never pulls the folder
    /// out from under the browser.
    var extensionFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clinqy/extension")
    }

    @discardableResult
    func prepareExtension() -> Bool {
        let fm = FileManager.default
        guard let bundled = Bundle.main.url(forResource: "extension", withExtension: nil) else {
            // A development build run from the repo: use the repo's folder as is.
            return fm.fileExists(atPath: extensionFolder.path)
        }
        try? fm.createDirectory(at: extensionFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: extensionFolder)
        return (try? fm.copyItem(at: bundled, to: extensionFolder)) != nil
    }

    func openExtensionsPage(_ b: Browser) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.id) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", app.path, b.page]
        try? task.run()
    }

    func revealExtension() {
        prepareExtension()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(extensionFolder.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([extensionFolder])
    }

    var extensionConnected: Bool {
        guard let browser = browsers.first(where: { $0.id == browserID }),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).first else { return false }
        return BrowserBridge.shared.isConnected(app)
    }

    var canAutoLoad: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() && !browsers.isEmpty }

    /// Clinqy loads its own extension: opens the browser's extensions page, turns on Developer mode, clicks
    /// Load unpacked and picks the folder. Setup steps aside while it works and comes back when it's done.
    func letClinqyLoadExtension() {
        guard prepareExtension(), let b = browsers.first(where: { $0.id == browserID }) ?? browsers.first else { return }
        let task = "foreground: Open \(b.name) and go to \(b.page). If Developer mode (top right) is off, turn it on. "
            + "Click Load unpacked. In the folder dialog press Command+Shift+G, type \(extensionFolder.path), "
            + "press Return, then click Select. Stop when the Clinqy extension shows in the list. Don't change any other setting."
        autoLoad = .working
        autoStarted = Date()
        hideWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.run(task) }
    }

    private func watchAutoLoad() {
        guard autoLoad == .working, let started = autoStarted else { return }
        if extensionConnected || (Date().timeIntervalSince(started) > 4 && !isRunning()) {
            autoLoad = extensionConnected ? .done : .gaveUp
            autoStarted = nil
            showWindow()
        }
    }

    // ── Coding agents ──

    struct Agent: Identifiable {
        let id: String
        let name: String
        let detail: String
    }

    let agents = [
        Agent(id: "claude", name: "Claude Code", detail: "claude mcp add"),
        Agent(id: "agy", name: "Antigravity CLI", detail: "agy mcp add"),
        Agent(id: "cursor", name: "Cursor", detail: "~/.cursor/mcp.json"),
        Agent(id: "codex", name: "Codex", detail: "~/.codex/config.toml"),
        Agent(id: "gemini", name: "Gemini CLI", detail: "~/.gemini/settings.json"),
        Agent(id: "opencode", name: "OpenCode", detail: "opencode mcp add --global"),
    ]

    func connect(_ id: String) {
        do {
            _ = try AgentConnect.connect(id)
            agentStatus[id] = "Connected"
        } catch {
            agentStatus[id] = error.localizedDescription
        }
    }

    /// Puts the `clinqy` command on the PATH (~/.local/bin), pointing at the copy inside the app.
    func installCommand() {
        let fm = FileManager.default
        guard let script = Bundle.main.url(forResource: "clinqy", withExtension: nil) else {
            commandStatus = "Not in this build (installed by ./build.sh instead)"
            return
        }
        let bin = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let link = bin.appendingPathComponent("clinqy")
        do {
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: script)
            let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0.hasSuffix("/.local/bin") }
            commandStatus = onPath ? "Installed at ~/.local/bin/clinqy" : "Installed at ~/.local/bin/clinqy. Add ~/.local/bin to your PATH to use it."
        } catch {
            commandStatus = error.localizedDescription
        }
    }
}

// MARK: - Views

private let blue = Brand.blue

/// Bracketed buttons, like the website's: [ Continue ].
private struct BrandButton: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            Text("[").opacity(0.5)
            configuration.label
            Text("]").opacity(0.5)
        }
        .font(Brand.mono(12.5, .semibold))
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .foregroundStyle(primary ? Brand.bg : Brand.text)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(primary ? Brand.text : Brand.text.opacity(configuration.isPressed ? 0.12 : 0.0001))
        )
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(primary ? Color.clear : Brand.text.opacity(0.28)))
        .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
        .contentShape(Rectangle())
    }
}

extension View {
    func brand(primary: Bool = false) -> some View { buttonStyle(BrandButton(primary: primary)) }

    func card(_ highlight: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: 8).fill(highlight ? blue.opacity(0.12) : Brand.text.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(highlight ? blue.opacity(0.55) : Brand.line))
    }
}

struct OnboardingView: View {
    static let size = CGSize(width: 900, height: 640)
    @ObservedObject var model: OnboardingModel
    @ObservedObject var dashboardModel: DashboardModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 220)
            Rectangle().fill(Brand.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    page
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 36)
                        .padding(.top, 44)
                        .padding(.bottom, 24)
                }
                .id(model.showingDashboard)
                if !model.showingDashboard {
                    Rectangle().fill(Brand.line).frame(height: 1)
                    Footer(model: model)
                }
            }
        }
        .frame(minWidth: Self.size.width, maxWidth: .infinity, minHeight: Self.size.height, maxHeight: .infinity)
        .background(Brand.bg)
        .ignoresSafeArea()   // the title bar is transparent; without this it pushes the footer off the bottom
        .foregroundStyle(Brand.text)
    }

    @ViewBuilder private var page: some View {
        if model.showingDashboard {
            DashboardContentView(model: dashboardModel)
        } else {
            switch model.step {
            case .welcome: WelcomePage()
            case .model: ModelPage(model: model)
            case .permissions: PermissionsPage(model: model)
            case .browser: BrowserPage(model: model)
            case .keys: KeysPage()
            case .agents: AgentsPage(model: model)
            case .done: DonePage(model: model)
            }
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                Text("clinqy").font(Brand.pixel(22))
            }
            .padding(.bottom, 26)
            ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { s in
                Button {
                    model.refreshConfiguration()
                    model.step = s
                    model.showingDashboard = false
                } label: {
                    StepRow(index: s.rawValue + 1, title: s.title, state: rowState(s))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(s.rawValue > model.step.rawValue)
            }
            Rectangle().fill(Brand.line).frame(height: 1).padding(.vertical, 12)
            Button { model.showingDashboard = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar")
                        .frame(width: 22, height: 22)
                        .foregroundStyle(model.showingDashboard ? Brand.blue : Brand.soft)
                    Text("Dashboard")
                        .font(Brand.mono(12.5, model.showingDashboard ? .semibold : .regular))
                    Spacer()
                }
                .foregroundStyle(model.showingDashboard ? Brand.text : Brand.soft)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.showingDashboard ? .isSelected : [])
            Spacer()
            Text("Setup and Dashboard are always available from the menu bar.")
                .font(Brand.mono(10.5)).foregroundStyle(Brand.soft).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 48)
        .padding(.bottom, 26)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Brand.text.opacity(0.025))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.showingDashboard)
    }

    private func rowState(_ s: OnboardingModel.Step) -> StepRow.RowState {
        s == model.step && !model.showingDashboard ? .current : (s.rawValue < model.step.rawValue ? .done : .todo)
    }
}

private struct StepRow: View {
    enum RowState { case todo, current, done }
    let index: Int
    let title: String
    let state: RowState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(state == .current ? blue : Color.clear)
                Circle().stroke(state == .current ? Color.clear : Brand.text.opacity(state == .done ? 0.5 : 0.18))
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.green)
                } else {
                    Text("\(index)").font(Brand.mono(10.5, .semibold))
                }
            }
            .frame(width: 22, height: 22)
            Text(title)
                .font(Brand.mono(12.5, state == .current ? .semibold : .regular))
                .foregroundStyle(state == .todo ? Brand.soft : Brand.text)
        }
        .padding(.vertical, 6)
    }
}

private struct Footer: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        HStack(spacing: 10) {
            if model.step != .welcome {
                Button("Back") { model.back() }.brand().keyboardShortcut(.cancelAction)
            }
            Spacer()
            switch model.step {
            case .welcome:
                Button("Get started") { model.next() }.brand(primary: true).keyboardShortcut(.defaultAction)
            case .model:
                Button("Save and continue") { model.save(); model.next() }
                    .brand(primary: true).keyboardShortcut(.defaultAction).disabled(!model.canSave)
            case .done:
                Button("Open Clinqy") { model.finish() }.brand(primary: true).keyboardShortcut(.defaultAction)
            default:
                if model.step == .agents || model.step == .browser {
                    Button("Skip") { model.next() }.brand()
                }
                Button("Continue") { model.next() }.brand(primary: true).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .background(Brand.text.opacity(0.02))
    }
}

struct PageTitle: View {
    let title: String
    let text: String
    var bottomPadding: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Brand.pixel(30))
            Text(text).font(.system(size: 13.5)).foregroundStyle(Brand.soft).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, bottomPadding)
    }
}

private struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88).padding(.leading, -8).padding(.bottom, 10)
            PageTitle(title: "Your cursor’s new buddy.",
                      text: "Press ⌃⌥ and say what you want. A small blue cursor goes and does it on screen, and hands your pointer back when it’s done.")
            VStack(alignment: .leading, spacing: 16) {
                Bullet(icon: "cpu", title: "Choose what drives it",
                       text: "A coding CLI you already use, your own API key, or a model running on this Mac.")
                Bullet(icon: "lock.shield", title: "Grant a few permissions",
                       text: "So it can see the screen, click and type. It asks before anything you can’t take back.")
                Bullet(icon: "safari", title: "Add the browser extension",
                       text: "For exact clicks and typing on web pages. Clinqy can load it for you.")
                Bullet(icon: "keyboard", title: "Learn the keys",
                       text: "Tap ⌃⌥ to type, hold it to talk, and stop any task from the menu bar.")
            }
            Text("Takes about three minutes.").font(Brand.mono(11.5)).foregroundStyle(Brand.soft).padding(.top, 26)
        }
    }
}

private struct Bullet: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(blue).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(text).font(.system(size: 12.5)).foregroundStyle(Brand.soft).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Model page

private struct ModelPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "What should drive Clinqy?",
                      text: "At each step Clinqy sends a screenshot or the screen’s layout to a model. Pick one; you can change it later.")
            ForEach([ModelChoice.Group.cli, .api, .local], id: \.rawValue) { group in
                Text(group.rawValue).font(Brand.mono(11, .semibold)).foregroundStyle(Brand.soft)
                    .padding(.top, group == .cli ? 0 : 16).padding(.bottom, 6)
                ForEach(ModelChoice.allCases.filter { $0.group == group }) { c in
                    ChoiceRow(model: model, choice: c)
                }
            }
            ChoiceDetail(model: model).padding(.top, 18)
        }
    }
}

private struct ChoiceRow: View {
    @ObservedObject var model: OnboardingModel
    let choice: ModelChoice

    var body: some View {
        let selected = model.choice == choice
        HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? blue : Brand.soft)
            VStack(alignment: .leading, spacing: 1) {
                Text(choice.title).font(.system(size: 13, weight: .medium))
                Text(choice.subtitle).font(.system(size: 11.5)).foregroundStyle(Brand.soft)
            }
            Spacer()
            if choice.group == .cli { CLIBadge(found: model.cliPath(choice) != nil, tick: model.tick) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .card(selected)
        .contentShape(Rectangle())
        .onTapGesture { model.choice = choice }
        .padding(.bottom, 4)
    }
}

private struct CLIBadge: View {
    let found: Bool
    let tick: Int

    var body: some View {
        Text(found ? "installed" : "not found")
            .font(Brand.mono(10.5, .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(found ? Brand.green.opacity(0.14) : Brand.text.opacity(0.06)))
            .foregroundStyle(found ? Brand.green : Brand.soft)
    }
}

private struct ChoiceDetail: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.choice.group {
            case .cli: CLIDetail(model: model)
            case .api: APIDetail(model: model)
            case .local: LocalDetail(model: model)
            }
            TestRow(model: model)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct CLIDetail: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let c = model.choice
        if let path = model.cliPath(c) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Found at \(path)", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.green).font(.system(size: 12.5))
                if c == .claude && !Provider.isClaudeLoggedIn {
                    Text("It doesn’t look logged in yet.").font(.system(size: 12.5)).foregroundStyle(.orange)
                }
                HStack {
                    Button("Log in in Terminal") { model.runInTerminal(c.install?.login ?? "") }.brand()
                    Text("Skip this if you’ve already logged in.").font(.system(size: 11.5)).foregroundStyle(Brand.soft)
                }
            }
        } else if let install = c.install {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(c.title) isn’t installed on this Mac yet.").font(.system(size: 12.5))
                HStack {
                    if let cmd = install.command {
                        Button("Install in Terminal") { model.runInTerminal("\(cmd) && \(install.login)") }.brand(primary: true)
                    }
                    Button("Open install guide") { NSWorkspace.shared.open(URL(string: install.docs)!) }.brand()
                }
                Text("This page notices when it’s installed.").font(.system(size: 11.5)).foregroundStyle(Brand.soft)
            }
        }
    }
}

private struct APIDetail: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.choice.title) API key").font(.system(size: 12.5, weight: .medium))
            SecureField(model.choice.keyHint, text: $model.apiKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                if let url = model.choice.keyURL {
                    Button("Get a key") { NSWorkspace.shared.open(URL(string: url)!) }.buttonStyle(.link)
                }
                Spacer()
                Text("Saved only in ~/.config/clinqy/env, readable by you alone.")
                    .font(.system(size: 11.5)).foregroundStyle(Brand.soft)
            }
        }
    }
}

private struct LocalDetail: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model (must understand images)").font(.system(size: 12.5, weight: .medium))
            TextField("qwen3-vl", text: $model.localModel).textFieldStyle(.roundedBorder)
            Text("Server address").font(.system(size: 12.5, weight: .medium))
            TextField(model.choice == .ollama ? "http://localhost:11434/v1" : "https://api.groq.com/openai/v1", text: $model.baseURL)
                .textFieldStyle(.roundedBorder)
            if model.choice == .compatible {
                Text("API key").font(.system(size: 12.5, weight: .medium))
                SecureField("Optional", text: $model.apiKey).textFieldStyle(.roundedBorder)
            } else {
                Button("Pull the model in Terminal") { model.runInTerminal("ollama pull \(model.localModel)") }.brand()
            }
        }
    }
}

private struct TestRow: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        HStack(spacing: 10) {
            Button(model.test == .running ? "Testing…" : "Test connection") { model.runTest() }
                .brand()
                .disabled(!model.canSave || model.test == .running)
            switch model.test {
            case .idle: Text("Sends one short request.").font(.system(size: 11.5)).foregroundStyle(Brand.soft)
            case .running: ProgressView().controlSize(.small)
            case .passed(let s): Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(Brand.green).font(.system(size: 12))
            case .failed(let s): Label(s, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .font(.system(size: 12)).lineLimit(3)
            }
        }
    }
}

// MARK: Permissions page

private struct PermissionsPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let _ = model.tick
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Let Clinqy see and use your Mac",
                      text: "Click Turn on, then switch Clinqy on in the System Settings page that opens. This page updates by itself. Nothing leaves your Mac except what goes to the model you chose.")
            ForEach(model.perms) { p in PermRow(model: model, perm: p) }
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise").foregroundStyle(Brand.soft)
                Text("Just turned on Screen Recording? It works after a restart.").font(.system(size: 12)).foregroundStyle(Brand.soft)
                Button("Restart Clinqy") { model.relaunch() }.brand()
            }
            .padding(.top, 14)
        }
    }
}

private struct PermRow: View {
    @ObservedObject var model: OnboardingModel
    let perm: OnboardingModel.Perm

    var body: some View {
        let ok = perm.granted()
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 17)).foregroundStyle(ok ? Brand.green : Brand.soft)
            VStack(alignment: .leading, spacing: 1) {
                Text(perm.id).font(.system(size: 13, weight: .medium))
                Text(perm.why).font(.system(size: 11.5)).foregroundStyle(Brand.soft)
            }
            Spacer()
            if !ok { Button("Turn on") { model.open(perm) }.brand() }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .card()
        .padding(.bottom, 4)
    }
}

// MARK: Browser page

private struct BrowserPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let _ = model.tick
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Add the browser extension",
                      text: "With it, Clinqy reads web pages exactly and clicks and types in the right place, even inside embedded forms. It only talks to Clinqy on this Mac. Chrome, Arc, Brave and Edge can load it.")
            ConnectedBadge(connected: model.extensionConnected).padding(.bottom, 16)
            AutoLoadCard(model: model).padding(.bottom, 14)
            ManualCard(model: model)
        }
        .onAppear { model.prepareExtension() }
    }
}

private struct ConnectedBadge: View {
    let connected: Bool

    var body: some View {
        Label(connected ? "Extension connected. You’re done here." : "Not connected yet. Use either way below.",
              systemImage: connected ? "checkmark.circle.fill" : "hourglass")
            .font(Brand.mono(11.5, .medium))
            .foregroundStyle(connected ? Brand.green : Brand.soft)
    }
}

/// "Let Clinqy do it": Clinqy loads its own extension while you watch.
private struct AutoLoadCard: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "cursorarrow.click.2").font(.system(size: 20)).foregroundStyle(blue).frame(width: 28)
            VStack(alignment: .leading, spacing: 8) {
                Text("Let Clinqy do it").font(.system(size: 14, weight: .semibold))
                Text("Clinqy opens your browser’s extensions page, turns on Developer mode, clicks Load unpacked and picks the folder. This window steps aside while it works, and comes back when it’s done.")
                    .font(.system(size: 12.5)).foregroundStyle(Brand.soft).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if model.browsers.count > 1 {
                        Picker("", selection: $model.browserID) {
                            ForEach(model.browsers) { b in Text(b.name).tag(b.id) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 60 * CGFloat(model.browsers.count))
                    }
                    Button(model.autoLoad == .working ? "Working…" : "Let Clinqy do it") { model.letClinqyLoadExtension() }
                        .brand(primary: true)
                        .disabled(!model.canAutoLoad || model.autoLoad == .working || model.extensionConnected)
                }
                if !model.canAutoLoad {
                    Text(model.browsers.isEmpty ? "No Chrome, Arc, Brave or Edge on this Mac."
                                                : "Turn on Accessibility and Send input events on the last step first.")
                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                } else if model.autoLoad == .gaveUp && !model.extensionConnected {
                    Text("It didn’t finish. Try again, or do it yourself below; it takes a minute.")
                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(true)
    }
}

/// Doing it by hand: the animation shows the three clicks, the steps say where they are.
private struct ManualCard: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Or do it yourself").font(.system(size: 14, weight: .semibold))
            HStack(alignment: .top, spacing: 18) {
                ExtensionArt().frame(width: 230, height: 200)
                VStack(alignment: .leading, spacing: 0) {
                    NumberedStep(n: 1, text: "Open the extensions page and switch on Developer mode, top right.") {
                        HStack {
                            ForEach(model.browsers) { b in Button(b.name) { model.openExtensionsPage(b) }.brand() }
                        }
                    }
                    NumberedStep(n: 2, text: "Click Load unpacked. In the window that opens, press ⌘⇧G, paste (the folder’s path is already copied) and press Return.") {
                        Button("Copy path, show folder") { model.revealExtension() }.brand()
                    }
                    NumberedStep(n: 3, text: "Click Select. Clinqy appears in your extensions, and the line at the top of this page turns green.") {
                        EmptyView()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct NumberedStep<Content: View>: View {
    let n: Int
    let text: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(Brand.mono(11, .bold))
                .frame(width: 22, height: 22).overlay(Circle().stroke(Brand.text.opacity(0.3)))
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                content
            }
        }
        .padding(.bottom, 16)
    }
}

// MARK: Keys page

private struct KeysPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "The keys you’ll use",
                      text: "Everything starts from ⌃⌥ (Control + Option, together), from any app.")
            HStack(alignment: .top, spacing: 12) {
                KeyCard(title: "Tap ⌃⌥", text: "Opens the bar. Type what you want and press Return.") { TapKeysArt() }
                KeyCard(title: "Hold ⌃⌥", text: "Talk while you hold it. Let go and it sends.") { HoldKeysArt() }
                KeyCard(title: "Click ■ to stop", text: "While it works, the menu-bar icon turns into a stop button.") { StopArt() }
            }
            Text("Also good to know").font(Brand.mono(11, .semibold)).foregroundStyle(Brand.soft).padding(.top, 22).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 7) {
                Hint(key: "⌃⌥", text: "while it works: tap to add something or change the plan")
                Hint(key: "esc", text: "closes the bar")
                Hint(key: "Dry run", text: "in the bar: shows what it would click and type, without doing it")
                Hint(key: "Circle", text: "draw a loop around anything on screen and ask about “this”")
                Hint(key: "Watch & learn", text: "do a task once yourself, and it becomes a skill")
            }
        }
    }
}

private struct KeyCard<Art: View>: View {
    let title: String
    let text: String
    @ViewBuilder let art: Art

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            art.frame(height: 150).frame(maxWidth: .infinity)
            Text(title).font(Brand.mono(13, .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(Brand.soft).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}

private struct Hint: View {
    let key: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text(key).font(Brand.mono(11.5, .semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Brand.text.opacity(0.08)))
                .frame(minWidth: 110, alignment: .leading)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Brand.soft)
        }
    }
}

// MARK: Agents page

private struct AgentsPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Connect your coding agents",
                      text: "Optional. Clinqy becomes a tool your coding agent can call: to read the tab you have open, check how a page really renders, or click through a flow in your own browser.")
            ForEach(model.agents) { a in AgentRow(model: model, agent: a) }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("The clinqy command").font(.system(size: 13, weight: .medium))
                    Text(model.commandStatus.isEmpty ? "Run tasks and read pages from any terminal." : model.commandStatus)
                        .font(.system(size: 11.5)).foregroundStyle(Brand.soft)
                }
                Spacer()
                Button("Install") { model.installCommand() }.brand()
            }
            .padding(.vertical, 9).padding(.horizontal, 12)
            .card()
            .padding(.top, 12)
        }
    }
}

private struct AgentRow: View {
    @ObservedObject var model: OnboardingModel
    let agent: OnboardingModel.Agent

    var body: some View {
        let status = model.agentStatus[agent.id]
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name).font(.system(size: 13, weight: .medium))
                Text(status ?? agent.detail).font(.system(size: 11.5))
                    .foregroundStyle(status == "Connected" ? Brand.green : (status == nil ? Brand.soft : Color.orange))
            }
            Spacer()
            Button(status == "Connected" ? "Connected" : "Connect") { model.connect(agent.id) }
                .brand()
                .disabled(status == "Connected")
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .card()
        .padding(.bottom, 4)
    }
}

// MARK: Done page

private struct DonePage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let _ = model.tick
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "You’re set. Try it.",
                      text: "Clinqy lives in your menu bar. Open Clinqy below, or press ⌃⌥ anywhere, and ask for something.")
            VStack(alignment: .leading, spacing: 8) {
                Status(ok: Provider.current.cliPath != nil || !Provider.current.isCLI, text: "Model: \(ModelChoice.from(Provider.current).title)")
                Status(ok: Permissions.allGranted, text: Permissions.allGranted ? "Permissions on" : "Some permissions are still off")
                Status(ok: model.extensionConnected, text: model.extensionConnected ? "Browser extension connected" : "Browser extension not connected (optional)")
            }
            Text("Things to try").font(Brand.mono(11, .semibold)).foregroundStyle(Brand.soft).padding(.top, 26).padding(.bottom, 8)
            ForEach(["where’s the brightness setting?", "open example.com and tell me what it’s about", "add a reminder to call Raj tomorrow"], id: \.self) {
                Text("“\($0)”").font(Brand.mono(12.5)).padding(.vertical, 3)
            }
        }
    }
}

private struct Status: View {
    let ok: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.system(size: 12.5))
            .foregroundStyle(ok ? Brand.green : .orange)
    }
}
