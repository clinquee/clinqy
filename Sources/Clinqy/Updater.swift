import AppKit

/// Keeps Clinqy for Mac up to date from its GitHub releases. Mac releases are tagged `mac-v<version>` and carry
/// `Clinqy.dmg` (the repo's "latest" release is the Windows one, so this reads the list rather than /latest).
/// Checks a minute after launch and then once a day; a newer version shows in the menu bar menu and asks once.
/// Installing downloads the disk image, swaps the app in /Applications, and reopens it. Settings, memory and
/// history live outside the app, so they're kept. UPDATE_CHECK=off in ~/.config/clinqy/env turns the checks off.
@MainActor
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let dmg: URL
        let page: URL
        let notes: String
    }

    private(set) var available: Release?
    /// Called when `available` changes (the app delegate updates its menu item).
    var onChange: () -> Void = {}
    private var timer: Timer?
    private(set) var installing = false

    nonisolated static let repo = "Amrit-Nigam/clinqy"

    /// This copy's version (CLINQY_VERSION overrides it, for testing the updater).
    nonisolated static var current: String {
        ProcessInfo.processInfo.environment["CLINQY_VERSION"]
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Whether `a` is a newer version than `b` (dot-separated numbers).
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// The newest published Mac release, from the GitHub API.
    nonisolated static func newestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=100")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Clinqy/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "Clinqy", code: 1, userInfo: [NSLocalizedDescriptionKey: "GitHub didn't answer (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"])
        }
        var best: Release?
        for r in list where r["draft"] as? Bool != true && r["prerelease"] as? Bool != true {
            guard let tag = r["tag_name"] as? String, tag.hasPrefix("mac-v"),
                  let assets = r["assets"] as? [[String: Any]],
                  let dmg = assets.first(where: { ($0["name"] as? String) == "Clinqy.dmg" })?["browser_download_url"] as? String,
                  let dmgURL = URL(string: dmg), let page = (r["html_url"] as? String).flatMap(URL.init(string:)) else { continue }
            let version = String(tag.dropFirst("mac-v".count))
            if best == nil || isNewer(version, than: best!.version) {
                best = Release(version: version, dmg: dmgURL, page: page, notes: r["body"] as? String ?? "")
            }
        }
        return best
    }

    /// Starts the background checks (a minute after launch, then daily).
    func start() {
        guard Config.value("UPDATE_CHECK")?.lowercased() != "off" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in Task { await self?.check(userAsked: false) } }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userAsked: false) }
        }
    }

    /// Looks for a newer version. When the user asked (the menu item), always says what it found.
    func check(userAsked: Bool) async {
        do {
            let newest = try await Self.newestRelease()
            if let newest, Self.isNewer(newest.version, than: Self.current) {
                available = newest
                onChange()
                Agent.writeLog("update: \(newest.version) is out (this is \(Self.current))")
                let askedKey = "updateOffered"
                if userAsked || UserDefaults.standard.string(forKey: askedKey) != newest.version {
                    UserDefaults.standard.set(newest.version, forKey: askedKey)
                    offer(newest)
                }
            } else {
                available = nil
                onChange()
                if userAsked { info("Clinqy is up to date", "You have the newest version, \(Self.current).") }
            }
        } catch {
            if userAsked { info("Couldn't check for updates", error.localizedDescription) }
        }
    }

    private func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Asks whether to install `release` now.
    func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Clinqy \(release.version) is available"
        let notes = release.notes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }.prefix(5).joined(separator: "\n")
        alert.informativeText = "You have \(Self.current). Installing takes a few seconds and Clinqy reopens by itself; "
            + "your settings, memory and history are kept." + (notes.isEmpty ? "" : "\n\nNew:\n" + notes.replacingOccurrences(of: "**", with: ""))
        alert.addButton(withTitle: "Install and Reopen")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: Task { await install(release) }
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.page)
        default: break
        }
    }

    /// Downloads the release, swaps it in for this app, and reopens it.
    func install(_ release: Release) async {
        guard !installing else { return }
        installing = true
        defer { installing = false }
        let target = Bundle.main.bundleURL
        do {
            let staged = try await Self.download(release)
            guard target.path.hasSuffix(".app") else { throw NSError(domain: "Clinqy", code: 2, userInfo: [NSLocalizedDescriptionKey: "Clinqy isn't running from an app bundle"]) }
            try Self.swapInAndReopen(staged, replacing: target, waitingFor: getpid())
            Agent.writeLog("update: installing \(release.version), reopening")
            NSApp.terminate(nil)
        } catch {
            info("Couldn't install the update", error.localizedDescription + "\n\nYou can download it from the release page instead.")
            NSWorkspace.shared.open(release.page)
        }
    }

    /// Downloads the disk image and copies the app out of it into a staging folder; returns the staged app.
    nonisolated static func download(_ release: Release) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: release.dmg)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Clinqy", code: 3, userInfo: [NSLocalizedDescriptionKey: "the download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"])
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-update-\(release.version)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var keepStagedApp = false
        defer { if !keepStagedApp { try? FileManager.default.removeItem(at: work) } }
        let dmg = work.appendingPathComponent("Clinqy.dmg")
        try FileManager.default.moveItem(at: file, to: dmg)
        let mount = work.appendingPathComponent("mnt")
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        let app = mount.appendingPathComponent("Clinqy.app")
        let staged = work.appendingPathComponent("Clinqy.app")
        try run("/usr/bin/ditto", [app.path, staged.path])
        try validateApp(staged, expectedVersion: release.version)
        keepStagedApp = true
        return staged
    }

    /// The signed bundle must match the release selected before it can replace an installed copy.
    nonisolated static func validateApp(_ app: URL, expectedVersion: String) throws {
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == "com.amritnigam.clinqy" else {
            throw NSError(domain: "Clinqy", code: 4, userInfo: [NSLocalizedDescriptionKey: "the download isn't Clinqy"])
        }
        guard info?["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw NSError(domain: "Clinqy", code: 5, userInfo: [NSLocalizedDescriptionKey: "the downloaded app version does not match this release"])
        }
    }

    /// Hands the swap to a small script that waits for this process to quit, replaces the app and opens the new one.
    /// The new copy is first staged as a sibling (`<app>.new`) so the installed bundle is only touched once a complete
    /// replacement exists next to it; the original is renamed to `<app>.old` and removed only after the new one is in
    /// place. If the first rename fails the original is left exactly as it was (nothing is deleted), and a rollback only
    /// ever restores a backup that actually exists. The outcome is written to `receipt` when given
    /// (installed / unchanged / rolled-back / failed-staging).
    @discardableResult
    nonisolated static func swapInAndReopen(_ staged: URL, replacing target: URL, waitingFor pid: Int32?, reopen: Bool = true, receipt: URL? = nil) throws -> Process {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let t = q(target.path), old = q(target.path + ".old"), new = q(target.path + ".new")
        let rec = receipt.map { q($0.path) }
        let script = """
        \(pid.map { "while kill -0 \($0) 2>/dev/null; do sleep 0.2; done" } ?? "")
        report() { \(rec.map { "echo \"$1\" > \($0)" } ?? ":") ; }
        # A backup left by an interrupted earlier swap is the only copy if the app itself is gone: restore, never delete it.
        if [ -e \(old) ] && [ ! -e \(t) ]; then mv \(old) \(t); fi
        rm -rf \(new)
        if /usr/bin/ditto \(q(staged.path)) \(new); then
          if [ -e \(old) ]; then rm -rf \(old); fi
          if mv \(t) \(old); then
            if mv \(new) \(t); then rm -rf \(old); report installed
            else
              rm -rf \(new)
              if [ -e \(old) ] && [ ! -e \(t) ]; then mv \(old) \(t); fi
              report rolled-back
            fi
          else
            rm -rf \(new); report unchanged
          fi
        else
          rm -rf \(new); report failed-staging
        fi
        rm -rf \(q(staged.deletingLastPathComponent().path))
        \(reopen ? "/usr/bin/open \(t)" : "")
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        return p
    }

    @discardableResult
    nonisolated static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Clinqy", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: path).lastPathComponent) failed: \(text.prefix(200))"])
        }
        return text
    }
}
