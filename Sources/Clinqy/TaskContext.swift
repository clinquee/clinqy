import Foundation

/// Each browser job gets independent singleton-backed services. Swift task-local inheritance keeps
/// observations, tabs and undo/replay state with the job across suspension and child tasks.
final class TaskExecutionContext: @unchecked Sendable {
    let id: UUID
    @MainActor private var services: [ObjectIdentifier: AnyObject] = [:]
    init(id: UUID = UUID()) { self.id = id }
    @MainActor func service<T: AnyObject>(_ type: T.Type, make: () -> T) -> T {
        let key = ObjectIdentifier(type)
        if let existing = services[key] as? T { return existing }
        let created = make(); services[key] = created; return created
    }
}

enum TaskExecution {
    @TaskLocal static var current: TaskExecutionContext?
}

enum BrowserTaskRouting {
    static func browser(in text: String) -> String? {
        let value = text.lowercased()
        for (pattern, name) in [(#"\b(chrome|google chrome)\b"#, "Google Chrome"), (#"\barc\b"#, "Arc"),
                                (#"\bbrave\b"#, "Brave Browser"), (#"\b(edge|microsoft edge)\b"#, "Microsoft Edge")] {
            if value.range(of: pattern, options: .regularExpression) != nil { return name }
        }
        return nil
    }
    static func isBrowserTask(_ text: String) -> Bool {
        text.range(of: #"(?i)https?://|\b(chrome|browser|website|webpage|youtube|spotify|wikipedia|linkedin|gmail)\b|\bwhatsapp\s+web\b|\b(in|on|using)\s+(arc|brave|edge)\b|\b(open|use|search|work).{0,30}\b(tabs?|arc|brave|edge)\b"#, options: .regularExpression) != nil
    }
    static func requestsExistingTabs(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(already\s+open|existing|current|active|these|those)\b.{0,100}\btabs?\b|\btabs?\b.{0,80}\b(already\s+open|open\s+already)\b"#, options: .regularExpression) != nil
    }
    static func requestsParallel(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(parallel|simultaneously|concurrently|separate tasks)\b|\b([2-9]|[1-9][0-9]|two|three|four|five)\s+(browser\s+)?tabs?\b"#, options: .regularExpression) != nil
    }
}

/// Background jobs consume their own bounded slots; one foreground controller is independent.
/// Coordinators waiting for their children consume no browser execution slot.
enum TaskCapacity {
    static func canStart(background: Bool, foregroundRunning: Bool, backgroundRunning: Int, limit: Int) -> Bool {
        background ? backgroundRunning < max(1, limit) : !foregroundRunning
    }
}

enum CursorVisibility {
    static func suppressPrimary(browserCursor: Bool, backgroundIndicators: Int, foregroundRunning: Bool, inputPanelVisible: Bool = false) -> Bool {
        inputPanelVisible || browserCursor || (backgroundIndicators > 0 && !foregroundRunning)
    }
}
