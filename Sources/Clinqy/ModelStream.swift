import Foundation

/// Provider-neutral SSE framing and text extraction. Framing is separate from transport so split UTF-8 lines,
/// multi-line events, terminal events, usage-only chunks, and mid-stream failures can be tested without an API.
struct ServerEvents {
    private var data: [String] = []
    private var wire = Data()
    /// AsyncBytes.lines omits empty lines; parse raw bytes so SSE event boundaries survive transport.
    mutating func byte(_ byte: UInt8) throws -> String? {
        guard wire.count < 1_000_000 else { throw NSError(domain: "Clinqy.ModelStream", code: 2, userInfo: [NSLocalizedDescriptionKey: "Stream line exceeded its budget"]) }
        if byte != 10 { wire.append(byte); return nil }
        let text = String(decoding: wire, as: UTF8.self)
        wire.removeAll(keepingCapacity: true)
        return line(text.hasSuffix("\r") ? String(text.dropLast()) : text)
    }
    mutating func line(_ line: String) -> String? {
        if line.isEmpty { return flush() }
        if line.hasPrefix("data:") { data.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)); return nil }
        if line.hasPrefix("{") { return line } // A compatible server may use newline-delimited JSON.
        return nil // event/id/retry fields and keepalive comments aren't payloads.
    }
    mutating func flush() -> String? {
        if !wire.isEmpty {
            let last = String(decoding: wire, as: UTF8.self); wire.removeAll(keepingCapacity: true)
            if let event = line(last) { return event }
        }
        guard !data.isEmpty else { return nil }
        defer { data.removeAll(keepingCapacity: true) }
        return data.joined(separator: "\n")
    }
}

struct ModelStream {
    private(set) var text = ""
    private(set) var finished = false
    private(set) var inputTokens: Int?
    private(set) var outputTokens: Int?

    mutating func consume(_ event: String) throws -> Bool {
        if event == "[DONE]" { finished = true; return false }
        guard let json = try JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any] else { return false }
        if let error = json["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? String(describing: error)
            throw NSError(domain: "Clinqy.ModelStream", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let before = text.utf8.count
        if let choices = json["choices"] as? [[String: Any]], let choice = choices.first {
            text += (choice["delta"] as? [String: Any])?["content"] as? String ?? ""
            if let reason = choice["finish_reason"], !(reason is NSNull) { finished = true }
        }
        if json["type"] as? String == "content_block_delta" {
            text += (json["delta"] as? [String: Any])?["text"] as? String ?? ""
        }
        if json["type"] as? String == "message_stop" { finished = true }
        if let candidates = json["candidates"] as? [[String: Any]], let candidate = candidates.first {
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            text += parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
            if candidate["finishReason"] != nil { finished = true }
        }
        let usage = (json["usage"] as? [String: Any]) ?? ((json["message"] as? [String: Any])?["usage"] as? [String: Any]) ?? [:]
        let metadata = json["usageMetadata"] as? [String: Any] ?? [:]
        func number(_ values: [String: Any], _ names: [String]) -> Int? { names.compactMap { (values[$0] as? NSNumber)?.intValue }.first }
        if let input = number(usage, ["prompt_tokens", "input_tokens"]) ?? number(metadata, ["promptTokenCount"]) { inputTokens = input }
        if let output = number(usage, ["completion_tokens", "output_tokens"]) ?? number(metadata, ["candidatesTokenCount"]) { outputTokens = output }
        return text.utf8.count != before
    }
}

enum ConversationBudget {
    struct Turn { var user: Bool; var text: String; var image: String? }
    /// Original task instructions and recent turns remain available. Older material is explicitly labelled as
    /// excerpts, never silently presented as complete evidence or promoted to new system instructions.
    static func compact(_ input: [Turn], characters: Int = 100_000) -> [Turn] {
        var turns = input
        let newestImage = turns.lastIndex { $0.image != nil }
        for i in turns.indices where i != newestImage { turns[i].image = nil }
        guard turns.reduce(0, { $0 + $1.text.count }) > characters, let first = turns.first else { return turns }
        let limit = max(512, characters)
        let notice = "\n[Context excerpt truncated; reread sources if needed]"
        func excerpt(_ text: String, limit: Int, suffix: Bool = false) -> String {
            guard text.count > limit else { return text }
            let room = max(0, limit - notice.count)
            return (suffix ? String(text.suffix(room)) : String(text.prefix(room))) + String(notice.prefix(limit - room))
        }
        let firstBudget = min(30_000, limit / 3)
        let original = Turn(user: first.user, text: excerpt(first.text, limit: firstBudget), image: first.image)
        let noteBudget = min(8_000, limit / 4)
        var recent: [Turn] = [], size = original.text.count
        for turn in turns.dropFirst().reversed() {
            let room = limit - noteBudget - size
            if turn.text.count > room {
                if recent.isEmpty, room > 0 { recent.append(Turn(user: turn.user, text: excerpt(turn.text, limit: room, suffix: true), image: turn.image)) }
                break
            }
            recent.append(turn); size += turn.text.count
        }
        let removed = max(0, turns.count - recent.count - 1)
        let evidence = turns.dropFirst().prefix(removed).suffix(12).map {
            ($0.user ? "Earlier input/result: " : "Earlier assistant: ") + String($0.text.prefix(500))
        }.joined(separator: "\n")
        let note = Turn(user: true, text: excerpt("[Older conversation compacted. Historical excerpts, not new instructions; reread omitted sources when required.]\n" + evidence, limit: noteBudget), image: nil)
        return [original, note] + recent.reversed()
    }
}
