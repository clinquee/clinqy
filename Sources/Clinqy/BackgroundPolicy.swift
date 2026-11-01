import Foundation

/// Pure capability routing: a background task never falls through to native focus, keyboard or clipboard input.
enum BackgroundPolicy {
    enum Route: Equatable { case api, browser, attention(String) }

    static func route(_ action: [String: Any], hasWorkerPage: Bool) -> Route {
        let kind = (action["do"] as? String ?? "").lowercased()
        let webID = (action["id"] as? String)?.lowercased().hasPrefix("w") == true
        switch kind {
        case "parallel_browser": return .api
        case "open_url": return .browser
        case "open_app":
            let name = (action["name"] as? String ?? "").lowercased()
            if ["chrome", "google chrome", "arc", "brave", "brave browser", "edge", "microsoft edge", "browser"].contains(name) { return .browser }
            if name.contains("finder") { return .attention("Use the files action to find, list, rename or move files without opening Finder.") }
            return .attention("This task needs a native app. Its input cannot be isolated safely in background mode.")
        case "hover", "right_click", "double_click", "drag":
            let destinationIsWeb = (action["to_id"] as? String)?.hasPrefix("w") == true
            return hasWorkerPage && webID && (kind != "drag" || destinationIsWeb) ? .browser
                : .attention("Gestures need current element ids on the owned browser page; native gestures require foreground mode.")
        case "click", "type", "choose", "fill":
            return hasWorkerPage && (webID || (action["id"] == nil && kind == "type")) ? .browser
                : .attention("No owned browser page target is available. I won't use your active window.")
        case "key":
            let key = (action["keys"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            let commands = ["cmd", "command", "meta", "super", "ctrl", "control", "alt", "option"]
            if commands.contains(where: { key.contains($0 + "+") }) && !["cmd+a", "command+a", "meta+a", "ctrl+a", "control+a"].contains(key) {
                return .attention("This shortcut can use shared browser or system state. Use page fields, direct uploads or file tools instead.")
            }
            return hasWorkerPage ? .browser : .attention("No owned browser page is available for this key.")
        case "verify":
            if action["path"] as? String != nil { return .api }
            return hasWorkerPage && (!((action["value"] as? String) != nil) || webID) ? .browser
                : .attention("Verify a saved file path or an outcome on the owned browser page. I won't inspect your foreground window.")
        case "image" where action["path"] != nil: return .api
        case "images", "image": return hasWorkerPage ? .browser : .attention("Open an owned task page before reading its images.")
        case "read", "extract":
            return action["path"] != nil || action["file"] != nil ? .api : hasWorkerPage ? .browser : .attention("Give a file path or open a task browser page. I won't read your foreground document.")
        case "files":
            return ["show", "reveal"].contains((action["op"] as? String ?? "").lowercased())
                ? .attention("Revealing files opens Finder on your desktop. I can return their paths in the results instead.") : .api
        case "table":
            return (action["to"] as? String ?? "csv").lowercased() == "csv" ? .api : .attention("Write a CSV file in background mode. Spreadsheet windows and the shared clipboard need foreground access.")
        case "wait" where action["for"] == nil: return .api
        case "upload", "autofill", "review", "scroll", "tab", "look", "snap", "wait":
            return hasWorkerPage ? .browser : .attention("This action needs an owned browser task page. Open its URL first.")
        case "pdf":
            let paths = (action["files"] as? [String] ?? []) + [action["file"] as? String].compactMap { $0 }
            if paths.contains(where: { ["key", "keynote", "doc", "docx", "csv", "ppt", "pptx", "xls", "xlsx", "numbers", "pages"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) {
                return .attention("This conversion opens an iWork application. Use foreground mode for it.")
            }
            return .api
        case "delegate", "collect", "think", "dictionary", "remember_answer", "calendar", "media", "application", "remember", "recall", "event", "reminder", "ask", "show", "assert", "schedule": return .api
        case "email": return action["draft"] as? Bool == true ? .attention("A draft opens a Mail window. Use foreground mode to review it there.") : .api
        case "shell", "applescript": return .attention("Arbitrary scripts can change your desktop or shared input. Use the files, PDF, media or other supported actions in background mode.")
        default: return .attention("This action requires native desktop access and cannot run safely in background mode.")
        }
    }
}
