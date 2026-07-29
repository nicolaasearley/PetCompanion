import Foundation

/// The training half of the in-memory backend (F08).
///
/// It enforces the same invariants the database does, so a bug that the mock
/// tolerates is one the server would reject: at most one non-retired goal per
/// (pet, skill), a session pins the catalogue version it followed, and
/// progress moves only on an explicit selection.
extension MockBackend {
    func trainingOverview(petId: UUID) -> TrainingOverview {
        var names: [UUID: String] = [:]
        for member in members {
            names[member.userId] = member.displayName
        }
        return TrainingOverview(
            catalogue: trainingCatalogue,
            goals: trainingGoals
                .filter { $0.petId == petId }
                .sorted { $0.startedAt > $1.startedAt },
            recentSessions: trainingSessions
                .filter { $0.petId == petId }
                .sorted { $0.effectiveDate > $1.effectiveDate },
            actorNames: names
        )
    }

    /// US-061: starting twice is idempotent. A paused goal is returned
    /// untouched rather than silently resumed — resuming is its own action.
    @discardableResult
    func startTrainingGoal(petId: UUID, skillRef: String) -> TrainingGoal {
        if let existing = trainingGoals.first(where: {
            $0.petId == petId && $0.skillRef == skillRef && $0.status != .retired
        }) {
            return existing
        }
        let goal = TrainingGoal(
            householdId: household?.id ?? UUID(),
            petId: petId,
            skillRef: skillRef,
            startedBy: currentUserId
        )
        trainingGoals.append(goal)
        return goal
    }

    @discardableResult
    func setTrainingGoalStatus(_ goalId: UUID, to status: TrainingGoalStatus) throws -> TrainingGoal {
        guard let index = trainingGoals.firstIndex(where: { $0.id == goalId }) else {
            throw TrainingError.goalNotFound
        }
        // US-064: pausing does not mark the skill complete, so `progressState`
        // is deliberately not touched here by any transition.
        trainingGoals[index].status = status
        trainingGoals[index].pausedAt = status == .paused ? Date() : nil
        trainingGoals[index].retiredAt = status == .retired ? Date() : nil
        trainingGoals[index].revision += 1
        return trainingGoals[index]
    }

    @discardableResult
    func setTrainingProgress(_ goalId: UUID, to state: TrainingProgressState) throws -> TrainingGoal {
        guard let index = trainingGoals.firstIndex(where: { $0.id == goalId }) else {
            throw TrainingError.goalNotFound
        }
        trainingGoals[index].progressState = state
        trainingGoals[index].progressStateUpdatedAt = Date()
        trainingGoals[index].progressStateUpdatedBy = currentUserId
        trainingGoals[index].revision += 1
        return trainingGoals[index]
    }

    @discardableResult
    func logTrainingSession(
        goalId: UUID,
        effectiveDate: Date,
        durationMinutes: Int?,
        outcomeNote: String?,
        progressStateAfter: TrainingProgressState?
    ) throws -> TrainingSession {
        guard let index = trainingGoals.firstIndex(where: { $0.id == goalId }) else {
            throw TrainingError.goalNotFound
        }
        let goal = trainingGoals[index]
        let skill = trainingCatalogue.first { $0.contentId == goal.skillRef }
        let session = TrainingSession(
            goalId: goal.id,
            petId: goal.petId,
            skillRef: goal.skillRef,
            // DM §12.3: the session records the version that was followed.
            skillVersion: skill?.version ?? 1,
            effectiveDate: effectiveDate,
            durationMinutes: durationMinutes,
            outcomeNote: outcomeNote,
            progressStateAfter: progressStateAfter,
            actorUserId: currentUserId
        )
        trainingSessions.append(session)

        trainingGoals[index].sessionCount += 1
        if let existing = trainingGoals[index].lastSessionOn {
            trainingGoals[index].lastSessionOn = max(existing, effectiveDate)
        } else {
            trainingGoals[index].lastSessionOn = effectiveDate
        }
        // US-063: a session never advances mastery on its own. Progress moves
        // only when the caregiver used the separate picker.
        if let progressStateAfter {
            trainingGoals[index].progressState = progressStateAfter
            trainingGoals[index].progressStateUpdatedAt = Date()
            trainingGoals[index].progressStateUpdatedBy = currentUserId
            trainingGoals[index].revision += 1
        }
        return session
    }
}

