import Foundation

/// Input delivery and application state are independent facts. A dispatched click alone is never a checkpoint.
struct ActionOutcome: Codable, Equatable {
    enum Delivery: String, Codable { case notAttempted, delivered, unknown }
    enum Status: String, Codable { case confirmed, unverified, failed, refused }
    let delivery: Delivery
    let status: Status

    static let confirmed = ActionOutcome(delivery: .delivered, status: .confirmed)
    static let unverified = ActionOutcome(delivery: .delivered, status: .unverified)
    static let uncertain = ActionOutcome(delivery: .unknown, status: .unverified)
    static let failed = ActionOutcome(delivery: .notAttempted, status: .failed)
    static let refused = ActionOutcome(delivery: .notAttempted, status: .refused)
    var isConfirmed: Bool { status == .confirmed }
    var needsVerification: Bool { status == .unverified }

    /// The browser state signature includes target state, URL, global text hash and focus. Only target state or
    /// navigation is evidence of this interaction; unrelated page text/focus changes cannot confirm a click.
    static func browserClick(before: String?, after: String?, consequential: Bool) -> ActionOutcome {
        guard !consequential, let before, let after,
              let old = try? JSONSerialization.jsonObject(with: Data(before.utf8)) as? [Any],
              let new = try? JSONSerialization.jsonObject(with: Data(after.utf8)) as? [Any],
              old.count >= 7, new.count >= 7 else { return .unverified }
        let oldTarget = Array(old.prefix(7)) as NSArray
        let newTarget = Array(new.prefix(7)) as NSArray
        return oldTarget.isEqual(newTarget) ? .unverified : .confirmed
    }
}

/// Fresh listings may identify a target uniquely, but proximity must never break an identity tie.
enum TargetResolution {
    struct Candidate { let index: Int; let identity: String }
    static func unique(index: Int, identity: String, candidates: [Candidate], stableIndex: Bool) -> Int? {
        if stableIndex, candidates.contains(where: { $0.index == index && $0.identity == identity }) { return index }
        let matches = candidates.filter { $0.identity == identity }
        return matches.count == 1 ? matches[0].index : nil
    }
}

/// A postcondition must demonstrate the pending operation, rather than merely describe existing UI.
enum VerificationEvidence {
    static func changedValue(before: String?, after: String?, expected: String, sameTarget: Bool, fieldInput: Bool) -> Bool {
        guard fieldInput, sameTarget, let before, let after else { return false }
        return before != expected && after == expected
    }

    static func newText(_ expected: String, before: String?, after: String?) -> Bool {
        guard !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let before, let after else { return false }
        return !appears(expected, in: before) && appears(expected, in: after)
    }

    /// Case-insensitive match that does not count a word fragment: "Paid" is not on a page that only says "unpaid",
    /// and "Order" is not "Orders". Punctuation and symbols at the edges of `expected` still match as written.
    static func appears(_ expected: String, in haystack: String) -> Bool {
        // Code editors and rich pages use non-breaking spaces and uneven runs of whitespace for ordinary spaces.
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{00A0}", with: " ").split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        let needle = normalized(expected.trimmingCharacters(in: .whitespacesAndNewlines))
        let haystack = normalized(haystack)
        guard !needle.isEmpty else { return false }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        let wantsLeading = needle.first.map(isWord) ?? false, wantsTrailing = needle.last.map(isWord) ?? false
        var from = haystack.startIndex
        while let range = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: from..<haystack.endIndex) {
            let leftOK = !wantsLeading || range.lowerBound == haystack.startIndex || !isWord(haystack[haystack.index(before: range.lowerBound)])
            let rightOK = !wantsTrailing || range.upperBound == haystack.endIndex || !isWord(haystack[range.upperBound])
            if leftOK && rightOK { return true }
            from = haystack.index(after: range.lowerBound)
        }
        return false
    }
}

/// A sheet may report a different AXWindow while still descending from the exact observed parent.
/// Following only parent/window links never admits an unrelated sibling window from the same app.
enum NativeWindowHierarchy {
    static func contains<Node>(_ target: Node, root: Node, parents: (Node) -> [Node], equal: (Node, Node) -> Bool) -> Bool {
        var queue = [target], seen: [Node] = [], index = 0
        while index < queue.count && seen.count < 64 {
            let node = queue[index]; index += 1
            if equal(node, root) { return true }
            if seen.contains(where: { equal($0, node) }) { continue }
            seen.append(node); queue.append(contentsOf: parents(node))
        }
        return false
    }
}
enum TaskCompletionPolicy {
    static func reportsFailure(_ summary: String) -> Bool {
        summary.range(of: #"(?i)^\s*(?:i |we )?(couldn['’]?t|cannot|can['’]?t|was unable to|were unable to|unable to|failed to)\s+(send|attach|finish|complete|deliver|capture|open|submit|save|upload)\b"#, options: .regularExpression) != nil
    }
    static func requestsWriteUp(_ request: String) -> Bool {
        let text = request.components(separatedBy: "\n\nPrevious Telegram task").first ?? request
        if text.range(of: #"(?is)\b(no|not|don't|do not|without)\b.{0,40}\b(doc|document|write[ -]?up|report)\b"#, options: .regularExpression) != nil { return false }
        return text.range(of: #"(?is)\b(create|make|write|prepare|document|paste|put|add|insert)\b.{0,100}\b(doc|document|report|guide|write[ -]?up)\b"#, options: .regularExpression) != nil
    }
}

/// How a returned or thrown low-level input maps to an outcome. A failure to report is never success, and a Return
/// whose delivery is unknown is never replayed blindly (it is `.uncertain`, which holds the repeat barrier).
enum InputDelivery {
    static func pageScroll(error: Error?) -> ActionOutcome { error == nil ? .confirmed : .failed }
    static func returnPress(delivered: Bool) -> ActionOutcome { delivered ? .unverified : .uncertain }
}
