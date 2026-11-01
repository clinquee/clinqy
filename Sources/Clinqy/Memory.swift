import Foundation

/// Durable facts the agent learns about the user ("mom = WhatsApp chat 'Mom ❤️'"), one per line in
/// ~/.config/clinqy/memory.md, which the user may edit by hand.
///
/// A line can carry a scope tag for know-how that only matters in one place: "[site:docs.google.com] date fields are
/// dd/mm/yyyy", "[app:Find My] open it as 'FindMy'". Scoped facts come along whenever that site or app is in use, also
/// mid-task, the moment the agent gets there. Untagged how-to lines that name a site or app get a scope inferred
/// (the file isn't rewritten for it).
///
/// Retrieval is hybrid: BM25 over the facts' words (query words widened with on-device word neighbours and with words
/// the best hits share), plus sentence-vector similarity (cached, see Embedder), plus how often and how lately a fact
/// was really used (memory.meta.json, keyed by a hash of the fact).
enum Memory {
    struct Scope: Hashable {
        /// "site" or "app"
        let kind: String
        /// "docs.google.com", "Find My"
        let name: String
        var tag: String { "[\(kind):\(name)]" }

        init(kind: String, name: String) {
            self.kind = kind
            self.name = kind == "site" ? Memory.bareHost(name) : name
        }

        /// "site:wellfound.com" / "app:Find My" (the form the model writes in a remember action).
        init?(_ raw: String?) {
            guard let raw, let colon = raw.firstIndex(of: ":") else { return nil }
            let kind = raw[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let name = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard ["site", "app"].contains(kind), !name.isEmpty else { return nil }
            self.init(kind: kind, name: name)
        }

        /// The site or app this is about is the one in use.
        func matches(app: String?, host: String?) -> Bool {
            if kind == "site" {
                guard let host = host.map(Memory.bareHost), !host.isEmpty else { return false }
                return host == name || host.hasSuffix("." + name) || name.hasSuffix("." + host)
            }
            guard let app else { return false }
            return Memory.squash(app) == Memory.squash(name)
        }

        /// The request names it ("open find my", "apply on wellfound").
        func mentioned(in text: String) -> Bool {
            let t = text.lowercased()
            if kind == "site" {
                if t.contains(name) { return true }
                // The site's own name ("wellfound" for wellfound.com); not the big umbrella ones (docs.google.com).
                let parts = name.split(separator: ".")
                guard parts.count >= 2 else { return false }
                let core = String(parts[parts.count - 2])
                return core.count >= 4 && !["google", "apple", "microsoft", "amazon"].contains(core) && Memory.hasWord(core, in: t)
            }
            let squashed = Memory.squash(name)
            return Memory.hasWord(name.lowercased(), in: t) || (squashed.count >= 5 && Memory.squash(t).contains(squashed))
        }
    }

    struct Fact: Equatable {
        let text: String
        let scope: Scope?
        /// The scope was written in the file (rather than inferred).
        let tagged: Bool
        /// The line as stored.
        var line: String { tagged ? "\(scope!.tag) \(text)" : text }
    }

