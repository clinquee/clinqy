import Foundation

/// Which question a notification response belongs to. Every question notification carries its own identifier;
/// a response is honoured only while that question is still the live one, and it resolves through the options that
/// notification was issued with, never through whatever question was asked last.
struct NotificationLedger {
    static let questionPrefix = "clinqy.question."

    enum Resolution: Equatable {
        case answer(String)
        case open(question: Bool)
        /// The response belongs to a question that has been answered, cleared or replaced.
        case stale
    }

    private(set) var liveID: String?
    private var options: [String: String] = [:]

    /// A new question: the previous one is retired. Returns the notification identifier to post it under.
    mutating func issue(options list: [String], sensitive: Bool) -> (id: String, actions: [(id: String, title: String)]) {
        let id = Self.questionPrefix + UUID().uuidString
        liveID = id
        options = [:]
        var actions: [(String, String)] = []
        if !sensitive {
            for (i, option) in list.prefix(4).enumerated() {
                let action = "option.\(i)"
                options[action] = option
                actions.append((action, String(option.prefix(40))))
            }
        }
        return (id, actions)
    }

    mutating func clear() { liveID = nil; options = [:] }

    static func isQuestion(_ notificationID: String) -> Bool { notificationID.hasPrefix(questionPrefix) }

    func resolve(notificationID: String, action: String, typed: String?) -> Resolution {
        guard Self.isQuestion(notificationID) else { return .open(question: false) }
        guard notificationID == liveID else { return .stale }
        switch action {
        case "reply":
            if let typed, !typed.trimmingCharacters(in: .whitespaces).isEmpty { return .answer(typed) }
            return .open(question: true)
        case let id where options[id] != nil:
            return .answer(options[id]!)
        default:
            return .open(question: true)
        }
    }
}
