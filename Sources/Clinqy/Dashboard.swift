import AppKit
import SwiftUI

@MainActor
final class DashboardModel: ObservableObject {
    @Published var page = "Overview"
    /// The window showing the dashboard is on screen (set by its window).
    var windowVisible: () -> Bool = { true }
    @Published var range = UsageRange.month
    @Published var selectedProvider = Provider.current.rawValue
    @Published var modelChoice = "sonnet"
    @Published var modelIdentifier = ""
    @Published var summonKey = Config.value("HOTKEY") ?? "ctrl+alt"
    @Published var talkKey = Config.value("TALK_HOTKEY") ?? ""
    @Published var tokenLimit = Config.value("MONTHLY_TOKEN_LIMIT") ?? ""
    @Published var requestLimit = Config.value("MONTHLY_REQUEST_LIMIT") ?? ""
    @Published var status = ""
    @Published private(set) var configuredProviders: Set<Provider>?
    @Published var summary = UsageStore.summary(range: .month)
    @Published var monthlySummary = UsageStore.summary(range: .month)

    let providers = Provider.allCases
    let providerManaged = Provider.isManagedByEnvironment
    let shortcutsManaged = ProcessInfo.processInfo.environment["HOTKEY"] != nil ||
        ProcessInfo.processInfo.environment["TALK_HOTKEY"] != nil
    private let providerChanged: () -> Void
    private let providerSetup: () -> Void
    private let shortcutsChanged: () -> Void
    private let captureChanged: (Bool) -> Void
    private var savedSettings: [String: String] = [:]
    private var savedModelState: [String] = []
    private var modelProvider = Provider.current
    private var configurationTask: Task<Void, Never>?

    init(providerChanged: @escaping () -> Void, shortcutsChanged: @escaping () -> Void,
         captureChanged: @escaping (Bool) -> Void, providerSetup: @escaping () -> Void) {
        self.providerChanged = providerChanged
        self.providerSetup = providerSetup
        self.shortcutsChanged = shortcutsChanged
        self.captureChanged = captureChanged
        savedSettings = ["HOTKEY": summonKey, "TALK_HOTKEY": talkKey,
                         "MONTHLY_TOKEN_LIMIT": tokenLimit, "MONTHLY_REQUEST_LIMIT": requestLimit]
        loadAppModel(for: Provider.current)
    }

    var currentProvider: Provider { Provider(rawValue: selectedProvider) ?? Provider.current }
    var usesModelTiers: Bool { ![.codexCLI, .ollama, .compatible].contains(currentProvider) }
    var modelManaged: Bool {
        let environment = ProcessInfo.processInfo.environment
        switch currentProvider {
        case .ollama, .compatible: return environment["LOCAL_MODEL"] != nil
        case .codexCLI: return environment["CODEX_MODEL"] != nil
        case .agyCLI:
            return environment["AGY_MODEL"] != nil ||
                (Config.value("AGY_MODEL") == nil && environment["CLAUDE_MODEL"] != nil)
        default:
            return environment["CLAUDE_MODEL"] != nil ||
                (Config.value("CLAUDE_MODEL") == nil && environment["AGY_MODEL"] != nil)
        }
    }
    var canSaveModel: Bool {
        if usesModelTiers && modelChoice != "custom" { return true }
        return !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || currentProvider == .codexCLI
    }
    var modelName: String {
        let model = currentProvider.model(Brain.defaultModel(for: currentProvider))
        return model.isEmpty ? "Provider default" : model
    }
    var displayedTalkKey: String {
        if ["off", "none", "disabled"].contains(talkKey.lowercased()) { return "Off" }
        return talkKey.isEmpty ? "Same as summon · hold to talk" : talkKey
    }
    var tokenLimitValue: Int { Int(tokenLimit) ?? 0 }
    var requestLimitValue: Int { Int(requestLimit) ?? 0 }

