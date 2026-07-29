import Foundation
import Observation

/// The one in-memory Daily Plan that Home and Planner both render (doc 19).
///
/// Both surfaces act on the same household work, so a change one of them
/// confirms has to be visible in the other without waiting for that surface
/// to refetch. Keeping the snapshot here — rather than inside `HomeViewModel`
/// with every Planner adapter reaching back into it — makes that true for the
/// production adapter as well as the compatibility one.
///
/// `reconciliationEpoch` bumps when multi-device Realtime (or a foreground
/// safety refresh) asks dependent surfaces to re-read. Home primarily follows
/// `snapshot`; Planner agenda follows the epoch with a visible-window refresh
/// that also re-attaches household Events for US-080.
@MainActor
@Observable
final class SharedPlanState {
    var snapshot: PlanSnapshot?
    /// Monotonic signal for surfaces that hold their own fetched windows
    /// (Planner agenda). Cleared on sign-out with the snapshot.
    private(set) var reconciliationEpoch: UInt64 = 0

    /// Sign-out and account switches: the next account must never inherit a
    /// previous household's plan.
    func clear() {
        snapshot = nil
        reconciliationEpoch = 0
    }

    /// Publishes a server-verified snapshot from remote reconciliation and
    /// notifies dependent surfaces.
    func publishRemote(_ snapshot: PlanSnapshot) {
        self.snapshot = snapshot
        reconciliationEpoch &+= 1
    }

    /// Bumps the epoch without replacing the snapshot — used when a refresh
    /// attempt failed or only returned a cache-served copy that must not
    /// overwrite a live in-memory plan, while Planner should still try its
    /// own agenda read (tasks + attached events).
    func noteReconciliationSignal() {
        reconciliationEpoch &+= 1
    }
}
