import XCTest

/// ST-01 Settings hub and ST-04 members & invitations.
final class SettingsScenarioTests: ReviewScenarioCase {
    override class var scenarioName: String { "settings" }

    override func drive() {
        guard navigator.reachHome() else {
            driver.capture("stopped-before-home")
            driver.note("could not reach Home, so Settings was never opened")
            return
        }

        guard navigator.openSettingsFromHome() else {
            driver.capture("settings-entry-not-found")
            return
        }
        guard driver.waitForScreen(
            [app.navigationBars["Settings"], app.staticTexts["Reminders"]],
            describedAs: "ST-01 Settings hub"
        ) else {
            driver.capture("settings-did-not-load")
            return
        }

        driver.capture("settings-hub")
        driver.recordRenderedTextScale(
            probe: app.staticTexts["Reminders"],
            describedAs: "Reminders section header"
        )

        driver.scrollDown()
        driver.capture("settings-hub-scrolled")
        driver.scrollToTop()

        openMembers()

        driver.note(
            "Sync shows \"Demo data\" here: the offline mutation queue only exists for a real "
                + "backend, so the queue-status and rejected-changes rows cannot be reached in "
                + "mock mode."
        )
    }

    private func openMembers() {
        guard driver.tap(
            button(startingWith: "Members & invitations"),
            describedAs: "Members & invitations row"
        ) else {
            driver.note("household members screen not reached")
            return
        }
        guard driver.waitForScreen(
            [app.staticTexts["Household members"], app.navigationBars["Members"]],
            describedAs: "ST-04 members & invitations"
        ) else { return }
        driver.capture("settings-household-members")

        driver.note(
            "The invitation list is empty and stays that way. Creating one is reachable "
                + "(\"Invite a caregiver\"), but accepting needs a second real identity on a "
                + "live backend, so the accept flow is left alone rather than faked."
        )
    }
}