    func refresh(settings: Bool = false) {
        let current = UsageStore.summary(range: range)
        if summary != current { summary = current }
        let month = range == .month ? current : UsageStore.summary(range: .month)
        if monthlySummary != month { monthlySummary = month }
        if settings {
            selectedProvider = Provider.current.rawValue
            let latest = ["HOTKEY": Config.value("HOTKEY") ?? "ctrl+alt",
                          "TALK_HOTKEY": Config.value("TALK_HOTKEY") ?? "",
                          "MONTHLY_TOKEN_LIMIT": Config.value("MONTHLY_TOKEN_LIMIT") ?? "",
                          "MONTHLY_REQUEST_LIMIT": Config.value("MONTHLY_REQUEST_LIMIT") ?? ""]
            if summonKey == savedSettings["HOTKEY"] { summonKey = latest["HOTKEY"] ?? "ctrl+alt" }
            if talkKey == savedSettings["TALK_HOTKEY"] { talkKey = latest["TALK_HOTKEY"] ?? "" }
            if tokenLimit == savedSettings["MONTHLY_TOKEN_LIMIT"] { tokenLimit = latest["MONTHLY_TOKEN_LIMIT"] ?? "" }
            if requestLimit == savedSettings["MONTHLY_REQUEST_LIMIT"] { requestLimit = latest["MONTHLY_REQUEST_LIMIT"] ?? "" }
            savedSettings = latest
            let provider = currentProvider
            if provider != modelProvider || modelDraft == savedModelState { loadAppModel(for: provider) }
            refreshProviderStatus()
        }
    }

    // CLI configuration checks can pump the run loop; keep them out of SwiftUI rendering.
    private func refreshProviderStatus() {
        configurationTask?.cancel()
        configurationTask = Task { [weak self] in
            let configured = await Task.detached {
                Set(Provider.allCases.filter { $0.isConfigured })
            }.value
            guard !Task.isCancelled else { return }
            self?.configuredProviders = configured
        }
    }

    func changeRange(_ value: UsageRange) {
        range = value
        summary = UsageStore.summary(range: value)
    }

    func setupProvider() { providerSetup() }

    func chooseProvider(_ raw: String) {
        guard !providerManaged, let provider = Provider(rawValue: raw) else { return }
        guard provider.isConfigured else {
            status = "Set up \(provider.displayName) before switching to it."
            return
        }
        do {
            try Config.write(["PROVIDER": provider.rawValue, "USE_AGY": nil])
            selectedProvider = provider.rawValue
            loadAppModel(for: provider)
            status = "Using \(provider.displayName)."
            providerChanged()
        } catch {
            status = "Couldn't save provider: \(error.localizedDescription)"
        }
    }

    private var modelDraft: [String] { [modelChoice, modelIdentifier] }

    private func loadAppModel(for provider: Provider) {
        modelProvider = provider
        if provider == .ollama || provider == .compatible {
            modelChoice = "custom"
            modelIdentifier = Config.value("LOCAL_MODEL") ?? "qwen3-vl"
        } else if provider == .codexCLI {
            modelChoice = "custom"
            modelIdentifier = Config.value("CODEX_MODEL") ?? ""
        } else {
            let configured = Brain.defaultModel(for: provider)
            if ["haiku", "sonnet", "opus"].contains(configured.lowercased()) {
                modelChoice = configured.lowercased()
                modelIdentifier = ""
            } else {
                modelChoice = "custom"
                modelIdentifier = configured
            }
        }
        savedModelState = modelDraft
    }

    func saveAppModel() {
        guard !modelManaged else {
            status = "The model is managed by an environment variable."
            return
        }
        guard canSaveModel else {
            status = "Enter a model ID before saving."
            return
        }
        let value = usesModelTiers && modelChoice != "custom"
            ? modelChoice
            : modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String
        switch currentProvider {
        case .ollama, .compatible: key = "LOCAL_MODEL"
        case .codexCLI: key = "CODEX_MODEL"
        case .agyCLI: key = "AGY_MODEL"
        case .claudeCLI: key = "CLAUDE_MODEL"
        case .anthropic: key = "ANTHROPIC_MODEL"
        case .openai: key = "OPENAI_MODEL"
        case .gemini: key = "GEMINI_MODEL"
        case .openrouter: key = "OPENROUTER_MODEL"
        }
        do {
            try Config.write([key: value.isEmpty ? nil : value])
            savedModelState = modelDraft
            status = currentProvider == .codexCLI && value.isEmpty
                ? "Using Codex's configured default model."
                : "App model saved."
            providerChanged()
        } catch {
            status = "Couldn't save model: \(error.localizedDescription)"
        }
    }

