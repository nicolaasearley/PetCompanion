import Foundation

/// Daily-plan boundary — WP-5. The server-generated plan (engine pipeline)
/// arrives behind this protocol later with no UI changes.
@MainActor
protocol PlanService: AnyObject {
    /// The plan for one pet on one local day.
    /// - Parameter resectioningCompleted: when true, items completed since
    ///   generation move to the Completed section — the "next natural list
    ///   update" from doc 09 §8; a plain fetch never re-sections, so a
    ///   just-completed card stays inline (no plan-jumping, engine §4.3).
    func plan(
        forPet petId: UUID,
        on date: Date,
        resectioningCompleted: Bool
    ) async throws -> PlanSnapshot

    /// Completes an item (optimistically confirmed). Completing a
    /// recommendation promotes it to a real occurrence first (doc 10 §10.3).
    func completeItem(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot

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

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to continue."
        case .planNotFound: "That plan couldn't be loaded. Pull to refresh."
        case .itemNotFound: "That item couldn't be found. Pull to refresh."
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
