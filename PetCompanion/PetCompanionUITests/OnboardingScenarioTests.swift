import XCTest

/// ON-01 → ON-08, ending on HM-01.
///
/// Nothing here is a real account: mock auth checks the shape of the address
/// and the length of the password and then makes up a user.
final class OnboardingScenarioTests: ReviewScenarioCase {
    override class var scenarioName: String { "onboarding" }

    func testWalkOnboardingToHome() {
        let reached = navigator.completeOnboarding(capturing: true)
        driver.capture(reached ? "home-after-onboarding" : "onboarding-stopped-here")

        if reached {
            driver.recordRenderedTextScale(
                probe: app.staticTexts["Today"],
                describedAs: "Today section header on HM-01"
            )
        } else {
            driver.note(
                "onboarding did not reach Home; the screens above are as far as the walk got"
            )
        }

        driver.note(
            "ON-05 review-invitation is reachable in the UI but cannot be completed in mock "
                + "mode: accepting needs a second real identity on a live backend."
        )
    }
}
