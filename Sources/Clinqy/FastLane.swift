import Foundation

/// Hands routine turns (the rest of a form the lead model already planned, ticking listed options, scrolling on)
/// to a faster model, so long runs don't pay the main model's latency for every mechanical step.
/// The lead opts in per turn with a "routine" plan; the helper gets that plan, recent steps and the screen,
/// may only use harmless actions, and hands back on anything risky, unclear, failed, repeated or final.
/// The lead rarely writes a plan itself, so a streak of pure navigation turns (scroll, look, Next, esc) starts
/// a shorter, navigation-only stint on its own (FAST_AUTO=off turns that off).
/// Everything the helper did is replayed to the lead at its next turn, so the lead's context stays whole.
/// FAST_MODEL=haiku (default) picks the helper model; FAST_MODEL=off turns it off.
@MainActor
final class FastLane {
    /// The helper model, or nil when turned off.
    static var model: String? {
        let raw = (Config.value("FAST_MODEL") ?? "haiku").trimmingCharacters(in: .whitespaces)
        return ["", "off", "none", "no", "0", "false"].contains(raw.lowercased()) ? nil : raw
    }

    /// Most helper turns in a row before the lead checks in again.
    static let maxStint = 6
    /// Same, for a stint started on its own (the lead didn't plan it, so it checks in sooner).
    static let maxAutoStint = 4

    /// Whether navigation streaks start a helper stint without the lead asking.
    static var autoDelegates: Bool {
        !["off", "none", "no", "0", "false"].contains((Config.value("FAST_AUTO") ?? "on").lowercased())
    }

    private let model: String?
    private let intro: String
    private var session: AgySession?
    /// The lead's routine plan; set = the next turns go to the helper.
    private var plan: String?
    /// The current stint was started on its own: the helper may only navigate (no typing, no picking options).
    private var auto = false
    /// Navigation-only lead turns in a row; `autoAfter` of them start an automatic stint.
    private var routineStreak = 0
    /// Raised each time an automatic stint hands back without doing anything, so a bad fit isn't retried every turn.
    private var autoAfter = 2
    private var stintTurns = 0
    private var stintFailures = 0
    private var briefed = false
    /// The task's context, sent to the helper ahead of its first stint (see `warm`).
    private var briefing: Task<Void, Never>?
    /// The previous turn ("say: actions"), waiting for its results.
    private var lastTurn: String?
    private var lastSignature = ""
    /// The screen the last reply was made for: the same step again is only a loop if the screen didn't change.
    private var lastScreen = ""
    /// Recent steps from both models, with results (the helper's briefing).
    private var recent: [String] = []
    /// Helper steps the lead hasn't heard about yet.
    private var unreported: [String] = []
    private var handback: String?
    /// Element lines of the last full screen, by id ("w3" → "w3 button: Submit").
    private var labels: [String: String] = [:]
    /// Who answered the last turn, for the log: "fast · ", "lead ← fast (why) · ", or "".
    private(set) var tag = ""

    /// The lead's provider: the helper runs on it too (a per-task provider override must not be silently dropped).
    private let provider: Provider

    /// `provider` is the lead session's. Names are compared as the provider resolves them, so a helper that would
    /// land on the very same model as the lead (Codex picks its own default for both) is not a helper at all.
    init(intro: String, leadModel: String, provider: Provider = Provider.current) {
        self.intro = intro
        self.provider = provider
        let fast = Self.model
        if let fast, fast == leadModel || provider.model(fast) == provider.model(leadModel) { model = nil } else { model = fast }
    }

    /// The helper's identity, for the log: nil when the helper is off.
    var helperRoute: String? {
        guard let model else { return nil }
        return "fast helper: provider=\(provider.rawValue) requested=\(model) model=\(provider.model(model).isEmpty ? "(cli default)" : provider.model(model)) role=helper"
    }

