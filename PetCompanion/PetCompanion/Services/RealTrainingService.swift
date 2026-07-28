import Foundation
import Supabase

/// Supabase-backed `TrainingService` (F08, epic E06).
///
/// Reads are direct RLS-protected PostgREST queries; every mutation goes
/// through the single write-path edge function, because `training_goals` and
/// `training_sessions` carry invariants (one non-retired goal per pet+skill,
/// the pinned skill version, published-content-only) that only the write path
/// can uphold. Clients hold SELECT on those tables and nothing else.
@MainActor
final class RealTrainingService: TrainingService {
    private let client: SupabaseClient
    private let decoder = SupabaseCoding.restDecoder
    private let operationQueue: OfflineOperationQueue?

    init(client: SupabaseClient, operationQueue: OfflineOperationQueue? = nil) {
        self.client = client
        self.operationQueue = operationQueue
    }

    // MARK: - Reads

    func overview(petId: UUID) async throws -> TrainingOverview {
        async let catalogue = publishedCatalogue()
        async let goals = goals(petId: petId)
        async let sessions = recentSessions(petId: petId)
        async let names = memberNames(petId: petId)
        return TrainingOverview(
            catalogue: try await catalogue,
            goals: try await goals,
            recentSessions: try await sessions,
            actorNames: try await names
        )
    }

    /// Only published versions, and only the newest version of each skill.
    /// `content_versions` is world-readable, so the publication filter is a
    /// join rather than a second round trip; drafts must never be presented as
    /// practisable guidance (DM §18.11).
    private func publishedCatalogue() async throws -> [TrainingSkill] {
        struct Row: Decodable {
            let content_id: String
            let version: Int
            let skill_group: String
            let title: String
            let promise: String?
            let steps: [String]
            let prerequisite_skill_refs: [String]
            let stage_guidance: String
            let effort_band: String
            let recommended_frequency: String
            let common_mistakes: [String]
            let safety_notes: String?
            let review_status: String
            let content_versions: PublicationRow?

            struct PublicationRow: Decodable { let publication_status: String }
        }

        let response = try await client
            .from("training_skills")
            .select(
                """
                content_id, version, skill_group, title, promise, steps,
                prerequisite_skill_refs, stage_guidance, effort_band,
                recommended_frequency, common_mistakes, safety_notes, review_status,
                content_versions!inner(publication_status)
                """
            )
            .eq("content_versions.publication_status", value: "published")
            .is("retired_at", value: nil)
            .order("content_id", ascending: true)
            .execute()

        let rows = try decoder.decode([Row].self, from: response.data)
        // Newest published version wins; the catalogue is keyed by content id
        // everywhere else in the app.
        var newest: [String: Row] = [:]
        for row in rows where (newest[row.content_id]?.version ?? 0) < row.version {
            newest[row.content_id] = row
        }
        return newest.values
            .map { row in
                TrainingSkill(
                    contentId: row.content_id,
                    version: row.version,
                    skillGroup: row.skill_group,
                    title: row.title,
                    promise: row.promise,
                    steps: row.steps,
                    prerequisiteSkillRefs: row.prerequisite_skill_refs,
                    // An unrecognised stage is a content change the app has
                    // not shipped support for yet; showing the skill without a
                    // stage chip beats hiding reviewed guidance.
                    stageGuidance: DevelopmentStage(rawValue: row.stage_guidance) ?? .unknown,
                    effortBand: EffortBand(rawValue: row.effort_band) ?? .short,
                    recommendedFrequency: row.recommended_frequency,
                    commonMistakes: row.common_mistakes,
                    safetyNotes: row.safety_notes,
                    reviewStatus: TrainingSkill.ReviewStatus(rawValue: row.review_status)
                        ?? .pendingProfessionalReview
                )
            }
            .sorted { ($0.skillGroup, $0.title) < ($1.skillGroup, $1.title) }
    }

