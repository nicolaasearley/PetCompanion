import Foundation

/// Training catalogue and progress — Core Features F08, Data Model doc 10
/// §12.1–§12.3, wireframes TR-01 to TR-05.
///
/// Raw values match the backend's column values so these decode straight from
/// `training_skills`, `training_goals` and `training_sessions`.

/// The owner-reported progress states of F08.
///
/// F08 lists seven; the seventh, "Paused", is a lifecycle fact carried by
/// `TrainingGoal.status`, not a judgement about the puppy's learning. Keeping
/// it out of here is what makes pausing non-destructive: a paused goal
/// remembers exactly what the household last reported (US-064). The server
/// refuses `paused` as a progress state for the same reason.
enum TrainingProgressState: String, Codable, CaseIterable, Sendable {
    case notStarted = "not_started"
    case introduced
    case practicing
    case reliableInFamiliarSetting = "reliable_in_familiar_setting"
    case generalizing
    case maintained

    var displayName: String {
        switch self {
        case .notStarted: "Not started"
        case .introduced: "Introduced"
        case .practicing: "Practicing"
        case .reliableInFamiliarSetting: "Reliable in a familiar setting"
        case .generalizing: "Generalizing"
        case .maintained: "Maintained"
        }
    }

    /// What the state means in the caregiver's terms, so the picker never asks
    /// them to guess at a label (US-065).
    var explanation: String {
        switch self {
        case .notStarted: "Nothing practiced yet."
        case .introduced: "You've shown it a few times."
        case .practicing: "Working on it in short, regular sessions."
        case .reliableInFamiliarSetting: "Usually works at home, with no distractions."
        case .generalizing: "Starting to work in new places too."
        case .maintained: "Keeping it fresh with the occasional session."
        }
    }

    /// 1-based position on the owner-reported continuum (F08's six learning
    /// states). F08's seventh label, "Paused", is a goal lifecycle status —
    /// not a step here — so pausing never moves this index (US-064).
    var continuumStep: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }

    /// Count of discrete continuum steps — never derived from session counts.
    static var continuumStepCount: Int { allCases.count }
}

/// Goal lifecycle — DM §12.2. `retired` is a closed pursuit: it frees the
/// (pet, skill) pair so the household can genuinely start over later.
enum TrainingGoalStatus: String, Codable, Sendable {
    case active, paused, retired
}

/// A catalogue skill (global content, DM §12.1). Read from the server, never
/// authored on device — `contentId` and `version` identify exactly which
/// reviewed guidance a caregiver followed.
struct TrainingSkill: Codable, Identifiable, Hashable, Sendable {
    let contentId: String
    let version: Int
    var skillGroup: String
    var title: String
    var promise: String?
    var steps: [String]
    var prerequisiteSkillRefs: [String]
    var stageGuidance: DevelopmentStage
    var effortBand: EffortBand
    var recommendedFrequency: String
    var commonMistakes: [String]
    var safetyNotes: String?
    var reviewStatus: ReviewStatus

    var id: String { contentId }

    /// F08 "Identify content source, version, and review status."
    enum ReviewStatus: String, Codable, Sendable {
        case pendingProfessionalReview = "pending_professional_review"
        case professionallyReviewed = "professionally_reviewed"

        var badgeText: String {
            switch self {
            case .pendingProfessionalReview: "Seed content · pending professional review"
            case .professionallyReviewed: "Professionally reviewed"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, title, promise, steps
        case contentId = "content_id"
        case skillGroup = "skill_group"
        case prerequisiteSkillRefs = "prerequisite_skill_refs"
        case stageGuidance = "stage_guidance"
        case effortBand = "effort_band"
        case recommendedFrequency = "recommended_frequency"
        case commonMistakes = "common_mistakes"
        case safetyNotes = "safety_notes"
        case reviewStatus = "review_status"
    }

    /// The frequency is stored as the catalogue's own phrase ("3-5/week",
    /// "daily at first"); this is the only place it is rewritten for display.
    var frequencyDisplayText: String {
        let raw = recommendedFrequency.replacingOccurrences(of: "/week", with: "× per week")
        return raw.replacingOccurrences(of: "-", with: "–")
    }
}

/// A pet's active pursuit of a skill — DM §12.2.
struct TrainingGoal: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var householdId: UUID
    var petId: UUID
    var skillRef: String
    var status: TrainingGoalStatus
    var progressState: TrainingProgressState
    var startedAt: Date
    var startedBy: UUID?
    var pausedAt: Date?
    var retiredAt: Date?
    var progressStateUpdatedAt: Date?
    var progressStateUpdatedBy: UUID?
    var revision: Int
    /// Most recent logged session, for TR-01's recency line.
    var lastSessionOn: Date?
    var sessionCount: Int

    enum CodingKeys: String, CodingKey {
        case id, status, revision
        case householdId = "household_id"
        case petId = "pet_id"
        case skillRef = "skill_ref"
        case progressState = "progress_state"
        case startedAt = "started_at"
        case startedBy = "started_by"
        case pausedAt = "paused_at"
        case retiredAt = "retired_at"
        case progressStateUpdatedAt = "progress_state_updated_at"
        case progressStateUpdatedBy = "progress_state_updated_by"
        case lastSessionOn = "last_session_on"
        case sessionCount = "session_count"
    }

