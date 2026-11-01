import Foundation
import Combine

/// One concrete, replayable step: what was done and how to find its target again — no model needed.
struct WorkflowStep: Codable, Equatable {
    /// open_app, open_url, click, type, key, scroll, applescript, wait, expect
    var action: String
    var name: String?
    var url: String?
    var text: String?
    var keys: String?
    var dir: String?
    var script: String?
    var ms: Int?
    var submit: Bool?
    var target: Target?

    /// How to find an element again: in a web page (role + visible text) or an app (AX role + label).
    struct Target: Codable, Equatable {
        var kind: String   // "web" | "ax"
        var role: String
        var label: String
    }

    var summary: String {
        let t = target.map { "\($0.role) “\($0.label.prefix(50))”" } ?? ""
        switch action {
        case "open_app": return "Open \(name ?? "?")"
        case "open_url": return "Go to \(url ?? "?")"
        case "click": return "Click \(t)"
        case "type": return "Type “\((text ?? "").prefix(40))”\(t.isEmpty ? "" : " into \(t)")\(submit == true ? " ⏎" : "")"
        case "key": return "Press \(keys ?? "?")"
        case "scroll": return "Scroll \(dir ?? "down")"
        case "applescript": return "Run a script"
        case "wait": return "Wait \(ms ?? 0) ms"
        case "expect": return "Expect “\((text ?? "").prefix(60))”"
        default: return action
        }
    }

    /// The step as an agent action, with {parameters} filled in; the target is resolved to an id by the caller.
    func action(params: [String: String], id: String?) -> [String: Any] {
        func fill(_ s: String?) -> String? {
            guard var s else { return nil }
            for (k, v) in params { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
            return s
        }
        var a: [String: Any] = ["do": action]
        if let v = fill(name) { a["name"] = v }
        if let v = fill(url) { a["url"] = v }
        if let v = fill(text) { a["text"] = v }
        if let v = keys { a["keys"] = v }
        if let v = dir { a["dir"] = v }
        if let v = fill(script) { a["script"] = v }
        if let v = ms { a["ms"] = v }
        if let v = submit { a["submit"] = v }
        if let id { a["id"] = id }
        return a
    }
}

/// A saved, deterministic workflow (replayed without a model; healed by the model only when a step breaks).
struct Workflow: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var summary: String
    var params: [String]
    var steps: [WorkflowStep]
    var created: Date
    /// "HH:mm" to run every day, or nil.
    var schedule: String?
    var lastScheduledRun: Date?
    var healedAt: Date?
    var runs: Int = 0
    /// Values used when a parameter isn't given (the ones from the original run).
    var defaults: [String: String]? = nil

    /// Builds a workflow from a finished run: typed text becomes a named parameter (the field's label),
    /// defaulting to what was typed, so `clinqy workflow <name> "Your name=Priya"` works.
    static func from(_ entry: History.Entry) -> Workflow? {
        guard entry.requiresFreshWork != true else { return nil }
        guard var steps = entry.trace, !steps.isEmpty else { return nil }
        var params: [String] = []
        var defaults: [String: String] = [:]
        for i in steps.indices where steps[i].action == "type" {
            guard let text = steps[i].text, !text.isEmpty else { continue }
            var key = (steps[i].target?.label ?? "text").trimmingCharacters(in: .whitespaces)
            if key.isEmpty { key = "text" }
            var unique = key, n = 2
            while params.contains(unique) { unique = "\(key) \(n)"; n += 1 }
            params.append(unique)
            defaults[unique] = text
            steps[i].text = "{\(unique)}"
        }
        return Workflow(name: String(entry.request.prefix(60)), summary: entry.answer, params: params, steps: steps,
                        created: Date(), defaults: defaults)
    }
}

