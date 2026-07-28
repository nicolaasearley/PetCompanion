import Foundation
import Observation

/// The one in-memory Daily Plan that Home and Planner both render (doc 19).
///
/// Both surfaces act on the same household work, so a change one of them
/// confirms has to be visible in the other without waiting for that surface
/// to refetch. Keeping the snapshot here — rather than inside `HomeViewModel`
/// with every Planner adapter reaching back into it — makes that true for the
/// production adapter as well as the compatibility one.
@MainActor
@Observable
final class SharedPlanState {
    var snapshot: PlanSnapshot?

    /// Sign-out and account switches: the next account must never inherit a
    /// previous household's plan.
    func clear() {
        snapshot = nil
    }
}