    /// Appended to the lead's first message: how to hand routine steps off (empty when off).
    var leadNote: String {
        guard model != nil else { return "" }
        return """


        Routine steps: when the next steps are purely mechanical and already decided (filling the remaining fields of \
        a form with values you know, ticking options you've chosen, scrolling on through a form), you may add \
        "routine":"<those steps, with the exact values to use>" to your reply (or "routine":true to just keep \
        scrolling and clicking Next/Continue the way you are). A faster helper then carries them out and \
        you get its steps and results before anything else is decided. Never mark as routine anything that needs a \
        choice or a detail you don't have yet, or that submits, sends, pays, books, deletes, posts, uploads, asks the \
        user or finishes the task.
        """
    }

    /// Gets this turn's reply: from the helper when the lead planned routine steps and nothing speaks against it,
    /// otherwise (or when the helper hands back) from the lead, told first what the helper did. `partial` sees the lead's
    /// reply as it's written (the helper's isn't streamed: its actions are vetted only once it's complete).
    func reply(to turnText: String, message: String, image: String?, failures: Int, lead: AgySession,
               partial: (@Sendable (String) -> Void)? = nil) async throws -> String {
        absorb(message: message, turnText: turnText, failures: failures)
        tag = ""
        if let why = blocker(turnText: turnText, failures: failures) {
            if plan != nil { end(why) }
        } else if let reply = await helperReply(turnText, image: image) {
            tag = "fast · "
            return reply
        }
        return try await leadReply(turnText, image: image, lead: lead, partial: partial)
    }

    func close() {
        briefing?.cancel()
        briefing = nil
        session?.close()
        session = nil
    }

    /// A last-line reminder: without it either model often writes a fake <invoke> tool call first, costing seconds a turn.
    private static let jsonOnly = "\n\nReply with the JSON object only — no tool-call or XML tags."

    /// The lead answered the last turn and will answer the next one, so it has seen every screen in between (a
    /// screen described as changes since the last one is only readable by the model that saw that one).
    var leadHasContinuity: Bool { !tag.hasPrefix("fast") && (model == nil || plan == nil) }

    // MARK: - Routing

    /// Why this turn must go to the lead (nil = the helper may take it).
    private func blocker(turnText: String, failures: Int) -> String? {
        guard model != nil, plan != nil else { return "no routine plan" }
        if turnText.hasPrefix("The user added") { return "the user added something" }
        if turnText.contains("Delegated worker results") { return "the lead must reconcile delegated results" }
        if stintTurns == 0, failures > 0 { return "the lead's last step failed" }
        if stintFailures >= 2 { return "steps failed twice" }
        let most = auto ? Self.maxAutoStint : Self.maxStint
        if stintTurns >= most { return "\(most) routine steps done, checking in" }
        return nil
    }

    private func helperReply(_ turnText: String, image: String?) async -> String? {
        guard let model, let plan else { return nil }
        await briefing?.value
        briefing = nil
        if session?.isAlive != true { session = try? AgySession(system: Self.system, model: model, provider: provider); briefed = false }
        var text = ""
        if !briefed {
            text += "The lead's context for this task:\n\(intro)\n\n"
            briefed = true
        }
        if stintTurns == 0 {
            text += (auto ? "The lead didn't plan this; it was just navigating. " : "") + "The lead's routine steps for you: \(plan)\n"
            if !recent.isEmpty { text += "Recent steps:\n" + recent.suffix(4).map { "- \($0)" }.joined(separator: "\n") + "\n" }
            text += "\n"
        }
        text += turnText + Self.jsonOnly
        let reply: String
        do {
            if session?.isAlive != true { session = try AgySession(system: Self.system, model: model, provider: provider) }
            guard let s = session else { return nil }
            reply = try await withTaskCancellationHandler { try await s.send(text, image: image) } onCancel: { s.close() }
        } catch {
            end("the helper failed: \(error.localizedDescription)")
            return nil
        }
        guard var json = Brain.json(from: reply) else { end("the helper's reply wasn't JSON"); return nil }
        let say = json["say"] as? String ?? ""
        let actions = json["actions"] as? [[String: Any]] ?? []
        if json["handback"] as? Bool == true { end("the helper handed back: \(say.prefix(80))"); return nil }
        if let bad = actions.first(where: { !Self.isSafe($0, labels: labels, navOnly: auto) }) {
            end("the helper wanted \(Self.brief(bad))")
            return nil
        }
        let signature = actions.map { "\($0)" }.joined()
        if signature == lastSignature, Self.screenPart(turnText) == lastScreen { end("the helper repeated itself"); return nil }
        let finishing = json["done"] as? Bool == true
        if actions.isEmpty { end(finishing ? "the helper thinks it's finished" : "the helper had nothing to do"); return nil }

        lastSignature = signature
        lastScreen = Self.screenPart(turnText)
        stintTurns += 1
        lastTurn = "[helper] \(say): " + actions.map(Self.brief).joined(separator: ", ")
        // Only the lead finishes: run the helper's last actions, then let the lead check.
        if finishing {
            json["done"] = false
            end("the helper finished its steps")
            guard let data = try? JSONSerialization.data(withJSONObject: json), let fixed = String(data: data, encoding: .utf8) else { return nil }
            return fixed
        }
        return reply
    }