    func saveLimits() {
        guard validLimit(tokenLimit), validLimit(requestLimit) else {
            status = "Enter a whole number of zero or greater, or leave the limit empty."
            return
        }
        do {
            try Config.write([
                "MONTHLY_TOKEN_LIMIT": tokenLimit.isEmpty ? nil : tokenLimit,
                "MONTHLY_REQUEST_LIMIT": requestLimit.isEmpty ? nil : requestLimit,
            ])
            savedSettings["MONTHLY_TOKEN_LIMIT"] = tokenLimit
            savedSettings["MONTHLY_REQUEST_LIMIT"] = requestLimit
            status = "Monthly warning limits saved."
        } catch {
            status = "Couldn't save limits: \(error.localizedDescription)"
        }
    }

    func saveShortcuts() {
        guard !shortcutsManaged else {
            status = "Shortcuts are managed by environment variables."
            return
        }
        guard Self.validSummon(summonKey), talkKey.isEmpty || Self.validTalk(talkKey) else {
            status = "Summon needs modifier keys. Push-to-talk needs modifiers and one key."
            return
        }
        do {
            try Config.write(["HOTKEY": summonKey, "TALK_HOTKEY": talkKey.isEmpty ? nil : talkKey])
            savedSettings["HOTKEY"] = summonKey
            savedSettings["TALK_HOTKEY"] = talkKey
            shortcutsChanged()
            status = "Shortcuts saved. Listening only starts while the push-to-talk shortcut is held."
        } catch {
            status = "Couldn't save shortcuts: \(error.localizedDescription)"
        }
    }

    func resetTalkShortcut() {
        talkKey = ""
        saveShortcuts()
    }

    func captureShortcut(talk: Bool) {
        guard !shortcutsManaged else {
            status = "Shortcuts are managed by environment variables."
            return
        }
        captureChanged(true)
        var captured: String?
        let alert = NSAlert()
        alert.messageText = talk ? "Press a push-to-talk shortcut" : "Press a summon shortcut"
        alert.informativeText = talk
            ? "Hold modifier keys and one letter, number, Space, or function key."
            : "Press one or more modifier keys together, without another key."
        alert.addButton(withTitle: "Cancel")
        let view = ShortcutCaptureView(allowKey: talk) { value in
            captured = value
            NSApp.stopModal()
        }
        alert.accessoryView = view
        alert.window.initialFirstResponder = view
        alert.runModal()
        captureChanged(false)
        if let captured {
            if talk { talkKey = captured } else { summonKey = captured }
        }
    }

    private func validLimit(_ value: String) -> Bool {
        value.isEmpty || Int(value).map { $0 >= 0 } == true
    }

    private static func validSummon(_ value: String) -> Bool {
        let parts = value.lowercased().split(separator: "+").map(String.init)
        return !parts.isEmpty && parts.allSatisfy { ["ctrl", "control", "alt", "option", "opt", "shift", "cmd", "command"].contains($0) }
            && parts.count == Set(parts).count
    }

    private static func validTalk(_ value: String) -> Bool {
        let parts = value.lowercased().split(separator: "+").map(String.init)
        guard parts.count >= 2 else { return false }
        let modifiers = ["ctrl", "control", "alt", "option", "opt", "shift", "cmd", "command"]
        return parts.dropLast().allSatisfy { modifiers.contains($0) } && parts.dropLast().count == Set(parts.dropLast()).count
            && (parts.last == "space" || parts.last?.count == 1 || parts.last.map { $0.first == "f" && Int($0.dropFirst()).map { (1...12).contains($0) } == true } == true)
    }
}

private final class ShortcutCaptureView: NSView {
    private let allowKey: Bool
    private let captured: (String) -> Void
    private var lastModifiers: NSEvent.ModifierFlags = []

