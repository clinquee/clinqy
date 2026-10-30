import Foundation

/// Credentials that turn up in command output or typed text (an access token printed by `gh auth token`, an API key
/// in a config file): masked before anything is written to the log, History or the replay cache.
enum Secrets {
    private static let patterns: [NSRegularExpression] = [
        #"\b(gh[pousr]_)[A-Za-z0-9]{20,}"#,              // GitHub tokens
        #"\b(github_pat_)[A-Za-z0-9_]{20,}"#,
        #"\b(sk-(?:ant-|proj-)?)[A-Za-z0-9_\-]{20,}"#,   // Anthropic / OpenAI keys
        #"\b(AIza)[A-Za-z0-9_\-]{30,}"#,                 // Google API keys
        #"\b(xox[abprs]-)[A-Za-z0-9\-]{10,}"#,           // Slack tokens
        #"\b(AKIA)[0-9A-Z]{16}\b"#,                      // AWS access key ids
        #"\b(\d{8,10}:)[A-Za-z0-9_\-]{35}\b"#,           // Telegram bot tokens
        #"(?i)\b((?:aws_secret_access_key|secret|password|passwd|api[_-]?key|token)\s*[=:]\s*)[^\s"',;]{8,}"#,
        #"(?i)\b(bearer\s+)[A-Za-z0-9._\-]{20,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func mask(_ text: String) -> String {
        var out = text
        for p in patterns {
            out = p.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1[redacted]")
        }
        return out
    }

    /// Redact every string value, including nested trace arguments and result cards, without damaging JSON syntax.
    static func maskJSON(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func scrub(_ value: Any) -> Any {
            if let text = value as? String { return mask(text) }
            if let array = value as? [Any] { return array.map(scrub) }
            if let dict = value as? [String: Any] { return dict.mapValues(scrub) }
            return value
        }
        return try? JSONSerialization.data(withJSONObject: scrub(object), options: [.sortedKeys])
    }
}
