import Foundation

/// How Clinqy has been doing, from ~/Library/Logs/Clinqy/runs.jsonl (one line per run) and the "✗" lines in
/// agent.log: success rate, run times, seconds per model turn, why runs fail, and which apps it works in.
enum StatsCard {
    struct Run {
        let date: Date?
        let request: String
        let ok: Bool
        let stopped: Bool
        let seconds: Double
        let turns: Int
        var modelSeconds: Double? = nil
        let app: String
    }

    private static let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clinqy")

    static func runs() -> [Run] {
        guard let text = try? String(contentsOf: logs.appendingPathComponent("runs.jsonl"), encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        return text.split(separator: "\n").compactMap { line in
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
            return Run(date: (obj["date"] as? String).flatMap(iso.date(from:)), request: obj["request"] as? String ?? "",
                       ok: obj["ok"] as? Bool ?? false, stopped: obj["stopped"] as? Bool ?? false,
                       seconds: (obj["seconds"] as? NSNumber)?.doubleValue ?? 0, turns: (obj["turns"] as? NSNumber)?.intValue ?? 0,
                       modelSeconds: (obj["model_seconds"] as? NSNumber)?.doubleValue,
                       app: (obj["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—")
        }
    }

    /// Why runs ended badly ("[ 92.81s] ✗ Stopped") and why steps failed ("[ 7.98s]     ✗ FAILED: …"), grouped.
    static func failures() -> (runs: [(String, Int)], steps: [(String, Int)]) {
        let files = ["agent.log.1", "agent.log"].map { logs.appendingPathComponent($0) }
        var runEnds: [String: Int] = [:], stepFails: [String: Int] = [:]
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("✗") {
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]"), let mark = line.range(of: "✗ "),
                      close < mark.lowerBound else { continue }
                let indent = line[line.index(after: close)..<mark.lowerBound].count
                let reason = normalize(String(line[mark.upperBound...]))
                guard !reason.isEmpty else { continue }
                if indent <= 1 { runEnds[reason, default: 0] += 1 } else { stepFails[reason, default: 0] += 1 }
            }
        }
        func top(_ d: [String: Int]) -> [(String, Int)] { d.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) } }
        return (top(runEnds), top(stepFails))
    }

    /// Groups similar reasons: quoted names, numbers and element ids are replaced, long tails cut.
    private static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("FAILED: ") { s.removeFirst(8) }
        if s.hasPrefix("I got stuck on") { return "Got stuck on a step (no progress for 30 s)" }
        if s.hasPrefix("Ran out of steps") { return "Ran out of steps" }
        if s.hasPrefix("I kept trying the same thing") { return "Kept repeating the same action" }
        for (pattern, with) in [(#"“[^”]*”?"#, "“…”"), (#""[^"]*""#, "\"…\""), (#"\b[ewx]\d+\b"#, "#"), (#"\d+(\.\d+)?"#, "N")] {
            s = s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
        }
        if let cut = s.firstIndex(where: { $0 == "(" || $0 == ":" || $0 == ";" }), s.distance(from: s.startIndex, to: cut) > 12 {
            s = String(s[..<cut])
        }
        return String(s.prefix(90)).trimmingCharacters(in: .whitespaces)
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let i = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[i]
    }

    private static func secs(_ s: Double) -> String {
        s >= 90 ? String(format: "%.1f min", s / 60) : String(format: "%.0f s", s)
    }

    /// The Stats card (menu: Stats…).
    static var card: ResultCard {
        let all = runs()
        guard !all.isEmpty else {
            return ResultCard(title: "Stats", text: "No runs logged yet — ~/Library/Logs/Clinqy/runs.jsonl fills up as Clinqy works.", items: [])
        }
        let ok = all.filter(\.ok).count, stopped = all.filter(\.stopped).count
        let week = all.filter { ($0.date ?? .distantPast) > Date().addingTimeInterval(-7 * 86400) }
        func rate(_ runs: [Run]) -> String { runs.isEmpty ? "—" : "\(Int((Double(runs.filter(\.ok).count) / Double(runs.count) * 100).rounded()))%" }
        let times = all.filter(\.ok).map(\.seconds).sorted()
        let turnRuns = all.filter { $0.turns > 0 }
        let measured = turnRuns.filter { $0.modelSeconds != nil }
        let perTurn = measured.isEmpty ? 0 : measured.compactMap(\.modelSeconds).reduce(0, +) / Double(measured.map(\.turns).reduce(0, +))
        let avgTurns = turnRuns.isEmpty ? 0 : Double(turnRuns.map(\.turns).reduce(0, +)) / Double(turnRuns.count)

        var items: [ResultCard.Item] = [
            .init(title: "Success rate", subtitle: "\(ok) of \(all.count) runs · \(stopped) stopped by you · last 7 days: \(rate(week)) of \(week.count)",
                  detail: rate(all), link: nil),
            .init(title: "Time to finish (successful runs)", subtitle: "median · p90 \(secs(percentile(times, 0.9)))",
                  detail: secs(percentile(times, 0.5)), link: nil),
            .init(title: "Seconds per model turn", subtitle: String(format: "%.1f turns per run · %d runs with model timings", avgTurns, measured.count),
                  detail: measured.isEmpty ? "—" : String(format: "%.1f s", perTurn), link: nil),
        ]
        let (runEnds, stepFails) = failures()
        for (reason, n) in runEnds {
            items.append(.init(title: reason, subtitle: "run ended badly", detail: "\(n)×", link: nil))
        }
        for (reason, n) in stepFails.prefix(4) {
            items.append(.init(title: reason, subtitle: "step failed", detail: "\(n)×", link: nil))
        }
        let apps = Dictionary(grouping: all, by: \.app).sorted { $0.value.count > $1.value.count }.prefix(8)
        for (app, runs) in apps {
            items.append(.init(title: app, subtitle: "\(rate(runs)) success · median \(secs(percentile(runs.map(\.seconds).sorted(), 0.5)))",
                               detail: "\(runs.count) runs", link: nil))
        }
        let since = all.compactMap(\.date).min().map { " since " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        return ResultCard(title: "Stats · \(all.count) runs\(since)",
                          text: "Top rows: overall numbers. Then why runs failed (from agent.log), then runs per app.", items: items)
    }
}
