import Foundation

/// Which cached replay each run was offered, so a failure is booked against the offer that run actually received.
/// Runs are keyed by their task identity (nil = the single foreground run); interleaved browser jobs never see
/// each other's offers.
struct ReplayOffers {
    private var offers: [UUID?: UUID] = [:]

    mutating func offer(_ route: UUID, to run: UUID?) { offers[run] = route }
    mutating func clear(run: UUID?) { offers.removeValue(forKey: run) }
    /// The offer made to `run`, consumed: a run's outcome is booked once.
    mutating func take(run: UUID?) -> UUID? { offers.removeValue(forKey: run) }
    func peek(run: UUID?) -> UUID? { offers[run] }
}