    init(
        id: UUID = UUID(),
        householdId: UUID,
        petId: UUID,
        skillRef: String,
        status: TrainingGoalStatus = .active,
        progressState: TrainingProgressState = .notStarted,
        startedAt: Date = Date(),
        startedBy: UUID? = nil,
        pausedAt: Date? = nil,
        retiredAt: Date? = nil,
        progressStateUpdatedAt: Date? = nil,
        progressStateUpdatedBy: UUID? = nil,
        revision: Int = 1,
        lastSessionOn: Date? = nil,
        sessionCount: Int = 0
    ) {
        self.id = id
        self.householdId = householdId
        self.petId = petId
        self.skillRef = skillRef
        self.status = status
        self.progressState = progressState
        self.startedAt = startedAt
        self.startedBy = startedBy
        self.pausedAt = pausedAt
        self.retiredAt = retiredAt
        self.progressStateUpdatedAt = progressStateUpdatedAt
        self.progressStateUpdatedBy = progressStateUpdatedBy
        self.revision = revision
        self.lastSessionOn = lastSessionOn
        self.sessionCount = sessionCount
    }

    /// What TR-01 shows under the skill name. "Paused" comes from the status,
    /// never from the progress state, so pausing cannot read as a verdict.
    func recencyText(calendar: Calendar, now: Date = Date()) -> String {
        if status == .paused { return "Paused · \(progressState.displayName.lowercased())" }
        guard let lastSessionOn else {
            return "\(progressState.displayName) · no sessions yet"
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: lastSessionOn),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        let recency = switch days {
        case ..<1: "practiced today"
        case 1: "practiced yesterday"
        default: "practiced \(days) days ago"
        }
        return "\(progressState.displayName) · \(recency)"
    }
}

/// One logged practice session — DM §12.3. `skillVersion` is the catalogue
/// version the caregiver actually followed, pinned at write time.
struct TrainingSession: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var goalId: UUID
    var petId: UUID
    var skillRef: String
    var skillVersion: Int
    var effectiveDate: Date
    var durationMinutes: Int?
    var outcomeNote: String?
    var progressStateAfter: TrainingProgressState?
    var actorUserId: UUID?
    var recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case goalId = "goal_id"
        case petId = "pet_id"
        case skillRef = "skill_ref"
        case skillVersion = "skill_version"
        case effectiveDate = "effective_date"
        case durationMinutes = "duration_minutes"
        case outcomeNote = "outcome_note"
        case progressStateAfter = "progress_state_after"
        case actorUserId = "actor_user_id"
        case recordedAt = "recorded_at"
    }

    init(
        id: UUID = UUID(),
        goalId: UUID,
        petId: UUID,
        skillRef: String,
        skillVersion: Int,
        effectiveDate: Date,
        durationMinutes: Int? = nil,
        outcomeNote: String? = nil,
        progressStateAfter: TrainingProgressState? = nil,
        actorUserId: UUID? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.goalId = goalId
        self.petId = petId
        self.skillRef = skillRef
        self.skillVersion = skillVersion
        self.effectiveDate = effectiveDate
        self.durationMinutes = durationMinutes
        self.outcomeNote = outcomeNote
        self.progressStateAfter = progressStateAfter
        self.actorUserId = actorUserId
        self.recordedAt = recordedAt
    }
}

/// Everything TR-01 renders in one read, so the overview never shows goals
/// and catalogue from two different moments.
struct TrainingOverview: Equatable, Sendable {
    var catalogue: [TrainingSkill] = []
    var goals: [TrainingGoal] = []
    var recentSessions: [TrainingSession] = []
    /// Display names by user id, for session attribution (US-063).
    var actorNames: [UUID: String] = [:]

    func skill(_ contentId: String) -> TrainingSkill? {
        catalogue.first { $0.contentId == contentId }
    }

    func goal(forSkill contentId: String) -> TrainingGoal? {
        goals.first { $0.skillRef == contentId && $0.status != .retired }
    }

    var activeGoals: [TrainingGoal] {
        goals.filter { $0.status == .active }
    }

    var pausedGoals: [TrainingGoal] {
        goals.filter { $0.status == .paused }
    }

    /// Prerequisites are a hard constraint (engine §12.3): a skill is not
    /// presented as ready to practice until each prerequisite has a goal that
    /// is under way. A retired goal deliberately does not count — the
    /// household stopped, they did not finish.
    func unmetPrerequisites(for skill: TrainingSkill) -> [TrainingSkill] {
        skill.prerequisiteSkillRefs.compactMap { ref in
            let met = goals.contains { $0.skillRef == ref && $0.status == .active }
            return met ? nil : self.skill(ref)
        }
    }

    func sessions(forGoal goalId: UUID) -> [TrainingSession] {
        recentSessions.filter { $0.goalId == goalId }
    }
}

/// Every way a training action can fail, in the caregiver's terms.
enum TrainingError: LocalizedError, Equatable {
    case noPet
    case notSignedIn
    case goalNotFound
    case changedElsewhere
    case offline
    case server(String)

    init(code: String, message: String) {
        switch code {
        case "REVISION_CONFLICT": self = .changedElsewhere
        case "FORBIDDEN": self = .notSignedIn
        default: self = .server(message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .noPet:
            "Add your puppy's profile first."
        case .notSignedIn:
            "Sign in to continue."
        case .goalNotFound:
            "That goal is no longer active."
        case .changedElsewhere:
            "Someone else changed this goal. Pull to refresh and try again."
        case .offline:
            "You need a connection to do this. Nothing was changed."
        case .server(let message):
            message
        }
    }
}
