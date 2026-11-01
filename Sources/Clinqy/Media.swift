@preconcurrency import AVFoundation

/// Video/audio jobs with AVFoundation, in the background with no time limit: join, trim, shrink, convert,
/// pull out the audio. Joining and trimming copy the streams without re-encoding when they can (seconds, not minutes).
enum Media {
    static let ops = ["combine", "trim", "compress", "to_mp4", "to_audio", "info"]
    static let videoTypes: Set<String> = ["mp4", "mov", "m4v", "3gp"]
    static let audioTypes: Set<String> = ["m4a", "mp3", "wav", "aac", "aiff", "aif", "caf"]

    /// `progress` gets 0…1 while an export runs (on the main actor).
    static func run(_ op: String, files: [URL], options o: [String: Any],
                    progress: @escaping @MainActor (Double) -> Void) async throws -> String {
        guard !files.isEmpty else { throw Pdf.Failure("no files given") }
        for f in files where !FileManager.default.fileExists(atPath: f.path) { throw Pdf.Failure("no such file: \(f.path)") }
        for f in files where !videoTypes.contains(f.pathExtension.lowercased()) && !audioTypes.contains(f.pathExtension.lowercased()) {
            throw Pdf.Failure("can't open .\(f.pathExtension) files (works with \((videoTypes.union(audioTypes)).sorted().joined(separator: ", ")); for others try ffmpeg)")
        }
        let overwrite = o["overwrite"] as? Bool == true
        let out = try (o["out"] as? String).map { try Pdf.resolveOutput(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath), sources: files, overwrite: overwrite) }
        let audioOnly = files.allSatisfy { audioTypes.contains($0.pathExtension.lowercased()) }
        let ext = audioOnly ? "m4a" : "mp4"

        switch op {
        case "combine":
            guard files.count >= 2 else { throw Pdf.Failure("combine needs 2+ files") }
            let comp = AVMutableComposition()
            let video = audioOnly ? nil : comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            let audio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            var at = CMTime.zero
            for f in files {
                let asset = AVURLAsset(url: f)
                let duration = try await asset.load(.duration)
                let range = CMTimeRange(start: .zero, duration: duration)
                if let video, let track = try await asset.loadTracks(withMediaType: .video).first {
                    try video.insertTimeRange(range, of: track, at: at)
                    if at == .zero { video.preferredTransform = try await track.load(.preferredTransform) }
                }
                if let audio, let track = try await asset.loadTracks(withMediaType: .audio).first {
                    try audio.insertTimeRange(range, of: track, at: at)
                }
                at = at + duration
            }
            let dest = out ?? Pdf.output(for: files[0], suffix: "combined", ext: ext)
            let how = try await export(comp, to: dest, presets: audioOnly ? [AVAssetExportPresetAppleM4A] : [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality], progress: progress)
            return "combined \(files.count) files (\(clock(at))) → \(describe(dest))\(how)"

        case "trim":
            let asset = AVURLAsset(url: files[0])
            let duration = try await asset.load(.duration)
            let start = try seconds(o["start"], default: 0)
            let end = min(try seconds(o["end"], default: duration.seconds), duration.seconds)
            guard end > start else { throw Pdf.Failure("end must be after start (the file is \(clock(duration)) long)") }
            let dest = out ?? Pdf.output(for: files[0], suffix: "trimmed", ext: ext)
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
            let how = try await export(asset, to: dest, presets: audioOnly ? [AVAssetExportPresetAppleM4A] : [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality],
                                       range: range, progress: progress)
            return "trimmed to \(clock(range.start))–\(clock(range.end)) → \(describe(dest))\(how)"

        case "compress":
            guard !audioOnly else { throw Pdf.Failure("compress is for videos") }
            // Re-encodes to HEVC at a share of the source's bitrate (presets pick fixed high bitrates, which can make
            // already-small videos bigger); extreme also scales down to at most 540p.
            let level = (o["level"] as? String ?? "recommended").lowercased()
            let (share, maxHeight): (Double, CGFloat) = switch level {
            case "light", "low": (0.7, 4320)
            case "extreme", "strong", "max", "high": (0.3, 540)
            default: (0.45, 4320)
            }
            let dest = out ?? Pdf.output(for: files[0], suffix: "compressed", ext: "mp4")
            // Encoded beside the destination first; it only replaces/creates `dest` when it is actually smaller.
            let candidate = Pdf.scratch(for: dest)
            try await transcode(AVURLAsset(url: files[0]), to: candidate, bitrateShare: share, maxHeight: maxHeight, progress: progress)
            guard fileSize(candidate) < fileSize(files[0]) else {
                try? FileManager.default.removeItem(at: candidate)   // only the file this job just created
                return "\(files[0].lastPathComponent) is already well compressed (\(size(files[0]))); \(level == "extreme" ? "it can't get smaller" : "level \"extreme\" lowers the resolution to shrink it")"
            }
            try Pdf.commit(candidate, to: dest)
            return "compressed \(files[0].lastPathComponent): \(size(files[0])) → \(size(dest)) (−\(100 - fileSize(dest) * 100 / max(fileSize(files[0]), 1))%) → \(dest.path)"

        case "to_mp4":
            let dest = out ?? Pdf.output(for: files[0], suffix: nil, ext: "mp4")
            let how = try await export(AVURLAsset(url: files[0]), to: dest, presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality], progress: progress)
            return "converted → \(describe(dest))\(how)"

        case "to_audio":
            let dest = out ?? Pdf.output(for: files[0], suffix: nil, ext: "m4a")
            _ = try await export(AVURLAsset(url: files[0]), to: dest, presets: [AVAssetExportPresetAppleM4A], progress: progress)
            return "audio saved → \(describe(dest))"

