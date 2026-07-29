import XCTest

/// HM-01 Daily Plan, its item detail sheet (HM-02) and the capacity sheet
/// (HM-04).
final class HomeScenarioTests: ReviewScenarioCase {
    override class var scenarioName: String { "home" }

    func testHomeAndItsSheets() {
        guard navigator.reachHome() else {
            driver.capture("stopped-before-home")
            driver.note("could not reach Home; nothing below was exercised")
            return
        }

        driver.capture("home-daily-plan")
        driver.recordRenderedTextScale(
            probe: app.staticTexts["Today"],
            describedAs: "Today section header"
        )

        // Scrolled view: the recommended and coming-up sections sit below the
        // fold at any text size, and below several screens at AX5.
        app.scrollViews.firstMatch.swipeUp()
        driver.capture("home-scrolled")
        driver.scrollToTop()

        openPlanItemDetail()
        openCapacitySheet()
        openQuickAdd()
    }

    /// The obligation card the §26.2 fixture always contains.
    private func openPlanItemDetail() {
        let card = button(startingWith: "Morning potty routine")
        guard driver.tap(card, describedAs: "Morning potty routine card") else {
            driver.note("plan item detail sheet not reached")
            return
        }
        guard driver.waitForScreen(
            [app.buttons["Mark complete"], app.buttons["Close"]],
            describedAs: "plan item detail sheet"
        ) else { return }
        driver.capture("plan-item-detail")
        driver.dismissSheet()
    }

    /// Reached from the "Adjust" action on the Recommended section header.
    private func openCapacitySheet() {
        let adjust = app.buttons["Adjust"]
        if !adjust.exists { driver.scrollToReveal(adjust) }
        guard driver.tap(adjust, describedAs: "Adjust (Recommended header)") else {
            driver.note("capacity sheet not reached")
            return
        }
        guard driver.waitForScreen(
            [app.staticTexts["How much can today hold?"]],
            describedAs: "HM-04 capacity sheet"
        ) else { return }
        driver.capture("capacity-sheet")

        // The sheet is a decision surface — show a non-default selection too,
        // since that is where the "Essentials only" copy actually renders.
        if driver.tap(app.buttons["Essentials only"], describedAs: "Essentials only") {
            driver.capture("capacity-sheet-essentials-selected")
        }
        driver.dismissSheet()
        driver.scrollToTop()
    }

    /// The docked quick-add button and its alert.
    private func openQuickAdd() {
        guard driver.tap(app.buttons["Add task"], describedAs: "Add task button") else {
            return
        }
        guard driver.waitForScreen(
            [app.alerts.firstMatch],
            describedAs: "quick add alert"
        ) else { return }
        driver.capture("quick-add-task")
        let cancel = app.alerts.buttons["Cancel"]
        if cancel.exists { cancel.tap() }
    }
}
