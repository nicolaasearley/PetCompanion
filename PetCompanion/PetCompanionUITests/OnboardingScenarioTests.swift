import XCTest

/// ON-01 → ON-08, ending on HM-01.
///
/// Nothing here is a real account. `MockAuthService` checks only the shape of
/// the address and the length of the password, and `MockBackend.signIn`
/// ignores the password entirely — so the values below are placeholders, not
/// credentials.
final class OnboardingScenarioTests: ReviewScenarioCase {
    override class var scenarioName: String { "onboarding" }

    override func drive() {
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
            "ON-05 review-invitation is reachable in the UI but cannot be completed here: "
                + "accepting an invitation needs a second real identity on a live backend, "
                + "so it is deliberately not exercised rather than faked."
        )
    }
}
