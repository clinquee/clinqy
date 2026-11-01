import Foundation

/// One typed table of the model-facing actions: which arguments each action reads, which operations it supports and
/// how it is classified for completion evidence. The standalone executor validates against it before any checkpoint
/// or input, so an ignored argument can never change what an action means (for example `op` on a `type`).
enum ActionContract {
    struct Spec {
        /// Arguments the dispatcher reads (besides `do`). nil: not yet enumerated, only the global rules apply.
        let keys: Set<String>?
        /// Supported `op` values; nil when the action has no operation argument.
        let ops: Set<String>?
        init(keys: Set<String>? = nil, ops: Set<String>? = nil) { self.keys = keys; self.ops = ops }
    }

    /// Actions whose dispatcher reads `op`. Anywhere else an `op` is an ignored argument.
    static let opKinds: Set<String> = ["window", "tab", "pdf", "media", "application", "event", "reminder", "files"]

    static let specs: [String: Spec] = [
        "click": Spec(keys: ["id", "x", "y", "text", "nth", "button", "count", "modifiers", "duration_ms"]),
        "hover": Spec(keys: ["id", "x", "y"]),
        "right_click": Spec(keys: ["id", "x", "y"]),
        "double_click": Spec(keys: ["id", "x", "y"]),
        "drag": Spec(keys: ["id", "x", "y", "to_id", "to_x", "to_y"]),
        "type": Spec(keys: ["id", "text", "submit", "mode"]),
        "set_state": Spec(keys: ["id", "state"]),
        "key": Spec(keys: ["keys"]),
        "scroll": Spec(keys: ["dir", "direction", "unit", "amount"]),
        "open_app": Spec(keys: ["name"]),
        "open_url": Spec(keys: ["url"]),
        "menu": Spec(keys: ["path"]),
        "delegate": Spec(keys: ["jobs"]),
        "collect": Spec(keys: ["ids", "wait", "timeout"]),
        "look": Spec(keys: []),
        "paste_snaps": Spec(keys: []),
        "verify": Spec(keys: ["text", "url", "value", "id", "path", "contains", "seconds", "visual", "user_confirms", "sha256", "min_bytes"]),
        "shell": Spec(keys: ["cmd"]),
        "applescript": Spec(keys: ["script"]),
        "wait": Spec(keys: ["ms", "for", "gone", "timeout", "seconds"]),
        "application": Spec(keys: ["op", "query", "company", "role", "url", "status", "resume", "notes"],
                            ops: ["find", "check", "list", "show", "record", "update"]),
        "window": Spec(keys: ["op", "x", "y", "w", "h", "width", "height", "title", "on"],
                       ops: ["move", "resize", "minimize", "restore", "fullscreen", "close", "raise"]),
        "tab": Spec(keys: ["op", "id"], ops: ["list", "switch", "close", "look", "read"]),
    ]

    /// Every action name the Mac standalone dispatcher routes. The prompt, parser and dispatcher are checked against it.
    static let supportedKinds: Set<String> = [
        "open_app", "open_url", "click", "hover", "right_click", "double_click", "drag", "type", "key", "choose", "scroll",
        "menu", "window", "tab", "point", "mark", "read", "images", "image", "ask", "show", "verify", "assert", "snap",
        "paste_snaps", "pdf", "media", "upload", "review", "application", "email", "extract", "table", "event", "reminder",
        "files", "look", "wait", "recall", "remember", "remember_answer", "autofill", "think", "schedule", "dictionary",
        "applescript", "shell", "parallel_browser", "calendar", "set_state", "delegate", "collect",
    ]

    /// Operations that only read. Only these two actions have a read-only `info` operation; `op` on anything else
    /// does not change what the action does and must never lower its classification.
    static func readsOnly(kind: String, op: String) -> Bool {
        (kind == "pdf" || kind == "media") && op.lowercased() == "info"
    }

    private static func isBool(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }
    private static func isNumber(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue.isFinite
    }

