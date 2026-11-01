import Foundation

@main
struct ModelRouteTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }
    static func main() {
        check(ModelRoute.codexEffort(nil) == nil, "unset effort is not forwarded to codex")
        check(ModelRoute.codexEffort("") == nil, "blank effort is not forwarded")
        check(ModelRoute.codexEffort("MAX") == "high", "max maps to a value codex accepts")
        check(ModelRoute.codexEffort("none") == "minimal", "none maps to minimal")
        check(ModelRoute.codexEffort("medium") == "medium", "medium passes through")
        check(ModelRoute.codexEffort("turbo") == nil, "unknown effort is dropped, not sent")
        check(ModelRoute.openAIEffort(model: "gpt-5.6-terra", effort: "max") == "high", "openai max -> high")
        check(ModelRoute.openAIEffort(model: "gpt-4o", effort: "high") == nil, "non-reasoning model gets no effort")
        check(ModelRoute.openAIEffort(model: "o3", effort: "low") == "low", "o-series gets effort")
        check(ModelRoute.geminiLevel("medium") == "low" && ModelRoute.geminiLevel("max") == "high", "gemini two levels")

        let route = ModelRoute(provider: "codex-cli", requestedModel: "sonnet", resolvedModel: "", requestedEffort: "high",
                               sentEffort: "high", transport: "app-server", imageHistory: "per-turn", tools: "none", role: "helper")
        let line = route.summary
        for part in ["role=helper", "provider=codex-cli", "model=(cli default)", "effort_requested=high", "effort_sent=high", "transport=app-server"] {
            check(line.contains(part), "summary names " + part)
        }
        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("model route: all checks passed")
    }
}
