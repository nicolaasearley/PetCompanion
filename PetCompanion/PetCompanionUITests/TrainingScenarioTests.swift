import XCTest

/// TR-01 Training overview → TR-02 catalogue → TR-03 lesson → logging a
/// session.
///
/// Mock mode starts with no training goals, so the walk starts one. That is
/// deliberate: "Log session" only exists once a goal does, and a screenshot
/// of the logging sheet is worth more than a note explaining why it is
/// missing.
final class TrainingScenarioTests: ReviewScenarioCase {
    override class var scenarioName: String { "training" }

    override func drive() {
        guard navigator.reachHome() else {
            driver.capture("stopped-before-home")
            driver.note("could not reach Home, so the Training tab was never opened")
            return
        }
        guard navigator.openTab("Training") else {
            driver.capture("stopped-before-training")
            return
        }
        guard driver.waitForScreen(
            [app.staticTexts["Small sessions, real progress"]],
            describedAs: "TR-01 Training overview"
        ) else {
            driver.capture("training-did-not-load")
            return
        }

        driver.capture("training-overview")
        driver.recordRenderedTextScale(
            probe: app.staticTexts["Small sessions, real progress"],
            describedAs: "Training overview headline"
        )

        openCatalogue()
        openLessonAndStartGoal()
        logASession()
    }

    private func openCatalogue() {
        guard driver.tap(
            button(startingWith: "Skill catalogue"),
            describedAs: "Skill catalogue row"
        ) else {
            driver.note("training catalogue not reached")
            return
        }
        guard driver.waitForScreen(
            [app.navigationBars.firstMatch],
            describedAs: "TR-02 skill catalogue"
        ) else { return }
        driver.capture("training-catalogue")
    }

    /// From the catalogue, open the first skill and start a goal on it.
    private func openLessonAndStartGoal() {
        let firstSkill = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Name response")
        ).firstMatch
        guard driver.tap(firstSkill, describedAs: "a skill row in the catalogue") else {
            driver.note("training lesson not reached")
            return
        }
        guard driver.waitForScreen(
            [app.staticTexts["Steps"], app.buttons["Start this goal"]],
            describedAs: "TR-03 skill lesson"
        ) else { return }
        driver.capture("training-lesson")

        guard driver.tap(app.buttons["Start this goal"], describedAs: "Start this goal") else {
            driver.note("goal not started, so the logging sheet is out of reach")
            return
        }
        guard driver.waitForScreen(
            [app.buttons["Log session"]],
            describedAs: "lesson with an active goal"
        ) else { return }

        // Honest progress affordance: owner-reported state bar, never a %.
        let progressBar = app.descendants(matching: .any)["training-progress-state-bar"]
        if progressBar.waitForExistence(timeout: 3) {
            let label = progressBar.label
            if label.localizedCaseInsensitiveContains("%") {
                driver.note("FAIL: training progress bar accessibility label contains a percentage: \(label)")
            } else if !label.localizedCaseInsensitiveContains("Owner-reported") {
                driver.note("training progress bar missing owner-reported wording: \(label)")
            } else {
                driver.note("training progress bar shows owner-reported state (no %)")
            }
        } else {
            driver.note("training progress state bar not found after starting goal")
        }

        driver.capture("training-lesson-goal-started")
    }

    private func logASession() {
        guard driver.tap(app.buttons["Log session"], describedAs: "Log session") else {
            driver.note("log session sheet not reached")
            return
        }
        guard driver.waitForScreen(
            [app.navigationBars.firstMatch, app.buttons["Cancel"]],
            describedAs: "log training session sheet"
        ) else { return }
        driver.capture("training-log-session")
        driver.dismissSheet()
    }
}
