import AppKit
import PDFKit
import Quartz
import Vision

/// iLovePDF-style file jobs done in the background with macOS's own frameworks: no app window opens
/// (except iWork exporting PowerPoint/Excel/Keynote/Numbers files, which runs hidden and quits again).
enum Pdf {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static let ops = ["merge", "split", "extract", "delete_pages", "rotate", "reorder", "compress", "to_pdf",
                      "to_images", "to_word", "to_text", "protect", "unlock", "watermark", "page_numbers", "ocr", "info"]

    static let imageTypes: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
    static let textTypes: Set<String> = ["txt", "rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive", "md", "wordml"]

    /// Runs one job; returns a line for the agent (what was saved where, and sizes).
    static func run(_ op: String, files: [URL], options o: [String: Any]) async throws -> String {
        guard !files.isEmpty || op == "info" else { throw Failure("no files given") }
        for f in files where !FileManager.default.fileExists(atPath: f.path) { throw Failure("no such file: \(f.path)") }
        let pages = o["pages"] as? String
        let overwrite = o["overwrite"] as? Bool == true
        // An explicit output path may not be one of the inputs, and an existing file there is only replaced when asked to.
        let folderOp = op == "split" || op == "to_images"
        let out = try (o["out"] as? String).map { raw -> URL in
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            return folderOp ? try resolveFolder(url, sources: files) : try resolveOutput(url, sources: files, overwrite: overwrite)
        }

        switch op {
        case "merge":
            guard files.count >= 2 else { throw Failure("merge needs 2+ files") }
            let merged = PDFDocument()
            for f in files {
                let doc = try await asPDF(f)
                for i in 0..<doc.pageCount { if let p = doc.page(at: i)?.copy() as? PDFPage { merged.insert(p, at: merged.pageCount) } }
            }
            let dest = out ?? output(for: files[0], suffix: "merged")
            try save(merged, to: dest)
            return "merged \(files.count) files (\(merged.pageCount) pages) → \(describe(dest))"

        case "split":
            let doc = try open(files[0])
            let groups: [[Int]]
            if let pages, pages.lowercased() != "each" {
                groups = pages.split(separator: ",").map { try? pageList(String($0), count: doc.pageCount) }.compactMap { $0 }
                guard !groups.isEmpty else { throw Failure("couldn't understand pages \(pages)") }
            } else {
                groups = (0..<doc.pageCount).map { [$0] }
            }
            let folder = out ?? unique(files[0].deletingLastPathComponent()
                .appendingPathComponent(files[0].deletingPathExtension().lastPathComponent + "-split"))
            let stem = files[0].deletingPathExtension().lastPathComponent
            try inFolder(folder, overwrite: overwrite) { place in
                for group in groups {
                    let name = group.count == 1 ? "\(stem)-p\(group[0] + 1).pdf" : "\(stem)-p\(group[0] + 1)-\(group.last! + 1).pdf"
                    try save(subset(doc, group), to: place(name))
                }
            }
            return "split into \(groups.count) files in \(folder.path)"

        case "extract":
            guard let pages else { throw Failure("extract needs pages, e.g. \"1-3,5\"") }
            let doc = try open(files[0])
            let dest = out ?? output(for: files[0], suffix: "pages-\(pages.replacingOccurrences(of: ",", with: "_"))")
            try save(subset(doc, try pageList(pages, count: doc.pageCount)), to: dest)
            return "extracted pages \(pages) → \(describe(dest))"

        case "delete_pages":
            guard let pages else { throw Failure("delete_pages needs pages") }
            let doc = try open(files[0])
            let drop = Set(try pageList(pages, count: doc.pageCount))
            guard drop.count < doc.pageCount else { throw Failure("that would delete every page") }
            let dest = out ?? output(for: files[0], suffix: "edited")
            try save(subset(doc, (0..<doc.pageCount).filter { !drop.contains($0) }), to: dest)
            return "removed \(drop.count) pages → \(describe(dest))"

        case "rotate":
            let degrees = (o["degrees"] as? Int) ?? 90
            guard degrees % 90 == 0 else { throw Failure("degrees must be a multiple of 90") }
            let doc = try open(files[0])
            for i in try pages.map({ try pageList($0, count: doc.pageCount) }) ?? Array(0..<doc.pageCount) {
                if let p = doc.page(at: i) { p.rotation = ((p.rotation + degrees) % 360 + 360) % 360 }
            }
            let dest = out ?? output(for: files[0], suffix: "rotated")
            try save(doc, to: dest)
            return "rotated \(degrees)° → \(describe(dest))"

        case "reorder":
            guard let order = o["order"] as? String else { throw Failure("reorder needs order, e.g. \"3,1,2\"") }
            let doc = try open(files[0])
            let dest = out ?? output(for: files[0], suffix: "reordered")
            try save(subset(doc, try pageList(order, count: doc.pageCount)), to: dest)
            return "reordered → \(describe(dest))"

        case "compress":
            return try compress(files, level: (o["level"] as? String) ?? "recommended", out: out)

        case "to_pdf":
            var made: [URL] = []
            do {
                for f in files {
                    let doc = try await asPDF(f)
                    let dest = files.count == 1 ? (out ?? output(for: f, suffix: nil)) : output(for: f, suffix: nil)
                    try save(doc, to: dest)
                    made.append(dest)
                }
            } catch {
                // With several inputs every output is a fresh file made by this job (never an explicit, pre-existing path).
                if files.count > 1 { for m in made { try? FileManager.default.removeItem(at: m) } }
                throw error
            }
            if o["combine"] as? Bool == true, made.count > 1 {
                let merged = PDFDocument()
                for m in made { if let d = PDFDocument(url: m) { for i in 0..<d.pageCount { if let p = d.page(at: i) { merged.insert(p, at: merged.pageCount) } } } }
                let dest = out ?? output(for: files[0], suffix: "combined")
                try save(merged, to: dest)
                for m in made { try? FileManager.default.removeItem(at: m) }
                return "made one PDF from \(files.count) files → \(describe(dest))"
            }
            return "converted → " + made.map(describe).joined(separator: "; ")

        case "to_images":
            let format = ((o["format"] as? String) ?? "png").lowercased()
            let dpi = Double((o["dpi"] as? Int) ?? 150)
            let doc = try open(files[0])
            let folder = out ?? unique(files[0].deletingLastPathComponent()
                .appendingPathComponent(files[0].deletingPathExtension().lastPathComponent + "-images"))
            let stem = files[0].deletingPathExtension().lastPathComponent
            let list = try pages.map { try pageList($0, count: doc.pageCount) } ?? Array(0..<doc.pageCount)
            try inFolder(folder, overwrite: overwrite) { place in
                for i in list {
                    guard let page = doc.page(at: i), let image = render(page, scale: dpi / 72) else { continue }
                    let rep = NSBitmapImageRep(cgImage: image)
                    let data = format == "png" ? rep.representation(using: .png, properties: [:])
                        : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
                    guard let data else { throw Failure("couldn't encode page \(i + 1)") }
                    try data.write(to: place("\(stem)-\(i + 1).\(format == "png" ? "png" : "jpg")"))
                }
            }
            return "saved \(list.count) \(format == "png" ? "PNG" : "JPG") images in \(folder.path)"

        case "to_word", "to_text":
            // Text and basic formatting only (fonts, bold, paragraphs); layout, columns and images don't come across.
            let word = op == "to_word"
            var made: [String] = []
            for f in files {
                let doc = try open(f)
                let text = NSMutableAttributedString()
                var scanned = 0
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    if i > 0 { text.append(NSAttributedString(string: "\n\n")) }
                    if let a = page.attributedString, !a.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        text.append(a)
                    } else if let seen = recognise(page) {
                        text.append(NSAttributedString(string: seen, attributes: [.font: NSFont.systemFont(ofSize: 11)]))
                        scanned += 1
                    }
                }
                guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("no text found in \(f.lastPathComponent)") }
                let dest = files.count == 1 ? (out ?? output(for: f, suffix: nil, ext: word ? "docx" : "txt")) : output(for: f, suffix: nil, ext: word ? "docx" : "txt")
                if word {
                    let data = try text.data(from: NSRange(location: 0, length: text.length),
                                             documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
                    try data.write(to: dest)
                } else {
                    try text.string.write(to: dest, atomically: true, encoding: .utf8)
                }
                made.append(describe(dest) + (scanned > 0 ? " (\(scanned) scanned pages read with text recognition)" : ""))
            }
            return "converted → " + made.joined(separator: "; ")

