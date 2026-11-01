import AppKit
import ScreenCaptureKit

/// Captures the target app's window and draws numbered boxes over the elements we'll offer GPT,
/// so it sees the real screen and can refer to elements by the same "e<N>" ids.
enum Screenshot {
    /// Immutable capture passed with the observation. Resizing for the byte budget is reflected in geometry.
    struct Capture: @unchecked Sendable {
        let window: NativeWindowObservation
        let image: CGImage
        let rawImage: CGImage
        let data: Data
        let geometry: ObservationGeometry
        /// Set when the image is valid but flat (one colour): the content is real, but may be a loading or blank window.
        var notice: String? = nil
        var imageSize: CGSize { geometry.imageSize }
        var base64: String { data.base64EncodedString() }
        var pointScale: CGSize { geometry.pointScale }
        func screenPoint(x: Double, y: Double) -> CGPoint? {
            guard window.staleness(includeContent: true) == nil else { return nil }
            return geometry.screenPoint(x: x, y: y)
        }

        /// Raw pixel actions also compare the target's current visual neighbourhood. Canvas-only changes may
        /// leave AX untouched; checking a fresh patch prevents clicking old screenshot coordinates in that case.
        func validatedScreenPoint(x: Double, y: Double) async -> CGPoint? {
            guard let point = screenPoint(x: x, y: y),
                  let fresh = await Screenshot.currentImage(window: window, width: rawImage.width, height: rawImage.height),
                  let oldPatch = Screenshot.targetPatch(rawImage, x: x / imageSize.width, y: y / imageSize.height),
                  let newPatch = Screenshot.targetPatch(fresh, x: x / imageSize.width, y: y / imageSize.height),
                  ObservationGeometry.visuallyMatches(oldPatch, newPatch), window.staleness(includeContent: true) == nil else { return nil }
            return point
        }
    }
    /// Debug-only image cache. Action targeting must use Capture, never these diagnostic values.
    nonisolated(unsafe) private static var lastWindowFrame: CGRect?
    /// The last annotated capture (what the model saw) and whose window it was, for click traces.
    nonisolated(unsafe) static var lastImage: CGImage?
    nonisolated(unsafe) static var lastPID: pid_t?
    /// Set when the last `annotated` capture came back blank (and nil was returned instead of an image),
    /// so the caller can tell the model why there's no screenshot rather than send a useless one.
    nonisolated(unsafe) static var lastBlank: Blankness?

    /// Bounded image budget; Capture geometry always reflects the actual encoded dimensions.
    static var maxSide: CGFloat { CGFloat(min(3840, max(640, Int(Config.value("VISION_MAX_SIDE") ?? "1920") ?? 1920))) }
    static var maxBytes: Int { min(2_000_000, max(100_000, Int(Config.value("VISION_MAX_BYTES") ?? "800000") ?? 800_000)) }

    /// Why a capture produced no image, so a caller can tell a missing permission from a stale window.
    enum CaptureError: Error, Equatable {
        case noObservation, staleWindow, provenanceMismatch, permissionMissing, windowUnavailable, geometryMismatch
        case captureFailed, allBlack, encodingFailed

        var hint: String {
            switch self {
            case .noObservation: return "No observed native window to capture; look again."
            case .staleWindow: return "The window changed since it was observed; look again."
            case .provenanceMismatch: return "The element list belongs to a different observation than the window; look again."
            case .permissionMissing: return "Screen Recording permission is missing, so no screenshot can be taken."
            case .windowUnavailable: return "The window is not available to the screen recorder (minimized, on another Space or closed)."
            case .geometryMismatch: return "The window's frame and the screen recorder disagree; look again."
            case .captureFailed: return "The screen recorder returned no image."
            case .allBlack: return Blankness.allBlack.hint
            case .encodingFailed: return "The image could not be encoded within the size budget."
            }
        }
    }
    /// The reason the last `capture` returned nil.
    nonisolated(unsafe) static var lastError: CaptureError?

