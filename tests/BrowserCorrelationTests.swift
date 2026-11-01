import Foundation

@main struct BrowserCorrelationTests {
    static func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL " + message); exit(1) } }

    static func main() {
        // A response is honoured only from the connection its request went to.
        var table = BridgeRequestTable<String, Int>(epoch: "aaaa")
        let a = table.register("waiter-on-new-connection", owner: 2)
        check(table.claim(a, from: 1) == nil, "a response from a different (retired) connection completed the request")
        check(table.count == 1, "a foreign response must leave the request pending")
        check(table.claim(a, from: 2) == "waiter-on-new-connection", "the right connection could not complete it")
        check(table.claim(a, from: 2) == nil, "a request completed twice")

        // Ids from a restarted app (different epoch) never collide with the old process's sequential ids.
        var restarted = BridgeRequestTable<String, Int>(epoch: "bbbb")
        let b = restarted.register("w", owner: 2)
        check(a != b, "ids collide across app restarts: \(a) vs \(b)")
        check(restarted.claim(a, from: 2) == nil, "an old process's id completed a new waiter")
        var sameEpoch = BridgeRequestTable<String, Int>()
        let ids = (0..<5).map { _ in sameEpoch.register("w", owner: 1) }
        check(Set(ids).count == 5, "ids are not unique within a launch")
        check(BridgeRequestTable<String, Int>().epoch != BridgeRequestTable<String, Int>().epoch, "epoch is not per-instance random")

        // Timeout removes it; a late answer then finds nothing. A closed connection fails exactly its own requests.
        var t = BridgeRequestTable<String, Int>(epoch: "cccc")
        let slow = t.register("slow", owner: 1), other = t.register("other", owner: 2), also = t.register("also", owner: 1)
        check(t.discard(slow) == "slow" && t.claim(slow, from: 1) == nil, "late answer after timeout completed something")
        check(Set(t.drain(owner: 1)) == ["also"] && t.count == 1, "closing a connection must fail only its requests")
        check(t.claim(other, from: 2) == "other" && t.claim(also, from: 1) == nil, "drain/claim bookkeeping wrong")
        print("PASS bridge responses bind to their connection, ids survive restarts, timeouts and closes retire requests")

        // Replay offers are per run: A's failure is booked on A's offer, never B's.
        var offers = ReplayOffers()
        let routeA = UUID(), routeB = UUID(), jobA = UUID(), jobB = UUID()
        offers.offer(routeA, to: jobA)
        offers.offer(routeB, to: jobB)
        check(offers.take(run: jobA) == routeA, "run A received another run's offer")
        check(offers.peek(run: jobB) == routeB, "taking A's offer disturbed B's")
        check(offers.take(run: jobA) == nil, "an outcome was booked twice")
        offers.offer(routeA, to: nil)
        check(offers.take(run: jobB) == routeB && offers.take(run: nil) == routeA, "foreground and job offers mixed")
        offers.offer(routeB, to: jobA); offers.clear(run: jobA)
        check(offers.peek(run: jobA) == nil, "clear did not clear")
        print("PASS replay offers are tracked per run, so interleaved jobs cannot book failures on each other's offer")
    }
}
