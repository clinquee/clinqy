import Foundation
import CoreFoundation

/// Host agents own a short lease and a single-use observation. Losing an action reply cannot authorize
/// delivery again: refresh the observation and inspect/verify first. The app serializes each request.
struct ControlLease {
    let session = UUID().uuidString
    private(set) var observation: String?
    private(set) var expires: Date
    init(now: Date = Date()) { expires = now.addingTimeInterval(120) }
    mutating func touch(now: Date = Date()) { expires = now.addingTimeInterval(120) }
    mutating func observe(now: Date = Date()) -> String {
        observation = UUID().uuidString; expires = now.addingTimeInterval(120)
        return observation!
    }
    func accepts(session: String, now: Date = Date()) -> Bool { session == self.session && now < expires }
    mutating func consume(_ token: String, now: Date = Date()) -> Bool {
        guard now < expires, observation == token else { return false }
        observation = nil; expires = now.addingTimeInterval(120); return true
    }
}

enum ControlProtocol {
    static let actions: Set<String> = ["click", "type", "key", "scroll", "hover", "right_click", "double_click", "drag",
        "open_app", "open_url", "read", "look", "verify", "wait"]
    static func validateRequest(_ body: [String: Any]) -> String? {
        guard let op = body["op"] as? String, ["observe", "act", "verify", "wait", "release"].contains(op) else { return "Unknown control operation" }
        for key in ["image", "complete"] where body[key] != nil {
            guard let value = body[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return "Invalid boolean: " + key }
        }
        for key in ["session", "observation"] where body[key] != nil {
            guard let token = body[key] as? String, UUID(uuidString: token) != nil else { return "Invalid " + key + " token" }
        }
        if op == "observe", body["session"] == nil {
            guard let task = body["task"] as? String, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.utf8.count <= 8000 else { return "Initial observe requires the user's task (up to 8000 bytes)" }
        } else if body["session"] == nil { return "session is required" }
        if ["act", "verify", "wait"].contains(op) {
            guard body["observation"] != nil, var action = body["action"] as? [String: Any] else { return "observation and action are required" }
            if op != "act" { action["do"] = op }
            return validate(action)
        }
        return nil
    }
    static func validate(_ action: [String: Any]) -> String? {
        guard let kind = action["do"] as? String, actions.contains(kind) else { return "Unsupported direct action" }
        let allowed: Set<String> = ["do", "id", "to_id", "x", "y", "to_x", "to_y", "seconds", "text", "keys",
            "name", "url", "path", "contains", "value", "for", "submit", "gone", "dir",
            "button", "count", "modifiers", "duration_ms", "unit", "amount", "direction"]
        guard Set(action.keys).isSubset(of: allowed) else { return "Unknown action argument" }
        if kind != "click", !Set(action.keys).isDisjoint(with: ["button", "count", "modifiers", "duration_ms"]) { return "Click options apply only to click" }
        if kind != "scroll", !Set(action.keys).isDisjoint(with: ["unit", "amount", "direction"]) { return "Scroll options apply only to scroll" }
        if kind == "click", case .failure(let error) = ClickOptions.parse(action) { return error.message }
        for key in ["submit", "gone"] where action[key] != nil {
            guard let value = action[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return "Invalid boolean argument: " + key }
        }
        for key in ["id", "to_id"] where action[key] != nil {
            guard let ref = action[key] as? String, ref.range(of: #"^[ew][0-9]{1,4}$"#, options: .regularExpression) != nil else { return "Invalid element reference" }
        }
        for key in ["x", "y", "to_x", "to_y", "seconds"] where action[key] != nil {
            guard let value = action[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  value.doubleValue >= 0 else { return "Invalid numeric argument: " + key }
        }
        if let seconds = action["seconds"] as? NSNumber, seconds.doubleValue > 15 { return "Direct waits are limited to 15 seconds" }
        for key in ["text", "keys", "name", "url", "path", "contains", "value", "for"] where action[key] != nil {
            guard let text = action[key] as? String, text.utf8.count <= 100_000 else { return "Invalid text argument: " + key }
        }
        if ["hover", "right_click", "double_click", "drag", "click"].contains(kind), action["id"] == nil,
           !(action["x"] != nil && action["y"] != nil), !(kind == "click" && action["text"] is String) { return "A target id or screenshot coordinates are required" }
        if kind == "drag", action["to_id"] == nil, !(action["to_x"] != nil && action["to_y"] != nil) { return "A drag destination is required" }
        for (name, key) in [("type", "text"), ("key", "keys"), ("open_app", "name"), ("open_url", "url")] {
            if kind == name, action[key] as? String == nil { return key + " is required" }
        }
        if kind == "verify", !["text", "url", "path", "value"].contains(where: { action[$0] is String }) { return "A verification postcondition is required" }
        if kind == "verify", action["value"] != nil, action["id"] == nil { return "Field verification needs an id" }
        if kind == "verify", action["contains"] != nil, action["path"] == nil { return "File content verification needs a path" }
        if kind == "scroll" {
            if action["dir"] == nil && action["direction"] == nil { return "Scroll direction must be up, down, left or right" }
            if case .failure(let error) = ScrollPlan.parse(action) { return error.message }
        }
        if kind == "wait", action["for"] as? String == nil { return "Direct waits require a text predicate" }
        return nil
    }
}