    private func leadReply(_ turnText: String, image: String?, lead: AgySession,
                           partial: (@Sendable (String) -> Void)?) async throws -> String {
        var text = turnText
        if !unreported.isEmpty || handback != nil {
            text = "While you waited, a faster helper did routine steps for you:\n"
                + (unreported.isEmpty ? "(none)" : unreported.map { "- \($0)" }.joined(separator: "\n"))
                + (handback.map { "\nIt handed back because \($0)." } ?? "")
                + "\nContinue from here (latest results and screen below).\n\n" + turnText
            if let handback { tag = "lead ← fast (\(handback)) · " }
            unreported = []
            handback = nil
        }
        let reply = try await lead.send(text + Self.jsonOnly, image: image, partial: partial)
        let json = Brain.json(from: reply)
        let actions = json?["actions"] as? [[String: Any]] ?? []
        lastSignature = actions.map { "\($0)" }.joined()
        lastScreen = Self.screenPart(turnText)
        lastTurn = json.map { "\($0["say"] as? String ?? ""): " + actions.map(Self.brief).joined(separator: ", ") }
        // A routine plan starts a new stint, and so does a streak of pure navigation; anything else keeps the lead in charge.
        let say = json?["say"] as? String ?? ""
        let finishing = json?["done"] as? Bool == true
        routineStreak = !actions.isEmpty && actions.allSatisfy({ Self.isNavigation($0, labels: labels) }) ? routineStreak + 1 : 0
        if model != nil, !finishing, let routine = json.flatMap({ Self.routine(in: $0, say: say, actions: actions) }) {
            // "routine":true names no steps, so it gets the same navigation-only limits as an automatic stint.
            start(routine, auto: json?["routine"] is Bool)
        } else if model != nil, !finishing, Self.autoDelegates, routineStreak >= autoAfter {
            start(Self.keepGoing(say: say, actions: actions), auto: true)
        } else {
            plan = nil
            if Self.autoDelegates, routineStreak == autoAfter - 1 { warm() }
        }
        return reply
    }

    /// The screen part of a turn's text (from "Frontmost app:"), without the step results before it.
    private static func screenPart(_ turnText: String) -> String {
        turnText.range(of: "Frontmost app: ").map { String(turnText[$0.lowerBound...]) } ?? turnText
    }

    /// Books the previous turn's results and reads the element labels off a full screen.
    private func absorb(message: String, turnText: String, failures: Int) {
        if let last = lastTurn {
            let results = message.range(of: "Results:\n").map { String(message[$0.upperBound...]) } ?? ""
            let line = last + (results.isEmpty ? "" : " → " + results.replacingOccurrences(of: "\n", with: " ").prefix(300))
            recent = Array((recent + [line]).suffix(6))
            if tag.hasPrefix("fast") {
                unreported.append(line)
                if failures > 0 { stintFailures += 1 }
            }
            lastTurn = nil
        }
        if turnText.contains("\nFrontmost app: ") || turnText.hasPrefix("Frontmost app: ") {
            // A screen sent as changes updates the labels already known; a full listing replaces them.
            labels = Self.labels(in: turnText, updating: turnText.contains("changes since your last look") ? labels : [:])
        }
    }

