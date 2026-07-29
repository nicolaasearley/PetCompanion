import XCTest

/// Knows how PetCompanion is laid out, so scenarios can say "go to Planner"
/// instead of restating element queries.
///
/// One thing worth knowing before reading further: **mock mode does not seed a
/// household.** `AppModel.bootstrap()` starts at `.onboarding` and
/// `MockBackend` starts empty — `seedForPreview` is only wired to SwiftUI
/// previews, not to a launched app. So every signed-in surface is reached by
/// actually walking ON-01 → ON-08 first. That is slower than a seeded launch
/// but it is also the honest path, and it means the onboarding screens get
/// exercised on the way to everything else.
struct AppNavigator {
    let driver: ReviewDriver

    var app: XCUIApplication { driver.app }

    /// Obviously synthetic. Mock auth only checks the shape of the address
    /// and the length of the password — nothing here is or resembles a
    /// credential, and none is needed.
    static let reviewerEmail = "critic@example.test"
    static let placeholderSecret = "not-a-real-password"
    static let petName = "Maple"

    // MARK: - Screens

    var welcomeHeadline: XCUIElement { app.buttons["Get started"] }

    var homeGreeting: XCUIElement { app.staticTexts[AppNavigator.petName] }

    func tabButton(_ title: String) -> [XCUIElement] {
        [
            app.tabBars.buttons[title],
            app.buttons[title],
        ]
    }

    // MARK: - Onboarding

    /// Walks ON-01 → ON-08 and lands on Home.
    ///
    /// `capturing` controls whether each onboarding screen is screenshotted:
    /// the Onboarding scenario wants them, every other scenario is just
    /// passing through.
    @discardableResult
    func completeOnboarding(capturing: Bool) -> Bool {
        guard driver.waitForScreen([welcomeHeadline], describedAs: "ON-01 Welcome") else {
            return false
        }
        if capturing { driver.capture("welcome") }

        guard driver.tap(welcomeHeadline, describedAs: "Get started") else { return false }

        // ON-02 Create account.
        let emailField = app.textFields.firstMatch
        guard driver.type(
            AppNavigator.reviewerEmail,
            into: emailField,
            describedAs: "email field on ON-02"
        ) else { return false }

        let passwordField = app.secureTextFields.firstMatch
        _ = driver.type(
            AppNavigator.placeholderSecret,
            into: passwordField,
            describedAs: "password field on ON-02"
        )
        if capturing { driver.capture("create-account") }

        guard driver.tap(
            app.buttons["Continue with email"],
            describedAs: "Continue with email"
        ) else { return false }

        // ON-06 Create household. The name is prefilled from the display
        // name the mock derived from the email, so this only confirms.
        guard driver.waitForScreen(
            [app.staticTexts["Name your household"]],
            describedAs: "ON-06 Create household"
        ) else { return false }
        if capturing { driver.capture("create-household") }
        guard driver.tap(app.buttons["Continue"], describedAs: "Continue (ON-06)") else {
            return false
        }

        // ON-07 Add pet.
        guard driver.waitForScreen(
            [app.staticTexts["Tell us about your puppy"]],
            describedAs: "ON-07 Add pet"
        ) else { return false }
        guard driver.type(
            AppNavigator.petName,
            into: app.textFields.firstMatch,
            describedAs: "pet name field on ON-07"
        ) else { return false }
        if capturing { driver.capture("add-pet") }
        guard driver.tap(app.buttons["Continue"], describedAs: "Continue (ON-07)") else {
            return false
        }

        // ON-08 Routine basics.
        guard driver.waitForScreen(
            [app.staticTexts["When does your day run?"]],
            describedAs: "ON-08 Routine basics"
        ) else { return false }
        if capturing { driver.capture("routine-basics") }
        guard driver.tap(
            app.buttons["Skip — use defaults"],
            describedAs: "Skip — use defaults"
        ) else { return false }

        return driver.waitForScreen(
            [homeGreeting, app.staticTexts["Today"]],
            describedAs: "HM-01 Home after onboarding"
        )
    }

    /// Reaches Home without capturing the onboarding screens.
    @discardableResult
    func reachHome() -> Bool {
        completeOnboarding(capturing: false)
    }

    // MARK: - Tabs

    @discardableResult
    func openTab(_ title: String) -> Bool {
        driver.tapFirstAvailable(tabButton(title), describedAs: "\(title) tab")
    }

    // MARK: - Settings

    /// Home's header avatar. It is the only Settings entry on HM-01.
    @discardableResult
    func openSettingsFromHome() -> Bool {
        driver.tapFirstAvailable(
            [app.buttons["Profile and settings"]],
            describedAs: "Profile and settings button"
        )
    }
}
