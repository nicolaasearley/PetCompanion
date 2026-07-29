import Foundation

/// Training boundary — F08 / epic E06. Every mutation is a write-path command
/// (`start_training_goal`, `pause_training_goal`, `resume_training_goal`,
/// `retire_training_goal`, `update_training_progress`,
/// `log_training_session`); the catalogue and history are RLS-scoped reads.
@MainActor
protocol TrainingService: AnyObject {
    /// One read for TR-01 so the overview never mixes two moments.
    func overview(petId: UUID) async throws -> TrainingOverview
    /// Idempotent (US-061): starting the same skill twice returns the goal
    /// that already exists, unchanged.
    func startGoal(petId: UUID, skillRef: String) async throws -> TrainingGoal
    func pauseGoal(_ goal: TrainingGoal) async throws -> TrainingGoal
    func resumeGoal(_ goal: TrainingGoal) async throws -> TrainingGoal
    func retireGoal(_ goal: TrainingGoal) async throws -> TrainingGoal
    /// Owner-reported only; never inferred from engagement (US-065).
    func updateProgress(_ goal: TrainingGoal, to state: TrainingProgressState) async throws -> TrainingGoal
    /// TR-04. `progressStateAfter` is a separate, deliberate control: a
    /// session on its own never declares mastery (US-063).
    func logSession(
        goal: TrainingGoal,
        effectiveDate: Date,
        durationMinutes: Int?,
        outcomeNote: String?,
        progressStateAfter: TrainingProgressState?
    ) async throws -> TrainingSession
}

@MainActor
final class MockTrainingService: TrainingService {
    private let backend: MockBackend

    init(backend: MockBackend) {
        self.backend = backend
    }

    func overview(petId: UUID) async throws -> TrainingOverview {
        try? await Task.sleep(for: .milliseconds(150))
        return backend.trainingOverview(petId: petId)
    }

    func startGoal(petId: UUID, skillRef: String) async throws -> TrainingGoal {
        guard backend.currentUserId != nil else { throw TrainingError.notSignedIn }
        try? await Task.sleep(for: .milliseconds(200))
        return backend.startTrainingGoal(petId: petId, skillRef: skillRef)
    }

    func pauseGoal(_ goal: TrainingGoal) async throws -> TrainingGoal {
        try? await Task.sleep(for: .milliseconds(150))
        return try backend.setTrainingGoalStatus(goal.id, to: .paused)
    }

    func resumeGoal(_ goal: TrainingGoal) async throws -> TrainingGoal {
        try? await Task.sleep(for: .milliseconds(150))
        return try backend.setTrainingGoalStatus(goal.id, to: .active)
    }

    func retireGoal(_ goal: TrainingGoal) async throws -> TrainingGoal {
        try? await Task.sleep(for: .milliseconds(150))
        return try backend.setTrainingGoalStatus(goal.id, to: .retired)
    }

    func updateProgress(_ goal: TrainingGoal, to state: TrainingProgressState) async throws -> TrainingGoal {
        try? await Task.sleep(for: .milliseconds(150))
        return try backend.setTrainingProgress(goal.id, to: state)
    }

    func logSession(
        goal: TrainingGoal,
        effectiveDate: Date,
        durationMinutes: Int?,
        outcomeNote: String?,
        progressStateAfter: TrainingProgressState?
    ) async throws -> TrainingSession {
        try? await Task.sleep(for: .milliseconds(200))
        return try backend.logTrainingSession(
            goalId: goal.id,
            effectiveDate: effectiveDate,
            durationMinutes: durationMinutes,
            outcomeNote: outcomeNote,
            progressStateAfter: progressStateAfter
        )
    }
}
