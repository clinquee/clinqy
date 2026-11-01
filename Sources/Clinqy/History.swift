import Foundation
import Combine

/// Past runs, newest first, kept in Application Support so the user can revisit or continue them.
@MainActor
final class History: ObservableObject {
    static let shared = History()

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let date: Date
        let request: String
        let answer: String
        let ok: Bool
        let steps: [String]
        let app: String?
        let result: ResultCard?
        /// What the run did, replayable (lets it be saved as a workflow).
        var trace: [WorkflowStep]? = nil
        /// The document the run read, for a follow-up task to use without reopening it.
        var readText: String? = nil
        /// The first request of a chain of "continue"s: its instructions stay in force for every follow-up.
        var task: String? = nil
        /// Stable links survive restarts and let task retrieval include later user corrections.
        var threadID: UUID? = nil
        var parentID: UUID? = nil
        /// UI steps alone can't replay the fresh research/analysis that generated their typed content.
        var requiresFreshWork: Bool? = nil

        var episode: TaskMemory.Episode? {
            guard let data = try? JSONEncoder.iso.encode(self), let safe = Secrets.maskJSON(data),
                  let payload = String(data: safe, encoding: .utf8),
                  let entry = try? JSONDecoder.iso.decode(Entry.self, from: safe) else { return nil }
            return TaskMemory.Episode(id: id, date: date, request: entry.request, answer: entry.answer, ok: ok,
                                      steps: entry.steps, app: entry.app, threadID: threadID ?? id,
                                      parentID: parentID, payload: payload)
        }
    }

    @Published private(set) var entries: [Entry] = []

    private static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clinqy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }
    private let url: URL
    private let archive: TaskMemory

    init(file: URL? = nil, archive: TaskMemory = .shared) {
        self.url = file ?? Self.defaultURL
        self.archive = archive
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder.iso.decode([Entry].self, from: data) {
            entries = saved
            // Import retained history once per ID. Older builds only saved the original request of a thread.
            var roots: [String: UUID] = [:]
            for i in entries.indices.reversed() {
                let root = entries[i].threadID ?? entries[i].task.flatMap { roots[$0] } ?? entries[i].id
                entries[i].threadID = root
                roots[entries[i].request] = root
            }
            archive.record(entries.compactMap(\.episode))
        }
    }

    func add(_ entry: Entry) {
        // The archive receives the full redacted record before the UI's recent-history window is trimmed.
        guard let episode = entry.episode,
              let safe = try? JSONDecoder.iso.decode(Entry.self, from: Data(episode.payload.utf8)) else { return }
        archive.record([episode])
        entries.insert(safe, at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
        save()
    }

    func remove(_ entry: Entry) {
        archive.remove(entry.id)
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        archive.clear()
        entries = []
        save()
    }

    private func save() { Persist.write(entries, to: url, encoder: .iso) }
}

/// Something a task produced for the user to look at: options, a plan, prices, a summary.
struct ResultCard: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id = UUID()
        let title: String
        let subtitle: String?
        let detail: String?
        let link: String?

        enum CodingKeys: String, CodingKey { case title, subtitle, detail, link }
    }

    let title: String
    let text: String?
    let items: [Item]

    /// Parses the agent's {"do":"show", "title", "text", "items":[{title, subtitle, detail, link}]}.
    init?(action: [String: Any]) {
        let title = (action["title"] as? String) ?? "Result"
        let text = action["text"] as? String
        let items = (action["items"] as? [[String: Any]] ?? []).compactMap { i -> Item? in
            guard let t = i["title"] as? String else { return nil }
            return Item(title: t, subtitle: i["subtitle"] as? String, detail: i["detail"] as? String, link: i["link"] as? String)
        }
        guard text?.isEmpty == false || !items.isEmpty else { return nil }
        self.init(title: title, text: text, items: items)
    }

    init(title: String, text: String?, items: [Item]) {
        self.title = title
        self.text = text
        self.items = items
    }

    /// Plain text for copying.
    var plain: String {
        var lines = [title]
        if let text { lines.append(text) }
        for i in items {
            lines.append("• " + [i.title, i.subtitle, i.detail, i.link].compactMap { $0 }.joined(separator: " — "))
        }
        return lines.joined(separator: "\n")
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

private extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}
