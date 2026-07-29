import XCTest

/// PL-01 Planner: day navigation and a task's detail sheet.
final class PlannerScenarioTests: ReviewScenarioCase {
    override class var scenarioName: String { "planner" }

    override func drive() {
        guard navigator.reachHome() else {
            driver.capture("stopped-before-home")
            driver.note("could not reach Home, so the Planner tab was never opened")
            return
        }
        guard navigator.openTab("Planner") else {
            driver.capture("stopped-before-planner")
            return
        }
        guard driver.waitForScreen(
            [app.buttons["Today"], app.staticTexts["Planner"]],
            describedAs: "PL-01 Planner"
        ) else {
            driver.capture("planner-did-not-load")
            return
        }

        driver.capture("planner-today")
        driver.recordRenderedTextScale(
            probe: app.staticTexts["Planner"],
            describedAs: "Planner navigation title"
        )

        navigateDays()
        openTaskDetail()
        openMonthJump()
    }

    /// The week navigator: forward a week, back to today.
    private func navigateDays() {
        if driver.tap(app.buttons["Next week"], describedAs: "Next week") {
            driver.capture("planner-next-week")
        }
        if driver.tap(app.buttons["Previous week"], describedAs: "Previous week") {
            driver.capture("planner-back-to-this-week")
        }
        // "Today" is disabled while today is already selected, so this only
        // does anything after the navigation above moved off it.
        driver.tap(app.buttons["Today"], describedAs: "Today")
    }

    /// Agenda rows open PlannerTaskDetail. In mock mode the agenda is served
    /// by the PlanService compatibility adapter, so the rows are the same
    /// §26.2 fixture items Home shows.
    private func openTaskDetail() {
        let row = button(startingWith: "Morning potty routine")
        guard driver.tap(row, describedAs: "Morning potty routine agenda row") else {
            driver.note("planner task detail not reached")
            return
        }
        guard driver.waitForScreen(
            [app.buttons["Close"], app.buttons["Edit"], app.staticTexts["Morning potty routine"]],
            describedAs: "planner task detail sheet"
        ) else { return }
        driver.capture("planner-task-detail")
        driver.dismissSheet()
    }

    /// The month-jump sheet behind the toolbar's month button.
    private func openMonthJump() {
        guard driver.tap(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "20")).firstMatch,
            describedAs: "month title button"
        ) else {
            driver.note("month jump sheet not reached")
            return
        }
        guard driver.waitForScreen(
            [app.staticTexts["Jump to date"], app.buttons["Show date"]],
            describedAs: "Jump to date sheet"
        ) else { return }
        driver.capture("planner-jump-to-date")
        driver.dismissSheet()
    }
}