    /// Where memory lives (tests point this at a scratch folder).
    nonisolated(unsafe) static var directoryOverride: URL?
    private static var directory: URL { directoryOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/clinqy") }
    private static var url: URL { directory.appendingPathComponent("memory.md") }
    private static var metaURL: URL { directory.appendingPathComponent("memory.meta.json") }

    // MARK: Reading (cached until the file changes)

    private struct Loaded {
        let stamp: Date?
        let size: Int
        let entries: [Fact]
        let index: Index
        let graph: MemoryGraph?
    }
    nonisolated(unsafe) private static var loaded: Loaded?
    private static let lock = NSLock()
    private static let graphQueue = DispatchQueue(label: "clinqy.memory-graph", qos: .utility)
    private final class Batch {
        var entries: [Fact]
        var dirty = false
        var metaDirty = false
        var changes: [Change] = []
        init(_ entries: [Fact]) { self.entries = entries }
    }
    private static var batch: Batch? { Thread.current.threadDictionary["clinqy.memory.batch"] as? Batch }

    /// Learning produces a small set of edits. Commit it once, then rebuild indexes/metadata once.
    static func performBatch(_ body: () -> Void) {
        if batch != nil { body(); return }
        let staged = Batch(entries)
        Thread.current.threadDictionary["clinqy.memory.batch"] = staged
        body()
        Thread.current.threadDictionary.removeObject(forKey: "clinqy.memory.batch")
        if staged.dirty { write(staged.entries.map(\.line)) }
        if staged.metaDirty { saveMeta() }
        for change in staged.changes { record(old: change.old, new: change.new, why: change.why) }
    }

    /// False when the memory file couldn't be written (a batched change reports success; the batch's flush reports its own).
    private static func commit(_ entries: [Fact]) -> Bool {
        if let batch { batch.entries = entries; batch.dirty = true; return true }
        return write(entries.map(\.line))
    }

    private static var current: Loaded {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = attrs?[.modificationDate] as? Date, size = (attrs?[.size] as? Int) ?? -1
        lock.lock()
        defer { lock.unlock() }
        if let l = loaded, l.stamp == stamp, l.size == size { return l }
        var text = ""
        switch StoreFile.load(url, decode: { String(data: $0, encoding: .utf8) }) {
        case .value(let t): text = t
        case .unreadable: StoreFile.quarantine(url)   // set aside, so the next save can't replace it with an empty memory
        case .absent: break
        }
        let entries = parse(text)
        let l = Loaded(stamp: stamp, size: size, entries: entries, index: Index(entries.map(\.text)), graph: nil)
        loaded = l
        graphQueue.async {
            guard lock.withLock({ loaded?.stamp == stamp && loaded?.size == size && loaded?.entries == entries }) else { return }
            let graph = MemoryGraph(entries)
            lock.lock(); defer { lock.unlock() }
            guard let current = loaded, current.stamp == stamp, current.size == size, current.entries == entries else { return }
            loaded = Loaded(stamp: stamp, size: size, entries: entries, index: current.index, graph: graph)
        }
        // New or edited facts get their vectors in the background.
        Embedder.shared.warm(entries.map(\.text))
        return l
    }

    /// Every fact, in the order learned (scope tags left off).
    static var facts: [String] { entries.map(\.text) }
    static var entries: [Fact] { batch?.entries ?? current.entries }
    /// The file's lines as written, tags included (for tidy-ups that rewrite the file).
    static var lines: [String] { entries.map(\.line) }

    static func parse(_ text: String) -> [Fact] {
        text.split(separator: "\n").compactMap { raw -> Fact? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Headings and comments in a hand-edited file aren't facts.
            if line.hasPrefix("#") && line.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil || line.hasPrefix("<!--") { return nil }
            // Any list style: "- ", "* ", "• ", "1. ", "2) ", "- [ ] ".
            if let bullet = line.range(of: #"^(?:[-*•+]|\d{1,3}[.)])\s+(?:\[[ xX]\]\s+)?"#, options: .regularExpression) {
                line = String(line[bullet.upperBound...])
            }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
            guard !line.isEmpty else { return nil }
            if let m = line.range(of: #"^\[(site|app)\s*:\s*[^\]]+\]\s*"#, options: [.regularExpression, .caseInsensitive]) {
                let tag = line[m].trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
                line = String(line[m.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let scope = Scope(String(tag)), !line.isEmpty { return Fact(text: line, scope: scope, tagged: true) }
            }
            return Fact(text: line, scope: inferScope(line), tagged: false)
        }
    }

    // MARK: Upgrading

    /// The memory format this build writes. Raise it when a change needs existing memory rewritten, and say how
    /// in `upgradeIfNeeded`.
    static let format = 2
    private static var formatURL: URL { directory.appendingPathComponent("memory.format") }

    /// Brings memory written by an older Clinqy (or edited by hand) to the current format, once, on the first launch
    /// of a newer build (app or `clinqy` command): one "- fact" line each, headings and other list styles cleaned
    /// up, exact duplicates merged (the newest kept, with any scope tag the older copy had). The old file is kept as
    /// a memory.backup-<date>.md first, and every merged line is logged in memory.history.jsonl. Returns a report
    /// when something changed.
    @discardableResult
    static func upgradeIfNeeded() -> String? {
        let have = (try? String(contentsOf: formatURL, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
        guard have < format else { return nil }
        var failed = false
        defer {
            // Marked done only when nothing went wrong, so a failed rewrite is tried again next launch.
            if !failed { StoreFile.write(Data("\(format)\n".utf8), to: formatURL) }
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (lines, merged) = normalized(parse(text))
        let rewritten = lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
        guard rewritten != text else { return nil }
        guard replaceAll(with: lines, backup: true) else { failed = true; return nil }
        for fact in merged { record(old: fact, new: nil, why: "upgrade: duplicate") }
        return "memory upgraded to format \(format): \(lines.count) facts\(merged.isEmpty ? "" : ", \(merged.count) duplicates merged")"
    }

    /// One line per fact, newest copy of a duplicate kept (in its place) with a scope tag if any copy had one.
    static func normalized(_ entries: [Fact]) -> (lines: [String], merged: [String]) {
        var lastIndex: [String: Int] = [:], tagged: [String: Scope] = [:]
        for (i, e) in entries.enumerated() {
            let k = e.text.lowercased()
            lastIndex[k] = i
            if e.tagged, let scope = e.scope { tagged[k] = scope }
        }
        var lines: [String] = [], merged: [String] = []
        for (i, e) in entries.enumerated() {
            let k = e.text.lowercased()
            guard lastIndex[k] == i else { merged.append(e.text); continue }
            lines.append(Fact(text: e.text, scope: tagged[k] ?? e.scope, tagged: tagged[k] != nil).line)
        }
        return (lines, merged)
    }

    // MARK: Scopes

    /// Words that make a fact know-how for a place (how to work a site or app) rather than a fact about the user.
    private static let howTo = #"(?i)(\b(click|clicking|press|tap|type into|button|field|fields|dropdown|combobox|listbox|picker|menu|selector|segment|shortcut|open_app|opened with|opens with|reached via|managed at|is at|go-to|scroll|upload|sign-?in|log-?in|sidebar|toolbar|tab group|spaces?)\b|\b(cmd|ctrl|shift|option|alt)\+)"#
    static let hostRegex = try? NSRegularExpression(pattern: hostPattern, options: [.caseInsensitive])
    private static let hostPattern = #"(?<![@\w.])(?:https?://)?((?:[a-z0-9-]+\.)+(?:com|io|in|org|net|ai|edu|co|dev|app|so|xyz|me|gg|tv))(?![\w-])"#

    /// Web products by name, so "In Google Forms…" or "Greenhouse forms: …" is know-how for that site even when
    /// no address is written out.
    static let webProducts: [(name: String, host: String)] = [
        ("Google Forms", "docs.google.com"), ("Google Docs", "docs.google.com"), ("Google Doc", "docs.google.com"),
        ("Google Sheets", "docs.google.com"), ("Google Slides", "docs.google.com"), ("Google Drive", "drive.google.com"),
        ("Google Meet", "meet.google.com"), ("Google Calendar", "calendar.google.com"), ("Gmail", "mail.google.com"),
        ("YouTube", "youtube.com"), ("LinkedIn", "linkedin.com"), ("GitHub", "github.com"), ("Wellfound", "wellfound.com"),
        ("Workday", "myworkdayjobs.com"), ("Greenhouse", "greenhouse.io"), ("Lever", "lever.co"), ("LeetCode", "leetcode.com"),
        ("ChatGPT", "chatgpt.com"), ("AWS Console", "console.aws.amazon.com"), ("Twitter", "x.com"), ("Notion", "notion.so"),
    ]

    /// The site or app an untagged how-to line is about; nil for facts about the user. When a line names several
    /// places ("On Lever forms … his X URL (https://x.com/…)"), the first one is what it's about.
    static func inferScope(_ text: String) -> Scope? {
        guard !isProfile(text), text.range(of: howTo, options: .regularExpression) != nil else { return nil }
        var found: [(at: String.Index, scope: Scope)] = []
        if let re = hostRegex, let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text) {
            found.append((r.lowerBound, Scope(kind: "site", name: String(text[r]))))
        }
        for product in webProducts where text.contains(product.name) {
            if let r = wordRange(product.name, in: text, caseSensitive: true) { found.append((r.lowerBound, Scope(kind: "site", name: product.host))) }
        }
        // An app counts only as a place ("in Arc", "WhatsApp Mac", "the Notes app"), not any word that happens to
        // be an app's name ("phone number", "Home / X").
        for (app, spaced) in installedApps where !webProducts.contains(where: { $0.name == app }) {
            // A plain substring check first: this runs for every app on every fact.
            guard text.contains(app) || text.contains(spaced) else { continue }
            let name = "(?:" + Set([app, spaced]).map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")"
            let place = "(?:^|(?<=\\b(?:in|on|via|open|opens|opened|using|within|inside) )|(?<=\\b(?:in|on|via|using|within|inside) the ))"
                + name + "(?:'s)?(?![\\p{L}\\p{N}])|(?<![\\p{L}\\p{N}])" + name + " (?:app|Mac|desktop)\\b"
            if let r = text.range(of: place, options: .regularExpression) { found.append((r.lowerBound, Scope(kind: "app", name: app))) }
        }
        return found.min { $0.at < $1.at }?.scope
    }

    /// Names of the apps on this Mac, longest first (so "Google Chrome" wins over "Chrome"), each with the way it's
    /// written in prose ("FindMy" → "Find My").
    static let installedApps: [(name: String, spaced: String)] = {
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        let names = dirs.flatMap { (try? fm.contentsOfDirectory(atPath: $0)) ?? [] }
            .filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }.filter { $0.count >= 3 }
        return Array(Set(names)).sorted { $0.count > $1.count }.map {
            ($0, $0.replacingOccurrences(of: #"(?<=\p{Ll})(?=\p{Lu})"#, with: " ", options: .regularExpression))
        }
    }()

    /// The facts kept for the site or app in use.
    static func scoped(app: String?, host: String?) -> [String] {
        entries.filter { $0.scope?.matches(app: app, host: host) == true }.map(\.text)
    }

    static func bareHost(_ raw: String) -> String {
        var h = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func hasWord(_ word: String, in text: String, caseSensitive: Bool = false) -> Bool {
        wordRange(word, in: text, caseSensitive: caseSensitive) != nil
    }

    static func wordRange(_ word: String, in text: String, caseSensitive: Bool = false) -> Range<String.Index>? {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: caseSensitive ? .regularExpression : [.regularExpression, .caseInsensitive])
    }

    // MARK: Profile

    /// Profile facts, always sent: who the user is and how to reach/represent them (forms need all of these). Only a
    /// fact that *states* one of these counts ("Phone number is …", "Amrit's gender is …", "Student at …"); one that
    /// merely mentions LinkedIn or a resume ("LinkedIn feed posts sometimes repost…") is ranked like the rest. (Matching
    /// mentions made 42 of 194 facts "profile", which filled the whole budget and left nothing to rank.)
    private static let corePattern = #"(?i)^(?:[\p{L}\p{N}-]+'s\s+)?(?:(?:personal|college|school|work|primary|full|current|home|default|preferred)\s+)?(?:name|full name|phone(?: number)?|mobile(?: number)?|e-?mail(?: address)?|gmail|browser|gender|date of birth|birthday|dob|roll number|cgpa|gpa|github|linkedin|portfolio|website|resume|cv|tech stack|skills|college|university|degree|address|location|city|nationality|pronouns)\b(?:\s*\([^)]*\))?(?:\s+for\s+\w+)?(?:\s+[^\s:]+)?\s*(?:\bis\b|\bare\b|:|=)|^(?:the user is|user is|student at|studies at|lives in|based in|born|works at|messages people)\b"#

    static func isProfile(_ fact: String) -> Bool { fact.range(of: corePattern, options: .regularExpression) != nil }

    /// Only tiny memories go along whole (~500 tokens); growing memory is retrieved instead of taxing every turn.
    static let sendAllBudget = 2_000

    // MARK: Retrieval

    /// The facts worth sending for this request: the profile always, know-how for the app or site in use (or named),
    /// and the best matches among the rest. Everything while memory is small.
    static func relevant(to context: String, app: String? = nil, host: String? = nil, limit: Int = 24) -> (facts: [String], omitted: Int) {
        let r = relevantExplained(to: context, app: app, host: host, limit: limit)
        return (r.facts, r.omitted)
    }

    /// `relevant`, also naming the facts that came in only through a link to a matching fact (for `clinqy memory`).
    static func relevantExplained(to context: String, app: String? = nil, host: String? = nil, limit: Int = 24)
        -> (facts: [String], omitted: Int, linked: Set<String>) {
        let l = current
        let all = l.entries
        let profile = all.indices.filter { isProfile(all[$0].text) }
        let rest = all.indices.filter { !isProfile(all[$0].text) }
        if all.map(\.line).joined().count <= sendAllBudget { return ((profile + rest).map { all[$0].text }, 0, []) }
        var here = rest.filter { i in all[i].scope.map { $0.matches(app: app, host: host) || $0.mentioned(in: context) } ?? false }
        let others = rest.filter { !here.contains($0) }
        let room = max(0, limit - profile.count - here.count)
        let (merged, viaLinks) = withLinks(rank(context, among: others, in: l), among: others, in: l)
        var ranked = Array(merged.prefix(room).map(\.0))
        // The best matches may name a place ("Uses Find My on Mac" for "where's mom"): bring that place's notes too
        // ("open it as 'FindMy'"), since that's where the task is about to go.
        let leads = ranked.prefix(5).map { all[$0].text }.joined(separator: "\n")
        let places = Set(rest.compactMap { all[$0].scope }.filter { $0.mentioned(in: leads) })
        let notes = others.filter { i in all[i].scope.map(places.contains) ?? false }.prefix(6)
        here += notes
        ranked.removeAll { notes.contains($0) }
        let chosen = profile + here + ranked
        let linked = Set(ranked.filter(viaLinks.contains).map { all[$0].text })
        return (chosen.map { all[$0].text }, all.count - chosen.count, linked)
    }

    /// Spreads from the best matches along the memory graph: a fact that shares a person, place, account or detail
    /// with a strong match ("Mom's chat is 'Mom ❤️'" → "Mom is in Pune") scores a damped share of that match, in the
    /// same units, so the two lists merge into one ranking. Returns it, plus the facts that only links brought in.
    private static func withLinks(_ scored: [(Int, Double)], among: [Int], in l: Loaded) -> ([(Int, Double)], Set<Int>) {
        guard let strongest = scored.first?.1 else { return (scored, []) }
        var best = Dictionary(scored, uniquingKeysWith: max)
        var via: Set<Int> = []
        let allowed = Set(among)
        for (j, a) in (l.graph?.spread(from: Array(scored.prefix(6)), damping: 0.8) ?? [:]) where allowed.contains(j) && a >= strongest * 0.3 {
            if best[j] == nil { via.insert(j) }
            best[j] = max(best[j] ?? 0, a)
        }
        return (best.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }, via)
    }

    /// Facts that answer what's on screen right now, matched label by label: each field's question or placeholder,
    /// and the page's title and headings. Brought to the agent with the page, so it doesn't spend a model turn on a
    /// recall (in the logs most recalls were a turn of their own, ~2–3 s each, for a search that takes milliseconds).
    /// Strict, since it rides along every new page: a fact must cover at least half a label's words, including one
    /// that few facts share (so "Email" alone doesn't drag in every fact naming an email).
    static func forPage(labels: [String], excluding shown: Set<String>, app: String? = nil, host: String? = nil, limit: Int = 6) -> [String] {
        let l = current
        // Know-how kept for another site or app doesn't apply here (Workday's phone rule on a Lever form).
        let candidates = l.entries.indices.filter { i in
            let f = l.entries[i]
            return !shown.contains(f.text) && !isProfile(f.text) && (f.scope.map { $0.matches(app: app, host: host) } ?? true)
        }
        guard !candidates.isEmpty else { return [] }
        let distinctive = max(3, l.entries.count / 25)
        var best: [Int: Double] = [:]
        for label in Set(labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where label.count >= 3 && label.count <= 200 {
            let terms = Set(words(label).map(stem)).subtracting(formWords)
            guard !terms.isEmpty else { continue }
            let hits = l.index.scores(Dictionary(uniqueKeysWithValues: terms.map { ($0, 1.0) }), among: candidates)
            guard let (i, score) = hits.max(by: { $0.value < $1.value }) else { continue }
            // A word the fact has exactly counts 1; one it has only by prefix ("education" ~ "educational") counts ½.
            let have = Set(l.index.tf[i].keys)
            let exact = terms.filter(have.contains)
            let near = terms.subtracting(exact).filter { t in have.contains { min($0.count, t.count) >= 4 && ($0.hasPrefix(t) || t.hasPrefix($0)) } }
            let matched = Double(exact.count) + 0.5 * Double(near.count)
            let coverage = matched / Double(terms.count)
            let rare = exact.contains { (l.index.df[$0] ?? 0) <= distinctive }
            guard coverage >= 0.5, rare, matched >= Double(min(2, terms.count)) else { continue }
            best[i] = max(best[i] ?? 0, score * coverage)
        }
        return best.sorted { $0.value > $1.value }.prefix(limit).map { l.entries[$0.key].text }
    }

    /// Words every form uses, which say nothing about which fact a field wants (stemmed).
    private static let formWords: Set<String> = ["detail", "info", "information", "enter", "select", "choose", "required",
        "optional", "submit", "next", "back", "continue", "field", "value", "here", "click", "button", "page", "form",
        "question", "answer", "option", "yes", "type", "save", "cancel", "search", "new", "add", "edit", "more", "limited",
        "please", "provide", "mention", "specify", "below", "above", "list", "upload", "attach", "file",
        // The profile (always sent) covers these on their own.
        "name", "full", "first", "last", "email", "mail", "phone", "mobile", "number", "subject", "message"]

    /// Searches everything remembered (for the agent's recall action), best matches first.
    static func search(_ query: String) -> [String] {
        let l = current
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return l.entries.map(\.text) }
        // A recall that names a site or app also gets everything kept for it.
        let named = l.entries.indices.filter { l.entries[$0].scope?.mentioned(in: q) == true }
        let all = Array(l.entries.indices)
        let ranked = withLinks(rank(q, among: all, in: l), among: all, in: l).0.map(\.0).filter { !named.contains($0) }
        return (named + ranked).prefix(25).map { l.entries[$0].text }
    }

    private static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "into", "open", "please", "can",
                                            "you", "your", "his", "her", "use", "get", "are", "was", "will", "what", "whats",
                                            "who", "how", "when", "where", "which", "there", "here", "then", "them", "they",
                                            "some", "something", "also", "just", "now", "all", "any", "make", "want", "need",
                                            "tell", "show", "give", "let", "its", "it's", "him", "has", "have", "had", "does",
                                            "did", "not", "but", "out", "one", "about", "these", "those", "user", "uses", "amrit"]

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 && !stop.contains($0) }
    }

    /// A light stemmer: ordering/ordered/orders → order, applies/applied → apply.
    static func stem(_ w: String) -> String {
        if w.count >= 5, w.hasSuffix("ies") || w.hasSuffix("ied") { return String(w.dropLast(3)) + "y" }
        for suffix in ["ing", "ed", "es", "s"] where w.count - suffix.count >= 4 && w.hasSuffix(suffix) {
            if suffix == "es", !(w.hasSuffix("ses") || w.hasSuffix("xes") || w.hasSuffix("ches") || w.hasSuffix("shes")) { continue }
            return String(w.dropLast(suffix.count))
        }
        // relocate ~ relocating/relocated (both → relocat).
        if w.count >= 6, w.hasSuffix("e") { return String(w.dropLast()) }
        return w
    }

    /// A BM25 index over the facts' stemmed words.
    struct Index {
        let tf: [[String: Int]]
        let len: [Int]
        let df: [String: Int]
        let avg: Double
        let vocab: [String]

        init(_ docs: [String]) {
            tf = docs.map { Dictionary(Memory.words($0).map { (Memory.stem($0), 1) }, uniquingKeysWith: +) }
            len = tf.map { $0.values.reduce(0, +) }
            var df: [String: Int] = [:]
            for doc in tf { for term in doc.keys { df[term, default: 0] += 1 } }
            self.df = df
            avg = Double(max(1, len.reduce(0, +))) / Double(max(1, tf.count))
            vocab = Array(df.keys)
        }

        /// Scores every doc in `among` for weighted query terms. A query term also matches index words it's a prefix
        /// of, or that are a prefix of it, at 4+ letters ("appl" ~ "application"), at a lower weight.
        func scores(_ want: [String: Double], among: [Int]) -> [Int: Double] {
            let n = Double(tf.count), k1 = 1.2, b = 0.75
            var expanded: [String: Double] = [:]
            for (q, w) in want {
                for t in vocab {
                    let weight: Double
                    if t == q { weight = w }
                    else if min(t.count, q.count) >= 4, t.hasPrefix(q) || q.hasPrefix(t) { weight = w * 0.7 }
                    else { continue }
                    expanded[t] = max(expanded[t] ?? 0, weight)
                }
            }
            var out: [Int: Double] = [:]
            for i in among {
                var s = 0.0
                for (t, w) in expanded {
                    guard let f = tf[i][t] else { continue }
                    let docFreq = Double(df[t] ?? 0)
                    let idf = log(1.0 + (n - docFreq + 0.5) / (docFreq + 0.5))
                    let fd = Double(f)
                    let num = fd * (k1 + 1.0)
                    let den = fd + k1 * (1.0 - b + b * Double(len[i]) / avg)
                    s += w * idf * num / den
                }
                if s > 0 { out[i] = s }
            }
            return out
        }
    }

    /// The query's words with their weights: its own (1), close words from the word vectors (0.5).
    static func expand(_ query: String) -> [String: Double] {
        var want: [String: Double] = [:]
        for w in words(query) {
            want[stem(w)] = 1
            for n in Embedder.shared.related(w) where n.count >= 3 && !stop.contains(n) {
                let s = stem(n.lowercased())
                want[s] = max(want[s] ?? 0, 0.5)
            }
        }
        return want
    }

    /// Facts in `among` ranked for the query, best first, only those with real signal: a word match, or a meaning
    /// match far above the rest (the on-device sentence vectors are coarse, so meaning alone must stand out) (a z-score, so it doesn't depend on how the vectors happen to be scaled).
    private static func rank(_ query: String, among: [Int], in l: Loaded) -> [(Int, Double)] {
        guard !among.isEmpty else { return [] }
        var want = expand(query)
        var lexical = l.index.scores(want, among: among)
        // Pseudo-relevance feedback: words the two best hits share with few other facts ("eat" → the Swiggy fact →
        // swiggy) widen the query once, so the user's own vocabulary links related facts.
        let top = lexical.sorted { $0.value > $1.value }.prefix(2).map(\.key)
        var added = false
        for i in top {
            for t in l.index.tf[i].keys where want[t] == nil && (l.index.df[t] ?? 0) <= 3 {
                want[t] = 0.3
                added = true
            }
        }
        if added { lexical = l.index.scores(want, among: among) }
        let best = lexical.values.max() ?? 0

        var z: [Int: Double] = [:]
        if let qv = Embedder.shared.vector(query) {
            let sims = among.compactMap { i in Embedder.shared.cached(l.entries[i].text).map { (i, Double(Embedder.cosine(qv, $0))) } }
            if sims.count >= 8 {
                let mean = sims.map(\.1).reduce(0, +) / Double(sims.count)
                let sd = (sims.map { ($0.1 - mean) * ($0.1 - mean) }.reduce(0, +) / Double(sims.count)).squareRoot()
                if sd > 1e-6 { for (i, s) in sims { z[i] = (s - mean) / sd } }
            }
        }
        let usage = usageBoosts(among.map { l.entries[$0].text })
        // The retrieval model's vectors find the fact a request *means* ("something to eat" → Swiggy); the system's
        // only roughly, so then meaning alone must stand far out.
        let (alone, weight) = Embedder.shared.usesModel ? (2.2, 0.5) : (3.0, 0.35)
        let scored = among.compactMap { i -> (Int, Double)? in
            let lex = best > 0 ? (lexical[i] ?? 0) / best : 0
            let zi = z[i] ?? 0
            guard lex > 0 || zi >= alone else { return nil }
            return (i, lex + weight * max(0, zi - 1) + (usage[l.entries[i].text] ?? 0))
        }.sorted { $0.1 > $1.1 }
        // A long tail of weak matches (one shared common word) is noise: keep what's within reach of the best.
        let strongest = scored.first?.1 ?? 0
        return scored.filter { $0.1 >= strongest * 0.3 }
    }

    // MARK: Writing

    /// Saves a fact (moved to the end if it was already there, so it reads as the newest).
    /// Returns whether the fact is now stored (false when it was empty or the memory file couldn't be written).
    @discardableResult
    static func add(_ fact: String, scope: Scope? = nil) -> Bool {
        let text = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var all = entries.filter { $0.text != text }
        let kept = scope ?? entries.first { $0.text == text && $0.tagged }?.scope
        all.append(Fact(text: text, scope: kept, tagged: kept != nil))
        // Never drop facts to make room (a cap here once silently deleted the user's email, CGPA and more).
        guard commit(all) else { return false }
        touch(text, added: true)
        return true
    }

    /// Rewrites one fact in place (keeping its scope tag), e.g. a newer phone number.
    @discardableResult
    static func update(_ old: String, to new: String) -> Bool {
        let text = new.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = entries
        guard !text.isEmpty, let i = all.firstIndex(where: { $0.text == old }) else { return false }
        let fact = Fact(text: text, scope: all[i].tagged ? all[i].scope : nil, tagged: all[i].tagged)
        // The new wording may already be there as another line: keep just this one.
        let revised = all.indices.compactMap { j -> Fact? in j == i ? fact : (all[j].text == text ? nil : all[j]) }
        guard commit(revised) else { return false }
        touch(text, added: true)
        record(old: old, new: text, why: "updated")
        return true
    }

    @discardableResult
    static func remove(_ fact: String, why: String? = nil) -> Bool {
        let all = entries
        guard all.contains(where: { $0.text == fact }) else { return false }
        guard commit(all.filter { $0.text != fact }) else { return false }
        record(old: fact, new: nil, why: why ?? "removed")
        return true
    }

    // MARK: Versions

    /// What memory used to say: every update and removal, oldest first, in memory.history.jsonl. A newer phone
    /// number replaces the old line, but "what was my old number" still has an answer, and a wrong removal can be
    /// put back.
    struct Change: Codable {
        let at: Date
        let old: String
        let new: String?
        let why: String
    }

    private static var historyURL: URL { directory.appendingPathComponent("memory.history.jsonl") }

    static func record(old: String, new: String?, why: String) {
        if let batch { batch.changes.append(Change(at: Date(), old: old, new: new, why: why)); return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Change(at: Date(), old: old, new: new, why: why)) else { return }
        let line = data + Data("\n".utf8)
        try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: historyURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: historyURL, options: .atomic)
        }
    }

