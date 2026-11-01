import AppKit

enum Config { static func value(_ key: String) -> String? { nil } }
@MainActor enum Agent { static func writeLog(_ text: String) {} }
@main struct UpdaterTests {
    static func main() throws {
        precondition(Updater.isNewer("0.3.0", than: "0.2.3"))
        precondition(Updater.isNewer("0.10.0", than: "0.3.0"))
        precondition(!Updater.isNewer("0.3.0", than: "0.3"))
        precondition(!Updater.isNewer("0.2.3", than: "0.3.0"))
        let app = URL(fileURLWithPath: "build/Clinqy.app")
        let version = try String(contentsOfFile: "MAC_VERSION", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try Updater.validateApp(app, expectedVersion: version)
        do { try Updater.validateApp(app, expectedVersion: "99.99.99"); fatalError("wrong app version was accepted") } catch {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-update-validation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do { try Updater.validateApp(root, expectedVersion: version); fatalError("unsigned app was accepted") } catch {}
        try swapTests()
        print("PASS updater version ordering, signed app acceptance, mismatched version and unsigned bundle rejection")
    }

    /// Runs a swap in a scratch directory and returns the receipt text.
    static func swap(lockParent: Bool, stagedContent: Bool = true) throws -> (receipt: String, target: URL, parent: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clinqy-swap-\(UUID())")
        let parent = root.appendingPathComponent("apps"), target = parent.appendingPathComponent("Clinqy.app")
        let staged = root.appendingPathComponent("stage/Clinqy.app")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: target.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("marker"))
        if lockParent { try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path) }
        let receipt = root.appendingPathComponent("receipt")
        let p = try Updater.swapInAndReopen(staged, replacing: target, waitingFor: nil, reopen: false, receipt: receipt)
        p.waitUntilExit()
        if lockParent { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        let text = (try? String(contentsOf: receipt, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (text, target, parent)
    }

    static func swapTests() throws {
        let fm = FileManager.default
        // Success: new content in place, no leftovers.
        let ok = try swap(lockParent: false)
        defer { try? fm.removeItem(at: ok.parent.deletingLastPathComponent()) }
        precondition(ok.receipt == "installed", "receipt \(ok.receipt)")
        precondition((try? String(contentsOf: ok.target.appendingPathComponent("marker"), encoding: .utf8)) == "new")
        precondition(!fm.fileExists(atPath: ok.target.path + ".old") && !fm.fileExists(atPath: ok.target.path + ".new"))
        // The first rename is denied: the installed original must survive untouched.
        if getuid() != 0 {
            let locked = try swap(lockParent: true)
            defer { try? fm.removeItem(at: locked.parent.deletingLastPathComponent()) }
            precondition(locked.receipt != "installed")
            precondition((try? String(contentsOf: locked.target.appendingPathComponent("marker"), encoding: .utf8)) == "original", "original bundle was lost: receipt \(locked.receipt)")
        }
    }
}
