import Foundation

enum Secrets { static func mask(_ text: String) -> String { text.replacingOccurrences(of: "test-secret", with: "[private]") } }
@main struct BackgroundTaskTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-task-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tasks.json")
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let store = TaskStore(file: file)
        let id = store.enqueue("Submit a sample form", source: .telegram, conversationID: 42)!
        check(store.start(id), "starts persisted task")
        check(store.beginAction(id, kind: "click"), "writes checkpoint before action")
        let queued = store.enqueue("Next task", source: .telegram, conversationID: 42)!
        let restored = TaskStore(file: file)
        check(restored.record(id)?.state == .interrupted, "running becomes interrupted")
        check(restored.record(id)?.pendingAction == "click", "uncertain action survives restart")
        check(!restored.start(id, explicitlyReviewed: true), "never replays interrupted submit")
        check(!restored.start(queued), "restored queue requires review")
        check(restored.start(queued, explicitlyReviewed: true), "review starts queued request")
        restored.endAction(queued, kind: "read", outcome: .confirmed, completedSteps: 1)
        check(restored.record(queued)?.lastConfirmedStep == "read", "records confirmed stage")
        restored.finish(queued, ok: true, answer: "Complete")
        let final = TaskStore(file: file)
        check(final.record(queued)?.state == .succeeded, "terminal result retained")
        let uncertain = final.enqueue("Submit once", source: .mac)!
        check(final.start(uncertain), "starts uncertain action case")
        check(final.beginAction(uncertain, kind: "click"), "checkpoints one submission")
        check(final.endAction(uncertain, kind: "click", outcome: .uncertain, completedSteps: 0), "persists unknown delivery")
        check(final.record(uncertain)?.lastConfirmedStep == nil, "unknown delivery is never confirmed")
        check(final.record(uncertain)?.unverifiedAction == "click", "retains uncertain action separately")
        check(final.beginAction(uncertain, kind: "read"), "permits independent readback")
        check(final.endAction(uncertain, kind: "read", outcome: .confirmed, completedSteps: 1), "records readback")
        check(final.record(uncertain)?.unverifiedAction == "click", "unrelated successful read does not erase uncertain input")
        let crash = TaskStore(file: file)
        check(crash.record(uncertain)?.unverifiedAction == "click", "uncertain outcome survives crash after delivery")
        final.finish(uncertain, ok: true, answer: "Done")
        check(final.record(uncertain)?.state == .failed, "cannot claim task success with unresolved side effect")
        let verified = final.enqueue("Submit and verify", source: .mac)!
        check(final.start(verified), "starts verification case")
        _ = final.beginAction(verified, kind: "click")
        _ = final.endAction(verified, kind: "click", outcome: .unverified, completedSteps: 0)
        check(final.confirmAction(verified, evidence: "new receipt number"), "explicit verification resolves input")
        check(final.record(verified)?.unverifiedAction == nil, "clears only verified outcome")
        final.finish(verified, ok: true, answer: "Receipt confirmed")
        check(final.record(verified)?.state == .succeeded, "verified task can complete")
        let scheduled = final.enqueue("Scheduled once", source: .mac, idempotencyKey: "schedule:42")!
        check(final.enqueue("Scheduled once", source: .mac, idempotencyKey: "schedule:42") == scheduled, "durable dispatch deduplicates queued occurrence")
        check(final.start(scheduled), "starts scheduled occurrence")
        final.finish(scheduled, ok: true, answer: "Complete")
        check(final.enqueue("Scheduled once", source: .mac, idempotencyKey: "schedule:42") == scheduled, "never re-enqueues completed scheduled occurrence")
        let absent: String? = nil
        let initial = "[false,null,null,null,null,\"\",\"https://example.test/\",\"old-text\",false]"
        let textChange = "[false,null,null,null,null,\"\",\"https://example.test/\",\"new-text\",true]"
        let checked = "[true,null,null,null,null,\"\",\"https://example.test/\",\"old-text\",true]"
        check(ActionOutcome.browserClick(before: absent, after: checked, consequential: false) == .unverified, "unreadable pre-state cannot confirm input")
        check(ActionOutcome.browserClick(before: initial, after: absent, consequential: false) == .unverified, "unreadable post-state cannot confirm input")
        check(ActionOutcome.browserClick(before: initial, after: textChange, consequential: false) == .unverified, "unrelated text or focus change does not confirm target")
        check(ActionOutcome.browserClick(before: initial, after: checked, consequential: false) == .confirmed, "target checked state is valid evidence")
        check(ActionOutcome.browserClick(before: initial, after: checked, consequential: true) == .unverified, "submission still requires acknowledgement")
        check(ActionOutcome.browserClick(before: "invalid", after: checked, consequential: false) == .unverified, "invalid observation fails closed")
        check(!VerificationEvidence.changedValue(before: "old", after: "new", expected: "new", sameTarget: true, fieldInput: false), "field value cannot confirm a consequential submit")
        check(!VerificationEvidence.changedValue(before: "old", after: "new", expected: "new", sameTarget: false, fieldInput: true), "unrelated field cannot confirm input")
        check(!VerificationEvidence.changedValue(before: "new", after: "new", expected: "new", sameTarget: true, fieldInput: true), "preexisting field value does not establish an uncertain input")
        check(!VerificationEvidence.changedValue(before: nil, after: "new", expected: "new", sameTarget: true, fieldInput: true), "unreadable baseline does not confirm input")
        check(VerificationEvidence.changedValue(before: "old", after: "new", expected: "new", sameTarget: true, fieldInput: true), "fresh changed target value confirms field input")
        check(!VerificationEvidence.newText("Receipt", before: "Receipt already present", after: "Receipt already present"), "preexisting receipt text cannot confirm another submit")
        check(!VerificationEvidence.newText("Receipt", before: nil, after: "Receipt 123"), "missing baseline cannot confirm new text")
        check(VerificationEvidence.newText("Receipt", before: "Submit", after: "Receipt 123"), "new receipt text is independent confirmation")
        let duplicate = [TargetResolution.Candidate(index: 2, identity: "Delete"), .init(index: 3, identity: "Delete")]
        check(TargetResolution.unique(index: 1, identity: "Delete", candidates: duplicate, stableIndex: false) == nil, "duplicate controls never resolve by nearest position")
        check(TargetResolution.unique(index: 2, identity: "Delete", candidates: duplicate, stableIndex: true) == 2, "valid live identity remains addressable")
        check(TargetResolution.unique(index: 1, identity: "Delete", candidates: [.init(index: 3, identity: "Delete")], stableIndex: false) == 3, "unique semantic match can be resolved")
        let secret = final.enqueue("Use test-secret", source: .mac)!
        check(final.record(secret)?.request == "Use [private]", "redacts persisted request")
        check(!final.start(secret, explicitlyReviewed: true), "redacted request must be rewritten")
        let missing = final.enqueue("Upload", files: [root.appendingPathComponent("missing")], source: .mac)!
        check(!final.start(missing) && final.active == nil, "missing attachment cannot run or block queue")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        check(mode == 0o600, "history is private")
        let bad = root.appendingPathComponent("broken.json")
        try Data("broken".utf8).write(to: bad)
        let corrupt = TaskStore(file: bad)
        check(corrupt.enqueue("No execution", source: .mac) == nil, "corrupt storage fails closed")
        check(try String(contentsOf: bad, encoding: .utf8) == "broken", "preserves corrupt original")
        func denied(_ action: [String: Any]) -> Bool { if case .attention = BackgroundPolicy.route(action, hasWorkerPage: true) { return true }; return false }
        for action: [String: Any] in [["do":"open_app","name":"Finder"], ["do":"shell"], ["do":"applescript"], ["do":"paste_snaps"], ["do":"files","op":"reveal"], ["do":"key","keys":"cmd+v"], ["do":"table","to":"clipboard"], ["do":"click","id":"e2"]] {
            check(denied(action), "blocks shared desktop action: \(action)")
        }
        check(BackgroundPolicy.route(["do":"files","op":"list"], hasWorkerPage: false) == .api, "Finder work routes to filesystem")
        check(BackgroundPolicy.route(["do":"delegate"], hasWorkerPage: false) == .api, "delegation doesn't require foreground access")
        check(BackgroundPolicy.route(["do":"collect"], hasWorkerPage: false) == .api, "worker collection doesn't require foreground access")
        check(BackgroundPolicy.route(["do":"type","id":"w2"], hasWorkerPage: true) == .browser, "owned web field allowed")
        check(BackgroundPolicy.route(["do":"key","keys":"cmd+a"], hasWorkerPage: true) == .browser, "owned select-all allowed")
        print("PASS: \(checks) task recovery and background policy checks")
    }
}
