import AppKit

/// Notices when the user copies something, so "translate this" / "reply to this" / "add this to my tracker"
/// can mean what they just copied when nothing is selected. Only the time of the last *change of content*
/// counts: Clinqy's own ⌘C tricks put the user's clipboard back as it was, which isn't a new copy.
@MainActor
enum Clipboard {
    private static var lastCount = NSPasteboard.general.changeCount
    private static var lastText: String?
    private static var lastFiles: [URL] = []
    private static var copiedAt: Date?
    private static var timer: Timer?

    static func start() {
        guard timer == nil else { return }
        lastText = NSPasteboard.general.string(forType: .string)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
        timer?.tolerance = 0.2
    }

    private static func poll() {
        let board = NSPasteboard.general
        guard board.changeCount != lastCount else { return }
        lastCount = board.changeCount
        // Passwords from password managers are marked concealed/transient: never keep those.
        let types = board.types ?? []
        if types.contains(where: { ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"].contains($0.rawValue) }) {
            lastText = nil; lastFiles = []; copiedAt = nil
            return
        }
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let text = files.isEmpty ? board.string(forType: .string) : nil
        guard text != lastText || files != lastFiles else { return }
        lastText = text
        lastFiles = files
        copiedAt = Date()
    }

    /// What the user copied in the last `minutes`, if anything.
    static func recent(minutes: Double = 10) -> (text: String?, files: [URL], age: TimeInterval)? {
        poll()
        guard let at = copiedAt, Date().timeIntervalSince(at) < minutes * 60 else { return nil }
        let text = lastText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (text?.isEmpty == false) || !lastFiles.isEmpty else { return nil }
        return (text?.isEmpty == false ? text : nil, lastFiles, Date().timeIntervalSince(at))
    }

    static func describeAge(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "just now" : "\(Int(seconds / 60)) min ago"
    }
}

/// Every item and every type on a pasteboard, so a temporary use of the clipboard can put back rich content
/// (images, files, styled text), and only while the clipboard is still the one Clinqy wrote: if the user copied
/// something meanwhile, their copy is theirs and is left alone.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ board: NSPasteboard = .general) {
        items = (board.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { data[type] = d } }
            return data
        }
    }

    var isEmpty: Bool { items.isEmpty }

    /// Puts the snapshot back if the pasteboard's change count is still `ownedCount` (our own last write).
    /// Returns false, touching nothing, when something else wrote to the clipboard in between.
    @discardableResult
    func restore(to board: NSPasteboard = .general, ifUnchangedSince ownedCount: Int) -> Bool {
        guard board.changeCount == ownedCount else { return false }
        board.clearContents()
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
        return true
    }
}