@MainActor
final class Workflows: ObservableObject {
    static let shared = Workflows()
    @Published private(set) var all: [Workflow] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clinqy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workflows.json")
    }()

    @Published private(set) var storageError: String?
    private var corrupt = false

    private init() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { all = try JSONDecoder.iso8601.decode([Workflow].self, from: Data(contentsOf: url)) }
        catch {
            corrupt = true
            storageError = "Workflows couldn't be read safely. The existing file was preserved; scheduled workflows are disabled."
        }
    }

    @discardableResult
    func add(_ w: Workflow) -> Bool { mutate { $0.insert(w, at: 0) } }
    @discardableResult
    func remove(_ w: Workflow) -> Bool { mutate { $0.removeAll { $0.id == w.id } } }
    @discardableResult
    func update(_ w: Workflow) -> Bool {
        guard let i = all.firstIndex(where: { $0.id == w.id }) else { return false }
        return mutate { $0[i] = w }
    }
    func named(_ name: String) -> Workflow? {
        all.first { $0.name.lowercased() == name.lowercased() } ?? all.first { $0.name.lowercased().contains(name.lowercased()) }
    }

    /// Schedule acknowledgement must be durable before the caller treats it as saved. Workflow files are
    /// small; use an atomic synchronous write instead of the best-effort asynchronous history/cache queue.
    private func mutate(_ change: (inout [Workflow]) -> Void) -> Bool {
        guard !corrupt else { return false }
        let previous = all
        change(&all)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder.iso8601.encode(all).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            storageError = nil
            return true
        } catch {
            all = previous
            storageError = "Couldn't save workflows. The existing file was preserved; scheduled task records prevent duplicate dispatch."
            return false
        }
    }
}

/// What a run that worked did, kept so a similar request later starts from the known path instead of exploring.
/// Saved automatically (unlike a Workflow, which the user saves), keyed by where it started (site or app), the
/// request's content words and the page title's shape.
struct CachedRoute: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Where the run started: the page's host ("linkedin.com") or the app ("whatsapp").
    var place: String
    /// The start page's title with numbers blanked ("jobs | linkedin", "(#) whatsapp"); "" for apps.
    var title: String
    /// The site the run opened itself, if its first step was a URL (then where it started doesn't matter).
    var site: String?
    var request: String
    var words: [String]
    var steps: [WorkflowStep]
    var uses = 1
    /// Runs this was offered to that didn't work out; too many and it's dropped.
    var misses = 0
    var last: Date
}

@MainActor
final class ReplayCache {
    static let shared = ReplayCache()
    private(set) var all: [CachedRoute] = []
    /// The replay offered to each run, so its outcome is booked against that run's offer and no other's.
    private var offers = ReplayOffers()
    private var currentRun: UUID? { TaskExecution.current?.id }