    /// nil when the action is well formed; otherwise why it was refused before any input.
    static func validate(_ action: [String: Any]) -> String? {
        let kind = (action["do"] as? String ?? "").lowercased()
        if action["op"] != nil, !opKinds.contains(kind) {
            return "\(kind) takes no op argument; it was not run. Send it without op"
        }
        guard let spec = specs[kind] else { return nil }
        if let allowed = spec.keys {
            let extra = Set(action.keys).subtracting(allowed.union(["do"]))
            if !extra.isEmpty {
                return "\(kind) does not use \(extra.sorted().joined(separator: ", ")); it was not run. Allowed: "
                    + (allowed.isEmpty ? "none" : allowed.sorted().joined(separator: ", "))
            }
        }
        if let ops = spec.ops, let raw = action["op"] {
            guard let op = raw as? String, ops.contains(op.lowercased()) else {
                return "\(kind) op must be one of: " + ops.sorted().joined(separator: ", ")
            }
        }
        switch kind {
        case "scroll":
            if action["dir"] != nil, action["direction"] != nil { return "scroll takes dir or direction, not both" }
            guard action["dir"] != nil || action["direction"] != nil else { return "scroll needs dir: up, down, left or right" }
            if case .failure(let error) = ScrollPlan.parse(action) { return error.message }
        case "window":
            if action["on"] != nil, !isBool(action["on"]) { return "window on must be true or false" }
            if action["on"] != nil, (action["op"] as? String)?.lowercased() != "fullscreen" { return "window on only applies to op fullscreen" }
        case "type":
            if action["submit"] != nil, !isBool(action["submit"]) { return "type submit must be true or false" }
            if let mode = action["mode"] {
                guard let name = (mode as? String)?.lowercased(), TextEditMode(rawValue: name) != nil else { return "type mode must be replace, insert or append" }
                if name != "replace", action["submit"] as? Bool == true { return "type mode \(name) cannot submit; press return in a separate key action" }
            }
        case "set_state":
            guard action["id"] is String else { return "set_state needs the control's id" }
            guard action["state"] != nil else { return "set_state needs state: on, off or a number" }
        case "wait":
            if action["gone"] != nil, !isBool(action["gone"]) { return "wait gone must be true or false" }
            if action["gone"] != nil, action["for"] == nil { return "wait gone needs a for text" }
        case "click", "hover", "right_click", "double_click", "drag":
            let byID = action["id"] != nil, byText = action["text"] != nil
            let byPoint = action["x"] != nil || action["y"] != nil
            if [byID, byText, byPoint].filter({ $0 }).count > 1 {
                return "\(kind) needs exactly one target: id, text or x+y; other target fields would be ignored"
            }
            if byPoint, !(isNumber(action["x"]) && isNumber(action["y"])) { return "\(kind) needs numeric x and y" }
            if kind == "click", case .failure(let error) = ClickOptions.parse(action) { return error.message }
            if kind == "drag", action["to_id"] != nil, action["to_x"] != nil || action["to_y"] != nil {
                return "drag needs one destination: to_id or to_x+to_y"
            }
        case "verify":
            return verifyPredicate(action)
        default: break
        }
        return nil
    }

    /// A verify names exactly one postcondition. Several predicates would otherwise be resolved by a hidden priority,
    /// so a true one could stand in for the others: send one verify per condition instead.
    static func verifyPredicate(_ action: [String: Any]) -> String? {
        var present: [String] = []
        if action["path"] != nil { present.append("path") }
        if action["url"] != nil { present.append("url") }
        if action["value"] != nil { present.append("value") }
        if action["text"] != nil { present.append("text") }
        if action["visual"] != nil { present.append("visual") }
        if action["user_confirms"] != nil { present.append("user_confirms") }
        if present.count > 1 {
            return "verify checks one postcondition (\(present.joined(separator: " and ")) were both given); send one verify action per condition"
        }
        if present.isEmpty { return "verify requires text, an exact url, value with id, a saved-file path, visual (after a fresh look) or user_confirms" }
        if action["value"] != nil, action["id"] == nil { return "verify value needs the field's id" }
        if action["id"] != nil, action["value"] == nil { return "verify id only applies together with value" }
        if (action["sha256"] != nil || action["min_bytes"] != nil), action["path"] == nil { return "verify sha256/min_bytes only apply with path" }
        if action["contains"] != nil, action["path"] == nil { return "verify contains only applies with path" }
        for key in present where !(action[key] is String) { return "verify \(key) must be text" }
        if action["seconds"] != nil, !isNumber(action["seconds"]) { return "verify seconds must be a number" }
        return nil
    }
}

/// Before Return is pressed, the field must hold exactly what was typed. Submitting a changed value cannot be undone.
enum SubmitReadback {
    /// `actual` nil with `unreadable` set means the field cannot be read back (a secure field): the typing itself
    /// was already refused unless the field accepted it, so the submit is not blocked for lack of a value.
    static func allows(expected: String, actual: String?, unreadable: Bool = false) -> Bool {
        if let actual { return actual == expected }
        return unreadable
    }
}