    private func start(_ routine: String, auto: Bool) {
        plan = routine
        self.auto = auto
        stintTurns = 0
        stintFailures = 0
        routineStreak = 0
        // Start the helper now, while the lead's actions run.
        warm()
    }

    /// Starts the helper and hands it the task's context in the background, so its first real turn is a short
    /// message: read cold, the briefing made that turn ~3 s slower than the rest.
    private func warm() {
        guard let model else { return }
        if session?.isAlive != true { session = try? AgySession(system: Self.system, model: model, provider: provider); briefed = false }
        guard !briefed, briefing == nil, let s = session else { return }
        briefed = true
        let text = "The lead's context for this task:\n\(intro)\n\nNo steps for you yet; reply {\"say\":\"ready\",\"actions\":[]}."
        briefing = Task { _ = try? await s.send(text) }
    }

    private func end(_ why: String) {
        // An automatic stint that did nothing was a bad fit: wait for a longer streak before the next one.
        if auto, stintTurns == 0 { autoAfter = min(autoAfter + 1, 5) }
        plan = nil
        auto = false
        stintTurns = 0
        routineStreak = 0
        handback = why
    }

    /// The lead's plan from "routine": a string, a list of steps, or true for "keep navigating like this".
    nonisolated static func routine(in json: [String: Any], say: String, actions: [[String: Any]]) -> String? {
        switch json["routine"] {
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || ["false", "no", "none", "null"].contains(t.lowercased()) ? nil : t
        case let list as [String]:
            let steps = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return steps.isEmpty ? nil : steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")
        case let yes as Bool where yes:
            return keepGoing(say: say, actions: actions)
        default:
            return nil
        }
    }

    /// The plan for "keep navigating the way the lead was".
    nonisolated static func keepGoing(say: String, actions: [[String: Any]]) -> String {
        "Carry on the way the lead has been going (\"\(say)\": \(actions.map(brief).joined(separator: ", "))). " + navRules
    }

    // MARK: - Rules

    /// Words on a control that commit, leave or open something the lead should decide on.
    nonisolated static let riskyLabel = #"(?i)\b(submit|send|pay|payment|buy|purchase|order|checkout|check out|book|reserve|confirm|delete|remove|trash|erase|discard|post|publish|tweet|share|apply|sign ?up|register|sign ?in|log ?in|log ?out|sign ?out|transfer|withdraw|donate|reply|forward|unsubscribe|cancel|deactivate|save|upload|attach|browse|add file|allow|approve|accept|agree|install|download|close|quit|finish|done)\b"#
    nonisolated private static let safeKinds: Set<String> = ["click", "type", "choose", "key", "scroll", "wait", "look", "read", "recall", "autofill"]
    nonisolated private static let safeKeys: Set<String> = ["tab", "shift+tab", "up", "down", "left", "right", "esc", "escape",
                                                "pageup", "pagedown", "page_up", "page_down", "home", "end"]

    /// Buttons that only move on through a page or form, or wave a popup away.
    nonisolated private static let navLabel = #"(?i)\b(next|continue|show more|see more|load more|view more|read more|more|expand|review|got it|ok|okay|dismiss|not now|no thanks|maybe later)\b"#
    nonisolated private static let navKinds: Set<String> = ["click", "key", "scroll", "wait", "look", "read", "recall"]

    /// What a navigation-only stint may do.
    nonisolated static let navRules = """
    You may only scroll, wait, look, press tab/arrows/esc (to wave a popup away), and click buttons like Next, \
    Continue or Show more. Don't type anything and don't pick or tick any option. Hand back as soon as a field \
    needs filling, a choice is needed, anything looks unexpected, or you reach a review, submit or final step.
    """

