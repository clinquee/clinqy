import Foundation

@main
struct ConnectionDraftsTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }
    static func main() {
        var d = ConnectionDrafts()
        // Typed OpenAI key, switch to Anthropic: the field must not carry the OpenAI key across.
        d.stash("sk-openai", for: "openai")
        check(d.draft(for: "anthropic", saved: nil) == "", "other provider starts empty")
        check(d.draft(for: "anthropic", saved: "saved-anthropic") == "saved-anthropic", "saved key used when no draft")
        check(d.draft(for: "openai", saved: "old") == "sk-openai", "switching back restores the draft")

        // A slow failing test is superseded by a retry: only the retry may report.
        let first = d.beginTest()
        let retry = d.beginTest()
        check(!d.accepts(first), "old test is retired by the retry")
        check(d.accepts(retry), "retry result is applied")
        // Provider change retires a running test.
        d.beginTest()
        check(!d.accepts(retry), "provider change retires the running test")
        d.reset()
        check(d.draft(for: "openai", saved: nil) == "", "reset clears drafts")
        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("connection drafts: all checks passed")
    }
}
