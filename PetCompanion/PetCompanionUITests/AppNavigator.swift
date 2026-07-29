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

        // ON-02 is photographed but not filled in — see `visitCreateAccount`.
        if capturing { visitCreateAccount() }

        // Authentication goes through ON-03 Sign in, not ON-02 Create
        // account. ON-02's password field declares `.newPassword`, so iOS
        // covers the keyboard with a "Use Strong Password?" panel whose close
        // button is inconsistently exposed — sometimes a Button, sometimes a
        // plain Image — and roughly half of runs could not get past it. ON-03
        // declares `.password`, which raises no such panel.
        //
        // Nothing is lost by this: `MockBackend.signIn` is find-or-create, so
        // signing in with an address that has never been seen produces the
        // same new user that creating an account would have. ON-03 is also a
        // screen a reviewer wants to see.
        guard driver.tap(
            app.buttons["I have an account"],
            describedAs: "I have an account"
        ) else { return false }

        guard driver.waitForScreen(
            [app.staticTexts["Welcome back"]],
            describedAs: "ON-03 Sign in"
        ) else { return false }

        guard driver.type(
            AppNavigator.reviewerEmail,
            into: app.textFields.firstMatch,
            describedAs: "email field on ON-03"
        ) else { return false }
        guard driver.type(
            AppNavigator.placeholderSecret,
            into: app.secureTextFields.firstMatch,
            describedAs: "password field on ON-03"
        ) else { return false }

        // Put the keyboard away before submitting. Its QuickType bar is a
        // separate window that sits over the form, and leaving it up made the
        // submit tap unreliable as well as polluting the screenshot.
        driver.dismissKeyboard()
        if capturing { driver.capture("sign-in") }

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

    /// Photographs ON-02 Create account and comes straight back.
    ///
    /// The screen is worth showing a reviewer, but it is not used to
    /// authenticate: focusing its `.newPassword` field summons the system
    /// strong-password panel. Looking without touching keeps the screenshot
    /// and skips the interstitial.
    private func visitCreateAccount() {
        guard driver.tap(welcomeHeadline, describedAs: "Get started") else { return }
        guard driver.waitForScreen(
            [app.staticTexts["Create your account"]],
            describedAs: "ON-02 Create account"
        ) else { return }
        driver.capture("create-account")
        driver.tapFirstAvailable(
            [app.buttons["BackButton"], app.buttons["Back"]],
            describedAs: "Back from ON-02"
        )
        driver.waitForScreen([welcomeHeadline], describedAs: "ON-01 Welcome (returning)")
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