    private static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clinqy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("replays.json")
    }
    private let url: URL
    private var procedures: ProcedureStore?

    init(file: URL? = nil) {
        self.url = file ?? Self.defaultURL
        switch StoreFile.load(url, decode: { try? JSONDecoder.iso8601.decode([CachedRoute].self, from: $0) }) {
        case .value(let saved): all = saved
        case .unreadable: StoreFile.quarantine(url)   // set aside, so the next save can't replace it with an empty cache
        case .absent: break
        }
        do {
            let store = try ProcedureStore(file: url.appendingPathExtension("sqlite"))
            try store.save(all, importing: true)
            all = try store.recent()
            procedures = store
        } catch { NSLog("Clinqy procedures: %@", error.localizedDescription) }
    }

    /// Keeps a successful run's steps. `url`/`title` are the page it started on (nil in an app); typed secrets are blanked.
    func record(request: String, trace: [WorkflowStep], app: String?, url: String?, title: String?, redact: [String] = []) {
        let steps = trace.map { step -> WorkflowStep in
            var s = step
            for secret in redact where secret.count >= 3 { s.text = s.text?.replacingOccurrences(of: secret, with: "••••") }
            return s
        }
        // One step (or only opening a page) isn't a path worth offering.
        guard steps.filter({ !["expect", "wait", "open_url", "open_app"].contains($0.action) }).count >= 2 else { return }
        let words = Self.words(request)
        guard !words.isEmpty else { return }
        let place = Self.place(url: url, app: app), shape = Self.titleShape(title)
        let site = steps.first.flatMap { $0.action == "open_url" ? Self.host($0.url) : nil }
        if let i = all.firstIndex(where: { $0.place == place && $0.title == shape && $0.site == site && Set($0.words) == words }) {
            all[i].steps = steps
            all[i].request = request
            all[i].uses += 1
            all[i].misses = 0
            all[i].last = Date()
        } else {
            all.insert(CachedRoute(place: place, title: shape, site: site, request: request, words: words.sorted(), steps: steps, last: Date()), at: 0)
        }
        all.sort { $0.last > $1.last }
        if all.count > 150 { all.removeLast(all.count - 150) }
        offers.clear(run: currentRun)
        Embedder.shared.warm([request])
        save()
    }

    /// The saved run closest to this request here, if it's close enough to be worth following.
    func match(request: String, app: String?, url: String?, title: String?) -> CachedRoute? {
        let want = Self.words(request)
        guard !want.isEmpty else { return nil }
        let place = Self.place(url: url, app: app), shape = Self.titleShape(title)
        // Exact, same-place repeats need neither an embedding nor ranking every cached route.
        if let exact = all.first(where: {
            Router.normalize($0.request) == Router.normalize(request) && $0.place == place && $0.title == shape
        }) { return exact }
        if let cold = try? procedures?.exact(request, place: place, title: shape) {
            all.removeAll { $0.id == cold.id }
            all.insert(cold, at: 0)
            if all.count > 150 { all.removeLast() }
            return cold
        }
        let wantVector = Embedder.shared.vector(request)
        let scored = all.compactMap { r -> (CachedRoute, Double)? in
            let have = Set(r.words)
            let shared = want.intersection(have).count
            var score = Double(shared) / Double(want.union(have).count)
            // The same ask in other words ("fill this job application" / "apply for this job"): sentence vectors add
            // a little when they're very close, and only on top of at least one shared word.
            if shared > 0, let a = wantVector, let b = Embedder.shared.cached(r.request) {
                score += max(0, Double(Embedder.cosine(a, b)) - (Embedder.shared.usesModel ? 0.8 : 0.7))
            }
            if r.site != nil {
                // It opened its own page: the words decide (naming the site counts as agreeing).
                if let site = r.site?.split(separator: ".").first, want.contains(String(site)) { score += 0.2 }
                guard score >= 0.5 else { return nil }
            } else {
                // It worked on what was on screen: only here, and a vague request ("fill this") needs the same page.
                guard r.place == place else { return nil }
                if !shape.isEmpty, r.title == shape { score += 0.3 } else if want.count < 3 { return nil }
                guard score >= 0.5 else { return nil }
            }
            return (r, score - Double(r.misses) * 0.15)
        }
        return scored.max { $0.1 < $1.1 }?.0
    }

    /// Text for the lead's first message when a similar run worked before (nil = nothing close).
    func hint(request: String, app: String?, url: String?, title: String?) -> String? {
        guard let r = match(request: request, app: app, url: url, title: title) else { offers.clear(run: currentRun); return nil }
        offers.offer(r.id, to: currentRun)
        let where_ = r.site ?? r.place
        return "\nYou did a very similar task before (“\(r.request.prefix(80))” on \(where_), worked \(r.uses)×). These steps worked then:\n"
            + r.steps.enumerated().map { "\($0.offset + 1). \($0.element.summary)" }.joined(separator: "\n")
            + "\nFollow them as the fastest known path, batching steps you can see, but check each against the screen: "
            + "text typed last time is only an example unless this request uses it too, and still confirm before anything "
            + "that sends, submits or pays. Where the screen differs, work it out as usual."
    }

    /// Books how the run that was offered a replay went: a failure counts against it, and one that keeps failing is dropped.
    /// (A success is booked by `record`.)
    func outcome(ok: Bool) {
        let offered = offers.take(run: currentRun)
        guard !ok, let id = offered, let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].misses += 1
        if all[i].misses >= 2, all[i].misses >= all[i].uses { all.remove(at: i) }
        save()
    }

    /// A replay safe to run with no model (then healed by the model on the first mismatch): the same request word
    /// for word, worked at least twice and never missed, and nothing in it sends, submits, pays or deletes.
    func replayable(request: String, app: String?, url: String?, title: String?) -> Workflow? {
        guard let r = match(request: request, app: app, url: url, title: title), r.uses >= 2, r.misses == 0,
              Router.normalize(r.request) == Router.normalize(request),
              !r.steps.contains(where: Self.isRisky) else { return nil }
        offers.offer(r.id, to: currentRun)
        return Workflow(name: String(r.request.prefix(60)), summary: "Replayed from an earlier run", params: [], steps: r.steps, created: r.last)
    }

    func remove(_ r: CachedRoute) {
        do { try procedures?.remove(r.id) } catch { NSLog("Clinqy procedures: %@", error.localizedDescription) }
        all.removeAll { $0.id == r.id }; save()
    }

    func corrected(request: String) {
        let raw = request.replacingOccurrences(of: #"(?i)^(in the background|dry run):\s*"#, with: "", options: .regularExpression)
        let normalized = Router.normalize(raw)
        do { try procedures?.corrected(raw) } catch { NSLog("Clinqy procedures: %@", error.localizedDescription) }
        for i in all.indices where Router.normalize(all[i].request) == normalized {
            all[i].misses += 1
        }
        save()
    }

    private func save() {
        do { try procedures?.save(all) }
        catch { NSLog("Clinqy procedures: %@", error.localizedDescription) }
        if procedures == nil { Persist.write(all, to: url, encoder: .iso8601) }
    }

    // MARK: Keys

    private static let stopWords: Set<String> = ["the", "and", "for", "this", "that", "these", "those", "also", "with", "from",
                                                 "can", "you", "your", "now", "then", "again", "just", "all", "please",
                                                 "into", "onto", "about", "some", "any", "its", "are", "was", "will"]

    /// The request's content words ("fill this form for me" → form, fill).
    static func words(_ request: String) -> Set<String> {
        Set(Router.normalize(request).replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init).filter { $0.count > 2 && !stopWords.contains($0) })
    }

    static func host(_ url: String?) -> String? {
        guard let url, let host = URL(string: url)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func place(url: String?, app: String?) -> String {
        host(url) ?? (app ?? "").lowercased()
    }

    /// A page title with the parts that change (counts, ids, dates) blanked, so the same page matches again.
    static func titleShape(_ title: String?) -> String {
        guard let title else { return "" }
        return String(title.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).prefix(80))
    }

    private static func isRisky(_ step: WorkflowStep) -> Bool {
        if step.submit == true || step.action == "applescript" { return true }
        if step.action == "key", let keys = step.keys?.lowercased(), keys.contains("return") || keys.contains("enter") { return true }
        guard step.action == "click", let label = step.target?.label else { return false }
        return label.range(of: FastLane.riskyLabel, options: .regularExpression) != nil
    }
}

/// Writes app data off the main thread: encoded where it's called (a consistent snapshot), written on one serial
/// queue in order. history.json alone is ~300 KB, and runs used to pay for writing it before the next could start.
enum Persist {
    private static let queue = DispatchQueue(label: "clinqy.persist", qos: .utility)

    /// `onError` is told when the value couldn't be encoded or written (called off the main thread).
    static func write<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder, onError: (@Sendable (Error) -> Void)? = nil) {
        let data: Data
        do { data = try encoder.encode(value) } catch { onError?(error); return }
        queue.async { if let error = StoreFile.write(data, to: url) { onError?(error) } }
    }

    /// Waits for pending writes (before the app quits).
    static func flush() {
        queue.sync {}
        TaskMemory.shared.flush()
    }
}

extension JSONDecoder {
    static let iso8601: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}