    /// A lead step that only moves on (scroll, look, wait, safe keys, clicking Next/Continue/Show more):
    /// a streak of these is what an automatic stint takes over.
    nonisolated static func isNavigation(_ action: [String: Any], labels: [String: String]) -> Bool {
        ["click", "key", "scroll", "wait", "look"].contains((action["do"] as? String ?? "").lowercased())
            && isSafe(action, labels: labels, navOnly: true)
    }

    /// Whether the helper may run this action on its own; `navOnly` for a stint the lead didn't plan in words
    /// (no typing or choosing, and clicks only on Next/Continue-style buttons).
    nonisolated static func isSafe(_ action: [String: Any], labels: [String: String], navOnly: Bool = false) -> Bool {
        let kind = (action["do"] as? String ?? "").lowercased()
        guard safeKinds.contains(kind), !navOnly || navKinds.contains(kind) else { return false }
        if navOnly, kind == "click" {
            // "Continue with Google" signs in and "Continue to payment" pays: only plain navigation labels count.
            guard let id = action["id"] as? String, let line = labels[id], line.range(of: navLabel, options: .regularExpression) != nil,
                  line.range(of: #"(?i)\bcontinue (with|to|as)\b"#, options: .regularExpression) == nil else { return false }
        }
        let id = action["id"] as? String
        // Know what it's touching, and that it isn't a commit button.
        func harmless(_ id: String?) -> Bool {
            guard let id, let line = labels[id] else { return false }
            return line.range(of: riskyLabel, options: .regularExpression) == nil
        }
        switch kind {
        case "click", "choose": return harmless(id)
        case "type":
            if action["submit"] as? Bool == true || (action["submit"] as? String)?.lowercased() == "true" { return false }
            return id.map { labels[$0] != nil } ?? true
        case "key": return safeKeys.contains((action["keys"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: ""))
        default: return true
        }
    }

    /// "w3" → "w3 button: Submit [...]" for every listed element.
    nonisolated static func labels(in screen: String, updating known: [String: String] = [:]) -> [String: String] {
        var map = known
        // Diff lines: "- w7 …" is gone, "+ w7 …" / "~ w7 …" is (now) there. Gone first: an id can go and come back.
        let lines = screen.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func id(_ s: Substring) -> String? {
            guard let first = s.first, first == "e" || first == "w", let space = s.firstIndex(of: " "),
                  space > s.index(after: s.startIndex), s[s.index(after: s.startIndex)..<space].allSatisfy(\.isNumber) else { return nil }
            return String(s[..<space])
        }
        for line in lines where line.hasPrefix("- ") { if let id = id(line.dropFirst(2)) { map[id] = nil } }
        for line in lines {
            let s = line.hasPrefix("+ ") || line.hasPrefix("~ ") ? line.dropFirst(2) : Substring(line)
            if let id = id(s) { map[id] = String(s) }
        }
        return map
    }

    nonisolated static func brief(_ action: [String: Any]) -> String {
        let kind = action["do"] as? String ?? "?"
        let detail = [action["id"], action["text"] ?? action["option"], action["keys"], action["dir"]]
            .compactMap { $0.map { "\($0)".prefix(40) } }.joined(separator: " ")
        return detail.isEmpty ? kind : "\(kind) \(detail)"
    }

    static let system = AgentPrompt.system + """


    You are the fast helper here, not the lead. A lead model planned some routine steps and gave them to you; \
    carry out only those, one screen at a time, using the elements you are shown. Use only click (by id), \
    type (never with submit), choose, key (tab, arrows, esc), scroll, wait, look, read and recall. \
    Put every step you're sure of into one turn. Never set done:true and never ask the user. \
    As soon as the routine steps are done, or something is unclear or unexpected, a step failed, a value you need \
    wasn't given, or the next step would submit, send, pay, book, delete, post, upload, save, sign in or finish, \
    reply {"say":"<why, a few words>","actions":[],"handback":true} and the lead takes over.
    """
}
