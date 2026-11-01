import Foundation

/// Reusable skills learned by watching the user (Watch & Learn), kept in Application Support.
@MainActor
final class Skills: ObservableObject {
    static let shared = Skills()

    struct Skill: Codable, Identifiable, Equatable {
        var id = UUID()
        let name: String
        let summary: String
        /// Things that change each time, e.g. ["repo name", "description"].
        let parameters: [String]
        /// Generalised steps, with parameters written as {repo name}.
        let steps: [String]
        let created: Date
    }

    @Published private(set) var all: [Skill] = []
    @Published private(set) var isLearning = false
    @Published var lastError: String?

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clinqy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("skills.json")
    }()

    private var readOnly = false

    private init() {
        switch StoreFile.load(url, decode: { try? JSONDecoder().decode([Skill].self, from: $0) }) {
        case .value(let saved): all = saved
        case .unreadable:
            // Set the unreadable file aside, so the next save can't replace it with an empty list.
            if StoreFile.quarantine(url) == nil { readOnly = true; lastError = "Your saved skills couldn't be read and couldn't be set aside; changes are not being saved." }
        case .absent: break
        }
    }

    @discardableResult
    func remove(_ skill: Skill) -> Bool {
        all.removeAll { $0.id == skill.id }
        return save()
    }

    /// Turns a recording into a skill with the agent (a one-off session).
    func learn(from recording: [String]) async {
        guard recording.count >= 2 else { lastError = "That was too short to learn from"; return }
        isLearning = true
        lastError = nil
        defer { isLearning = false }
        let system = """
        You turn a recording of what a Mac user did into a reusable skill that an assistant operating the Mac can \
        follow later. Reply with JSON only (no tool calls, no prose):
        {"name":"<3-6 word name, imperative>","summary":"<one sentence>","parameters":["<things that would change \
        next time, e.g. repo name, recipient, message>"],"steps":["<clear step using app/button/field names, with \
        parameters written as {parameter}>"]}
        Drop accidental or redundant actions (stray clicks, corrections). Keep app names and exact button/field labels.
        """
        do {
            let session = try AgySession(system: system, model: Brain.model)
            defer { session.close() }
            let reply = try await session.send("Recording:\n" + recording.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
            guard let json = Brain.json(from: reply), let name = json["name"] as? String,
                  let steps = json["steps"] as? [String], !steps.isEmpty else {
                lastError = "Couldn't make sense of that recording"
                return
            }
            all.insert(Skill(name: name, summary: json["summary"] as? String ?? "",
                             parameters: json["parameters"] as? [String] ?? [], steps: steps, created: Date()), at: 0)
            if !save() { lastError = "Learned “\(name)”, but couldn't save it to disk" }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// How skills are described to the agent.
    var promptText: String {
        guard !all.isEmpty else { return "" }
        return all.prefix(15).map { s in
            "- \(s.name): \(s.summary)\(s.parameters.isEmpty ? "" : " (needs: \(s.parameters.joined(separator: ", ")))")\n  Steps: "
                + s.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// False when the skills could not be written (the in-memory list still has the change until the app quits).
    @discardableResult
    private func save() -> Bool {
        guard !readOnly, let data = try? JSONEncoder().encode(all) else { return false }
        if let error = StoreFile.write(data, to: url) { lastError = "Skills couldn't be saved: \(error.localizedDescription)"; return false }
        return true
    }
}
