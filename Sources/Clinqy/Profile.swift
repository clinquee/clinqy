import AppKit

/// The user's job-application profile: the answers every application form asks for (contact details, CTC, notice
/// period, experience, links, resumes…) plus free-form question → answer pairs remembered from earlier forms.
/// Stored in Application Support as profile.json; the menu's "Job Profile…" opens it in the default editor.
/// Seeded once from memory and the application tracker, so it starts out useful.
enum Profile {
    struct QA: Codable, Equatable {
        var question: String
        var answer: String
    }

    struct Data: Codable, Equatable {
        var name = ""
        var email = ""
        var phone = ""
        var location = ""
        var currentCTC = ""
        var expectedCTC = ""
        var noticePeriod = ""
        var experienceYears: Int?
        var experienceMonths: Int?
        var linkedin = ""
        var github = ""
        var portfolio = ""
        var resumePaths: [String] = []
        var workAuthorization = ""
        var willingToRelocate = ""
        var qa: [QA] = []

        init() {}

        // Every key optional, so a hand-edited file with fields removed still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
            name = s(.name); email = s(.email); phone = s(.phone); location = s(.location)
            currentCTC = s(.currentCTC); expectedCTC = s(.expectedCTC); noticePeriod = s(.noticePeriod)
            experienceYears = (try? c.decodeIfPresent(Int.self, forKey: .experienceYears)) ?? nil
            experienceMonths = (try? c.decodeIfPresent(Int.self, forKey: .experienceMonths)) ?? nil
            linkedin = s(.linkedin); github = s(.github); portfolio = s(.portfolio)
            resumePaths = (try? c.decodeIfPresent([String].self, forKey: .resumePaths)) ?? []
            workAuthorization = s(.workAuthorization); willingToRelocate = s(.willingToRelocate)
            qa = (try? c.decodeIfPresent([QA].self, forKey: .qa)) ?? []
        }
    }

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clinqy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profile.json")
    }()

    /// The saved profile (seeded from memory and the tracker the first time).
    static var current: Data {
        switch StoreFile.load(url, decode: { try? JSONDecoder().decode(Data.self, from: $0) }) {
        case .value(let saved):
            return saved
        case .unreadable:
            // Never replace a profile the user can't see loading with a fresh seed: set it aside first. If that fails the
            // seed is used for this run only and nothing is written over the original.
            guard StoreFile.quarantine(url) != nil else { return seed() }
        case .absent:
            break
        }
        let seeded = seed()
        save(seeded)
        return seeded
    }

    /// Saves the profile; false when it could not be written (the caller must not say it was saved).
    @discardableResult
    static func save(_ profile: Data) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(profile),
              StoreFile.clearForWrite(url, decodes: { (try? JSONDecoder().decode(Data.self, from: $0)) != nil }) else { return false }
        return StoreFile.write(data, to: url) == nil
    }

    /// Menu: Job Profile… (creates it if needed, then opens the JSON in the default editor).
    static func open() {
        _ = current
        NSWorkspace.shared.open(url)
    }

    // MARK: - Answers

    private enum Field: CaseIterable {
        case expectedCTC, currentCTC, notice, experience, linkedin, github, portfolio, email, phone,
             relocate, authorization, location, resume, firstName, lastName, name
    }

    /// Which saved field a form question asks for. Order matters: "expected CTC" before "CTC", "LinkedIn URL"
    /// before "URL", "first name" before "name".
    private static func field(for question: String) -> Field? {
        let q = question.lowercased()
        func has(_ pattern: String) -> Bool { q.range(of: pattern, options: .regularExpression) != nil }
        if has(#"\b(expected|desired|expectation)\b.*\b(ctc|salary|stipend|compensation|pay|package)\b|\b(ctc|salary|stipend|compensation)\b.*\bexpect"#) { return .expectedCTC }
        if has(#"\b(current|present|last drawn|existing)\b.*\b(ctc|salary|stipend|compensation|package)\b|^\s*ctc\b"#) { return .currentCTC }
        if has(#"\bnotice\b|\b(join|start)(ing)?\b.*\b(date|when|soon|available|availability)\b|\bhow soon\b"#) { return .notice }
        // "Years of experience with React" is about one skill, not total experience.
        if has(#"\bexperience\b"#), has(#"\b(years?|months?|how (much|long)|total|overall|work|professional|industry)\b"#),
           !has(#"\b(with|in|using|of working (with|on))\s+(?!total|overall|the industry|industry|software|tech|work|years?|months?|yrs)[a-z0-9.#+]"#) || has(#"\b(total|overall|work|professional)\s+experience"#) {
            return .experience
        }
        if has(#"linked\s?in"#) { return .linkedin }
        if has(#"git\s?hub"#) { return .github }
        if has(#"\b(portfolio|personal (website|site)|website|blog)\b"#) { return .portfolio }
        if has(#"e-?mail"#) { return .email }
        if has(#"\b(phone|mobile|contact number|whatsapp number|cell)\b"#) { return .phone }
        if has(#"relocat"#) { return .relocate }
        // Sponsorship/visa questions want a yes/no the authorization text doesn't give: left to Q&A.
        if has(#"\b(authori[sz]ed|authori[sz]ation|legally (eligible|allowed))\b"#), !has(#"sponsor|visa"#) { return .authorization }
        if has(#"\b(current (city|location)|location|city|where (are you|do you) (based|live)|based in|residing)\b"#) { return .location }
        if has(#"\b(resume|cv|curriculum vitae)\b"#) { return .resume }
        if has(#"\bfirst name\b|\bgiven name\b"#) { return .firstName }
        if has(#"\b(last name|surname|family name)\b"#) { return .lastName }
        if has(#"\b(full name|your name|^name|name\s*\*?$)"#) { return .name }
        return nil
    }

    private static func value(of field: Field, in p: Data, question: String) -> String? {
        func nonEmpty(_ s: String) -> String? { s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s }
        let q = question.lowercased()
        switch field {
        case .expectedCTC: return nonEmpty(p.expectedCTC)
        case .currentCTC: return nonEmpty(p.currentCTC)
        case .notice: return nonEmpty(p.noticePeriod)
        case .experience:
            guard p.experienceYears != nil || p.experienceMonths != nil else { return nil }
            let total = (p.experienceYears ?? 0) * 12 + (p.experienceMonths ?? 0)
            if q.range(of: #"\bin months\b|\(months\)|number of months|how many months"#, options: .regularExpression) != nil { return "\(total)" }
            if q.range(of: #"\bin years\b|\(years\)|number of years|how many years|years of"#, options: .regularExpression) != nil {
                let years = Double(total) / 12
                return years == years.rounded() ? "\(Int(years))" : String(format: "%.1f", years)
            }
            let y = total / 12, m = total % 12
            return [y > 0 ? "\(y) year\(y == 1 ? "" : "s")" : nil, m > 0 || y == 0 ? "\(m) month\(m == 1 ? "" : "s")" : nil]
                .compactMap { $0 }.joined(separator: " ")
        case .linkedin: return nonEmpty(p.linkedin)
        case .github: return nonEmpty(p.github)
        case .portfolio: return nonEmpty(p.portfolio)
        case .email: return nonEmpty(p.email)
        case .phone: return nonEmpty(p.phone)
        case .relocate: return nonEmpty(p.willingToRelocate)
        case .authorization: return nonEmpty(p.workAuthorization)
        case .location: return nonEmpty(p.location)
        case .resume: return p.resumePaths.first
        case .name: return nonEmpty(p.name)
        case .firstName: return nonEmpty(p.name).map { String($0.split(separator: " ").first ?? "") }
        case .lastName:
            let parts = p.name.split(separator: " ")
            return parts.count > 1 ? parts.dropFirst().joined(separator: " ") : nil
        }
    }

    private static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "you", "your", "are", "have", "has",
                                            "what", "which", "please", "any", "our", "from", "into", "will", "would", "can",
                                            "did", "does", "do", "how", "why", "about", "enter", "provide", "mention", "a", "an",
                                            "of", "to", "in", "is", "if", "on", "or", "be", "we", "us", "it"]

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 && !stop.contains($0) })
    }

    /// How alike two questions are (0…1): shared meaningful words over all of them, with loose word endings.
    private static func similarity(_ a: String, _ b: String) -> Double {
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        let shared = wa.filter { x in wb.contains { y in x == y || (min(x.count, y.count) >= 4 && (x.hasPrefix(y) || y.hasPrefix(x))) } }.count
        return Double(shared) / Double(wa.union(wb).count)
    }

    private static let negations: Set<String> = ["not", "no", "never", "without", "non", "cannot", "cant", "dont", "wont", "isnt", "arent", "neither", "nor", "unwilling", "unable", "unauthorized", "unauthorised", "ineligible"]
    private static let places: Set<String> = [
        "us", "usa", "uk", "eu", "uae", "india", "canada", "australia", "germany", "france", "singapore", "china", "japan",
        "europe", "asia", "america", "american", "british", "indian", "canadian", "european", "ireland", "netherlands",
        "california", "texas", "york", "london", "remote", "onsite", "hybrid", "visa", "sponsorship", "citizen", "citizenship",
    ]

    /// Whether a saved answer to `saved` can stand in for `question` without being a different question: the
    /// questions must agree on negation, numbers and places (jurisdictions), or the answer could be the opposite fact.
    private static func sameMeaning(_ question: String, _ saved: String) -> Bool {
        func tokens(_ s: String) -> [String] {
            s.lowercased().replacingOccurrences(of: "n't", with: "nt").replacingOccurrences(of: "'", with: "")
                .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let a = tokens(question), b = tokens(saved)
        if a == b { return true }
        let sa = Set(a), sb = Set(b)
        let differing = sa.symmetricDifference(sb)
        if differing.contains(where: { negations.contains($0) || places.contains($0) || $0.contains(where: \.isNumber) }) { return false }
        // Capitalised words (names of countries, companies, cities) that only one side has.
        func proper(_ s: String) -> Set<String> {
            Set(s.split { !$0.isLetter && !$0.isNumber }.dropFirst().filter { $0.first?.isUppercase == true && $0.count > 1 }.map { $0.lowercased() })
        }
        return proper(question).symmetricDifference(proper(saved)).isEmpty
    }

    /// A saved yes/no style field answers only the positive form of its question, and an authorization answer only for
    /// the jurisdiction it was written for ("Authorized to work in India" says nothing about the US).
    private static func fieldAnswerFits(_ f: Field, question: String, value: String) -> Bool {
        guard f == .relocate || f == .authorization else { return true }
        let q = Set(question.lowercased().replacingOccurrences(of: "n't", with: "nt").split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if !q.isDisjoint(with: negations) { return false }
        let v = Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if f == .authorization { return q.intersection(places).subtracting(["visa", "sponsorship", "remote", "onsite", "hybrid"]).isSubset(of: v) }
        return true
    }

    /// The saved answer to a form question, if the profile has one: a close earlier question first (the user's own
    /// wording for that exact question wins), then the matching profile field. nil when nothing fits.
    static func answer(for question: String, in p: Data = current) -> String? {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        // Only questions that mean the same thing share an answer: "...require sponsorship" and "...not require
        // sponsorship", or "authorized to work in the US" and "...in India", are different questions.
        func bestMatch(minimum: Double) -> QA? {
            p.qa.filter { !$0.answer.isEmpty && sameMeaning(q, $0.question) }
                .map { ($0, similarity(q, $0.question)) }.filter { $0.1 >= minimum }.max(by: { $0.1 < $1.1 })?.0
        }
        if let hit = bestMatch(minimum: 0.6) { return hit.answer }
        if let f = field(for: q), let v = value(of: f, in: p, question: q), fieldAnswerFits(f, question: q, value: v) { return v }
        if let hit = bestMatch(minimum: 0.45) { return hit.answer }
        return nil
    }

    /// Saves the user's answer to a form question: into its profile field when it is one of them (only if that
    /// field is still empty, so a one-off answer can't overwrite the profile), otherwise as a Q&A pair (replacing an
    /// earlier answer to the same question).
    /// Returns whether the answer is now stored (false when it was empty, too long, or the file couldn't be written).
    @discardableResult
    static func remember(question: String, answer: String) -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !a.isEmpty, a.count < 2000 else { return false }
        var p = current
        if let f = field(for: q), fill(f, with: a, in: &p) {
            return save(p)
        }
        if let i = p.qa.firstIndex(where: { similarity(q, $0.question) >= 0.8 }) {
            p.qa[i] = QA(question: q, answer: a)
        } else {
            p.qa.append(QA(question: q, answer: a))
        }
        return save(p)
    }

    /// Fills an empty profile field; false when the field already has a value (the answer goes to Q&A instead).
    private static func fill(_ f: Field, with a: String, in p: inout Data) -> Bool {
        func set(_ k: WritableKeyPath<Data, String>) -> Bool {
            guard p[keyPath: k].isEmpty else { return p[keyPath: k] == a }
            p[keyPath: k] = a
            return true
        }
        switch f {
        case .expectedCTC: return set(\.expectedCTC)
        case .currentCTC: return set(\.currentCTC)
        case .notice: return set(\.noticePeriod)
        case .linkedin: return set(\.linkedin)
        case .github: return set(\.github)
        case .portfolio: return set(\.portfolio)
        case .email: return set(\.email)
        case .phone: return set(\.phone)
        case .relocate: return set(\.willingToRelocate)
        case .authorization: return set(\.workAuthorization)
        case .location: return set(\.location)
        case .name: return set(\.name)
        case .resume:
            guard !p.resumePaths.contains(a) else { return true }
            guard p.resumePaths.isEmpty else { return false }
            p.resumePaths = [a]
            return true
        case .experience:
            guard p.experienceYears == nil, p.experienceMonths == nil, let (y, m) = parseExperience(a) else { return false }
            p.experienceYears = y; p.experienceMonths = m
            return true
        case .firstName, .lastName: return false
        }
    }

    /// "1 year 6 months", "8 months", "1.5 years", "2" (years) → (years, months).
    static func parseExperience(_ text: String) -> (Int, Int)? {
        let t = text.lowercased()
        func number(before unit: String) -> Double? {
            guard let r = t.range(of: #"(\d+(\.\d+)?)\s*"# + unit, options: .regularExpression) else { return nil }
            return Double(t[r].prefix { $0.isNumber || $0 == "." })
        }
        let years = number(before: #"(years?|yrs?)\b"#), months = number(before: #"(months?|mos?)\b"#)
        // "nan", "inf" and "1e100" parse as doubles but are not experience: only a sane, finite span is accepted.
        func span(_ v: Double) -> Int? { v.isFinite && v >= 0 && v <= 1200 ? Int(v.rounded()) : nil }
        if years == nil, months == nil {
            guard let only = Double(t.trimmingCharacters(in: .whitespaces)), let total = span(only * 12) else { return nil }
            return (total / 12, total % 12)
        }
        guard let total = span((years ?? 0) * 12 + (months ?? 0)) else { return nil }
        return (total / 12, total % 12)
    }

    // MARK: - Prompt

    /// The profile in a few compact lines for the model (empty when nothing is saved).
    static var promptBlock: String {
        let p = current
        var parts: [String] = []
        func add(_ label: String, _ v: String) { if !v.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("\(label): \(v)") } }
        add("Name", p.name); add("Email", p.email); add("Phone", p.phone); add("Location", p.location)
        add("Current CTC", p.currentCTC); add("Expected CTC", p.expectedCTC); add("Notice period", p.noticePeriod)
        if p.experienceYears != nil || p.experienceMonths != nil {
            parts.append("Experience: \(p.experienceYears ?? 0)y \(p.experienceMonths ?? 0)m")
        }
        add("LinkedIn", p.linkedin); add("GitHub", p.github); add("Portfolio", p.portfolio)
        if !p.resumePaths.isEmpty { parts.append("Resume: " + p.resumePaths.joined(separator: " | ")) }
        add("Work authorization", p.workAuthorization); add("Relocate", p.willingToRelocate)
        guard !parts.isEmpty || !p.qa.isEmpty else { return "" }
        var text = "Job-application profile (use these in forms, don't ask for them):\n" + parts.joined(separator: " · ")
        if !p.qa.isEmpty {
            text += "\nSaved answers to earlier form questions:\n"
                + p.qa.suffix(40).map { "- \($0.question) → \($0.answer.prefix(300))" }.joined(separator: "\n")
        }
        return text
    }

    // MARK: - Seed

    /// First-run profile, mined from memory facts and the application tracker. Anything not found stays empty.
    private static func seed() -> Data {
        var p = Data()
        p.name = NSFullUserName()
        let facts = Memory.facts
        func first(_ pattern: String, in pool: [String]? = nil, group: Int = 0) -> String? {
            for fact in pool ?? facts {
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                      let m = re.firstMatch(in: fact, range: NSRange(fact.startIndex..., in: fact)),
                      let r = Range(m.range(at: group), in: fact) else { continue }
                return String(fact[r]).trimmingCharacters(in: CharacterSet(charactersIn: " .;,'\""))
            }
            return nil
        }
        let email = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        p.email = first(email, in: facts.filter { $0.lowercased().contains("personal") })
            ?? first(email, in: facts.filter { $0.range(of: #"(?i)\be-?mail\b"#, options: .regularExpression) != nil }) ?? ""
        p.phone = first(#"\+?\d[\d \-]{8,}\d"#, in: facts.filter { $0.range(of: #"(?i)\b(phone|mobile)\b"#, options: .regularExpression) != nil }) ?? ""
        p.linkedin = first(#"(https?://)?(www\.)?linkedin\.com/in/[A-Za-z0-9_-]+/?"#) ?? ""
        p.github = first(#"github\.com/[A-Za-z0-9_-]+"#, in: facts.filter { $0.range(of: #"(?i)^(his |my )?github (is|username is)"#, options: .regularExpression) != nil })
            .map { "https://" + $0 } ?? ""
        p.portfolio = first(#"portfolio is ([^\s,;]+)"#, group: 1) ?? ""
        p.location = first(#"(current location[^:]*:|based in|lives in)\s*([^;.]+)"#, group: 2) ?? ""
        p.expectedCTC = first(#"(expect\w*|desired) (stipend|salary|ctc)[^₹\d]*([₹$]?\s?[\d,]+[^;.]*?)(;|\.|$)"#, group: 3) ?? ""
        p.noticePeriod = first(#"notice period[^:]*(is|:)\s*([^;.]+)"#, group: 2) ?? ""
        p.currentCTC = first(#"current (ctc|salary|stipend)[^:]*(is|:)\s*([^;.]+)"#, group: 3) ?? ""
        if let exp = first(#"total experience[^\d]*([^;(]+)"#, group: 1), let (y, m) = parseExperience(exp) {
            p.experienceYears = y; p.experienceMonths = m
        }
        if let auth = first(#"(not )?authori[sz]ed to work( in [A-Za-z ]+?)?(?= and |;|\.|$)"#) { p.workAuthorization = auth.prefix(1).uppercased() + auth.dropFirst() }
        if let where_ = first(#"open to relocat\w*( to)?\s*([^;.]*)"#, group: 2) {
            p.willingToRelocate = where_.isEmpty ? "Yes" : "Yes (\(where_.replacingOccurrences(of: "for internships", with: "").trimmingCharacters(in: .whitespaces)))"
        }
        if let resume = first(#"https?://drive\.google\.com/\S+"#, in: facts.filter { $0.lowercased().contains("resume") }) {
            p.resumePaths.append(resume)
        }
        // The resume file the tracker used most, as a full path when it can be found.
        let names = Applications.all.compactMap(\.resume).filter { !$0.isEmpty }
        if let top = Dictionary(grouping: names, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let found = ["Downloads", "Documents", "Desktop", ""].map { home.appendingPathComponent($0).appendingPathComponent(top).path }
                .first { FileManager.default.fileExists(atPath: $0) }
            p.resumePaths.insert(found ?? top, at: 0)
        }
        // Standing answers the user gave to application questions.
        for fact in facts {
            if let q = first(#"application answer for '([^']+)'"#, in: [fact], group: 1), let a = first(#"':\s*(.+)$"#, in: [fact], group: 1) {
                p.qa.append(QA(question: q, answer: a))
            } else if let q = first(#"application questions? (on|about) (.+?), he answers"#, in: [fact], group: 2),
                      let a = first(#"he answers (.+)$"#, in: [fact], group: 1) {
                p.qa.append(QA(question: q, answer: a))
            }
        }
        if let year = first(#"graduation year is (\d{4})"#, group: 1) { p.qa.append(QA(question: "Graduation year", answer: year)) }
        return p
    }
}
