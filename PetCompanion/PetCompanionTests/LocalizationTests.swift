import XCTest
@testable import PetCompanion

/// Guards the localization foundation: catalog keys must resolve to the English
/// source strings bundled with the app (default locale).
final class LocalizationTests: XCTestCase {
    func testTabLabelsResolveFromStringCatalog() {
        XCTAssertEqual(PCL10n.Tab.home, "Home")
        XCTAssertEqual(PCL10n.Tab.planner, "Planner")
        XCTAssertEqual(PCL10n.Tab.training, "Training")
        XCTAssertEqual(PCL10n.Tab.care, "Care")
        XCTAssertEqual(PCL10n.Tab.life, "Life")
    }

    func testHomeShellStringsResolveFromStringCatalog() {
        XCTAssertEqual(
            PCL10n.Home.allCaughtUpMessage,
            "You're all caught up. Add something to the plan or enjoy the day together."
        )
        XCTAssertEqual(PCL10n.Home.allCaughtUpAddTask, "Add a task")
        XCTAssertEqual(PCL10n.Home.quickAddTitle, "Add task")
    }
}