    static var history: [Change] {
        guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder.iso8601.decode(Change.self, from: Data($0.utf8)) }
    }

    /// The earlier wordings of a fact, newest first (following update after update back).
    static func earlier(_ fact: String, in changes: [Change]? = nil, max: Int = 3) -> [String] {
        let changes = changes ?? history
        var out: [String] = [], current = fact
        while out.count < max, let c = changes.last(where: { $0.new == current && !out.contains($0.old) && $0.old != fact }) {
            out.append(c.old)
            current = c.old
        }
        return out
    }

    /// Lines that were dropped or replaced and match the query (for a recall about how things used to be).
    static func searchHistory(_ query: String, limit: Int = 5) -> [Change] {
        let want = Set(words(query).map(stem))
        guard !want.isEmpty else { return [] }
        return history.reversed().filter { c in
            let mine = Set(words(c.old).map(stem))
            return Double(mine.intersection(want).count) >= max(1, Double(want.count) * 0.5)
        }.prefix(limit).map { $0 }
    }

    /// Replaces every line (memory tidy-up), keeping the previous file as memory.backup-<date>.md (last 3 kept).
    @discardableResult
    static func replaceAll(with lines: [String], backup: Bool) -> Bool {
        let fm = FileManager.default
        if backup, fm.fileExists(atPath: url.path) {
            let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
            let copy = url.deletingLastPathComponent().appendingPathComponent("memory.backup-\(stamp).md")
            do { try fm.copyItem(at: url, to: copy) } catch { return false }   // no backup, no rewrite
            let dir = url.deletingLastPathComponent()
            let old = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("memory.backup-") }.sorted()
            for name in old.dropLast(3) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        }
        return write(lines)
    }

    /// Writes the memory file; false when it failed (nothing is then claimed as saved). A file that exists but can't be
    /// read is set aside first rather than overwritten.
    private static func write(_ lines: [String]) -> Bool {
        defer {
            lock.lock()
            loaded = nil
            lock.unlock()
        }
        guard StoreFile.clearForWrite(url, decodes: { String(data: $0, encoding: .utf8) != nil }) else { return false }
        return StoreFile.write(Data((lines.map { "- \($0)" }.joined(separator: "\n") + "\n").utf8), to: url) == nil
    }

    // MARK: Duplicates

    /// An existing fact that says nearly the same thing (same words, or the same meaning), if any.
    static func nearDuplicate(of fact: String) -> String? {
        let mine = Set(words(fact).map(stem))
        guard !mine.isEmpty else { return nil }
        let qv = Embedder.shared.vector(fact)
        for other in facts {
            let theirs = Set(words(other).map(stem))
            let jaccard = Double(mine.intersection(theirs).count) / Double(max(1, mine.union(theirs).count))
            if jaccard >= 0.8 { return other }
            if let qv, let v = Embedder.shared.cached(other), Embedder.cosine(qv, v) >= 0.95, jaccard >= 0.5 { return other }
        }
        return nil
    }

    /// Emails, links, long numbers and quoted names in a fact: the details that must never silently disappear,
    /// and the ones whose use shows a fact was put to work.
    static func details(_ text: String, quoted: Bool = false) -> Set<String> {
        var pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}/[^\s,;)]+|\+?\d[\d ]{3,}\d"#
        if quoted { pattern += #"|(?<=['“"])[^'”"]{3,40}(?=['”"])"# }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return Set(re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased().replacingOccurrences(of: " ", with: "")
        })
    }

    // MARK: Usage

    private struct Meta: Codable {
        var added: Date?
        var used: Date?
        var uses = 0
    }
    nonisolated(unsafe) private static var meta: [String: Meta]?
    private static let metaLock = NSLock()

    private static func withMeta<T>(_ body: (inout [String: Meta]) -> T) -> T {
        metaLock.lock()
        defer { metaLock.unlock() }
        if meta == nil {
            switch StoreFile.load(metaURL, decode: { try? JSONDecoder.iso8601.decode([String: Meta].self, from: $0) }) {
            case .value(let m): meta = m
            case .unreadable: StoreFile.quarantine(metaURL); meta = [:]
            case .absent: meta = [:]
            }
        }
        return body(&meta!)
    }

    private static func saveMeta() {
        if let batch { batch.metaDirty = true; return }
        let data = withMeta { m -> Data? in
            // Only facts still in memory.
            let live = Set(facts.map(Embedder.key))
            m = m.filter { live.contains($0.key) }
            return try? JSONEncoder.iso8601.encode(m)
        }
        if let data { StoreFile.write(data, to: metaURL) }
    }

    private static func touch(_ fact: String, added: Bool) {
        withMeta { m in
            let k = Embedder.key(fact)
            var e = m[k] ?? Meta()
            if added, e.added == nil { e.added = Date() }
            m[k] = e
        }
        saveMeta()
    }

    /// Books facts that a run put to work: they rank higher next time.
    static func noteUsed(_ used: [String]) {
        guard !used.isEmpty else { return }
        withMeta { m in
            for fact in used {
                let k = Embedder.key(fact)
                var e = m[k] ?? Meta()
                e.uses += 1
                e.used = Date()
                m[k] = e
            }
        }
        saveMeta()
    }

    /// Small ranking bonuses: facts used often, used lately, or just learned.
    private static func usageBoosts(_ texts: [String]) -> [String: Double] {
        let now = Date()
        return withMeta { m in
            var out: [String: Double] = [:]
            for t in texts {
                guard let e = m[Embedder.key(t)] else { continue }
                var b = 0.1 * log2(1 + Double(e.uses))
                if let used = e.used, now.timeIntervalSince(used) < 14 * 86_400 { b += 0.1 }
                if let added = e.added, now.timeIntervalSince(added) < 7 * 86_400 { b += 0.05 }
                if b > 0 { out[t] = b }
            }
            return out
        }
    }

    /// The facts among `shown` that this run's output used: one of their details (an email, a number, a quoted name)
    /// shows up in what was typed or answered, or the run worked where a scoped fact applies.
    static func used(among shown: Set<String>, output: String, apps: Set<String>, hosts: Set<String>) -> [String] {
        let out = output.lowercased().replacingOccurrences(of: " ", with: "")
        let byText = Dictionary(entries.map { ($0.text, $0) }, uniquingKeysWith: { a, _ in a })
        return shown.filter { fact in
            if let scope = byText[fact]?.scope,
               apps.contains(where: { scope.matches(app: $0, host: nil) }) || hosts.contains(where: { scope.matches(app: nil, host: $0) }) {
                return true
            }
            return details(fact, quoted: true).contains { out.contains($0) }
        }.sorted()
    }
}
