import AppKit
import PDFKit

// Stand-ins for the parts of the app these files call into but the tests don't exercise.
enum Shell { static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) async -> (status: Int32, output: String) { (1, "") } }
enum Hand { static func windowIDs(pid: pid_t) -> Set<CGWindowID> { [] } }
enum Background { static var active: Bool { false }; static var app: NSRunningApplication? { get { nil } set {} } }
enum AgentScreen { @discardableResult static func adopt(_ app: NSRunningApplication, keep: Set<CGWindowID> = []) -> Set<CGWindowID> { [] } }
struct TrackedApplication { var resume: String? }
enum Applications { static let all: [TrackedApplication] = [] }
extension JSONDecoder { static let iso8601: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }
extension JSONEncoder { static let iso8601: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }() }
enum Agent { static func writeLog(_ text: String) {} }

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
    if !condition() { FileHandle.standardError.write(Data("FAIL \(message())\n".utf8)); exit(1) }
}

let fm = FileManager.default
func scratch() -> URL {
    let dir = fm.temporaryDirectory.appendingPathComponent("clinqy-data-\(UUID().uuidString)")
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
func makePDF(_ url: URL, pages: Int) {
    let doc = PDFDocument()
    for i in 0..<pages {
        let image = NSImage(size: NSSize(width: 100, height: 100 + i), flipped: false) { NSColor.red.setFill(); $0.fill(); return true }
        doc.insert(PDFPage(image: image)!, at: i)
    }
    expect(doc.write(to: url), "fixture pdf")
}

@main struct DataStoreTests {
    @MainActor static func main() async throws {
        let root = scratch()
        defer { try? fm.removeItem(at: root) }
        try await filesUndo(root)
        try await csvAppend(root)
        try await pdfOutputs(root)
        try await mediaOutputs(root)
        profile()
        try await storeQuarantine(root)
        encoder(root)
        print("PASS data stores: file undo records, CSV append, PDF/media outputs, profile answers, store quarantine, encoder validation")
    }

    // (3) A conflict during undo must keep the record, and a later undo can finish the job.
    @MainActor static func filesUndo(_ root: URL) async throws {
        let dir = root.appendingPathComponent("undo")
        Files.logDirOverride = root.appendingPathComponent("undo-log")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.txt"), moved = dir.appendingPathComponent("sub/a.txt")
        try "mine".write(to: a, atomically: true, encoding: .utf8)
        let result = try Files.apply([(a, moved)])
        expect(result.done.count == 1 && fm.fileExists(atPath: moved.path), "move happened")
        try "someone else's".write(to: a, atomically: true, encoding: .utf8)   // the original path is taken again
        let first = try Files.undo()
        expect(text(a) == "someone else's" && text(moved) == "mine", "conflict must overwrite nothing: \(first)")
        let records = (try? fm.contentsOfDirectory(at: Files.logDirOverride!, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
        expect(records.count == 1, "the unresolved record must be kept (\(records.count) left)")
        try fm.removeItem(at: a)
        _ = try Files.undo()
        expect(text(a) == "mine" && !fm.fileExists(atPath: moved.path), "second undo restores")
        let left = (try? fm.contentsOfDirectory(at: Files.logDirOverride!, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
        expect(left.isEmpty, "resolved record is removed")
    }

    // (4) A CSV without a trailing newline must not get its last row merged with the first appended one.
    static func csvAppend(_ root: URL) async throws {
        let csv = root.appendingPathComponent("t.csv")
        try "a,b\n1,2".write(to: csv, atomically: true, encoding: .utf8)
        try Tables.appendRows([["3", "4"]], to: csv)
        expect(Tables.readDelimited(csv) == [["a", "b"], ["1", "2"], ["3", "4"]], "rows after append: \(text(csv) ?? "")")
        try Tables.appendRows([["5", "6"]], to: csv)
        expect(Tables.readDelimited(csv)?.count == 4, "append after newline-terminated file adds no blank row")
        let empty = root.appendingPathComponent("e.csv")
        fm.createFile(atPath: empty.path, contents: Data())
        try Tables.appendRows([["x"]], to: empty)
        expect(text(empty) == "x\n", "append to empty file")
    }

    // (2) PDF outputs: never an input, replace only when asked, clean up only what the job made.
    static func pdfOutputs(_ root: URL) async throws {
        let dir = root.appendingPathComponent("pdf")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf")
        makePDF(a, pages: 2); makePDF(b, pages: 1)
        let aBytes = try Data(contentsOf: a)
        // Output is the same file as an input: refused, input untouched.
        for out in [a.path, dir.appendingPathComponent("./a.pdf").path] {
            do { _ = try await Pdf.run("merge", files: [a, b], options: ["out": out, "overwrite": true]); expect(false, "aliased output accepted") } catch {}
        }
        let link = dir.appendingPathComponent("link.pdf")
        try fm.createSymbolicLink(at: link, withDestinationURL: a)
        do { _ = try await Pdf.run("rotate", files: [a], options: ["out": link.path, "overwrite": true]); expect(false, "symlink alias accepted") } catch {}
        let hard = dir.appendingPathComponent("hard.pdf")
        try fm.linkItem(at: a, to: hard)
        do { _ = try await Pdf.run("rotate", files: [a], options: ["out": hard.path, "overwrite": true]); expect(false, "hard link alias accepted") } catch {}
        expect((try? Data(contentsOf: a)) == aBytes, "input must be untouched after refused jobs")
        try fm.removeItem(at: hard); try fm.removeItem(at: link)
        // Existing unrelated file at `out`: kept unless overwrite is set.
        let taken = dir.appendingPathComponent("taken.pdf")
        try "precious".write(to: taken, atomically: true, encoding: .utf8)
        _ = try await Pdf.run("merge", files: [a, b], options: ["out": taken.path])
        expect(text(taken) == "precious", "existing output replaced without overwrite")
        expect(fm.fileExists(atPath: dir.appendingPathComponent("taken 2.pdf").path), "result lands on a free numbered name")
        _ = try await Pdf.run("merge", files: [a, b], options: ["out": taken.path, "overwrite": true])
        expect(PDFDocument(url: taken)?.pageCount == 3, "overwrite replaces it")
        // A failing job removes only what it made: the folder is not a file and nothing pre-existing is touched.
        let folder = dir.appendingPathComponent("existing-folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let keep = folder.appendingPathComponent("a-p1.pdf")
        try "keep me".write(to: keep, atomically: true, encoding: .utf8)
        _ = try await Pdf.run("split", files: [a], options: ["out": folder.path])
        expect(text(keep) == "keep me", "split must not overwrite an existing page file")
        expect(fm.fileExists(atPath: folder.appendingPathComponent("a-p2.pdf").path), "split wrote the other page")
        do { _ = try await Pdf.run("split", files: [a], options: ["out": a.path]); expect(false, "split into a file accepted") } catch {}
        let fresh = dir.appendingPathComponent("fresh-folder")
        do { _ = try await Pdf.run("to_images", files: [a], options: ["out": fresh.path, "pages": "1,9"]); expect(false, "bad page accepted") } catch {}
        expect(!fm.fileExists(atPath: fresh.path), "a failed job removes the folder it created")
        expect(fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path), "inputs survive failures")
    }

    // (2) Media: aliasing is refused before any export starts.
    static func mediaOutputs(_ root: URL) async throws {
        let video = root.appendingPathComponent("clip.mp4")
        try "not really video".write(to: video, atomically: true, encoding: .utf8)
        for op in ["to_mp4", "trim", "compress"] {
            do { _ = try await Media.run(op, files: [video], options: ["out": video.path, "overwrite": true]) { _ in }; expect(false, "\(op) aliased output accepted") } catch {}
        }
        expect(text(video) == "not really video", "source untouched")
    }

    // (6) Profile answers.
    static func profile() {
        var p = Profile.Data()
        p.qa = [Profile.QA(question: "Do you require visa sponsorship to work in the US?", answer: "No"),
                Profile.QA(question: "Are you willing to work in Germany?", answer: "Yes")]
        p.workAuthorization = "Authorized to work in India"
        p.willingToRelocate = "Yes"
        expect(Profile.answer(for: "Do you require visa sponsorship to work in the US?", in: p) == "No", "exact question reused")
        expect(Profile.answer(for: "Do you NOT require visa sponsorship to work in the US?", in: p) == nil, "negated question must not reuse the answer")
        expect(Profile.answer(for: "Do you require visa sponsorship to work in the UK?", in: p) == nil, "other jurisdiction must not reuse the answer")
        expect(Profile.answer(for: "Are you willing to work in France?", in: p) == nil, "other country must not reuse the answer")
        expect(Profile.answer(for: "Are you authorized to work in the US?", in: p) == nil, "authorization for another country")
        expect(Profile.answer(for: "Are you unwilling to relocate?", in: p) == nil, "negated relocation")
        expect(Profile.answer(for: "Are you willing to relocate?", in: p) == "Yes", "plain relocation still answered")
        for text in ["nan", "inf", "-inf", "1e100", "infinity", "99999999999999999999999 years", "1e400"] {
            _ = Profile.parseExperience(text)   // must not trap
        }
        expect(Profile.parseExperience("nan") == nil && Profile.parseExperience("1e100") == nil && Profile.parseExperience("inf") == nil, "nonfinite/huge experience rejected")
        expect(Profile.parseExperience("1.5 years").map { $0 == (1, 6) } == true, "normal experience still parses")
    }

    // (8) Unreadable originals are set aside; failed writes are reported.
    @MainActor static func storeQuarantine(_ root: URL) async throws {
        let dir = root.appendingPathComponent("memory")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        Memory.directoryOverride = dir
        let file = dir.appendingPathComponent("memory.md")
        let garbage = Data([0xFF, 0xFE, 0x80, 0x81, 0xC0])
        try garbage.write(to: file)
        expect(Memory.add("My email is a@b.co"), "add reports success")
        let set = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("memory.md.corrupt-") }
        expect(set.count == 1 && (try? Data(contentsOf: dir.appendingPathComponent(set[0]))) == garbage, "unreadable memory kept as *.corrupt-<ts>")
        expect(Memory.facts == ["My email is a@b.co"], "memory continues from empty, not from garbage")
        // A write that cannot happen is reported.
        let locked = root.appendingPathComponent("locked-memory")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        if getuid() != 0 {
            Memory.directoryOverride = locked
            expect(!Memory.add("will not be written"), "add must report a failed write")
        }
        Memory.directoryOverride = nil
        // Generic helper behaviour.
        let json = root.appendingPathComponent("s.json")
        try Data("{ not json".utf8).write(to: json)
        if case .unreadable = StoreFile.load(json, decode: { try? JSONSerialization.jsonObject(with: $0) }) {} else { expect(false, "unreadable detected") }
        expect(StoreFile.quarantine(json) != nil && !fm.fileExists(atPath: json.path), "quarantine moves the file")
    }

    // (7) The encoder only loads a structurally complete model.
    static func encoder(_ root: URL) {
        let dir = root.appendingPathComponent("model")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try! "[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\n".write(to: dir.appendingPathComponent("vocab.txt"), atomically: true, encoding: .utf8)
        func safetensors(_ header: String, payload: Int = 64) -> Data {
            var n = UInt64(header.utf8.count).littleEndian
            return Data(bytes: &n, count: 8) + Data(header.utf8) + Data(count: payload)
        }
        let model = dir.appendingPathComponent("model.safetensors")
        // Header claims a gigantic length.
        var bad = Data(count: 8); bad.withUnsafeMutableBytes { $0.storeBytes(of: UInt64.max, as: UInt64.self) }
        try! (bad + Data(count: 32)).write(to: model)
        expect(TextEncoder.load(from: dir) == nil, "huge header length")
        // Required tensors missing.
        try! safetensors(#"{"embeddings.word_embeddings.weight":{"dtype":"F32","shape":[5,384],"data_offsets":[0,64]}}"#).write(to: model)
        expect(TextEncoder.load(from: dir) == nil, "shape/byte-range mismatch")
        try! safetensors(#"{"embeddings.word_embeddings.weight":{"dtype":"F32","shape":[4,4],"data_offsets":[0,64]}}"#).write(to: model)
        expect(TextEncoder.load(from: dir) == nil, "incomplete tensor set")
        // Offsets past the end of the file.
        try! safetensors(#"{"x":{"dtype":"F32","shape":[2],"data_offsets":[0,9999999]}}"#).write(to: model)
        expect(TextEncoder.load(from: dir) == nil, "offsets outside file")
        // Embedder cache validation.
        expect(!Embedder.usable([Float.nan, 1], bge: false) && !Embedder.usable([1, 2], bge: true) && Embedder.usable([0.1, 0.2], bge: false), "vector sanity")
        // The real model, when this machine has it.
        if fm.fileExists(atPath: TextEncoder.dir.appendingPathComponent("model.safetensors").path) {
            guard let real = TextEncoder.load() else { expect(false, "the complete installed model must pass validation"); return }
            let v = real.embed("hello world")
            expect(v.count == 384 && Embedder.usable(v, bge: true), "real model embeds")
        }
    }
}