    private func goals(petId: UUID) async throws -> [TrainingGoal] {
        struct Row: Decodable {
            let id: UUID
            let household_id: UUID
            let pet_id: UUID
            let skill_ref: String
            let status: TrainingGoalStatus
            let progress_state: TrainingProgressState
            let started_at: Date
            let started_by: UUID?
            let paused_at: Date?
            let retired_at: Date?
            let progress_state_updated_at: Date?
            let progress_state_updated_by: UUID?
            let revision: Int
        }
        let response = try await client
            .from("training_goals")
            .select(
                """
                id, household_id, pet_id, skill_ref, status, progress_state,
                started_at, started_by, paused_at, retired_at,
                progress_state_updated_at, progress_state_updated_by, revision
                """
            )
            .eq("pet_id", value: petId)
            .order("started_at", ascending: false)
            .execute()
        return try decoder.decode([Row].self, from: response.data).map { row in
            TrainingGoal(
                id: row.id,
                householdId: row.household_id,
                petId: row.pet_id,
                skillRef: row.skill_ref,
                status: row.status,
                progressState: row.progress_state,
                startedAt: row.started_at,
                startedBy: row.started_by,
                pausedAt: row.paused_at,
                retiredAt: row.retired_at,
                progressStateUpdatedAt: row.progress_state_updated_at,
                progressStateUpdatedBy: row.progress_state_updated_by,
                revision: row.revision
            )
        }
    }

    private func recentSessions(petId: UUID) async throws -> [TrainingSession] {
        let response = try await client
            .from("training_sessions")
            .select(
                """
                id, goal_id, pet_id, skill_ref, skill_version, effective_date,
                duration_minutes, outcome_note, progress_state_after,
                actor_user_id, recorded_at
                """
            )
            .eq("pet_id", value: petId)
            .order("effective_date", ascending: false)
            .order("recorded_at", ascending: false)
            .limit(100)
            .execute()
        return try decoder.decode([TrainingSession].self, from: response.data)
    }

    /// Session attribution (US-063 "The session is attributed and visible to
    /// the household") needs co-members' display names, which only
    /// `household_member_profiles` exposes.
    private func memberNames(petId: UUID) async throws -> [UUID: String] {
        struct Row: Decodable {
            let user_id: UUID
            let display_name: String
            let user_status: String
        }
        let response = try await client
            .from("household_member_profiles")
            .select("user_id, display_name, user_status")
            .execute()
        let rows = try decoder.decode([Row].self, from: response.data)
        return rows.reduce(into: [:]) { result, row in
            result[row.user_id] = row.user_status == "deleted" ? "Former member" : row.display_name
        }
    }

    // MARK: - Writes (write-path envelope)

    private struct GoalResult: Decodable {
        struct Goal: Decodable {
            let id: UUID
            let household_id: UUID
            let pet_id: UUID
            let skill_ref: String
            let status: TrainingGoalStatus
            let progress_state: TrainingProgressState
            let started_at: Date
            let started_by: UUID?
            let paused_at: Date?
            let retired_at: Date?
            let progress_state_updated_at: Date?
            let progress_state_updated_by: UUID?
            let revision: Int
            let last_session_on: Date?
            let session_count: Int
        }
        let goal: Goal
    }

    private static func goal(from result: GoalResult) -> TrainingGoal {
        TrainingGoal(
            id: result.goal.id,
            householdId: result.goal.household_id,
            petId: result.goal.pet_id,
            skillRef: result.goal.skill_ref,
            status: result.goal.status,
            progressState: result.goal.progress_state,
            startedAt: result.goal.started_at,
            startedBy: result.goal.started_by,
            pausedAt: result.goal.paused_at,
            retiredAt: result.goal.retired_at,
            progressStateUpdatedAt: result.goal.progress_state_updated_at,
            progressStateUpdatedBy: result.goal.progress_state_updated_by,
            revision: result.goal.revision,
            lastSessionOn: result.goal.last_session_on,
            sessionCount: result.goal.session_count
        )
    }

    func startGoal(petId: UUID, skillRef: String) async throws -> TrainingGoal {
        struct Payload: Encodable {
            let pet_id: UUID
            let skill_ref: String
        }
        return try await send(
            command: "start_training_goal",
            payload: Payload(pet_id: petId, skill_ref: skillRef)
        )
    }

