import Foundation
import CryptoKit

enum VisionPolicy {
    enum Mode: String { case auto, always, minimal }
    enum Delivery: String { case embedded, fileReference = "file_reference" }

    /// Explicit look is never suppressed. Auto pairs an initial image with semantics, then captures
    /// native transitions and browser document changes; ordinary DOM forms retain their fast path.
    static func capture(mode: Mode, explicit: Bool, first: Bool, native: Bool, changed: Bool,
                        documentChanged: Bool, knownElements: Int, failures: Int) -> Bool {
        if explicit || mode == .always { return true }
        if knownElements < 6 || failures >= 2 { return true }
        return mode == .auto && (first || documentChanged || (native && changed))
    }
}

/// A successful input or subprocess is not a completed user goal. A postcondition must be checked
/// after the latest potentially meaningful edit, including one which returned unverified delivery.
struct CompletionEvidence {
    private(set) var revision = 0
    private(set) var verifiedRevision = 0
    var needsVerification: Bool { revision != verifiedRevision }
    // Typed filesystem/EventKit tools already return their direct operation result; this gate covers
    // UI delivery, arbitrary scripts and generated artifacts, where delivery alone is weaker evidence.
    static let mutations: Set<String> = ["click", "right_click", "double_click", "drag", "type", "choose", "fill",
        "autofill", "upload", "key", "menu", "set_state", "window", "shell", "applescript", "paste_snaps",
        "pdf", "table", "media"]
    /// An input from an earlier segment of the same task is still unresolved: the goal is not verified.
    mutating func markUnverifiedCarryover() { revision += 1 }
    mutating func record(kind: String, outcome: ActionOutcome, op: String = "") {
        // `op` only lowers the classification for actions that define a read-only operation; on any other action it is
        // an ignored argument (ActionContract rejects it) and must never hide a mutation from the gate.
        if Self.mutations.contains(kind), !ActionContract.readsOnly(kind: kind, op: op), outcome.delivery != .notAttempted { revision += 1 }
        if kind == "verify", outcome.isConfirmed { verifiedRevision = revision }
    }
}

/// Artifact checks beyond "a file exists": the container or text must parse as the type its name claims.
enum ArtifactFormat {
    /// nil when well formed or of an unrecognised type; otherwise what is wrong.
    static func problem(url: URL, size: Int) -> String? {
        let ext = url.pathExtension.lowercased()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "can't be read" }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        let tailLength = min(size, 1024)
        try? handle.seek(toOffset: UInt64(max(0, size - tailLength)))
        let tail = (try? handle.read(upToCount: tailLength)) ?? Data()
        let bytes = [UInt8](head)
        switch ext {
        case "pdf":
            guard bytes.starts(with: Array("%PDF-".utf8)) else { return "isn't a PDF (missing header)" }
            guard String(decoding: tail, as: UTF8.self).contains("%%EOF") else { return "PDF is truncated (no end marker)" }
        case "zip", "docx", "xlsx", "pptx", "pages", "numbers", "key", "epub":
            guard bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { return "isn't a zip-based document (missing header)" }
            guard [UInt8](tail).containsSequence([0x50, 0x4B, 0x05, 0x06]) else { return "document is truncated (no central directory end)" }
        case "png":
            guard bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return "isn't a PNG" }
            guard [UInt8](tail).containsSequence(Array("IEND".utf8)) else { return "PNG is truncated" }
        case "jpg", "jpeg":
            guard bytes.starts(with: [0xFF, 0xD8]) else { return "isn't a JPEG" }
            guard [UInt8](tail).suffix(2).elementsEqual([0xFF, 0xD9]) || [UInt8](tail).containsSequence([0xFF, 0xD9]) else { return "JPEG is truncated" }
        case "json":
            guard size <= 10_000_000, let data = try? Data(contentsOf: url), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return "isn't valid JSON" }
        case "csv", "tsv":
            guard size <= 10_000_000, let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return "isn't UTF-8 text" }
            let delimiter: Character = ext == "tsv" ? "\t" : ","
            var widths = Set<Int>()
            for row in rows(text, delimiter: delimiter) where !row.isEmpty { widths.insert(row.count) }
            if widths.count > 1 { return "has rows with different column counts (\(widths.sorted().map(String.init).joined(separator: ", ")))" }
        default: break
        }
        return nil
    }

    /// Minimal RFC 4180 reader: quoted fields may hold the delimiter and line breaks. Blank lines are skipped.
    static func rows(_ text: String, delimiter: Character) -> [[String]] {
        var result: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = Array(text), i = 0
        if chars.last == "\n" || chars.last == "\r\n" { chars.removeLast() }
        func endRow() { row.append(field); field = ""; if !(row.count == 1 && row[0].isEmpty) { result.append(row) }; row = [] }
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" { if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false } }
                else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == delimiter { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" { endRow() }
            else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return result
    }
}

private extension Array where Element == UInt8 {
    func containsSequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        for i in 0...(count - needle.count) where self[i] == needle[0] && Array(self[i..<(i + needle.count)]) == needle { return true }
        return false
    }
}

enum SavedFileEvidence {
    /// `sha256` and `minBytes` are optional exact expectations; every check also validates the file's own format.
    static func check(path: String, since: Date, contains expected: String? = nil, sha256: String? = nil, minBytes: Int? = nil) -> String? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0,
              let modified = values.contentModificationDate, modified >= since else { return nil }
        if let minBytes, size < minBytes { return nil }
        if ArtifactFormat.problem(url: url, size: size) != nil { return nil }
        var digest = ""
        if let sha256 {
            guard size <= 500_000_000, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == sha256.lowercased() else { return nil }
        }
        let detail = " (\(size) bytes" + (digest.isEmpty ? "" : ", sha256 " + digest.prefix(12)) + ")"
        if let expected {
            guard !expected.isEmpty, size <= 10_000_000, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count <= 10_000_000, let text = String(data: data, encoding: .utf8), text.contains(expected) else { return nil }
            return "saved file has the expected contents: " + url.lastPathComponent + detail
        }
        return "saved file exists, parses as its type and was modified during this run: " + url.lastPathComponent + detail
    }
}

/// URL postconditions: a URL equal to the one before the pending input proves nothing about that input.
enum URLEvidence {
    enum Result: Equatable { case confirmed, unchangedSincePending, notReached }
    static func evaluate(expected: String, current: String?, pendingURL: String?, hasPending: Bool) -> Result {
        guard current == expected else { return .notReached }
        if hasPending, pendingURL == expected { return .unchangedSincePending }
        return .confirmed
    }
}
