import Foundation

/// Decisions made before (or instead of) asking the model: does a saved workflow already do this request, and
/// does an answer to the follow-up mic mean "nothing more"?
enum Router {
    struct Match {
        let workflow: Workflow
        let params: [String: String]
    }

    /// Filler that doesn't change what's asked ("please", "hey clinqy", "can you").
    private static let fillerPrefix = #"^(hey |hi |ok |okay )?(clinqy[, ]+)?(please |pls |can you |could you |would you |kindly )*"#

    static func normalize(_ s: String) -> String {
        var t = s.lowercased().replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: fillerPrefix, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[\s.!?,]*(please|pls)?[\s.!?]*$"#, with: "", options: .regularExpression)
        return t
    }

    /// A saved workflow that does exactly this request, with its parameters read out of the words.
    /// The workflow's name is the request it was saved from; each parameter whose original value appears in that
    /// request becomes a slot ("message mom I'll be late" → "message mom {text}"). Confident means the new request
    /// fits the template exactly (slots aside): no guessing, or the model handles it.
    static func match(_ request: String, in workflows: [Workflow]) -> Match? {
        let want = normalize(request)
        guard !want.isEmpty else { return nil }
        var best: (Match, Int)?
        for wf in workflows where !wf.steps.isEmpty {
            let name = normalize(wf.name)
            guard !name.isEmpty else { continue }
            // Longest defaults first, so "Amrit Nigam" is a slot before "Amrit".
            let slots = (wf.defaults ?? [:]).filter { $0.value.count >= 2 && name.contains(normalize($0.value)) && !normalize($0.value).isEmpty }
                .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            // Slots are located in the name itself (longest first, never overlapping), then laid out in the order they
            // appear in the text: regex capture groups are numbered left to right, not by length.
            var claimed: [(range: Range<String.Index>, key: String)] = []
            for (key, value) in slots {
                let lit = normalize(value)
                var from = name.startIndex
                while let r = name.range(of: lit, range: from..<name.endIndex) {
                    if !claimed.contains(where: { $0.range.overlaps(r) }) { claimed.append((r, key)); break }
                    from = r.upperBound
                }
            }
            claimed.sort { $0.range.lowerBound < $1.range.lowerBound }
            var pattern = ""
            var order: [String] = []
            var cursor = name.startIndex
            for c in claimed {
                pattern += NSRegularExpression.escapedPattern(for: String(name[cursor..<c.range.lowerBound])).replacingOccurrences(of: " ", with: #"\s+"#)
                pattern += "(.+?)"
                order.append(c.key)
                cursor = c.range.upperBound
            }
            pattern += NSRegularExpression.escapedPattern(for: String(name[cursor...])).replacingOccurrences(of: " ", with: #"\s+"#)
            pattern = "^" + pattern + "$"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: want, range: NSRange(want.startIndex..., in: want)) else { continue }
            var params: [String: String] = [:]
            // Values come from the original request (keeps the user's capitalisation).
            let original = request.trimmingCharacters(in: .whitespacesAndNewlines)
            for (i, key) in order.enumerated() {
                guard let r = Range(m.range(at: i + 1), in: want) else { continue }
                let lowered = String(want[r])
                let cased = original.range(of: lowered, options: .caseInsensitive).map { String(original[$0]) } ?? lowered
                params[key] = cased.trimmingCharacters(in: .whitespaces)
            }
            // Prefer the most literal template (fewest slots = least guessing).
            let literal = name.count - claimed.reduce(0) { $0 + name[$1.range].count }
            if best == nil || literal > best!.1 { best = (Match(workflow: wf, params: params), literal) }
        }
        return best?.0
    }

    /// Requests that lean on what's on screen or selected ("reply to this", "this form") need the model to see it.
    static func refersToContext(_ request: String) -> Bool {
        normalize(request).range(of: #"\b(this|that|these|those|it|here|above|below|same|again|ye|yeh|isko|isse|usko|wahi)\b"#,
                                 options: .regularExpression) != nil
    }

    /// Saved skills whose name shares most words with the request (for pointing the model at the right one).
    static func skillHint(_ request: String, names: [String]) -> String? {
        let words = { (s: String) in Set(normalize(s).split(separator: " ").map(String.init).filter { $0.count > 2 }) }
        let want = words(request)
        guard !want.isEmpty else { return nil }
        let scored = names.map { name -> (String, Double) in
            let have = words(name)
            return (name, have.isEmpty ? 0 : Double(want.intersection(have).count) / Double(have.union(want).count))
        }
        return scored.filter { $0.1 >= 0.5 }.max { $0.1 < $1.1 }?.0
    }

    // MARK: Follow-ups

    /// "continue", "go on", "also make an answer list", "now send it to Rahul", "aur", "phir": builds on the last task.
    static func isFollowUp(_ request: String) -> Bool {
        let t = normalize(request)
        return isCorrection(request) || t.range(of: #"^(continue|carry on|go on|keep going|resume|finish( it| that)?|complete( it| that)?|try again|retry|"#
                       + #"also|and|now|then|next|after that|same|aur|phir|ab|aage|jari rakho|continue karo)\b"#,
                       options: .regularExpression) != nil
    }

    /// Explicit corrections should continue the prior task and stop its old route being replayed as proven.
    static func isCorrection(_ request: String) -> Bool {
        normalize(request).range(of: #"^(actually\b|instead\b|no[, :]|nope[, :]|not like that\b|that's wrong\b|that is wrong\b|correction for\b|i meant\b)|\b(use|save|export|send)\b.+\binstead\b"#,
                                 options: .regularExpression) != nil
    }

    /// "no thanks", "that's all", "kuch nahi": nothing more to do (an answer to the follow-up mic).
    static func isDismissal(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: #"[^\p{L}\s']"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return t.range(of: #"^(no|nope|nah|nothing|no thanks|no thank you|that's all|thats all|that's it|thats it|all good|done|i'm good|im good|"#
                       + #"thanks|thank you|ok thanks|okay thanks|great thanks|stop|cancel|never mind|nevermind|nahi|nahin|kuch nahi|bas|bas itna hi|bas itna|ruko|ho gaya|shukriya|dhanyavaad)( clinqy)?$"#,
                       options: .regularExpression) != nil
    }
}
