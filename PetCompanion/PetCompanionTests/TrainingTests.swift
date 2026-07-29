import XCTest
@testable import PetCompanion

/// E06 training: the rules the Training tab must not get wrong — starting is
/// idempotent, pausing is not a verdict, one session never declares mastery,
/// and a skill with an unmet prerequisite is never presented as practisable.
@MainActor
final class TrainingTests: XCTestCase {
    private func makeModel() -> (TrainingViewModel, MockBackend, Pet) {
        let backend = MockBackend()
        let seed = backend.seedForPreview(preArrival: false)
        let viewModel = TrainingViewModel(service: MockTrainingService(backend: backend))
        return (viewModel, backend, seed.pet)
    }

    func testStartingTheSameSkillTwiceKeepsOneGoal() async {
        let (viewModel, backend, pet) = makeModel()
        await viewModel.load(petId: pet.id)
        guard let skill = viewModel.overview.skill("skill.marker_intro") else {
            return XCTFail("seed catalogue is missing skill.marker_intro")
        }

        await viewModel.start(skill: skill, petId: pet.id)
        let first = viewModel.overview.goal(forSkill: skill.contentId)
        await viewModel.start(skill: skill, petId: pet.id)
        let second = viewModel.overview.goal(forSkill: skill.contentId)

        // US-061: "Starting the same goal twice remains idempotent."
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(backend.trainingGoals.filter { $0.skillRef == skill.contentId }.count, 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testPausingKeepsTheReportedProgressAndResumingRestoresIt() async {
        let (viewModel, _, pet) = makeModel()
        await viewModel.load(petId: pet.id)
        guard let skill = viewModel.overview.skill("skill.marker_intro") else {
            return XCTFail("seed catalogue is missing skill.marker_intro")
        }
        await viewModel.start(skill: skill, petId: pet.id)
        guard var goal = viewModel.overview.goal(forSkill: skill.contentId) else {
            return XCTFail("goal was not created")
        }

        await viewModel.updateProgress(goal, to: .reliableInFamiliarSetting)
        goal = viewModel.overview.goal(forSkill: skill.contentId)!
        XCTAssertEqual(goal.progressState, .reliableInFamiliarSetting)

        await viewModel.pause(goal)
        goal = viewModel.overview.goal(forSkill: skill.contentId)!
        // US-064: "Pausing does not mark the skill complete."
        XCTAssertEqual(goal.status, .paused)
        XCTAssertEqual(goal.progressState, .reliableInFamiliarSetting)
        XCTAssertTrue(goal.recencyText(calendar: .current).hasPrefix("Paused"))

        await viewModel.resume(goal)
        goal = viewModel.overview.goal(forSkill: skill.contentId)!
        XCTAssertEqual(goal.status, .active)
        XCTAssertEqual(goal.progressState, .reliableInFamiliarSetting)
    }

    func testLoggingASessionDoesNotAdvanceProgressOnItsOwn() async {
        let (viewModel, _, pet) = makeModel()
        await viewModel.load(petId: pet.id)
        guard let skill = viewModel.overview.skill("skill.crate_comfort") else {
            return XCTFail("seed catalogue is missing skill.crate_comfort")
        }
        await viewModel.start(skill: skill, petId: pet.id)
        guard let goal = viewModel.overview.goal(forSkill: skill.contentId) else {
            return XCTFail("goal was not created")
        }

        let saved = await viewModel.logSession(
            goal: goal,
            effectiveDate: Date(),
            durationMinutes: 4,
            outcomeNote: "Went well in the kitchen.",
            progressStateAfter: nil
        )

        XCTAssertTrue(saved)
        let updated = viewModel.overview.goal(forSkill: skill.contentId)!
        // US-063: "A single session does not automatically declare mastery."
        XCTAssertEqual(updated.progressState, .notStarted)
        XCTAssertEqual(updated.sessionCount, 1)
        XCTAssertNotNil(updated.lastSessionOn)
        XCTAssertEqual(viewModel.overview.sessions(forGoal: goal.id).count, 1)
    }

    func testASessionCarryingAnExplicitStateDoesMoveProgress() async {
        let (viewModel, _, pet) = makeModel()
        await viewModel.load(petId: pet.id)
        let skill = viewModel.overview.skill("skill.crate_comfort")!
        await viewModel.start(skill: skill, petId: pet.id)
        let goal = viewModel.overview.goal(forSkill: skill.contentId)!

        _ = await viewModel.logSession(
            goal: goal,
            effectiveDate: Date(),
            durationMinutes: nil,
            outcomeNote: nil,
            progressStateAfter: .introduced
        )

        XCTAssertEqual(viewModel.overview.goal(forSkill: skill.contentId)?.progressState, .introduced)
    }

    func testASessionPinsTheCatalogueVersionItFollowed() async {
        let (viewModel, _, pet) = makeModel()
        await viewModel.load(petId: pet.id)
        let skill = viewModel.overview.skill("skill.marker_intro")!
        await viewModel.start(skill: skill, petId: pet.id)
        let goal = viewModel.overview.goal(forSkill: skill.contentId)!

        _ = await viewModel.logSession(
            goal: goal,
            effectiveDate: Date(),
            durationMinutes: nil,
            outcomeNote: nil,
            progressStateAfter: nil
        )

        // DM §12.3: the session records which version was actually followed.
        XCTAssertEqual(viewModel.overview.sessions(forGoal: goal.id).first?.skillVersion, skill.version)
        XCTAssertEqual(viewModel.overview.sessions(forGoal: goal.id).first?.skillRef, skill.contentId)
    }

    func testAnUnmetPrerequisiteIsNamedRatherThanHidden() async {
        let (viewModel, _, pet) = makeModel()
        await viewModel.load(petId: pet.id)
        let aloneTime = viewModel.overview.skill("skill.alone_time")!

        // Engine §12.3: a prerequisite is a hard constraint, so alone time is
        // not presented as ready to practise until crate comfort is under way.
        XCTAssertEqual(
            viewModel.overview.unmetPrerequisites(for: aloneTime).map(\.contentId),
            ["skill.crate_comfort"]
        )
        XCTAssertFalse(
            viewModel.suggestedStarters(stage: .foundations).contains { $0.contentId == "skill.alone_time" }
        )

        let crate = viewModel.overview.skill("skill.crate_comfort")!
        await viewModel.start(skill: crate, petId: pet.id)

        XCTAssertTrue(viewModel.overview.unmetPrerequisites(for: aloneTime).isEmpty)
        XCTAssertTrue(
            viewModel.suggestedStarters(stage: .foundations, limit: 20)
                .contains { $0.contentId == "skill.alone_time" }
        )
    }

    func testARetiredPrerequisiteDoesNotCountAsMet() async {
        let (viewModel, _, pet) = makeModel()
        await viewModel.load(petId: pet.id)
        let crate = viewModel.overview.skill("skill.crate_comfort")!
        let aloneTime = viewModel.overview.skill("skill.alone_time")!

        await viewModel.start(skill: crate, petId: pet.id)
        let goal = viewModel.overview.goal(forSkill: crate.contentId)!
        await viewModel.retire(goal)

        // Retiring means the household stopped, not that they finished — the
        // same rule the engine applies to `training_state`.
        XCTAssertEqual(
            viewModel.overview.unmetPrerequisites(for: aloneTime).map(\.contentId),
            ["skill.crate_comfort"]
        )
        XCTAssertNil(viewModel.overview.goal(forSkill: crate.contentId))
    }

    func testRetiringFreesTheSkillToBeStartedAgain() async {
        let (viewModel, backend, pet) = makeModel()
        await viewModel.load(petId: pet.id)
        let skill = viewModel.overview.skill("skill.sit")!

        await viewModel.start(skill: skill, petId: pet.id)
        let first = viewModel.overview.goal(forSkill: skill.contentId)!
        await viewModel.retire(first)
        await viewModel.start(skill: skill, petId: pet.id)

        let restarted = viewModel.overview.goal(forSkill: skill.contentId)
        XCTAssertNotNil(restarted)
        XCTAssertNotEqual(restarted?.id, first.id)
        XCTAssertEqual(restarted?.progressState, .notStarted)
        XCTAssertEqual(backend.trainingGoals.filter { $0.skillRef == skill.contentId }.count, 2)
    }

    func testRecencyTextNamesTheReportedStateAndTheLastSession() {
        let calendar = Calendar.current
        let goal = TrainingGoal(
            householdId: UUID(),
            petId: UUID(),
            skillRef: "skill.recall_foundations",
            progressState: .practicing,
            lastSessionOn: calendar.date(byAdding: .day, value: -2, to: Date())
        )
        XCTAssertEqual(goal.recencyText(calendar: calendar), "Practicing · practiced 2 days ago")

        let unpractised = TrainingGoal(
            householdId: UUID(),
            petId: UUID(),
            skillRef: "skill.recall_foundations",
            progressState: .introduced
        )
        XCTAssertEqual(unpractised.recencyText(calendar: calendar), "Introduced · no sessions yet")
    }

    func testStageFilterHidesSkillsTheStageHasNotReached() async {
        let (viewModel, _, pet) = makeModel()
        await viewModel.load(petId: pet.id)

        let settlingIn = viewModel.skills(matching: "", stage: .settlingIn, fitsStageOnly: true)
        XCTAssertFalse(settlingIn.contains { $0.contentId == "skill.leave_it" })
        XCTAssertTrue(settlingIn.contains { $0.contentId == "skill.marker_intro" })

        // Turning the filter off shows everything (TR-02): browsing is never
        // blocked, only start eligibility is.
        let unfiltered = viewModel.skills(matching: "", stage: .settlingIn, fitsStageOnly: false)
        XCTAssertTrue(unfiltered.contains { $0.contentId == "skill.leave_it" })
    }

    func testProgressStatesCoverTheOwnerReportedListWithoutPaused() {
        // F08's seventh state, "Paused", is a goal status. Letting it in here
        // would make pausing destroy the reported progress.
        XCTAssertEqual(TrainingProgressState.allCases.count, 6)
        XCTAssertFalse(TrainingProgressState.allCases.map(\.rawValue).contains("paused"))
        for state in TrainingProgressState.allCases {
            XCTAssertFalse(state.displayName.isEmpty)
            XCTAssertFalse(state.explanation.isEmpty)
        }
    }

    // MARK: - Honest progress affordance (docs/22 §5.2)

    func testProgressAffordanceMapsOwnerReportedStatesToDiscreteSteps() {
        XCTAssertEqual(TrainingProgressState.notStarted.continuumStep, 1)
        XCTAssertEqual(TrainingProgressState.introduced.continuumStep, 2)
        XCTAssertEqual(TrainingProgressState.practicing.continuumStep, 3)
        XCTAssertEqual(TrainingProgressState.reliableInFamiliarSetting.continuumStep, 4)
        XCTAssertEqual(TrainingProgressState.generalizing.continuumStep, 5)
        XCTAssertEqual(TrainingProgressState.maintained.continuumStep, 6)
        XCTAssertEqual(TrainingProgressState.continuumStepCount, 6)

        // Every continuum state is a named step — never a blank or "%".
        for state in TrainingProgressState.allCases {
            let model = TrainingProgressAffordanceModel(state: state)
            XCTAssertEqual(model.title, state.displayName)
            XCTAssertEqual(model.stepNumber, state.continuumStep)
            XCTAssertFalse(model.title.contains("%"))
            XCTAssertFalse(model.caption.contains("%"))
            XCTAssertFalse(model.accessibilityLabel.contains("%"))
            XCTAssertTrue(model.accessibilityLabel.contains(state.displayName))
            XCTAssertTrue(model.rejectsComputedPercentage)
        }
    }

    func testProgressAffordanceNamesPausedWithoutMovingContinuumStep() {
        let practicing = TrainingProgressAffordanceModel(state: .practicing, isPaused: false)
        let paused = TrainingProgressAffordanceModel(state: .practicing, isPaused: true)

        XCTAssertEqual(practicing.stepNumber, paused.stepNumber)
        XCTAssertEqual(paused.title, "Paused · Practicing")
        XCTAssertTrue(paused.accessibilityLabel.contains("Paused"))
        XCTAssertTrue(paused.accessibilityLabel.contains("Practicing"))
        XCTAssertFalse(paused.caption.contains("%"))
        // Pausing is not a further step on the continuum (US-064).
        XCTAssertEqual(paused.stepNumber, 3)
    }

    func testProgressAffordanceIgnoresSessionCountAsCompletion() {
        // Session counts are factual history, never a completion ratio for the bar.
        let few = TrainingGoal(
            householdId: UUID(),
            petId: UUID(),
            skillRef: "skill.recall_foundations",
            progressState: .practicing,
            sessionCount: 2
        )
        let many = TrainingGoal(
            householdId: UUID(),
            petId: UUID(),
            skillRef: "skill.recall_foundations",
            progressState: .practicing,
            sessionCount: 40
        )
        let fewModel = TrainingProgressAffordanceModel(goal: few)
        let manyModel = TrainingProgressAffordanceModel(goal: many)
        XCTAssertEqual(fewModel.stepNumber, manyModel.stepNumber)
        XCTAssertEqual(fewModel.title, manyModel.title)
        XCTAssertFalse(fewModel.accessibilityLabel.contains("40"))
        XCTAssertFalse(manyModel.accessibilityLabel.contains("40"))
        XCTAssertFalse(fewModel.accessibilityLabel.contains("%"))
    }
}