        case "protect":
            guard let password = o["password"] as? String, !password.isEmpty else { throw Failure("protect needs password") }
            let doc = try open(files[0])
            let dest = out ?? output(for: files[0], suffix: "protected")
            guard doc.write(to: dest, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]) else { throw Failure("couldn't write \(dest.path)") }
            return "password-protected → \(describe(dest))"

        case "unlock":
            guard let password = o["password"] as? String else { throw Failure("unlock needs password") }
            guard let doc = CGPDFDocument(files[0] as CFURL) else { throw Failure("not a PDF: \(files[0].lastPathComponent)") }
            if doc.isEncrypted, !doc.unlockWithPassword(password) { throw Failure("wrong password") }
            let dest = out ?? output(for: files[0], suffix: "unlocked")
            try redraw(doc, to: dest) { _, _, _ in }
            return "unlocked → \(describe(dest))"

        case "watermark":
            guard let text = o["text"] as? String, !text.isEmpty else { throw Failure("watermark needs text") }
            guard let doc = CGPDFDocument(files[0] as CFURL) else { throw Failure("not a PDF") }
            let dest = out ?? output(for: files[0], suffix: "watermarked")
            try redraw(doc, to: dest) { ctx, box, _ in
                let size = min(box.width, box.height) / CGFloat(max(6, text.count)) * 1.6
                let line = ctLine(text, size: size, color: NSColor(white: 0.5, alpha: 0.28))
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.saveGState()
                ctx.translateBy(x: box.midX, y: box.midY)
                ctx.rotate(by: atan2(box.height, box.width))
                ctx.textPosition = CGPoint(x: -w / 2, y: -size / 3)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            return "watermarked “\(text)” → \(describe(dest))"

        case "page_numbers":
            guard let doc = CGPDFDocument(files[0] as CFURL) else { throw Failure("not a PDF") }
            let total = doc.numberOfPages
            let dest = out ?? output(for: files[0], suffix: "numbered")
            try redraw(doc, to: dest) { ctx, box, n in
                let line = ctLine("\(n) / \(total)", size: 10, color: .darkGray)
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.textPosition = CGPoint(x: box.midX - w / 2, y: box.minY + 20)
                CTLineDraw(line, ctx)
            }
            return "numbered \(total) pages → \(describe(dest))"

        case "ocr":
            let dest = out ?? output(for: files[0], suffix: "searchable")
            let n = try ocr(try await asPDF(files[0]), to: dest)
            return "made searchable (\(n) pages recognised) → \(describe(dest))"

        case "info":
            return try files.map { f in
                let doc = try open(f, allowLocked: true)
                let size = doc.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
                let text = (doc.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(f.lastPathComponent): \(doc.pageCount) pages, \(bytes(f)), \(Int(size.width))×\(Int(size.height)) pt"
                    + (doc.isLocked ? ", password-protected" : "") + (text.isEmpty && !doc.isLocked ? ", no text layer (scan?)" : "")
            }.joined(separator: "\n")

        default:
            throw Failure("unknown op \(op); use one of \(ops.joined(separator: ", "))")
        }
    }

    // MARK: - Compress

    private static func compress(_ files: [URL], level: String, out: URL?) throws -> String {
        try files.map { f in
            let doc = try open(f)
            let dest = files.count == 1 ? (out ?? output(for: f, suffix: "compressed")) : output(for: f, suffix: "compressed")
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            // Re-encode images as JPEG at the level's quality and resolution (a Quartz filter, like Preview's
            // "Reduce File Size", but tunable); PDFKit's own screen optimisation is a second candidate.
            let (quality, dpi, maxSide): (Double, Int, Int) = switch level {
            case "light", "low": (0.85, 220, 3200)
            case "extreme", "strong", "max", "high": (0.5, 96, 1600)
            default: (0.72, 150, 2400)
            }
            var candidates: [URL] = []
            let filterURL = tmp.appendingPathComponent("compress.qfilter")
            let plist: [String: Any] = ["Domains": ["Applications": true], "FilterType": 1, "Name": "Clinqy Compress",
                "FilterData": ["ColorSettings": ["ImageSettings": ["Compression Quality": quality, "ImageCompression": "ImageJPEGCompress",
                    "ImageScaleSettings": ["ImageResolution": dpi, "ImageScaleInterpolate": true, "ImageSizeMax": maxSide, "ImageSizeMin": 0]]]]]
            if (plist as NSDictionary).write(to: filterURL, atomically: true), let filter = QuartzFilter(url: filterURL) {
                let filtered = tmp.appendingPathComponent("filtered.pdf")
                if doc.write(to: filtered, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) { candidates.append(filtered) }
            }
            let screen = tmp.appendingPathComponent("screen.pdf")
            if doc.write(to: screen, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) { candidates.append(screen) }
            let original = fileSize(f)
            guard let best = candidates.min(by: { fileSize($0) < fileSize($1) }), fileSize(best) < original * 97 / 100 else {
                return "\(f.lastPathComponent) is already as small as it gets at this level (\(bytes(f)))\(quality > 0.5 ? "; level \"extreme\" may shrink it further at lower image quality" : "")"
            }
            let staged = scratch(for: dest)
            try FileManager.default.copyItem(at: best, to: staged)
            try commit(staged, to: dest)
            let saved = 100 - Int(Double(fileSize(dest)) / Double(max(original, 1)) * 100)
            return "compressed \(f.lastPathComponent): \(bytes(f)) → \(bytes(dest)) (−\(saved)%) → \(dest.path)"
        }.joined(separator: "\n")
    }

    // MARK: - Converting anything to a PDF

    /// A PDF for `url`: the file itself, or converted from an image, text/Word document, or iWork/Office file.
    static func asPDF(_ url: URL) async throws -> PDFDocument {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return try open(url) }
        if imageTypes.contains(ext) {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { throw Failure("couldn't read image \(url.lastPathComponent)") }
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            return doc
        }
        if let app = iWorkApp(for: ext), let doc = try await exportWithIWork(url, app: app) { return doc }
        if textTypes.contains(ext) { return try textToPDF(url) }
        if ["ppt", "pptx", "key", "xls", "xlsx", "numbers", "pages"].contains(ext) {
            throw Failure("converting .\(ext) needs Keynote/Numbers/Pages installed (free on the App Store)")
        }
        throw Failure("can't convert .\(ext) files to PDF")
    }

    private static func iWorkApp(for ext: String) -> String? {
        let app: String? = switch ext {
        case "ppt", "pptx", "key": "Keynote"
        case "xls", "xlsx", "numbers", "csv": "Numbers"
        case "pages", "doc", "docx": "Pages"
        default: nil
        }
        guard let app, NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.\(app)") != nil else { return nil }
        return app
    }

    /// Opens the file in the iWork app without bringing it forward, exports a PDF, closes it (and quits the app
    /// if it wasn't already running).
    private static func exportWithIWork(_ url: URL, app: String) async throws -> PDFDocument? {
        let wasRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.iWork.\(app)" }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let q = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = """
        tell application "\(app)"
            set d to open (POSIX file "\(q(url.path))" as alias)
            export d to (POSIX file "\(q(dest.path))") as PDF
            close d saving no
            \(wasRunning ? "" : "quit")
        end tell
        """
        let r = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120)
        defer { try? FileManager.default.removeItem(at: dest) }
        guard r.status == 0, let data = try? Data(contentsOf: dest), let doc = PDFDocument(data: data) else { return nil }
        return doc
    }

    /// Lays out a text/RTF/Word/HTML document on A4 pages (via textutil for the formats AppKit can't read directly).
    private static func textToPDF(_ url: URL) throws -> PDFDocument {
        var source = url
        var cleanup: URL?
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        if !["txt", "rtf", "md"].contains(url.pathExtension.lowercased()) {
            let rtf = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".rtf")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            p.arguments = ["-convert", "rtf", url.path, "-output", rtf.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw Failure("couldn't read \(url.lastPathComponent)") }
            source = rtf
            cleanup = rtf
        }
        let text: NSAttributedString
        if ["txt", "md"].contains(source.pathExtension.lowercased()) {
            let plain = try String(contentsOf: source, encoding: .utf8)
            text = NSAttributedString(string: plain, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
        } else {
            text = try NSAttributedString(url: source, options: [:], documentAttributes: nil)
        }
        let pageSize = CGSize(width: 595, height: 842), margin: CGFloat = 56
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        repeat {
            let c = NSTextContainer(size: CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin))
            layout.addTextContainer(c)
            containers.append(c)
            layout.ensureLayout(for: c)
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 2000

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw Failure("couldn't make a PDF") }
        for c in containers {
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)   // AppKit text draws top-down
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let range = layout.glyphRange(for: c)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard let doc = PDFDocument(data: data as Data) else { throw Failure("couldn't make a PDF") }
        return doc
    }

    // MARK: - OCR

    /// Each page as it was, plus an invisible text layer where Vision reads text (pages that already have text are kept as is).
    private static func ocr(_ doc: PDFDocument, to dest: URL) throws -> Int {
        guard let ctx = CGContext(dest as CFURL, mediaBox: nil, nil) else { throw Failure("couldn't write \(dest.path)") }
        var recognised = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = pageBox(page)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            page.draw(with: .mediaBox, to: ctx)
            if (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let image = render(page, scale: 2.5) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: image).perform([request])
                ctx.setTextDrawingMode(.invisible)
                for obs in request.results ?? [] {
                    guard let text = obs.topCandidates(1).first?.string else { continue }
                    let r = VNImageRectForNormalizedRect(obs.boundingBox, Int(box.width), Int(box.height))
                    let line = ctLine(text, size: max(4, r.height * 0.85), color: .black)
                    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                    ctx.saveGState()
                    ctx.translateBy(x: r.minX, y: r.minY + r.height * 0.15)
                    if w > 0 { ctx.scaleBy(x: r.width / w, y: 1) }
                    ctx.textPosition = .zero
                    CTLineDraw(line, ctx)
                    ctx.restoreGState()
                }
                ctx.setTextDrawingMode(.fill)
                recognised += 1
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return recognised
    }

    /// The text Vision reads on a page with no text layer (a scan), line by line.
    private static func recognise(_ page: PDFPage) -> String? {
        guard let image = render(page, scale: 2.5) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    static func open(_ url: URL, allowLocked: Bool = false) throws -> PDFDocument {
        guard url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: url) else { throw Failure("not a PDF: \(url.lastPathComponent)") }
        if doc.isLocked, !allowLocked { throw Failure("\(url.lastPathComponent) is password-protected; unlock it first") }
        return doc
    }

    private static func save(_ doc: PDFDocument, to dest: URL) throws {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written beside the destination and moved into place, so a failure never leaves a partial file or damages an existing one.
        let temp = scratch(for: dest)
        guard doc.write(to: temp) else { try? FileManager.default.removeItem(at: temp); throw Failure("couldn't write \(dest.path)") }
        try commit(temp, to: dest)
    }

    // MARK: - Output paths

    /// Whether two URLs name the same file (same path once resolved, or the same inode, which also catches hard links).
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let pa = a.resolvingSymlinksInPath().standardizedFileURL.path, pb = b.resolvingSymlinksInPath().standardizedFileURL.path
        if pa == pb || pa.lowercased() == pb.lowercased() && caseInsensitiveVolume(a) { return true }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let x = try? a.resourceValues(forKeys: keys).fileResourceIdentifier,
              let y = try? b.resourceValues(forKeys: keys).fileResourceIdentifier else { return false }
        return x.isEqual(y)
    }

    private static func caseInsensitiveVolume(_ url: URL) -> Bool {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe = probe.deletingLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) != true
    }

    /// An explicit output file: never one of the inputs; an existing file there is replaced only when `overwrite` is set,
    /// otherwise the result gets a free numbered name next to it (the reply states the real path).
    static func resolveOutput(_ out: URL, sources: [URL], overwrite: Bool) throws -> URL {
        if let clash = sources.first(where: { sameFile($0, out) }) {
            throw Failure("the output path \(out.path) is the same file as the input \(clash.lastPathComponent); choose a different output")
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: out.path, isDirectory: &isDir) {
            if isDir.boolValue { throw Failure("the output path \(out.path) is a folder; give a file name") }
            return overwrite ? out : unique(out)
        }
        return out
    }

    /// An explicit output folder: it may already exist, but it can't be a file or an input.
    static func resolveFolder(_ out: URL, sources: [URL]) throws -> URL {
        if let clash = sources.first(where: { sameFile($0, out) }) {
            throw Failure("the output folder \(out.path) is the same path as the input \(clash.lastPathComponent)")
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: out.path, isDirectory: &isDir), !isDir.boolValue {
            throw Failure("the output path \(out.path) is a file; give a folder")
        }
        return out
    }

    /// Runs `body` with a function that names each output file inside `folder` (numbered when the name is taken, unless
    /// `overwrite`). If the job fails, only the files and folder this job created are removed.
    static func inFolder(_ folder: URL, overwrite: Bool, _ body: ((String) -> URL) throws -> Void) throws {
        let fm = FileManager.default
        let folderExisted = fm.fileExists(atPath: folder.path)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var created: [URL] = []
        var claimed = Set<String>()
        func place(_ name: String) -> URL {
            var url = folder.appendingPathComponent(name)
            if !overwrite || claimed.contains(url.path) { url = unique(url) }
            while claimed.contains(url.path) { url = unique(url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "_")) }
            claimed.insert(url.path)
            if !fm.fileExists(atPath: url.path) { created.append(url) }
            return url
        }
        do { try body(place) } catch {
            for url in created { try? fm.removeItem(at: url) }
            if !folderExisted, ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["x"]).isEmpty { try? fm.removeItem(at: folder) }
            throw error
        }
    }

    /// A hidden sibling of `dest` to write into before moving into place.
    static func scratch(for dest: URL) -> URL {
        dest.deletingLastPathComponent().appendingPathComponent(".clinqy-\(UUID().uuidString.prefix(8))-" + dest.lastPathComponent)
    }

    /// Moves a finished temp file to `dest`, replacing what is there (the caller has already decided that's allowed).
    static func commit(_ temp: URL, to dest: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: temp) } else { try fm.moveItem(at: temp, to: dest) }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    private static func subset(_ doc: PDFDocument, _ indices: [Int]) -> PDFDocument {
        let out = PDFDocument()
        for i in indices { if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) } }
        return out
    }

    /// "1-3,5,8-" (1-based, "8-" = to the end, "last" = the last page) → 0-based indices in that order.
    static func pageList(_ spec: String, count: Int) throws -> [Int] {
        var result: [Int] = []
        for raw in spec.lowercased().replacingOccurrences(of: "last", with: "\(count)").split(separator: ",") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard ends.count <= 2, let a = Int(ends[0].isEmpty ? "1" : ends[0]),
                  let b = ends.count == 2 ? Int(ends[1].isEmpty ? "\(count)" : ends[1]) : a,
                  a >= 1, b >= 1, a <= count, b <= count else { throw Failure("bad pages “\(part)” (the file has \(count) pages)") }
            result += a <= b ? Array((a - 1)...(b - 1)) : Array(stride(from: a - 1, through: b - 1, by: -1))
        }
        guard !result.isEmpty else { throw Failure("no pages in “\(spec)”") }
        return result
    }

    /// The page's visible size, rotation applied.
    private static func pageBox(_ page: PDFPage) -> CGRect {
        let b = page.bounds(for: .mediaBox)
        return page.rotation % 180 == 0 ? CGRect(origin: .zero, size: b.size) : CGRect(x: 0, y: 0, width: b.height, height: b.width)
    }

    private static func render(_ page: PDFPage, scale: Double) -> CGImage? {
        let box = pageBox(page)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Copies every page into a new PDF, calling `stamp` to draw on top of each (page box, 1-based number).
    private static func redraw(_ doc: CGPDFDocument, to dest: URL, stamp: (CGContext, CGRect, Int) -> Void) throws {
        guard let ctx = CGContext(dest as CFURL, mediaBox: nil, nil) else { throw Failure("couldn't write \(dest.path)") }
        for n in 1...max(1, doc.numberOfPages) {
            guard let page = doc.page(at: n) else { continue }
            let media = page.getBoxRect(.mediaBox)
            var box = page.rotationAngle % 180 == 0 ? CGRect(origin: .zero, size: media.size)
                : CGRect(x: 0, y: 0, width: media.height, height: media.width)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.saveGState()
            ctx.concatenate(page.getDrawingTransform(.mediaBox, rect: box, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            ctx.restoreGState()
            stamp(ctx, box, n)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private static func ctLine(_ text: String, size: CGFloat, color: NSColor) -> CTLine {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font,
                                                    .init(kCTForegroundColorAttributeName as String): color.cgColor]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    /// `name-suffix.pdf` next to the source, never overwriting anything.
    static func output(for source: URL, suffix: String?, ext: String = "pdf") -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        return unique(source.deletingLastPathComponent().appendingPathComponent(stem + (suffix.map { "-\($0)" } ?? "") + ".\(ext)"))
    }

    static func unique(_ url: URL) -> URL {
        var candidate = url, n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let ext = url.pathExtension
            let name = url.deletingPathExtension().lastPathComponent + " \(n)"
            candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            n += 1
        }
        return candidate
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private static func bytes(_ url: URL) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize(url)), countStyle: .file)
    }

    private static func describe(_ url: URL) -> String { "\(url.path) (\(bytes(url)))" }
}

/// Sends email through the Mail app with AppleScript: no compose window, nothing to click.
enum Mailer {
    static func send(to: [String], cc: [String], subject: String, body: String, attachments: [URL], draft: Bool) async -> (ok: Bool, message: String) {
        let q = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let recipients = to.map { "make new to recipient at end of to recipients with properties {address:\"\(q($0))\"}" }
            + cc.map { "make new cc recipient at end of cc recipients with properties {address:\"\(q($0))\"}" }
        let files = attachments.map { "make new attachment with properties {file name:(POSIX file \"\(q($0.path))\" as alias)} at after the last paragraph" }
        let script = """
        tell application "Mail"
            if (count of accounts) is 0 then error "Mail has no email account set up"
            set m to make new outgoing message with properties {subject:"\(q(subject))", content:"\(q(body))" & return & return, visible:\(draft ? "true" : "false")}
            tell m
                \(recipients.joined(separator: "\n            "))
                \(files.joined(separator: "\n            "))
            end tell
            delay \(attachments.isEmpty ? 0.3 : 1.5)
            \(draft ? "activate" : "send m")
        end tell
        """
        let r = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 60)
        return (r.status == 0, r.output)
    }
}
