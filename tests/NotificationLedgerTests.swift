import Foundation

@main
struct NotificationLedgerTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

    static func main() {
        var ledger = NotificationLedger()
        let first = ledger.issue(options: ["Yes", "No"], sensitive: false)
        check(first.actions.map(\.title) == ["Yes", "No"], "options become actions")
        check(ledger.resolve(notificationID: first.id, action: "option.1", typed: nil) == .answer("No"), "live option resolves")

        // A newer question retires the older one: a delayed response to the first must not answer the second.
        let second = ledger.issue(options: ["Send", "Cancel"], sensitive: false)
        check(first.id != second.id, "each question has its own identity")
        check(ledger.resolve(notificationID: first.id, action: "option.0", typed: nil) == .stale, "old option is stale")
        check(ledger.resolve(notificationID: first.id, action: "reply", typed: "yes") == .stale, "old typed reply is stale")
        check(ledger.resolve(notificationID: second.id, action: "option.0", typed: nil) == .answer("Send"), "new option uses new options")

        // Empty typed reply opens Clinqy instead of answering.
        check(ledger.resolve(notificationID: second.id, action: "reply", typed: "  ") == .open(question: true), "blank reply opens")

        // Sensitive questions expose no answer path.
        let secret = ledger.issue(options: ["x"], sensitive: true)
        check(secret.actions.isEmpty, "sensitive has no actions")
        check(ledger.resolve(notificationID: secret.id, action: "option.0", typed: nil) == .open(question: true), "sensitive option cannot answer")

        // Cleared question: nothing resolves.
        ledger.clear()
        check(ledger.resolve(notificationID: secret.id, action: "reply", typed: "x") == .stale, "cleared is stale")

        // Done notifications are not questions.
        check(ledger.resolve(notificationID: "clinqy.done.abc", action: "show", typed: nil) == .open(question: false), "done opens work")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("notification ledger: all checks passed")
    }
}
