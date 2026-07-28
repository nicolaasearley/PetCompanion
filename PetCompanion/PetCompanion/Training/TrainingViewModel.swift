import Foundation
import Observation

/// State behind the Training stack (TR-01 to TR-05).
///
/// It holds one `TrainingOverview` so every screen renders the same moment:
/// the catalogue, the household's goals and the logged sessions are read
/// together, and each mutation replaces the affected goal in place rather than
/// leaving the list to guess.
@MainActor
@Observable
final class TrainingViewModel {
    private(set) var overview = TrainingOverview()
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// The last failed action, in the caregiver's terms. Actions never fail
    /// silently and never optimistically claim success.
    var errorMessage: String?
    /// Skill content id currently being started/paused/resumed, so exactly one
    /// button shows progress.
    private(set) var busySkillRef: String?

    private let service: any TrainingService
    private let calendar: Calendar

    init(service: any TrainingService, calendar: Calendar = .current) {
        self.service = service
        self.calendar = calendar
    }

    func load(petId: UUID?, force: Bool = false) async {
        guard let petId else {
            overview = TrainingOverview()
            hasLoaded = true
            return
        }
        guard force || !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            overview = try await service.overview(petId: petId)
            hasLoaded = true
            errorMessage = nil
        } catch {
            // A failed refresh keeps whatever was last shown: cached goals and
            // logged history stay readable when content is unavailable (TR-01
            // "content unavailable → cached catalogue + logged history intact").
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }

    // MARK: - Goal lifecycle

    func start(skill: TrainingSkill, petId: UUID?) async {
        guard let petId else {
            errorMessage = TrainingError.noPet.localizedDescription
            return
        }
        await perform(skillRef: skill.contentId) {
            try await self.service.startGoal(petId: petId, skillRef: skill.contentId)
        }
    }

    func pause(_ goal: TrainingGoal) async {
        await perform(skillRef: goal.skillRef) { try await self.service.pauseGoal(goal) }
    }

    func resume(_ goal: TrainingGoal) async {
        await perform(skillRef: goal.skillRef) { try await self.service.resumeGoal(goal) }
    }

    func retire(_ goal: TrainingGoal) async {
        await perform(skillRef: goal.skillRef) { try await self.service.retireGoal(goal) }
    }

    func updateProgress(_ goal: TrainingGoal, to state: TrainingProgressState) async {
        await perform(skillRef: goal.skillRef) {
            try await self.service.updateProgress(goal, to: state)
        }
    }

    // MARK: - Sessions

    /// TR-04. Returns true when the session was recorded, so the sheet only
    /// dismisses on a confirmed write.
    func logSession(
        goal: TrainingGoal,
        effectiveDate: Date,
        durationMinutes: Int?,
        outcomeNote: String?,
        progressStateAfter: TrainingProgressState?
    ) async -> Bool {
        busySkillRef = goal.skillRef
        defer { busySkillRef = nil }
        do {
            let session = try await service.logSession(
                goal: goal,
                effectiveDate: effectiveDate,
                durationMinutes: durationMinutes,
                outcomeNote: outcomeNote,
                progressStateAfter: progressStateAfter
            )
            overview.recentSessions.insert(session, at: 0)
            if let index = overview.goals.firstIndex(where: { $0.id == goal.id }) {
                overview.goals[index].sessionCount += 1
                overview.goals[index].lastSessionOn = max(
                    overview.goals[index].lastSessionOn ?? effectiveDate,
                    effectiveDate
                )
                // US-063: only an explicit selection moves the state.
                if let progressStateAfter {
                    overview.goals[index].progressState = progressStateAfter
                    overview.goals[index].progressStateUpdatedAt = Date()
                }
                overview.goals[index].revision += 1
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Derived views of the overview

    /// TR-02's "fits current stage" filter, plus free-text search.
    func skills(matching query: String, stage: DevelopmentStage, fitsStageOnly: Bool) -> [TrainingSkill] {
        overview.catalogue.filter { skill in
            let matchesQuery = query.isEmpty
                || skill.title.localizedCaseInsensitiveContains(query)
                || skill.skillGroup.localizedCaseInsensitiveContains(query)
            let matchesStage = !fitsStageOnly || Self.rank(skill.stageGuidance) <= Self.rank(stage)
            return matchesQuery && matchesStage
        }
    }

    /// TR-01's "Suggested next": stage-appropriate skills with every
    /// prerequisite under way and no goal yet. Browsing never schedules
    /// anything (US-060) — this is a suggestion, not a commitment.
    func suggestedStarters(stage: DevelopmentStage, limit: Int = 3) -> [TrainingSkill] {
        overview.catalogue
            .filter { overview.goal(forSkill: $0.contentId) == nil }
            .filter { Self.rank($0.stageGuidance) <= Self.rank(stage) }
            .filter { overview.unmetPrerequisites(for: $0).isEmpty }
            .sorted { Self.rank($0.stageGuidance) > Self.rank($1.stageGuidance) }
            .prefix(limit)
            .map { $0 }
    }

    func actorName(_ userId: UUID?) -> String {
        guard let userId else { return "Someone" }
        return overview.actorNames[userId] ?? "A caregiver"
    }

    static func rank(_ stage: DevelopmentStage) -> Int {
        DevelopmentStage.allCases.firstIndex(of: stage) ?? 0
    }

    private func perform(
        skillRef: String,
        _ action: @escaping () async throws -> TrainingGoal
    ) async {
        busySkillRef = skillRef
        defer { busySkillRef = nil }
        do {
            let updated = try await action()
            if let index = overview.goals.firstIndex(where: { $0.id == updated.id }) {
                // The server response is authoritative for status and revision,
                // but session counts are only present on command results.
                var merged = updated
                if merged.sessionCount == 0 {
                    merged.sessionCount = overview.goals[index].sessionCount
                    merged.lastSessionOn = overview.goals[index].lastSessionOn
                }
                overview.goals[index] = merged
            } else {
                overview.goals.insert(updated, at: 0)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