    init(allowKey: Bool, captured: @escaping (String) -> Void) {
        self.allowKey = allowKey
        self.captured = captured
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func flagsChanged(with event: NSEvent) {
        guard !allowKey else { return }
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if !mods.isEmpty {
            lastModifiers = mods
        } else if !lastModifiers.isEmpty {
            let shortcut = Self.modifierNames(lastModifiers)
            lastModifiers = []
            captured(shortcut)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard allowKey else { NSSound.beep(); return }
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !mods.isEmpty else { NSSound.beep(); return }
        let key: String
        if let functionKey = Self.functionKeyCodes[event.keyCode] {
            key = functionKey
        } else {
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            key = chars == " " ? "space" : chars
        }
        guard key == "space" || key.count == 1 || (key.first == "f" && Int(key.dropFirst()).map { (1...12).contains($0) } == true) else {
            NSSound.beep()
            return
        }
        captured(Self.modifierNames(mods) + "+" + key)
    }

    private static func modifierNames(_ flags: NSEvent.ModifierFlags) -> String {
        [(NSEvent.ModifierFlags.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "cmd")]
            .filter { flags.contains($0.0) }.map { $0.1 }.joined(separator: "+")
    }

    private static let functionKeyCodes: [UInt16: String] = [122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
                                                               98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]
}

struct DashboardContentView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var chartVisible = false

    private let pages = ["Overview", "Usage", "AI & Model", "Background", "Shortcuts"]
    @AppStorage("backgroundMode") private var backgroundMode = false
    @AppStorage("backgroundWebMode") private var backgroundWebMode = "extension"
    private let surface = Brand.text.opacity(0.035)
    private let text = Brand.text
    private let muted = Brand.soft
    private let blue = Brand.blue

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: "Dashboard", text: model.currentProvider.displayName + " · " + model.modelName, bottomPadding: 0)
            Picker("Dashboard section", selection: $model.page) {
                ForEach(pages, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented)
            .accessibilityLabel("Dashboard section")
            if model.page == "Overview" || model.page == "Usage" {
                HStack {
                    Text("Usage period").font(Brand.mono(11)).foregroundStyle(muted)
                    Spacer()
                    Picker("Usage period", selection: Binding(get: { model.range }, set: { model.changeRange($0) })) {
                        ForEach(UsageRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 180)
                }
            }
            pageContent
                .id(model.page)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 6)))
        }
        .foregroundStyle(text)
        .opacity(reduceMotion || appeared ? 1 : 0)
        .offset(y: reduceMotion || appeared ? 0 : 6)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.page)
        .onAppear {
            model.refresh(settings: true)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { appeared = true }
        }
        .onDisappear { appeared = false }
        .onReceive(Timer.publish(every: 8, tolerance: 1, on: .main, in: .common).autoconnect()) { _ in
            if model.windowVisible() { model.refresh() }
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch model.page {
        case "Usage": usagePage
        case "AI & Model": providerPage
        case "Shortcuts": shortcutsPage
        case "Background": backgroundPage
        default: overviewPage
        }
    }

    private var backgroundPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                Toggle(isOn: $backgroundMode) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Work in the background").font(.system(size: 15, weight: .semibold))
                        Text("Web tasks run in Clinqy’s own browser tabs while you keep browsing. File and supported service tasks run directly; native app work asks before switching to foreground. "
                             + "Either way, a request can choose: say or type “in the background” or “not in the background”.")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }
                }
                .toggleStyle(.switch)
            }
            card {
                Picker("Web browser mode", selection: $backgroundWebMode) {
                    Text("Signed-in browser tabs").tag("extension")
                    Text("Separate headless Chrome").tag("headless")
                }
                Text("Signed-in browser tabs use the Clinqy extension in your connected browser profile. Tabs stay inactive and reuse website sessions, with a Clinqy group where supported. Other tabs stay yours. Password prompts and security dialogs may need your input. Changes apply to the next task.")
                    .font(.system(size: 11)).foregroundStyle(muted)
                Text("Headless Chrome sign-in").font(.system(size: 14, weight: .semibold))
                Text("The optional headless mode uses a separate Chrome profile. Sign in here once, then finish sign-in before running headless tasks.")
                    .font(.system(size: 11)).foregroundStyle(muted)
                HStack {
                    Button("Sign in…") { (NSApp.delegate as? AppDelegate)?.workerLogin() }.brand()
                    Button("Finish sign-in") { (NSApp.delegate as? AppDelegate)?.finishWorkerLogin() }.brand()
                }
            }
            card {
                Text("Tasks and recovery").font(.system(size: 14, weight: .semibold))
                Text("Check the current stage and saved results here or in Telegram. Interrupted tasks stay stopped; queued tasks restored after a restart need review before starting.")
                    .font(.system(size: 11)).foregroundStyle(muted)
                HStack {
                    Button("Tasks & Recovery") { TasksPanel.shared.show() }.brand()
                    Button("Show background work") { AgentScreenView.shared.show() }.brand()
                }
            }
        }
    }

    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                metric("Requests", value: "\(model.summary.requests)", note: model.range.rawValue)
                metric("Input tokens", value: tokenText(model.summary.inputTokens), note: meterNote)
                metric("Output tokens", value: tokenText(model.summary.outputTokens), note: meterNote)
            }
            limitCard
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    providerCard.frame(maxWidth: .infinity)
                    shortcutCard.frame(maxWidth: .infinity)
                }.frame(minWidth: 660)
                VStack(spacing: 14) { providerCard; shortcutCard }
            }
            providerBreakdown
            statusText
        }
    }

    private var usagePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                metric("Model requests", value: "\(model.summary.requests)", note: model.range.rawValue)
                metric("Input tokens", value: tokenText(model.summary.inputTokens), note: meterNote)
                metric("Output tokens", value: tokenText(model.summary.outputTokens), note: meterNote)
            }
            usageTrend
            limitCard
            providerBreakdown
            statusText
        }
    }

    private var usageTrend: some View {
        card {
            Text("Daily token usage · last 14 active days").font(.system(size: 14, weight: .semibold))
            if model.summary.meteredRequests == 0 {
                Text("Daily token totals appear for providers that report usage.")
                    .font(.system(size: 11)).foregroundStyle(muted)
            } else {
                let days = Array(model.summary.days.suffix(14))
                let maximum = max(1, days.map { $0.inputTokens + $0.outputTokens }.max() ?? 0)
                HStack(alignment: .bottom, spacing: 7) {
                    ForEach(days) { day in
                        VStack(spacing: 6) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(blue.opacity(0.85))
                                .frame(height: chartVisible || reduceMotion ? max(3, CGFloat(day.inputTokens + day.outputTokens) / CGFloat(maximum) * 76) : 3)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: chartVisible)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: day.inputTokens + day.outputTokens)
                            Text(String(day.day.suffix(5)))
                                .font(Brand.mono(10)).foregroundStyle(muted)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 100)
                    }
                }
            }
        }
        .onAppear { chartVisible = true }
        .onDisappear { chartVisible = false }
    }

    private var providerPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Active provider").font(.system(size: 15, weight: .semibold))
                        Text(model.modelName).font(.system(size: 12, design: .monospaced)).foregroundStyle(muted)
                    }
                    Spacer()
                    if model.providerManaged { Text("Managed by environment").font(.system(size: 11)).foregroundStyle(muted) }
                }
                Divider().overlay(Brand.line)
                ForEach(model.providers, id: \.rawValue) { provider in
                    let configured = model.configuredProviders?.contains(provider)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.displayName).font(.system(size: 13, weight: .medium))
                            Text(configured == nil ? "Checking configuration…" : configured == true ? providerSubtitle(provider) : "Set up credentials or install this provider first")
                                .font(.system(size: 11)).foregroundStyle(muted)
                        }
                        Spacer()
                        if provider.rawValue == model.selectedProvider {
                            Text("In use").font(.system(size: 11, weight: .semibold)).foregroundStyle(blue)
                        } else if configured == true && !model.providerManaged {
                            Button("Use") { model.chooseProvider(provider.rawValue) }.brand()
                        } else if configured == false {
                            Button("Set up") { model.setupProvider() }.brand()
                        }
                    }.padding(.vertical, 8)
                }
                Divider().overlay(Brand.line)
                VStack(alignment: .leading, spacing: 9) {
                    Text("Model for Clinqy").font(.system(size: 13, weight: .semibold))
                    if model.usesModelTiers {
                        Picker("Model", selection: $model.modelChoice) {
                            Text("Fast · Haiku").tag("haiku")
                            Text("Balanced · Sonnet").tag("sonnet")
                            Text("Most capable · Opus").tag("opus")
                            Text("Custom model ID…").tag("custom")
                        }
                        .pickerStyle(.menu)
                        .disabled(model.modelManaged)
                        if model.modelChoice == "custom" {
                            TextField("Provider model ID", text: $model.modelIdentifier)
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.modelManaged)
                        }
                    } else {
                        TextField(model.currentProvider == .codexCLI ? "Codex model ID (optional)" : "Model ID, e.g. qwen3-vl",
                                  text: $model.modelIdentifier)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.modelManaged)
                        Text(model.currentProvider == .codexCLI
                             ? "Leave blank to use the model configured in Codex."
                             : "Use a model available from this local server.")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }
                    if model.modelManaged {
                        Text("Model selection is managed by your environment.")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }
                    HStack {
                        Text("Used for new Clinqy tasks.").font(.system(size: 11)).foregroundStyle(muted)
                        Spacer()
                        Button("Save model") { model.saveAppModel() }.brand(primary: true)
                            .disabled(model.modelManaged || !model.canSaveModel)
                    }
                }
            }
            if model.providerManaged {
                Text("The active provider is set by the environment or launch arguments, so Clinqy can't change it here.")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
            statusText
        }
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                Text("Summon Clinqy").font(.system(size: 15, weight: .semibold))
                if model.shortcutsManaged {
                    Text("Shortcuts are managed by environment variables.").font(.system(size: 11)).foregroundStyle(muted)
                }
                Text("Tap the modifier shortcut to open the command bar.").font(.system(size: 11)).foregroundStyle(muted)
                shortcutRow(value: model.summonKey, talk: false) { model.captureShortcut(talk: false) }
                Divider().overlay(Brand.line)
                Text("Push to talk").font(.system(size: 15, weight: .semibold))
                Text("Clinqy listens only while you hold this shortcut.").font(.system(size: 11)).foregroundStyle(muted)
                shortcutRow(value: model.displayedTalkKey, talk: true) { model.captureShortcut(talk: true) }
                if !model.talkKey.isEmpty {
                    Button("Use the current summon shortcut for hold-to-talk") { model.resetTalkShortcut() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(blue)
                }
                HStack {
                    Spacer()
                    Button("Save shortcuts") { model.saveShortcuts() }.brand(primary: true)
                }
            }
            card {
                Text("Current bindings").font(.system(size: 14, weight: .semibold))
                HStack {
                    Text("Summon"); Spacer(); keycap(model.summonKey)
                }
                HStack {
                    Text("Hold to talk"); Spacer(); keycap(model.displayedTalkKey)
                }
            }
            statusText
        }
    }

    private var limitCard: some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Monthly usage warnings").font(.system(size: 15, weight: .semibold))
                    Text("Request totals are local; tokens are provider-reported · warnings never block use").font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer()
                if let value = limitProgress {
                    Text("\(value)%").font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(value >= 100 ? Color.orange : blue)
                }
            }
            if let limit = Int(model.tokenLimit), limit > 0 {
                if model.monthlySummary.meteredRequests > 0 {
                    progressRow("Tokens", used: model.monthlySummary.inputTokens + model.monthlySummary.outputTokens, limit: limit)
                } else {
                    Text("No provider-reported token totals this month").font(.system(size: 11)).foregroundStyle(muted)
                }
            } else {
                Text("No token warning limit set").font(.system(size: 11)).foregroundStyle(muted)
            }
            if let limit = Int(model.requestLimit), limit > 0 {
                progressRow("Requests", used: model.monthlySummary.requests, limit: limit)
            } else {
                Text("No request warning limit set").font(.system(size: 11)).foregroundStyle(muted)
            }
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent {
                    TextField("No limit", text: $model.tokenLimit).textFieldStyle(.roundedBorder).frame(width: 180)
                } label: {
                    Text("Token warning").frame(width: 120, alignment: .leading)
                }
                LabeledContent {
                    TextField("No limit", text: $model.requestLimit).textFieldStyle(.roundedBorder).frame(width: 180)
                } label: {
                    Text("Request warning").frame(width: 120, alignment: .leading)
                }
                HStack { Spacer(); Button("Save warnings") { model.saveLimits() }.brand(primary: true) }
            }
        }
    }

    private var providerCard: some View {
        card {
            Text("AI provider").font(.system(size: 14, weight: .semibold))
            Text(model.currentProvider.displayName).font(Brand.mono(17, .medium))
            Text(model.modelName).font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
            Button("Manage provider") { model.page = "AI & Model" }.buttonStyle(.plain).foregroundStyle(blue)
        }
    }

    private var shortcutCard: some View {
        card {
            Text("Shortcuts").font(.system(size: 14, weight: .semibold))
            HStack { Text("Summon"); Spacer(); keycap(model.summonKey) }
            HStack { Text("Hold to talk"); Spacer(); keycap(model.displayedTalkKey) }
            Button("Customize shortcuts") { model.page = "Shortcuts" }.buttonStyle(.plain).foregroundStyle(blue)
        }
    }

    private var providerBreakdown: some View {
        card {
            HStack {
                Text("Provider activity").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(model.summary.meteredRequests) of \(model.summary.requests) requests returned token totals")
                    .font(.system(size: 10)).foregroundStyle(muted)
            }
            if model.summary.providers.isEmpty {
                Text("Usage tracking starts with your next model request.").font(.system(size: 12)).foregroundStyle(muted)
            } else {
                ForEach(model.summary.providers) { provider in
                    HStack {
                        Text(providerName(provider.provider)).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(provider.requests) requests").font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                        Text(provider.meteredRequests == 0 ? "— tokens" : "\(format(provider.inputTokens + provider.outputTokens)) tokens")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                    }.padding(.vertical, 5)
                }
            }
        }
    }

    private var statusText: some View {
        Group {
            if !model.status.isEmpty { Text(model.status).font(.system(size: 11)).foregroundStyle(muted)
                    .id(model.status).transition(.opacity) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.status)
    }

    private var meterNote: String {
        if model.summary.requests == 0 { return "No requests yet" }
        return model.summary.meteredRequests == model.summary.requests ? "Provider-reported" : "Some providers don't report tokens"
    }

    private var limitProgress: Int? {
        guard let limit = Int(model.tokenLimit), limit > 0 else { return nil }
        return min(100, (model.monthlySummary.inputTokens + model.monthlySummary.outputTokens) * 100 / limit)
    }

    private func metric(_ title: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(value).font(Brand.mono(23, .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: value)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(text)
            Text(note).font(.system(size: 11)).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading).padding(16)
        .background(surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line, lineWidth: 1))
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content)
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line, lineWidth: 1))
    }

    private func progressRow(_ title: String, used: Int, limit: Int) -> some View {
        let fraction = min(1, Double(used) / Double(limit))
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(format(used)) / \(format(limit))").font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.text.opacity(0.08))
                    Capsule().fill(fraction >= 1 ? Color.orange : blue).frame(width: proxy.size.width * fraction)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
                }
            }.frame(height: 6)
            if fraction >= 1 {
                Text("Monthly \(title.lowercased()) warning reached · Clinqy will continue to work")
                    .font(.system(size: 10)).foregroundStyle(Color.orange)
            }
        }
    }

    private func shortcutRow(value: String, talk: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            keycap(value.isEmpty ? "Press to record" : value)
            Spacer()
            Button("Record") { action() }.brand()
        }
    }

    private func keycap(_ value: String) -> some View {
        Text(value.replacingOccurrences(of: "ctrl", with: "⌃")
            .replacingOccurrences(of: "alt", with: "⌥")
            .replacingOccurrences(of: "shift", with: "⇧")
            .replacingOccurrences(of: "cmd", with: "⌘")
            .replacingOccurrences(of: "+", with: " "))
            .font(Brand.mono(11, .medium))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Brand.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    private func tokenText(_ count: Int) -> String {
        model.summary.meteredRequests == 0 ? "—" : format(count)
    }

    private func format(_ value: Int) -> String { value.formatted(.number) }
    private func providerName(_ raw: String) -> String { Provider(rawValue: raw)?.displayName ?? raw }
    private func providerSubtitle(_ provider: Provider) -> String {
        let model = provider.model(Brain.defaultModel(for: provider))
        return model.isEmpty ? "Ready · provider chooses its model" : "Ready · \(model)"
    }
}
