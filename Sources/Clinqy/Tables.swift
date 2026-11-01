import AppKit

/// Moving structured data between places: tables pulled out of a web page, PDF or CSV (extract), and rows
/// written out as a CSV file, a Numbers document or the clipboard (table). The model does the mapping in
/// between; for a web form as the destination it types the values in itself.
enum Tables {
    /// A web page's tables (via the extension) as text the model can read: "Table 1 “Invoices” (12 rows)" + rows.
    static func describe(_ tables: [[String: Any]]) -> String {
        tables.enumerated().map { i, t in
            let rows = t["rows"] as? [[String]] ?? []
            let name = (t["name"] as? String).flatMap { $0.isEmpty ? nil : "“\($0)”" } ?? ""
            let more = (t["more"] as? Int ?? 0) > 0 ? " (+\(t["more"] as? Int ?? 0) more rows not shown)" : ""
            let frame = (t["frame"] as? String).map { " [inside \(URL(string: $0)?.host ?? $0)]" } ?? ""
            return "Table \(i + 1) \(name)\(frame) — \(rows.count) rows\(more):\n" + rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Stream files through a small buffer; extraction callers use the bounded sample API.
    static func readDelimited(_ url: URL) -> [[String]]? { readSample(url, maxRows: .max, maxBytes: .max)?.rows }

    static func readSample(_ url: URL, maxRows: Int = 500, maxBytes: Int = 1_000_000) -> (rows: [[String]], truncated: Bool)? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 16_384), offset = 0, length = 0, consumed = 0
        var budgetReached = false
        func next() -> UInt8? {
            guard !Task.isCancelled else { return nil }
            if consumed >= maxBytes { budgetReached = true; return nil }
            if offset == length {
                length = stream.read(&buffer, maxLength: buffer.count); offset = 0
                if length <= 0 { return nil }
            }
            consumed += 1
            defer { offset += 1 }
            return buffer[offset]
        }
        // Detect tabs from a bounded first buffer rather than scanning the entire file.
        length = stream.read(&buffer, maxLength: buffer.count)
        guard length >= 0 else { return nil }
        let head = buffer.prefix(length)
        let sep: UInt8 = url.pathExtension.lowercased() == "tsv" || (!head.contains(44) && head.contains(9)) ? 9 : 44
        let limit = maxRows == .max ? Int.max : maxRows + 1
        var rows = parseBytes(separator: sep, maxRows: limit, next: next)
        guard stream.streamError == nil, !Task.isCancelled else { return nil }
        let truncated = budgetReached || rows.count > maxRows
        if budgetReached, !rows.isEmpty { rows.removeLast() } // A partial record must never look complete.
        return (Array(rows.prefix(maxRows)), truncated)
    }

    /// RFC 4180 without a second Character array: quoted fields, doubled quotes, CRLF and quoted newlines.
    static func parse(_ text: String, separator: Character = ",") -> [[String]] {
        var bytes = text.utf8.makeIterator()
        return parseBytes(separator: String(separator).utf8.first ?? 44, maxRows: .max) { bytes.next() }
    }

    private static func parseBytes(separator: UInt8, maxRows: Int, next: () -> UInt8?) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = Data()
        var quoted = false, quotePending = false, skipLF = false
        func finishField() {
            row.append(String(data: field, encoding: .utf8) ?? String(data: field, encoding: .isoLatin1) ?? "")
            field.removeAll(keepingCapacity: true)
        }
        while let c = next() {
            if skipLF { skipLF = false; if c == 10 { continue } }
            if quoted {
                if quotePending {
                    if c == 34 { field.append(34); quotePending = false; continue }
                    quoted = false; quotePending = false
                } else {
                    if c == 34 { quotePending = true } else { field.append(c) }
                    continue
                }
            }
            if c == 34 && field.isEmpty { quoted = true }
            else if c == separator { finishField() }
            else if c == 10 || c == 13 {
                finishField()
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row.removeAll(keepingCapacity: true)
                skipLF = c == 13
                if rows.count >= maxRows { return rows }
            } else { field.append(c) }
        }
        finishField()
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }

    static func csv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { f in f.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f }
                .joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }

    /// Writes rows out. `to`: csv (a file), numbers (a new Numbers document), clipboard (tab-separated, pastes into
    /// any spreadsheet's cells). Returns a line for the agent.
    @MainActor
    static func save(_ rows: [[String]], to destination: String, path: String?, title: String?, append: Bool) async throws -> String {
        guard !rows.isEmpty, rows.contains(where: { !$0.isEmpty }) else { throw Pdf.Failure("no rows given") }
        let width = rows.map(\.count).max() ?? 0
        let rows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        switch destination {
        case "clipboard", "paste":
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(rows.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t") }.joined(separator: "\n"), forType: .string)
            return "copied \(rows.count) rows × \(width) columns (tab-separated): click the first cell of a spreadsheet and press cmd+v"

        case "csv", "file", "numbers", "excel":
            let name = safeName(title ?? "Table")
            let wanted = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            var url = wanted ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/\(name).csv")
            if url.pathExtension.lowercased() != "csv" { url = url.appendingPathExtension("csv") }
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists, append {
                // Add to the end; skip the header row if the file already starts with the same one.
                guard let old = readSample(url, maxRows: 1) else { throw Pdf.Failure("couldn't read the existing CSV header") }
                let add = old.rows.first.map { $0 == rows.first ?? [] } == true ? Array(rows.dropFirst()) : rows
                try appendRows(add, to: url)
                if destination == "numbers", let app = numbersURL() {
                    _ = try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init())
                }
                return "appended \(add.count) rows to \(url.path)"
            }
            if exists { url = Pdf.unique(url) }   // never overwrite
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try csv(rows).write(to: url, atomically: true, encoding: .utf8)
            if destination == "numbers" || destination == "excel" {
                let appName = destination == "numbers" ? "Numbers" : "Microsoft Excel"
                guard let app = destination == "numbers" ? numbersURL() : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Excel") else {
                    return "saved \(rows.count) rows to \(url.path) (\(appName) isn't installed, so it's a CSV file)"
                }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = !Background.active
                let had = NSWorkspace.shared.runningApplications.first { $0.bundleURL == app }.map { Hand.windowIDs(pid: $0.processIdentifier) } ?? []
                let opened = try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
                if Background.active, let opened {
                    Background.app = opened
                    try? await Task.sleep(for: .milliseconds(1200))
                    AgentScreen.adopt(opened, keep: had)
                }
                return "saved \(rows.count) rows to \(url.path) and opened it in \(appName) (it's now \(Background.active ? "open behind the user's windows" : "frontmost"); save as a .\(destination == "numbers" ? "numbers" : "xlsx") file there if they want)"
            }
            return "saved \(rows.count) rows × \(width) columns to \(url.path)"

        default:
            throw Pdf.Failure("table to: csv, numbers, excel or clipboard (for a web form, type the values in)")
        }
    }

    /// Appends CSV rows to an existing file, starting a new line first when the file doesn't end with one.
    static func appendRows(_ add: [[String]], to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var prefix = ""
        if size > 0 {
            try handle.seek(toOffset: size - 1)
            if let last = try handle.read(upToCount: 1)?.first, last != 0x0A, last != 0x0D { prefix = "\n" }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: Data((prefix + csv(add)).utf8))
    }

    private static func numbersURL() -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Numbers") }

    static func safeName(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "Table" : cleaned).prefix(60))
    }
}