    /// How much detail a capture keeps. Standard never exceeds one pixel per point; high allows up to the display's
    /// backing scale (still within the longest-side and byte budgets).
    enum Detail { case standard, high }
    static var defaultDetail: Detail { Config.value("VISION_DETAIL")?.lowercased() == "high" ? .high : .standard }

    /// Backing scale of the display that holds most of `frame` (global top-left points).
    static func backingScale(for frame: CGRect) -> CGFloat {
        var best: (area: CGFloat, scale: CGFloat) = (0, NSScreen.main?.backingScaleFactor ?? 2)
        for screen in NSScreen.screens {
            let overlap = AXEngine.flipped(screen.frame).intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > best.area { best = (area, screen.backingScaleFactor) }
        }
        return best.scale
    }

    /// A capture with no visual detail. All black almost always means Screen Recording permission is
    /// missing (macOS hands back empty frames instead of failing) or the window is covered/minimized.
    enum Blankness: String {
        case allBlack = "all_black", allWhite = "all_white", uniform

        var hint: String {
            switch self {
            case .allBlack: return "The screenshot came back all black: Screen Recording permission is likely missing, or the window is minimized/covered. Don't rely on the image."
            case .allWhite: return "The screenshot came back all white: the window is likely blank or still loading. Wait a moment and look again."
            case .uniform: return "The screenshot came back a single flat color with no detail: the window may be loading, covered, or on another Space."
            }
        }
    }

    /// Luminance mean/stddev on a 64×64 grayscale thumbnail; a stddev under 2 (of 255) means no detail.
    static func blankness(_ image: CGImage) -> Blankness? {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let n = Double(pixels.count)
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / n
        let std = (pixels.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / n).squareRoot()
        guard std < 2 else { return nil }
        return mean < 5 ? .allBlack : mean > 250 ? .allWhite : .uniform
    }

