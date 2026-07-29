import XCTest

/// Shared setup for every review scenario.
///
/// Scenarios are separate `XCTestCase` subclasses rather than methods on one
/// class so a reviewer can run exactly one surface:
///
///     -only-testing:PetCompanionUITests/HomeScenarioTests
class ReviewScenarioCase: XCTestCase {
    /// Folder name under the output root. Overridden per scenario.
    class var scenarioName: String { "scenario" }

    private(set) var driver: ReviewDriver!
    private(set) var navigator: AppNavigator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A scenario that hits a dead end should still deliver the
        // screenshots it did reach, plus a note saying what it missed.
        continueAfterFailure = true
        driver = ReviewDriver(scenario: type(of: self).scenarioName, testCase: self)
        navigator = AppNavigator(driver: driver)
        driver.launch()
    }

    override func tearDownWithError() throws {
        driver?.note("screenshots written to \(driver.outputDirectory.path)")
        driver?.finish()
        if let path = driver?.outputDirectory.path {
            print("PC_UI_OUTPUT [\(type(of: self).scenarioName)] \(path)")
        }
        driver = nil
        navigator = nil
        try super.tearDownWithError()
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