/// A representative slice of `supabase/seed.sql`'s training content, for mock
/// and preview builds. Real environments read the catalogue from the server,
/// which is the only place reviewed content actually lives.
enum MockTrainingCatalogue {
    static let skills: [TrainingSkill] = [
        TrainingSkill(
            contentId: "skill.marker_intro",
            version: 1,
            skillGroup: "Foundations",
            title: "Marker word (\"yes!\")",
            promise: "A clear signal that tells your puppy exactly when they got it right.",
            steps: [
                "Choose one short word, such as \"yes\".",
                "Say the word once, then give a small reward.",
                "Repeat five to eight times in a quiet place.",
            ],
            prerequisiteSkillRefs: [],
            stageGuidance: .settlingIn,
            effortBand: .tiny,
            recommendedFrequency: "3-5/week",
            commonMistakes: ["Giving the reward before the marker", "Changing the marker word"],
            safetyNotes: nil,
            reviewStatus: .pendingProfessionalReview
        ),
        TrainingSkill(
            contentId: "skill.name_response",
            version: 1,
            skillGroup: "Foundations",
            title: "Name response",
            promise: "Their name predicts attention and good things.",
            steps: [
                "Wait until your puppy is calmly looking elsewhere.",
                "Say their name once in a warm voice.",
                "Mark and reward the moment they turn toward you.",
            ],
            prerequisiteSkillRefs: [],
            stageGuidance: .settlingIn,
            effortBand: .tiny,
            recommendedFrequency: "4-6/week",
            commonMistakes: ["Repeating the name", "Using the name for scolding"],
            safetyNotes: nil,
            reviewStatus: .pendingProfessionalReview
        ),
        TrainingSkill(
            contentId: "skill.crate_comfort",
            version: 1,
            skillGroup: "Calm behavior",
            title: "Crate comfort",
            promise: "The crate becomes a safe, predictable place through choice and rewards.",
            steps: [
                "Leave the door open and reward voluntary investigation.",
                "Feed a few rewards just inside the entrance.",
                "Build duration in seconds while your puppy stays relaxed.",
            ],
            prerequisiteSkillRefs: [],
            stageGuidance: .settlingIn,
            effortBand: .short,
            recommendedFrequency: "daily at first",
            commonMistakes: ["Using the crate as punishment", "Rushing duration"],
            safetyNotes: "Never use the crate as a punishment — it has to stay a good place.",
            reviewStatus: .pendingProfessionalReview
        ),
        TrainingSkill(
            contentId: "skill.paw_handling",
            version: 1,
            skillGroup: "Handling and grooming preparation",
            title: "Paw handling",
            promise: "Brief, gentle paw contact paired with rewards, before grooming is necessary.",
            steps: [
                "Touch a shoulder briefly, then reward.",
                "Progress down the leg over several easy sessions.",
                "Release the paw before your puppy pulls away.",
            ],
            prerequisiteSkillRefs: [],
            stageGuidance: .settlingIn,
            effortBand: .tiny,
            recommendedFrequency: "3-4/week",
            commonMistakes: ["Gripping tightly", "Continuing past discomfort"],
            safetyNotes: nil,
            reviewStatus: .pendingProfessionalReview
        ),
        TrainingSkill(
            contentId: "skill.alone_time",
            version: 1,
            skillGroup: "Calm behavior",
            title: "Alone-time foundations",
            promise: "Being alone is safe and short-lived — the foundation against separation stress.",
            steps: [
                "Start with your puppy settled. Step out of sight for two seconds, return calmly.",
                "Return before any fussing — you are teaching that you always come back.",
                "Vary it: sometimes two seconds, sometimes ten. Keep returns boring.",
            ],
            prerequisiteSkillRefs: ["skill.crate_comfort"],
            stageGuidance: .settlingIn,
            effortBand: .short,
            recommendedFrequency: "3-5/week",
            commonMistakes: ["Sneaking out", "Jumping to long absences"],
            safetyNotes: nil,
            reviewStatus: .pendingProfessionalReview
        ),
        TrainingSkill(
            contentId: "skill.sit",
            version: 1,
            skillGroup: "Foundations",
            title: "Sit",
            promise: "A simple, useful position built through short reward-based repetitions.",
            steps: [
                "Hold a reward near your puppy's nose.",
                "Move it slowly up and back until their rear lowers.",
                "Mark, reward, and release before repeating.",
            ],
            prerequisiteSkillRefs: ["skill.marker_intro"],
            stageGuidance: .foundations,
            effortBand: .tiny,
            recommendedFrequency: "3-5/week",
            commonMistakes: ["Pushing the puppy's rear down", "Keeping the lure forever"],
            safetyNotes: nil,
            reviewStatus: .pendingProfessionalReview
        ),
        TrainingSkill(
            contentId: "skill.recall_foundations",
            version: 1,
            skillGroup: "Recall and safety",
            title: "Recall (\"come\")",
            promise: "A joyful response to coming back to you, built in easy environments first.",
            steps: [
                "Begin only a step or two away in a quiet room.",
                "Say the cue once, then move backward invitingly.",
                "Reward generously when your puppy reaches you.",
            ],
            prerequisiteSkillRefs: ["skill.name_response"],
            stageGuidance: .foundations,
            effortBand: .short,
            recommendedFrequency: "3-5/week",
            commonMistakes: ["Repeating the cue", "Calling only to end fun", "Increasing distance too quickly"],
            safetyNotes: "Never call your puppy to something they dislike — recall has to stay worth answering.",
            reviewStatus: .pendingProfessionalReview
        ),
        TrainingSkill(
            contentId: "skill.leave_it",
            version: 1,
            skillGroup: "House manners",
            title: "Leave it",
            promise: "Disengagement as a rewarding choice rather than a confrontation.",
            steps: [
                "Close a low-value reward in your fist.",
                "Wait quietly for any move away from your hand.",
                "Mark and reward from your other hand.",
            ],
            prerequisiteSkillRefs: ["skill.marker_intro"],
            stageGuidance: .exploration,
            effortBand: .short,
            recommendedFrequency: "2-4/week",
            commonMistakes: ["Snatching the item away", "Escalating too quickly"],
            safetyNotes: "Trade up, never snatch — this game builds trust.",
            reviewStatus: .pendingProfessionalReview
        ),
        TrainingSkill(
            contentId: "skill.loose_leash",
            version: 1,
            skillGroup: "Leash skills",
            title: "Loose-leash foundations",
            promise: "Staying near you is rewarding, before distance and distraction make it hard.",
            steps: [
                "Practice indoors with a comfortable harness and light lead.",
                "Reward one or two steps beside you.",
                "Pause when the lead tightens and continue when it softens.",
            ],
            prerequisiteSkillRefs: ["skill.harness_intro"],
            stageGuidance: .exploration,
            effortBand: .short,
            recommendedFrequency: "3-4/week",
            commonMistakes: ["Letting pulling work sometimes", "Making early sessions too long"],
            safetyNotes: nil,
            reviewStatus: .pendingProfessionalReview
        ),
        TrainingSkill(
            contentId: "skill.harness_intro",
            version: 1,
            skillGroup: "Leash skills",
            title: "Harness introduction",
            promise: "The harness predicts good things long before the first walk.",
            steps: [
                "Hold the harness out and reward any interest.",
                "Feed through the neck opening without fastening it.",
                "Fasten briefly, reward, and take it straight off again.",
            ],
            prerequisiteSkillRefs: [],
            stageGuidance: .settlingIn,
            effortBand: .tiny,
            recommendedFrequency: "2-3/week",
            commonMistakes: ["Wrestling it on", "Leaving it on while distressed"],
            safetyNotes: nil,
            reviewStatus: .pendingProfessionalReview
        ),
    ]
}
