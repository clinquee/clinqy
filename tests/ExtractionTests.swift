import AppKit
import PDFKit

// File extraction never captures a native window; keep that boundary explicit in this fixture.
struct NativeWindowObservation {
    var pid: pid_t = 0
    var frame: CGRect = .zero
    var windowID: CGWindowID = 0
    static func capture(_ app: NSRunningApplication) -> Self? { nil }
    func staleness(includeContent: Bool) -> String? { nil }
}
enum Screenshot {
    struct Capture { let window: NativeWindowObservation; let rawImage: CGImage }
}
enum AXEngine { static func documentURL(of app: NSRunningApplication) -> URL? { nil } }
enum Pdf {
    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
    static func unique(_ url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".csv") }
}
@MainActor enum Background { static var active = false; static var app: NSRunningApplication? }
@MainActor enum Hand { static func windowIDs(pid: pid_t) -> Set<CGWindowID> { [] } }
@MainActor enum AgentScreen { static func adopt(_ app: NSRunningApplication, keep: Set<CGWindowID>) {} }

@main struct ExtractionTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-extraction-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        check(Tables.parse("name,notes\r\n\"Riya\",\"a,b\nline \"\"two\"\"\"\r\n") == [["name", "notes"], ["Riya", "a,b\nline \"two\""]], "quoted multiline CSV parses without a Character array")
        let csv = root.appendingPathComponent("large.csv")
        let original = Data(("name,notes\n" + String(repeating: "Riya,detail\n", count: 100_000)).utf8)
        try original.write(to: csv)
        let sample = Tables.readSample(csv)!
        check(sample.rows.count == 500 && sample.truncated, "large CSV extraction returns a bounded sample")
        check(Tables.readSample(csv, maxRows: 1)?.rows == [["name", "notes"]], "append can inspect just the header")
        let status = try await Tables.save([["name", "notes"], ["Amrit", "new"]], to: "csv", path: csv.path, title: nil, append: true)
        let appended = try Data(contentsOf: csv)
        check(appended == original + Data("Amrit,new\n".utf8), "append preserves all original data and skips a matching header")
        check(status.contains("appended 1 rows"), "append reports rows actually written")
        let noLF = root.appendingPathComponent("no-newline.csv")
        try Data("name,notes\nRiya,detail".utf8).write(to: noLF)
        _ = try await Tables.save([["name", "notes"], ["Amrit", "new"]], to: "csv", path: noLF.path, title: nil, append: true)
        check(try String(contentsOf: noLF, encoding: .utf8) == "name,notes\nRiya,detail\nAmrit,new\n", "append adds a missing record separator")
        let oversized = root.appendingPathComponent("oversized.csv")
        try Data(("head\n\"" + String(repeating: "a", count: 2_000_000)).utf8).write(to: oversized)
        let bounded = Tables.readSample(oversized)!
        check(bounded.truncated && bounded.rows == [["head"]], "a record cut off at the byte budget isn't presented as complete")
        let text = root.appendingPathComponent("large.txt")
        try Data(String(repeating: "document content ", count: 100_000).utf8).write(to: text)
        let excerpt = await Reader.fileText(text)
        check(excerpt?.contains("excerpt truncated") == true && (excerpt?.count ?? 0) < 12_100, "plain document loading is bounded before decoding")
        let cancelled = Task { await Reader.fileText(text) }; cancelled.cancel()
        check(await cancelled.value == nil, "cancelled document reads stop")
        print("PASS: \(checks) bounded extraction and lossless CSV append checks")
    }
}
