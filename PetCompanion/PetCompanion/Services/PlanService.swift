import Foundation

/// Daily-plan boundary — WP-5. The server-generated plan (engine pipeline)
/// arrives behind this protocol later with no UI changes.
@MainActor
protocol PlanService: AnyObject {
    /// The plan for one pet on one local day.
    ///
    /// `date` is any instant inside the wanted day *in the household's time
    /// zone* — that is the only zone `plans.local_date` is defined in. A day
    /// with no plan throws `noPlanForDay`; it never resolves to a different
    /// day's plan.
    /// - Parameter resectioningCompleted: when true, items completed since
    ///   generation move to the Completed section — the "next natural list
    ///   update" from doc 09 §8; a plain fetch never re-sections, so a
    ///   just-completed card stays inline (no plan-jumping, engine §4.3).
    ///   It applies to the current local day only: earlier days are read as
    ///   they were left, never regenerated (engine §10.4).
    func plan(
        forPet petId: UUID,
        on date: Date,
        resectioningCompleted: Bool
    ) async throws -> PlanSnapshot

    /// Completes an occurrence-backed item (optimistically confirmed).
    /// Recommendations must be accepted first so that intent is explicit.
    func completeItem(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot

    /// Promotes an optional recommendation into a pending scheduled
    /// occurrence. Acceptance and completion remain separate user intents.
    func acceptRecommendation(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot

    /// Appends an `undo_complete` disposition and returns the occurrence to
    /// pending (US-033).
    func undoCompletion(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot

    /// Applies a capacity mode for today or as the household default and
    /// regenerates recommendations (engine §10.2, §13.1). Required and
    /// scheduled items are untouched.
    func setCapacity(
        _ mode: CapacityMode,
        scope: CapacityScope,
        petId: UUID,
        on date: Date
    ) async throws -> PlanSnapshot

    /// Quick one-time task for today (US-050, minimal PL-02 path).
    func addOneTimeTask(title: String, petId: UUID, on date: Date) async throws -> PlanSnapshot
}

enum PlanServiceError: LocalizedError {
    case notSignedIn
    case planNotFound
    case itemNotFound
    /// A recommendation item was sent to completion before the separate
    /// accept/promote command created its occurrence.
    case recommendationNotYetActionable
    /// The requested local day has no plan at all. Deliberately distinct
    /// from `planNotFound` (a read that failed) and from an empty plan (a
    /// day that *was* planned and held nothing): a day the engine never
    /// generated cannot honestly be described as either.
    case noPlanForDay

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to continue."
        case .planNotFound: "That plan couldn't be loaded. Pull to refresh."
        case .itemNotFound: "That item couldn't be found. Pull to refresh."
        case .recommendationNotYetActionable: "Add this recommendation to today before completing it."
        case .noPlanForDay: "There is no plan for that day."
        }
    }
}

/// Mock implementation backed by the in-memory `MockBackend`, seeded with
/// the engine §26 example plans (26.1 pre-arrival, 26.2 normal day).
@MainActor
final class MockPlanService: PlanService {
    private let backend: MockBackend

    init(backend: MockBackend) {
        self.backend = backend
    }

    func plan(
        forPet petId: UUID,
        on date: Date,
        resectioningCompleted: Bool
    ) async throws -> PlanSnapshot {
        backend.planSnapshot(petId: petId, date: date, resectioningCompleted: resectioningCompleted)
    }

    func completeItem(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot {
        try backend.complete(itemId: itemId, petId: petId, date: date)
    }

    func acceptRecommendation(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot {
        try backend.acceptRecommendation(itemId: itemId, petId: petId, date: date)
    }

    func undoCompletion(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot {
        try backend.undoCompletion(itemId: itemId, petId: petId, date: date)
    }

    func setCapacity(
        _ mode: CapacityMode,
        scope: CapacityScope,
        petId: UUID,
        on date: Date
    ) async throws -> PlanSnapshot {
        backend.setCapacity(mode, scope: scope, petId: petId, date: date)
    }

    func addOneTimeTask(title: String, petId: UUID, on date: Date) async throws -> PlanSnapshot {
        try backend.addOneTimeTask(title: title, petId: petId, date: date)
    }
}