        case "info":
            var lines: [String] = []
            for f in files {
                let asset = AVURLAsset(url: f)
                var line = "\(f.lastPathComponent): \(clock(try await asset.load(.duration))), \(size(f))"
                if let v = try await asset.loadTracks(withMediaType: .video).first {
                    let s = try await v.load(.naturalSize)
                    line += ", \(Int(abs(s.width)))×\(Int(abs(s.height))), \(Int((try await v.load(.nominalFrameRate)).rounded())) fps"
                }
                lines.append(line)
            }
            return lines.joined(separator: "\n")

        default:
            throw Pdf.Failure("unknown op \(op); use one of \(ops.joined(separator: ", "))")
        }
    }

    /// Exports with the first preset that works (passthrough can fail when the clips' formats differ).
    /// Returns a note when it had to re-encode.
    private static func export(_ asset: AVAsset, to dest: URL, presets: [String], range: CMTimeRange? = nil,
                               progress: @escaping @MainActor (Double) -> Void) async throws -> String {
        var lastError: Error?
        for (i, preset) in presets.enumerated() {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let type: AVFileType = dest.pathExtension.lowercased() == "m4a" ? .m4a : .mp4
            guard session.supportedFileTypes.contains(type) else { continue }
            // Written to a hidden sibling and moved into place on success: a failed or cancelled export never touches `dest`.
            let temp = Pdf.scratch(for: dest)
            try? FileManager.default.removeItem(at: temp)
            session.outputURL = temp
            session.outputFileType = type
            session.shouldOptimizeForNetworkUse = true
            if let range { session.timeRange = range }
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    session.exportAsynchronously { done.resume() }
                }
            } onCancel: { session.cancelExport() }
            ticker.cancel()
            if session.status == .completed {
                try Pdf.commit(temp, to: dest)
                return i > 0 && preset != AVAssetExportPresetAppleM4A ? " (re-encoded: the clips' formats differ)" : ""
            }
            lastError = session.error
            try? FileManager.default.removeItem(at: temp)
            if Task.isCancelled { throw CancellationError() }
        }
        throw Pdf.Failure("export failed: \(lastError?.localizedDescription ?? "unsupported format")")
    }

    /// Decodes and re-encodes the video as HEVC at `bitrateShare` of its current bitrate (audio as 96 kbps AAC).
    private static func transcode(_ asset: AVURLAsset, to dest: URL, bitrateShare: Double, maxHeight: CGFloat,
                                  progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Pdf.Failure("no video track") }
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds
        let natural = try await vTrack.load(.naturalSize)
        let transform = try await vTrack.load(.preferredTransform)
        let sourceRate = Double(try await vTrack.load(.estimatedDataRate))
        let scale = min(1, maxHeight / min(natural.width, natural.height))
        let even = { (v: CGFloat) in Int((v * scale / 2).rounded()) * 2 }
        let (w, h) = (even(natural.width), even(natural.height))
        let bitrate = max(250_000, sourceRate * bitrateShare * Double(scale * scale))

        let finalDest = dest
        let dest = Pdf.scratch(for: finalDest)   // moved over `finalDest` only when the whole transcode succeeded
        try? FileManager.default.removeItem(at: dest)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: dest, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(bitrate)],
        ])
        vIn.transform = transform
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        var pairs = [(vOut as AVAssetReaderOutput, vIn)]
        if let aTrack {
            let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(aOut)
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 44_100, AVEncoderBitRateKey: 96_000,
            ])
            aIn.expectsMediaDataInRealTime = false
            writer.add(aIn)
            pairs.append((aOut, aIn))
        }
        guard reader.startReading() else { try? FileManager.default.removeItem(at: dest); throw Pdf.Failure("couldn't read the video: \(reader.error?.localizedDescription ?? "")") }
        guard writer.startWriting() else { try? FileManager.default.removeItem(at: dest); throw Pdf.Failure("couldn't write the video: \(writer.error?.localizedDescription ?? "")") }
        writer.startSession(atSourceTime: .zero)

        let cancelled = { Task.isCancelled }
        await withTaskGroup(of: Void.self) { group in
            for (i, (output, input)) in pairs.enumerated() {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "clinqy.transcode.\(i)")
                        var lastTick = Date.distantPast
                        input.requestMediaDataWhenReady(on: queue) {
                            while input.isReadyForMoreMediaData {
                                guard reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
                                    input.markAsFinished()
                                    done.resume()
                                    return
                                }
                                input.append(sample)
                                if i == 0, Date().timeIntervalSince(lastTick) > 0.7, duration > 0 {
                                    lastTick = Date()
                                    let p = CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration
                                    Task { @MainActor in progress(min(1, p)) }
                                }
                            }
                        }
                    }
                }
            }
        }
        if cancelled() || reader.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: dest)
            if cancelled() { throw CancellationError() }
            throw Pdf.Failure("couldn't read the video: \(reader.error?.localizedDescription ?? "")")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: dest)
            throw Pdf.Failure("couldn't write the video: \(writer.error?.localizedDescription ?? "")")
        }
        try Pdf.commit(dest, to: finalDest)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// 90, "90", "1:30", "01:02:03" → seconds.
    private static func seconds(_ value: Any?, default fallback: Double) throws -> Double {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        guard let s = value as? String, !s.isEmpty else { return fallback }
        let parts = s.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { throw Pdf.Failure("bad time “\(s)”") }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    private static func clock(_ t: CMTime) -> String {
        let s = Int(t.seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func size(_ url: URL) -> String {
        ByteCountFormatter.string(fromByteCount: Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0), countStyle: .file)
    }

    private static func describe(_ url: URL) -> String { "\(url.path) (\(size(url)))" }
}
