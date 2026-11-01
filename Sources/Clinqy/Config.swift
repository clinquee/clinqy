import Foundation

/// Reads settings from the environment, falling back to ~/.config/clinqy/env (KEY=VALUE lines).
enum Config {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/clinqy/env")

    private static let lock = NSLock()
    private static var cached: [String: String]?

    private static var fileValues: [String: String] {
        lock.withLock {
            if let cached { return cached }
            let values = parse((try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
            cached = values
            return values
        }
    }

    private static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq])
            var value = String(trimmed[trimmed.index(after: eq)...])
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            values[key] = value
        }
        return values
    }

    static func value(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key] ?? fileValues[key]
    }

    /// Re-reads the file, after onboarding (or anything else) changed it.
    static func reload() {
        lock.withLock { cached = nil }
    }

    /// Sets (or, with nil, removes) keys in the env file, keeping every other line and comment as it was.
    /// The file holds API keys, so it stays readable by the user only.
    static func write(_ updates: [String: String?]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        var pending = updates
        var lines: [String] = []
        for line in old.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eq])
                if let change = pending.removeValue(forKey: key) {
                    if let value = change { lines.append("\(key)=\(value)") }
                    continue
                }
            }
            lines.append(line)
        }
        while lines.last == "" { lines.removeLast() }
        for (key, value) in pending.sorted(by: { $0.key < $1.key }) {
            if let value { lines.append("\(key)=\(value)") }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        reload()
    }
}

/// Shared rules for the files Clinqy keeps about the user (memory, profile, history, skills, replay fixtures):
/// a write that fails is reported to the caller, and a file that exists but can't be read is set aside as
/// `<name>.corrupt-<timestamp>` instead of being replaced by an empty state on the next save.
enum StoreFile {
    /// Writes atomically; nil on success, the error otherwise. Creates the folder when needed.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Error? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return nil
        } catch { return error }
    }

    /// Renames an unreadable file to `<name>.corrupt-<timestamp>` (never overwriting an earlier one); returns where it went.
    @discardableResult
    static func quarantine(_ url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var target = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".corrupt-" + stamp)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".corrupt-" + stamp + "-\(n)")
            n += 1
        }
        do { try fm.moveItem(at: url, to: target); return target } catch { return nil }
    }

    /// Reads `url` and decodes it with `decode`. `.absent` when there is no file; `.unreadable` when there is one that
    /// can't be read or decoded (the caller should quarantine it before writing anything there).
    enum Loaded<T> { case absent, value(T), unreadable }

    static func load<T>(_ url: URL, decode: (Data) -> T?) -> Loaded<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url), let value = decode(data) else { return .unreadable }
        return .value(value)
    }

    /// True when `url` can be written without losing anything: it is absent or readable, or it was unreadable and has
    /// now been set aside. False when it is unreadable and could not be moved (the write must not go ahead).
    static func clearForWrite(_ url: URL, decodes: (Data) -> Bool) -> Bool {
        switch load(url, decode: { decodes($0) ? true : nil }) {
        case .absent, .value: return true
        case .unreadable: return quarantine(url) != nil
        }
    }
}
