import Foundation

/// What a model session was asked for, what it resolved to and what is actually sent: one inspectable record,
/// logged when the session starts, so two runs can be compared knowing they really used the same model, reasoning
/// effort, transport and image context (a requested name alone says none of that).
struct ModelRoute: Equatable {
    var provider: String
    var requestedModel: String
    /// The provider's own model id; empty = the CLI picks its account default.
    var resolvedModel: String
    /// The effort asked for (argument or configuration), or nil when none was configured.
    var requestedEffort: String?
    /// The effort value that reaches the service, or nil when none is sent (unsupported, or left to the default).
    var sentEffort: String?
    var transport: String
    var imageHistory: String
    var tools: String
    /// Set when this is a fast-lane helper: its role.
    var role = "lead"

    var summary: String {
        let fields: [(String, String)] = [
            ("role", role), ("provider", provider), ("requested", requestedModel),
            ("model", resolvedModel.isEmpty ? "(cli default)" : resolvedModel),
            ("effort_requested", requestedEffort ?? "-"), ("effort_sent", sentEffort ?? "-"),
            ("transport", transport), ("images", imageHistory), ("tools", tools),
        ]
        return "model route: " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    /// The effort a Codex CLI accepts for `model_reasoning_effort`; nil when none was configured.
    static func codexEffort(_ requested: String?) -> String? {
        guard let value = requested?.lowercased().trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        switch value {
        case "min", "minimal", "none": return "minimal"
        case "max": return "high"
        case "low", "medium", "high", "xhigh": return value
        default: return nil
        }
    }

    /// OpenAI's `reasoning_effort` for a model that has one (gpt-5.x, o-series); nil for models that don't.
    static func openAIEffort(model: String, effort: String) -> String? {
        guard model.hasPrefix("gpt-5") || model.range(of: #"^o\d"#, options: .regularExpression) != nil else { return nil }
        return ["min", "minimal", "none"].contains(effort) ? "minimal" : effort == "max" ? "high" : effort
    }

    /// Gemini only takes two thinking levels.
    static func geminiLevel(_ effort: String) -> String { effort == "high" || effort == "max" ? "high" : "low" }
}
