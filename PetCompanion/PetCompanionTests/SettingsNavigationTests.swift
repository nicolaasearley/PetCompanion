import Foundation
import XCTest
@testable import PetCompanion

/// Profile & Settings is a stack reached from a contextual entry, not a tab
/// (IA §5.2/§5.3). These cover what that entry is allowed to open.
@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testAnEntryOutsideHomeCanOpenAScreenDirectly() {
        XCTAssertEqual(
            SettingsView.Destination.initialPath(opening: .hub),
            [],
            "The hub is the stack's root; pushing it would leave a back button to itself"
        )
        XCTAssertEqual(
            SettingsView.Destination.initialPath(opening: .members),
            [.members],
            "ST-04 is named by the caller, not hunted for from the hub"
        )
        XCTAssertEqual(
            SettingsView.Destination.initialPath(opening: .rejectedChanges),
            [.rejectedChanges]
        )
        XCTAssertEqual(
            SettingsView.Destination.initialPath(opening: .events),
            [.events],
            "Appointments & events is named by the caller (F11 foundation)"
        )
    }

    /// The sync summary has to distinguish work that will still be sent from
    /// work that never will (doc 09 §15.1).
    func testRefusedWorkIsNotCountedAsWaitingToSync() {
        var status = MutationSyncStatus()
        status.rejectedCount = 2

        XCTAssertEqual(status.pendingCount, 0, "Nothing is waiting: a refusal is never retried")
        XCTAssertFalse(status.isCurrent, "But the device is not up to date either")

        status.rejectedCount = 0
        XCTAssertTrue(status.isCurrent)
    }
}