    func pauseGoal(_ goal: TrainingGoal) async throws -> TrainingGoal {
        try await transition(goal, command: "pause_training_goal")
    }

    func resumeGoal(_ goal: TrainingGoal) async throws -> TrainingGoal {
        try await transition(goal, command: "resume_training_goal")
    }

    func retireGoal(_ goal: TrainingGoal) async throws -> TrainingGoal {
        try await transition(goal, command: "retire_training_goal")
    }

    /// `expected_revision` is supplied so a second caregiver's change becomes
    /// an explicit conflict rather than a silent overwrite (DM §13).
    private func transition(_ goal: TrainingGoal, command: String) async throws -> TrainingGoal {
        struct Payload: Encodable {
            let goal_id: UUID
            let expected_revision: Int
        }
        return try await send(
            command: command,
            payload: Payload(goal_id: goal.id, expected_revision: goal.revision)
        )
    }

    func updateProgress(_ goal: TrainingGoal, to state: TrainingProgressState) async throws -> TrainingGoal {
        struct Payload: Encodable {
            let goal_id: UUID
            let progress_state: String
            let expected_revision: Int
        }
        return try await send(
            command: "update_training_progress",
            payload: Payload(
                goal_id: goal.id,
                progress_state: state.rawValue,
                expected_revision: goal.revision
            )
        )
    }

    func logSession(
        goal: TrainingGoal,
        effectiveDate: Date,
        durationMinutes: Int?,
        outcomeNote: String?,
        progressStateAfter: TrainingProgressState?
    ) async throws -> TrainingSession {
        struct Payload: Encodable {
            let goal_id: UUID
            let effective_date: String
            let duration_minutes: Int?
            let outcome_note: String?
            let progress_state_after: String?
        }
        struct Result: Decodable {
            struct Session: Decodable {
                let id: UUID
                let goal_id: UUID
                let pet_id: UUID
                let skill_ref: String
                let skill_version: Int
                let effective_date: Date
                let duration_minutes: Int?
                let outcome_note: String?
                let progress_state_after: TrainingProgressState?
                let actor_user_id: UUID?
                let recorded_at: Date
            }
            let session: Session
        }

        // No `expected_revision`: logging a session is additive, and failing a
        // caregiver's record of what they just did because someone else
        // renamed a progress state would lose real information.
        let payload = Payload(
            goal_id: goal.id,
            effective_date: SupabaseCoding.dateOnlyString(effectiveDate, timeZone: .current),
            duration_minutes: durationMinutes,
            outcome_note: outcomeNote,
            progress_state_after: progressStateAfter?.rawValue
        )

        do {
            let result: Result = try await WritePath.sendStable(
                client: client,
                command: "log_training_session",
                payload: payload,
                queue: operationQueue
            )
            return TrainingSession(
                id: result.session.id,
                goalId: result.session.goal_id,
                petId: result.session.pet_id,
                skillRef: result.session.skill_ref,
                skillVersion: result.session.skill_version,
                effectiveDate: result.session.effective_date,
                durationMinutes: result.session.duration_minutes,
                outcomeNote: result.session.outcome_note,
                progressStateAfter: result.session.progress_state_after,
                actorUserId: result.session.actor_user_id,
                recordedAt: result.session.recorded_at
            )
        } catch let error as WritePathError {
            throw Self.trainingError(from: error)
        }
    }

    /// Lifecycle and progress commands need a live answer: a queued pause
    /// would leave the caregiver looking at a goal that is still suggesting
    /// practice, so a failure is reported as a failure.
    private func send<Payload: Encodable>(command: String, payload: Payload) async throws -> TrainingGoal {
        do {
            let result: GoalResult = try await WritePath.send(
                client: client,
                command: command,
                payload: payload
            )
            return Self.goal(from: result)
        } catch let error as WritePathError {
            throw Self.trainingError(from: error)
        }
    }

    private static func trainingError(from error: WritePathError) -> Error {
        switch error {
        case .server(let code, let message):
            TrainingError(code: code, message: message)
        case .malformedResponse:
            TrainingError.server(error.localizedDescription)
        }
    }
}