    private static func currentImage(window snapshot: NativeWindowObservation, width: Int, height: Int) async -> CGImage? {
        guard snapshot.staleness(includeContent: true) == nil, CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.owningApplication?.processID == snapshot.pid && $0.windowID == snapshot.windowID }) else { return nil }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
    }

    /// A local target patch in grayscale. Normalized x/y refer to top-left image coordinates.
    private static func targetPatch(_ image: CGImage, x: Double, y: Double) -> [UInt8]? {
        let side = 64
        let region = CGRect(x: x * Double(image.width) - 32, y: y * Double(image.height) - 32, width: 64, height: 64)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !region.isEmpty, let patch = image.cropping(to: region) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(patch, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? pixels : nil
    }

    /// A clean, full-resolution PNG of the app's main window (what ⌃⌘⇧4 on that window would copy).
    static func windowPNG(app: NSRunningApplication, windowID: CGWindowID? = nil) async -> Data? {
        let snapshot = NativeWindowObservation.capture(app, windowID: windowID)
        guard let snapshot, CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.owningApplication?.processID == snapshot.pid && $0.windowID == snapshot.windowID }),
              snapshot.staleness() == nil
        else { return nil }
        let config = SCStreamConfiguration()
        let scale = min(2, 2000 / window.frame.width)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func capture(app: NSRunningApplication, window snapshot: NativeWindowObservation?, elements: [UIElementInfo],
                        circled: Annotation? = nil, detail: Detail? = nil) async -> Capture? {
        switch await captureResult(app: app, window: snapshot, elements: elements, circled: circled, detail: detail ?? defaultDetail) {
        case .success(let capture): lastError = nil; return capture
        case .failure(let error): lastError = error; return nil
        }
    }

    static func captureResult(app: NSRunningApplication, window snapshot: NativeWindowObservation?, elements: [UIElementInfo],
                              circled: Annotation? = nil, detail: Detail = .standard) async -> Result<Capture, CaptureError> {
        lastBlank = nil
        guard let snapshot, snapshot.pid == app.processIdentifier else { return .failure(.noObservation) }
        guard snapshot.staleness(includeContent: true) == nil else { return .failure(.staleWindow) }
        guard elements.allSatisfy({ $0.observationID == snapshot.id && $0.windowID == snapshot.windowID }) else { return .failure(.provenanceMismatch) }
        guard CGPreflightScreenCaptureAccess() else { return .failure(.permissionMissing) }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.owningApplication?.processID == snapshot.pid && $0.windowID == snapshot.windowID })
        else { return .failure(.windowUnavailable) }
        guard ObservationGeometry(frame: snapshot.frame, imageSize: CGSize(width: 1, height: 1)).matches(window.frame) else { return .failure(.geometryMismatch) }

        let config = SCStreamConfiguration()
        // Long side, not width: a tall narrow window would otherwise blow past the budget.
        let ceiling = detail == .high ? backingScale(for: window.frame) : 1
        let scale = min(ceiling, maxSide / max(window.frame.width, window.frame.height))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return .failure(.captureFailed) }
        guard snapshot.staleness(includeContent: true) == nil else { return .failure(.staleWindow) }
        // A flat image whose provenance is valid is still the window's real content (a blank page, a loading
        // screen), so it is kept with a notice. Only all-black, the signature of withheld frames, is refused.
        var notice: String?
        if let blank = blankness(image) {
            if blank == .allBlack {
                lastBlank = blank
                lastImage = nil
                return .failure(.allBlack)
            }
            notice = blank.hint
        }

        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .failure(.encodingFailed) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Element frames are global top-left points; the window frame is in the same space.
        let sx = CGFloat(width) / window.frame.width, sy = CGFloat(height) / window.frame.height
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        let font = NSFont.boldSystemFont(ofSize: 11)
        for (i, el) in elements.enumerated() {
            let local = CGRect(x: (el.frame.minX - window.frame.minX) * sx,
                               y: CGFloat(height) - (el.frame.maxY - window.frame.minY) * sy,
                               width: el.frame.width * sx, height: el.frame.height * sy)
            guard local.intersects(CGRect(x: 0, y: 0, width: width, height: height)) else { continue }
            NSColor.systemRed.withAlphaComponent(0.85).setStroke()
            let box = NSBezierPath(rect: local)
            box.lineWidth = 1.5
            box.stroke()
            let tag = NSAttributedString(string: "e\(i)", attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = tag.size()
            let tagRect = CGRect(x: local.minX, y: min(local.maxY, CGFloat(height) - size.height - 2),
                                 width: size.width + 4, height: size.height + 1)
            NSColor.systemRed.setFill()
            NSBezierPath(rect: tagRect).fill()
            tag.draw(at: CGPoint(x: tagRect.minX + 2, y: tagRect.minY))
        }
        // What the user circled, drawn the way they drew it.
        if let circled, let first = circled.points.first {
            let local = { (p: CGPoint) in CGPoint(x: (p.x - window.frame.minX) * sx, y: CGFloat(height) - (p.y - window.frame.minY) * sy) }
            let loop = NSBezierPath()
            loop.move(to: local(first))
            circled.points.dropFirst().forEach { loop.line(to: local($0)) }
            loop.lineWidth = 4
            loop.lineJoinStyle = .round
            NSColor.systemYellow.setStroke()
            loop.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let annotated = ctx.makeImage(), let encoded = budgeted(annotated) else { return .failure(.encodingFailed) }
        guard snapshot.staleness(includeContent: true) == nil else { return .failure(.staleWindow) }
        lastImage = annotated
        lastPID = snapshot.pid
        lastWindowFrame = snapshot.frame
        return .success(Capture(window: snapshot, image: annotated, rawImage: image, data: encoded.data,
                                geometry: ObservationGeometry(frame: snapshot.frame, imageSize: encoded.size), notice: notice))
    }

    /// JPEG within `maxBytes`, returning the dimensions of the encoded image alongside its bytes.
    static func visionJPEG(_ data: Data) -> Data? {
        guard let bitmap = NSBitmapImageRep(data: data), var image = bitmap.cgImage else { return nil }
        let factor = min(1, maxSide / CGFloat(max(image.width, image.height)))
        if factor < 1 {
            guard let scaled = resized(image, by: factor) else { return nil }
            image = scaled
        }
        return budgeted(image)?.data
    }

    private static func budgeted(_ image: CGImage) -> (data: Data, size: CGSize)? {
        var image = image
        for _ in 0..<3 {
            for quality in [0.6, 0.45, 0.3] {
                guard let jpeg = NSBitmapImageRep(cgImage: image)
                    .representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return nil }
                if jpeg.count <= maxBytes { return (jpeg, CGSize(width: image.width, height: image.height)) }
            }
            guard let smaller = resized(image, by: 0.75) else { return nil }
            image = smaller
        }
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.3]),
              data.count <= maxBytes else { return nil }
        return (data, CGSize(width: image.width, height: image.height))
    }

    private static func resized(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let w = Int(CGFloat(image.width) * factor), h = Int(CGFloat(image.height) * factor)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Where a run's click traces go: next to history.json, one folder per run.
    static func runFolder(_ runID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clinqy/runs/\(runID)", isDirectory: true)
    }

    /// Keeps the newest `keep` runs' click traces; older folders go (they're only for chasing a recent misclick).
    static func pruneRuns(keep: Int = 20) {
        let root = runFolder("x").deletingLastPathComponent()
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]),
              dirs.count > keep else { return }
        let date = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for old in dirs.sorted(by: { date($0) > date($1) }).dropFirst(keep) { try? fm.removeItem(at: old) }
    }

    /// Debug trace: a red crosshair and ring at `point` (global top-left screen coordinates) on the latest
    /// screenshot of `app`'s window, saved as runs/<runID>/step<N>.jpg. Reuses the image the model saw when
    /// it's this app's and covers the point; otherwise takes a fresh capture. Returns the file, if written.
    @discardableResult
    static func saveClickTrace(app: NSRunningApplication, point: CGPoint, step: Int, runID: String) async -> URL? {
        var image = lastImage, frame = lastWindowFrame
        if image == nil || lastPID != app.processIdentifier || frame.map({ !$0.contains(point) }) ?? true {
            guard let snapshot = NativeWindowObservation.capture(app), CGPreflightScreenCaptureAccess(),
                  let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let window = content.windows.first(where: { $0.owningApplication?.processID == snapshot.pid && $0.windowID == snapshot.windowID })
            else { return nil }
            let config = SCStreamConfiguration()
            let scale = min(1, maxSide / max(window.frame.width, window.frame.height))
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                configuration: config)
            frame = window.frame
        }
        guard let image, let frame, frame.width > 0, frame.height > 0 else { return nil }
        return await Task.detached(priority: .utility) { () -> URL? in
            let width = image.width, height = image.height
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Screen (top-left points) → image (bottom-left pixels).
            let x = (point.x - frame.minX) * CGFloat(width) / frame.width
            let y = CGFloat(height) - (point.y - frame.minY) * CGFloat(height) / frame.height
            let arm: CGFloat = 18, radius: CGFloat = 11
            ctx.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.1, alpha: 1))
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            ctx.move(to: CGPoint(x: x - arm, y: y)); ctx.addLine(to: CGPoint(x: x + arm, y: y))
            ctx.move(to: CGPoint(x: x, y: y - arm)); ctx.addLine(to: CGPoint(x: x, y: y + arm))
            ctx.strokePath()
            guard let marked = ctx.makeImage(),
                  let jpeg = NSBitmapImageRep(cgImage: marked).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
            else { return nil }
            let dir = runFolder(runID)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("step\(step).jpg")
            return (try? jpeg.write(to: url)) != nil ? url : nil
        }.value
    }
}
