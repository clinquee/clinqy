import AppKit

/// Finding and arranging files without clicking through Finder. Search goes through Spotlight's index
/// (name, content, where a download came from, who sent it), so "the PDF I got from HR last week" works.
/// Every rename/move batch is logged so `undo` can put it back; nothing is ever overwritten; trash is recoverable.
@MainActor
enum Files {
    struct Hit {
        let url: URL
        let size: Int
        let added: Date?
        let modified: Date?
        let from: [String]
    }

    // MARK: Search

    /// kind: pdf, image, video, audio, document, spreadsheet, presentation, folder, archive, app, or a file extension.
    static func find(query: String?, kind: String?, from: String?, days: Int?, folder: URL?, limit: Int = 20) async -> [Hit] {
        var parts: [String] = []
        for word in (query ?? "").split(whereSeparator: \.isWhitespace).map(String.init) where word.count >= 2 {
            let w = escape(word)
            parts.append("(kMDItemDisplayName == \"*\(w)*\"cd || kMDItemTextContent == \"\(w)*\"cdw || kMDItemWhereFroms == \"*\(w)*\"cd"
                         + " || kMDItemAuthors == \"*\(w)*\"cd || kMDItemTitle == \"*\(w)*\"cd || kMDItemSubject == \"*\(w)*\"cd)")
        }
        if let from, !from.isEmpty {
            let f = escape(from)
            parts.append("(kMDItemWhereFroms == \"*\(f)*\"cd || kMDItemAuthors == \"*\(f)*\"cd || kMDItemAuthorEmailAddresses == \"*\(f)*\"cd)")
        }
        if let kind = kind?.lowercased(), !kind.isEmpty { parts.append(kindQuery(kind)) }
        if let days, days > 0 {
            parts.append("(kMDItemDateAdded >= $time.today(-\(days)) || kMDItemFSCreationDate >= $time.today(-\(days)) || kMDItemFSContentChangeDate >= $time.today(-\(days)))")
        }
        if parts.isEmpty { parts.append("kMDItemFSContentChangeDate >= $time.today(-7)") }
        guard let predicate = NSPredicate(fromMetadataQueryString: parts.joined(separator: " && ")) else { return [] }

        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = [folder ?? NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSContentChangeDate", ascending: false)]
        let items: [NSMetadataItem] = await withCheckedContinuation { done in
            var token: NSObjectProtocol?
            var finished = false
            let finish = {
                guard !finished else { return }
                finished = true
                query.stop()
                if let token { NotificationCenter.default.removeObserver(token) }
                done.resume(returning: (query.results as? [NSMetadataItem]) ?? [])
            }
            token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { _ in
                MainActor.assumeIsolated { finish() }
            }
            query.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }   // a huge index shouldn't hang the run
        }
        let junk = ["/Library/", "/.Trash/", "/node_modules/", "/.git/", "/DerivedData/", ".app/Contents/"]
        return items.compactMap { item -> Hit? in
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !junk.contains(where: path.contains), !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
            return Hit(url: URL(fileURLWithPath: path),
                       size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? Int) ?? 0,
                       added: item.value(forAttribute: "kMDItemDateAdded") as? Date,
                       modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                       from: (item.value(forAttribute: NSMetadataItemWhereFromsKey) as? [String]) ?? [])
        }
        .sorted { ($0.added ?? $0.modified ?? .distantPast) > ($1.added ?? $1.modified ?? .distantPast) }
        .prefix(limit).map { $0 }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: "")
    }

    static func kindQuery(_ kind: String) -> String {
        let types: [String: [String]] = [
            "pdf": ["com.adobe.pdf"], "image": ["public.image"], "photo": ["public.image"], "video": ["public.movie"],
            "audio": ["public.audio"], "music": ["public.audio"], "folder": ["public.folder"], "archive": ["public.archive"],
            "zip": ["public.zip-archive"], "app": ["com.apple.application-bundle"],
            "document": ["public.composite-content", "com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
                         "public.rtf", "public.plain-text", "com.apple.iwork.pages.sffpages"],
            "doc": ["com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document"],
            "spreadsheet": ["public.spreadsheet", "public.comma-separated-values-text"],
            "presentation": ["public.presentation"],
        ]
        let key = kind.hasSuffix("s") && types[String(kind.dropLast())] != nil ? String(kind.dropLast()) : kind
        if let uti = types[key] { return "(" + uti.map { "kMDItemContentTypeTree == \"\($0)\"" }.joined(separator: " || ") + ")" }
        return "kMDItemFSName == \"*.\(escape(kind.trimmingCharacters(in: CharacterSet(charactersIn: "."))))\"c"
    }

    static func describe(_ h: Hit) -> String {
        let date = (h.added ?? h.modified).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "?"
        let from = h.from.first(where: { !$0.hasPrefix("http") || $0.count < 90 }).map { " · from \($0.prefix(80))" } ?? ""
        return "- \(h.url.path) · \(bytes(h.size)) · \(date)\(from)"
    }

    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    // MARK: Listing

    static func list(_ folder: URL, sort: String, limit: Int) throws -> String {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey, .isDirectoryKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        let rows = urls.map { u -> (URL, URLResourceValues?) in (u, try? u.resourceValues(forKeys: Set(keys))) }
        let sorted: [(URL, URLResourceValues?)]
        switch sort {
        case "name": sorted = rows.sorted { $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending }
        case "size": sorted = rows.sorted { ($0.1?.fileSize ?? 0) > ($1.1?.fileSize ?? 0) }
        default: sorted = rows.sorted { ($0.1?.addedToDirectoryDate ?? $0.1?.contentModificationDate ?? .distantPast) > ($1.1?.addedToDirectoryDate ?? $1.1?.contentModificationDate ?? .distantPast) }
        }
        return "\(folder.path): \(urls.count) items\n" + sorted.prefix(limit).map { u, v in
            "- \(u.lastPathComponent)\(v?.isDirectory == true ? "/" : " · \(bytes(v?.fileSize ?? 0))") · \((v?.addedToDirectoryDate ?? v?.contentModificationDate)?.formatted(date: .abbreviated, time: .shortened) ?? "")"
        }.joined(separator: "\n") + (urls.count > limit ? "\n(\(urls.count - limit) more)" : "")
    }

    // MARK: Moving things (logged for undo)

    /// Tests point this at a scratch folder.
    nonisolated(unsafe) static var logDirOverride: URL?
    private static var logDir: URL {
        if let logDirOverride { try? FileManager.default.createDirectory(at: logDirOverride, withIntermediateDirectories: true); return logDirOverride }
        return defaultLogDir
    }
    private static let defaultLogDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clinqy/file-moves", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Moves/renames each pair (never overwriting), then logs the batch so it can be undone.
    static func apply(_ pairs: [(URL, URL)]) throws -> (done: [(URL, URL)], skipped: [String]) {
        var done: [(URL, URL)] = [], skipped: [String] = []
        for (from, to) in pairs {
            guard FileManager.default.fileExists(atPath: from.path) else { skipped.append("\(from.lastPathComponent): not found"); continue }
            guard from.standardizedFileURL != to.standardizedFileURL else { continue }
            let dest = FileManager.default.fileExists(atPath: to.path) ? Pdf.unique(to) : to
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: from, to: dest)
                done.append((from, dest))
            } catch { skipped.append("\(from.lastPathComponent): \(error.localizedDescription)") }
        }
        if !done.isEmpty {
            let log = done.map { ["from": $0.0.path, "to": $0.1.path] }
            let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".json"
            do { try JSONSerialization.data(withJSONObject: log, options: .prettyPrinted).write(to: logDir.appendingPathComponent(name)) }
            catch { skipped.append("the undo record couldn't be saved (\(error.localizedDescription)): these moves can't be undone automatically") }
        }
        return (done, skipped)
    }

    /// Puts the most recent batch back.
    static func undo() throws -> String {
        let logs = (try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil)) ?? []
        guard let last = logs.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first,
              let data = try? Data(contentsOf: last), let moves = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            throw Pdf.Failure("nothing to undo")
        }
        var back = 0, kept: [[String: String]] = [], gone = 0
        for m in moves.reversed() {
            guard let from = m["from"], let to = m["to"] else { continue }
            let fm = FileManager.default
            if !fm.fileExists(atPath: to) {
                // Already back (or removed since): nothing left to restore for this record.
                if !fm.fileExists(atPath: from) { gone += 1 }
                continue
            }
            if fm.fileExists(atPath: from) { kept.append(m); continue }   // something now sits at the original path: don't overwrite it
            try? fm.createDirectory(at: URL(fileURLWithPath: from).deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(atPath: to, toPath: from)) != nil { back += 1 } else { kept.append(m) }
        }
        // A record stays on disk until it is resolved, so a conflict can be retried after the user clears the path.
        if kept.isEmpty {
            try? FileManager.default.removeItem(at: last)
        } else {
            let remaining = Array(kept.reversed())
            if let data = try? JSONSerialization.data(withJSONObject: remaining, options: .prettyPrinted) { try? data.write(to: last) }
        }
        var note = "put back \(back) of \(moves.count) files"
        if !kept.isEmpty { note += "; \(kept.count) couldn't be put back (the original location is occupied or the move failed), so they're still recorded for another undo" }
        if gone > 0 { note += "; \(gone) no longer exist" }
        return note
    }

    /// Top-level files of a folder grouped into subfolders by kind (Downloads → Images, PDFs, Documents…).
    static func organizePlan(_ folder: URL) throws -> [(URL, URL)] {
        let groups: [(String, Set<String>)] = [
            ("PDFs", ["pdf"]),
            ("Images", ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "svg", "raw", "psd"]),
            ("Videos", ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"]),
            ("Audio", ["mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg"]),
            ("Documents", ["doc", "docx", "pages", "rtf", "txt", "md", "odt", "epub"]),
            ("Spreadsheets", ["xls", "xlsx", "numbers", "csv", "tsv"]),
            ("Presentations", ["ppt", "pptx", "key"]),
            ("Archives", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]),
            ("Installers", ["dmg", "pkg", "iso"]),
            ("Code", ["swift", "py", "js", "ts", "json", "html", "css", "java", "c", "cpp", "go", "rs", "ipynb", "sh", "pem"]),
        ]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return urls.compactMap { u in
            guard (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true || u.pathExtension == "app" else { return nil }
            let ext = u.pathExtension.lowercased()
            guard !ext.isEmpty, !["crdownload", "download", "part"].contains(ext) else { return nil }   // still downloading
            let group = groups.first { $0.1.contains(ext) }?.0 ?? (ext == "app" ? "Apps" : "Other")
            return (u, folder.appendingPathComponent(group).appendingPathComponent(u.lastPathComponent))
        }
    }

    static func trash(_ urls: [URL]) async -> String {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return "none of those files exist" }
        let moved = (try? await NSWorkspace.shared.recycle(existing)) ?? [:]
        return "moved \(moved.count) of \(existing.count) to the Trash (recoverable from there)"
    }
}
