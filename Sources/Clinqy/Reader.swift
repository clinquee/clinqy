import AppKit
import PDFKit
import ScreenCaptureKit
import Vision

/// Reads what's in front of the user, from the best source available:
/// the document file behind the window (PDF, Word, RTF, text), a PDF open in the browser,
/// and — for scans, images and anything else — text recognition (OCR) on the window itself.
enum Reader {
    /// Text of the document a window has open (its AXDocument file), if it's a readable kind.
    static func documentText(of app: NSRunningApplication) async -> (name: String, text: String)? {
        guard let url = AXEngine.documentURL(of: app) else { return nil }
        return await fileText(url).map { (url.lastPathComponent, $0) }
    }

    /// Text of a local or downloadable file: PDFs through PDFKit, Word/RTF/HTML/text through AppKit.
    static func fileText(_ url: URL) async -> String? {
        guard !Task.isCancelled else { return nil }
        var local = url
        defer { if local != url { try? FileManager.default.removeItem(at: local) } }
        if !url.isFileURL {
            guard let (tmp, _) = try? await URLSession.shared.download(from: url) else { return nil }
            local = tmp
        }
        if url.pathExtension.lowercased() == "pdf" || isPDF(local) {
            guard let doc = PDFDocument(url: local) else { return nil }
            var text = ""
            var page = 0
            // Bound scanned/empty PDFs as well as text-rich documents.
            while page < min(doc.pageCount, 100), text.count < 12_000 {
                guard !Task.isCancelled else { return nil }
                text += (doc.page(at: page)?.string ?? "") + "\n\n"
                page += 1
            }
            return clean(text).map { $0 + (page < doc.pageCount ? "\n[excerpt truncated]" : "") }
        }
        let plain = ["txt", "md", "csv", "tsv", "json", "log", "swift", "py", "js", "ts", "rs", "xml", "yaml", "yml"]
        if plain.contains(url.pathExtension.lowercased()), let handle = try? FileHandle(forReadingFrom: local) {
            defer { try? handle.close() }
            let bytes = handle.readData(ofLength: 64_001)
            return clean(String(decoding: bytes.prefix(64_000), as: UTF8.self)).map {
                $0 + (bytes.count > 64_000 ? "\n[excerpt truncated]" : "")
            }
        }
        // Rich document importers allocate the entire document; refuse unbounded input.
        guard let size = try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000,
              !Task.isCancelled else { return nil }
        if let attributed = try? NSAttributedString(url: local, options: [:], documentAttributes: nil) {
            return clean(attributed.string)
        }
        return (try? String(contentsOf: local, encoding: .utf8)).flatMap(clean)
    }

    /// Recognizes the text on the app's frontmost window (works on scans, images, canvases, PDFs as pictures).
    static func ocr(_ app: NSRunningApplication, window: NativeWindowObservation? = nil) async -> String? {
        guard let capture = await windowCapture(app, window: window) else { return nil }
        return await ocr(image: capture.image)
    }

    static func ocr(_ capture: Screenshot.Capture) async -> String? {
        guard capture.window.staleness(includeContent: true) == nil else { return nil }
        return await ocr(image: capture.rawImage)
    }

    private static func ocr(image: CGImage) async -> String? {
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return clean(lines.joined(separator: "\n"))
        }.value
    }

    /// Each piece of text on the app's window with where it is on screen (global top-left points, like element
    /// frames), for clicking things the Accessibility tree doesn't show (WhatsApp's chats, canvases, custom UI).
    /// `want`, when given, is boxed on its own where a line holds more (the "Archive" in "Archive chat").
    static func textBoxes(_ app: NSRunningApplication, window: NativeWindowObservation? = nil, want: String? = nil) async -> [(text: String, rect: CGRect)]? {
        guard let capture = await windowCapture(app, window: window) else { return nil }
        return await textBoxes(image: capture.image, frame: capture.frame, want: want)
    }

    static func textBoxes(_ capture: Screenshot.Capture, want: String? = nil) async -> [(text: String, rect: CGRect)]? {
        guard capture.window.staleness(includeContent: true) == nil else { return nil }
        return await textBoxes(image: capture.rawImage, frame: capture.window.frame, want: want)
    }

    private static func textBoxes(image: CGImage, frame: CGRect, want: String?) async -> [(text: String, rect: CGRect)] {
        return await Task.detached(priority: .userInitiated) { () -> [(text: String, rect: CGRect)] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false   // labels and names, not prose
            try? VNImageRequestHandler(cgImage: image).perform([request])
            // Vision's boxes are 0…1 with the origin at the bottom left.
            let place = { (b: CGRect) in
                CGRect(x: frame.minX + b.minX * frame.width, y: frame.minY + (1 - b.maxY) * frame.height,
                       width: b.width * frame.width, height: b.height * frame.height)
            }
            var out: [(text: String, rect: CGRect)] = []
            for case let candidate? in (request.results ?? []).map({ $0.topCandidates(1).first }) {
                let line = candidate.string
                if let want, !want.isEmpty, let range = line.range(of: want, options: [.caseInsensitive, .diacriticInsensitive]),
                   range != line.startIndex..<line.endIndex, let part = try? candidate.boundingBox(for: range) {
                    out.append((String(line[range]), place(part.boundingBox)))
                }
                if let whole = try? candidate.boundingBox(for: line.startIndex..<line.endIndex) {
                    out.append((line, place(whole.boundingBox)))
                }
            }
            return out
        }.value
    }

    /// Capture only the selected AX window; another, larger window of the app must never substitute for it.
    private static func windowCapture(_ app: NSRunningApplication, window requested: NativeWindowObservation?) async -> (image: CGImage, frame: CGRect)? {
        guard let snapshot = requested ?? NativeWindowObservation.capture(app), snapshot.pid == app.processIdentifier,
              snapshot.staleness(includeContent: true) == nil, CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.owningApplication?.processID == snapshot.pid && $0.windowID == snapshot.windowID }),
              ObservationGeometry(frame: snapshot.frame, imageSize: CGSize(width: 1, height: 1)).matches(window.frame)
        else { return nil }
        let config = SCStreamConfiguration()
        // Full resolution for OCR. Geometry stays in screen points regardless of the backing pixel scale.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                      configuration: config),
              snapshot.staleness(includeContent: true) == nil else { return nil }
        return (image, snapshot.frame)
    }

    private static func isPDF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return handle.readData(ofLength: 5) == Data("%PDF-".utf8)
    }

    private static func clean(_ text: String) -> String? {
        let t = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(12_000))
    }
}
