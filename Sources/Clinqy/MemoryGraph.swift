import Foundation
import NaturalLanguage

/// Links between remembered facts, the way a knowledge graph would: two facts are connected when they're about the
/// same thing — a person ("mom"), a named contact or place (on-device name tagging), a site or app, or an exact
/// detail (an email, a link, a number, a quoted chat name). Retrieval spreads from the facts that match a request to
/// the ones linked to them, so "message mom" brings "Mom's WhatsApp chat is 'Mom ❤️'" *and* "Mom is in Pune" even
/// though the second shares no word with the request beyond "mom", and "where's mom" reaches the Find My notes.
///
/// Built from the facts alone (nothing extra stored), rebuilt whenever memory.md changes.
struct MemoryGraph {
    /// Each fact's entities, e.g. ["who:mom", "app:WhatsApp", "detail:'mom ❤️'"].
    let entities: [Set<String>]
    /// Entity → the facts that name it.
    let postings: [String: [Int]]
    /// Each fact's neighbours with link strength (0…1], strongest first.
    let links: [[(Int, Double)]]

    init(_ facts: [Memory.Fact]) {
        let entities = facts.map { MemoryGraph.entities(of: $0) }
        var postings: [String: [Int]] = [:]
        for (i, set) in entities.enumerated() { for e in set { postings[e, default: []].append(i) } }
        // An entity named by a big share of memory (the user's browser, their own name) says nothing about which
        // facts belong together: it isn't a link.
        let hub = max(5, facts.count / 12)
        var weight: [Int: [Int: Double]] = [:]
        for (e, docs) in postings where docs.count >= 2 && docs.count <= hub {
            let w = MemoryGraph.strength(of: e) / log2(1 + Double(docs.count))
            let bounded = docs.suffix(48)
            for a in bounded { for b in bounded where a != b { weight[a, default: [:]][b, default: 0] += w } }
        }
        self.entities = entities
        self.postings = postings
        links = facts.indices.map { i in
            (weight[i] ?? [:]).map { ($0.key, min(1, $0.value)) }.sorted { $0.1 > $1.1 }
        }
    }

    /// How much sharing one entity of this kind says two facts belong together.
    private static func strength(of entity: String) -> Double {
        switch entity.prefix(while: { $0 != ":" }) {
        case "detail", "who": return 1
        case "name": return 0.8
        default: return 0.6   // site, app: a place is broader than a person or a detail
        }
    }

    /// Activation reaching other facts from scored seeds, one hop: seed score × link strength × damping, keeping the
    /// best path to each fact. Seeds themselves aren't returned.
    func spread(from seeds: [(Int, Double)], damping: Double) -> [Int: Double] {
        let seedSet = Set(seeds.map(\.0))
        var out: [Int: Double] = [:]
        for (i, s) in seeds where i < links.count {
            for (j, w) in links[i].prefix(8) where !seedSet.contains(j) {
                out[j] = max(out[j] ?? 0, s * w * damping)
            }
        }
        return out
    }

    // MARK: Entities

    /// Family and close people, each folded to one name, so "his mother" and "Mom" are the same person.
    private static let people: [String: String] = [
        "mom": "mom", "mother": "mom", "mum": "mom", "mummy": "mom", "mumma": "mom", "maa": "mom",
        "dad": "dad", "father": "dad", "papa": "dad", "pappa": "dad",
        "sister": "sister", "sis": "sister", "didi": "sister", "brother": "brother", "bro": "brother", "bhai": "brother",
        "wife": "wife", "husband": "husband", "girlfriend": "girlfriend", "gf": "girlfriend", "boyfriend": "boyfriend",
        "grandma": "grandma", "grandmother": "grandma", "nani": "grandma", "dadi": "grandma",
        "grandpa": "grandpa", "grandfather": "grandpa", "nana": "grandpa", "dada": "grandpa",
        "aunt": "aunt", "uncle": "uncle", "cousin": "cousin", "boss": "boss", "manager": "manager",
        "roommate": "roommate", "flatmate": "roommate", "mentor": "mentor", "professor": "professor",
    ]

    private static let vocabulary = NLEmbedding.wordEmbedding(for: .english)

    /// "Phone", "Notes", "Arc": an English word as well as an app name.
    private static func isPlainWord(_ name: String) -> Bool {
        !name.contains(" ") && vocabulary?.contains(name.lowercased()) == true
    }

    nonisolated(unsafe) private static var cache: [String: Set<String>] = [:]
    private static let lock = NSLock()

    static func entities(of fact: Memory.Fact) -> Set<String> {
        let key = fact.line
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let found = extract(fact)
        lock.lock()
        if cache.count > 4000 { cache.removeAll() }
        cache[key] = found
        lock.unlock()
        return found
    }

    private static func extract(_ fact: Memory.Fact) -> Set<String> {
        let text = fact.text
        var out: Set<String> = []
        if let scope = fact.scope { out.insert(scope.kind + ":" + scope.name.lowercased()) }
        // Sites: written-out hosts, and web products by name.
        if let re = Memory.hostRegex {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { out.insert("site:" + Memory.bareHost(String(text[r]))) }
            }
        }
        for product in Memory.webProducts where Memory.hasWord(product.name, in: text, caseSensitive: true) {
            out.insert("site:" + product.host)
        }
        // Apps named as such (capitalised, whole word). An app whose name is also a plain word ("Phone", "Home",
        // "Mail") counts only where it reads as the app ("in Mail", "the Phone app").
        for (app, spaced) in Memory.installedApps where app.count >= 3 && (text.contains(app) || text.contains(spaced)) {
            let names = Set([app, spaced])
            guard names.contains(where: { Memory.hasWord($0, in: text, caseSensitive: true) }) else { continue }
            if isPlainWord(app) {
                let name = "(?:" + names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")"
                let place = "\\b(?:in|on|via|open|opens|opened|using|inside|from) (?:the )?" + name + "(?![\\p{L}\\p{N}])|(?<![\\p{L}\\p{N}])" + name + " (?:app|Mac|desktop)\\b"
                guard text.range(of: place, options: .regularExpression) != nil else { continue }
            }
            out.insert("app:" + app.lowercased())
        }
        // Exact details; a quoted bit must hold a real word (not the " or " between two quoted options).
        for d in Memory.details(text, quoted: true) where d.contains(where: \.isNumber) || d.contains("@") || d.contains(".")
            || Memory.words(d).contains(where: { $0.count >= 4 }) {
            out.insert("detail:" + d)
        }
        for w in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            if let who = people[String(w)] { out.insert("who:" + who) }
        }
        // Named people, places and organisations ("Priya", "Pune", "Swiggy"), tagged on-device; not the sites and
        // apps already found ("LinkedIn", "Arc"), nor umbrella companies whose name says little ("Google").
        let own = Set(NSFullUserName().lowercased().split(separator: " ").map(String.init))
            .union(["google", "apple", "microsoft", "amazon"])
            .union(out.compactMap { e -> String? in
                if e.hasPrefix("app:") { return String(e.dropFirst(4)) }
                guard e.hasPrefix("site:") else { return nil }
                let parts = e.dropFirst(5).split(separator: ".")
                return parts.count >= 2 ? String(parts[parts.count - 2]) : nil
            })
            .union(Memory.webProducts.map { $0.name.lowercased() })
            .union(Memory.installedApps.map { $0.name.lowercased() })
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                let name = text[range].lowercased()
                if name.count >= 3, !own.contains(name), !name.split(separator: " ").allSatisfy({ own.contains(String($0)) }) {
                    out.insert("name:" + name)
                }
            }
            return true
        }
        return out
    }
}
