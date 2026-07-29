import XCTest

/// Shared setup for every review scenario.
///
/// **Why variants are test methods rather than environment variables.**
/// The obvious design is one test per scenario, with the text size and
/// appearance passed in as `TEST_RUNNER_*` environment variables. That was
/// tried first and it does not work: under `xcodebuild test` the
/// `TEST_RUNNER_`-prefixed values never arrived in the runner process, and
/// the run silently used the default size instead. Silently is the problem —
/// a reviewer would have believed they were looking at AX5 and they would
/// have been looking at default text.
///
/// So each variant is a named test, and selecting one is ordinary
/// `-only-testing:`. What you asked for is what you get, or the command
/// fails outright:
///
///     -only-testing:PetCompanionUITests/HomeScenarioTests/testAtAccessibilityXXXL
class ReviewScenarioCase: XCTestCase {
    /// Folder name under `/tmp/petcompanion-ui`. Overridden per scenario.
    class var scenarioName: String { "scenario" }

    private(set) var driver: ReviewDriver!
    private(set) var navigator: AppNavigator!

    // MARK: - Variants

    func testAtDefaultText() {
        walk(textSize: .standard, appearance: .light)
    }

    func testAtAccessibilityXXXL() {
        walk(textSize: .ax5, appearance: .light)
    }

    func testAtDefaultTextDark() {
        walk(textSize: .standard, appearance: .dark)
    }

    /// The actual tour. Overridden by each scenario.
    func drive() {
        XCTFail("\(type(of: self)) must override drive()")
    }

    // MARK: - Harness

    private func walk(textSize: ReviewTextSize, appearance: ReviewAppearance) {
        // A scenario that hits a dead end should still deliver the
        // screenshots it did reach, plus a note saying what it missed.
        continueAfterFailure = true

        driver = ReviewDriver(
            scenario: type(of: self).scenarioName,
            testCase: self,
            textSize: textSize,
            appearance: appearance
        )
        navigator = AppNavigator(driver: driver)

        driver.launch()
        drive()

        driver.note("screenshots written to \(driver.outputDirectory.path)")
        driver.finish()
        print("PC_UI_OUTPUT [\(type(of: self).scenarioName)] \(driver.outputDirectory.path)")

        driver = nil
        navigator = nil
    }

    // MARK: - Element helpers

    var app: XCUIApplication { driver.app }

    /// Plan and agenda cards combine their children, so their accessibility
    /// label is "Title, meta line". Matching on the prefix is the stable way
    /// to reach one.
    func button(startingWith prefix: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", prefix)
        ).firstMatch
    }

    func staticText(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", fragment)
        ).firstMatch
    }
}
