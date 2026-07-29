import XCTest

/// TR-06 socialization passport → TR-07 one category → the record sheet.
///
/// The passport is a hero tile leading the Training tab's own content
/// (2026-07-29 hierarchy update), not a tab of its own — previously it was a
/// docked row under Training's content instead.
final class PassportScenarioTests: ReviewScenarioCase {
    override class var scenarioName: String { "passport" }

    override func drive() {
        guard navigator.reachHome() else {
            driver.capture("stopped-before-home")
            driver.note("could not reach Home, so the passport was never opened")
            return
        }
        guard navigator.openTab("Training") else {
            driver.capture("stopped-before-training")
            return
        }

        guard driver.tapFirstAvailable(
            [
                button(startingWith: "Socialization passport"),
                app.staticTexts["Socialization passport"],
            ],
            describedAs: "Socialization passport entry"
        ) else {
            driver.capture("passport-entry-not-found")
            return
        }
        guard driver.waitForScreen(
            [app.staticTexts["Categories"], app.navigationBars["Socialization"]],
            describedAs: "TR-06 socialization passport"
        ) else {
            driver.capture("passport-did-not-load")
            return
        }

        driver.capture("passport-overview")
        driver.recordRenderedTextScale(
            probe: app.staticTexts["Categories"],
            describedAs: "Categories section header"
        )

        openCategory()
        openRecordSheet()
    }

    /// Category cards combine their children, so the label is
    /// "Sounds, None this month".
    private func openCategory() {
        guard driver.tap(
            button(startingWith: "Sounds"),
            describedAs: "Sounds category card"
        ) else {
            driver.note("socialization category not reached")
            return
        }
        guard driver.waitForScreen(
            [app.staticTexts["Ideas"], app.navigationBars["Sounds"]],
            describedAs: "TR-07 Sounds category"
        ) else { return }
        driver.capture("passport-category-sounds")
    }

    /// The per-experience overflow menu carries "Record this", which is the
    /// route into the record sheet from inside a category.
    private func openRecordSheet() {
        let options = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Options for")
        ).firstMatch
        guard driver.tap(options, describedAs: "experience options menu") else {
            driver.note("record sheet not reached")
            return
        }
        guard driver.tap(app.buttons["Record this"], describedAs: "Record this") else {
            return
        }
        guard driver.waitForScreen(
            [app.navigationBars.firstMatch, app.buttons["Cancel"]],
            describedAs: "record socialization sheet"
        ) else { return }
        driver.capture("passport-record-experience")
        driver.dismissSheet()
    }
}
