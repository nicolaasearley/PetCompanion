import Foundation
import XCTest
@testable import PetCompanion

/// A reminder is convenience delivery, not the source of truth (doc 20
/// §4.10). These cover the rule that matters: nothing is presented until the
/// occurrence has been resolved again, and a target that is gone or
/// unverifiable degrades truthfully instead of opening a stale card.
@MainActor
final class NotificationDeepLinkTests: XCTestCase {
    func testTargetStillOnThePlanOpensItsCurrentState() {
        let fixture = planFixture()
        var completed = fixture.snapshot
        completed.occurrences[0].state = .completed

        XCTAssertEqual(
            NotificationDeepLinkResolver.resolve(fixture.target, against: completed),
            .planItem(id: fixture.itemId)
        )
    }

    func testTargetRemovedFromThePlanNeverNavigatesToIt() {
        let fixture = planFixture()
        var withoutItem = fixture.snapshot
        withoutItem.items = []

        XCTAssertEqual(
            NotificationDeepLinkResolver.resolve(fixture.target, against: withoutItem),
            .unavailable(.targetNoLongerInPlan)
        )
    }

    func testCacheServedPlanCannotConfirmTheItemSoTheTapLandsOnHome() {
        let fixture = planFixture()
        var cached = fixture.snapshot
        cached.servedFromCacheAt = .now

        XCTAssertEqual(
            NotificationDeepLinkResolver.resolve(fixture.target, against: cached),
            .home
        )
    }

    func testUnreadablePlanReportsAnOutageRatherThanALostHousehold() {
        XCTAssertEqual(
            NotificationDeepLinkResolver.resolve(planFixture().target, against: nil),
            .unavailable(.planUnavailable)
        )
    }

    func testAnotherPetsPlanIsNotTreatedAsTheRemindersTarget() {
        let fixture = planFixture()
        var target = fixture.target
        target.petId = UUID()

        XCTAssertEqual(
            NotificationDeepLinkResolver.resolve(target, against: fixture.snapshot),
            .unavailable(.targetNoLongerInPlan)
        )
    }

    /// A tap can wake the app before any session exists, so the inbox has to
    /// hold the target instead of dropping it.
    func testTapArrivingBeforeTheAppIsReadyIsDeliveredLater() {
        let inbox = NotificationDeepLinkInbox()
        let target = planFixture().target
        inbox.receive(target)

        var delivered: [AppDeepLinkTarget] = []
        inbox.setHandler { delivered.append($0) }
        XCTAssertEqual(delivered, [target])

        inbox.receive(target)
        XCTAssertEqual(delivered, [target, target])
    }

    private func planFixture() -> (
        snapshot: PlanSnapshot,
        target: AppDeepLinkTarget,
        itemId: UUID
    ) {
        let plan = Plan(
            householdId: UUID(),
            petId: UUID(),
            localDate: Date(),
            timeZoneSnapshot: "America/Toronto",
            stageSnapshot: StageSnapshot(stageKey: "foundations")
        )
        let occurrence = TaskOccurrence(
            occurrenceKey: "deep-link",
            householdId: plan.householdId,
            petId: plan.petId,
            localDueDate: plan.localDate,
            obligationClass: .scheduled,
            origin: .userCreated
        )
        let item = PlanItem(
            planId: plan.id,
            itemKey: "deep-link",
            kind: .obligation,
            occurrenceId: occurrence.id,
            title: "Evening walk",
            category: .household,
            obligationClass: .scheduled,
            section: .today
        )
        return (
            PlanSnapshot(
                plan: plan,
                items: [item],
                occurrences: [occurrence],
                dispositions: []
            ),
            .planItem(item.id, petId: plan.petId, date: plan.localDate),
            item.id
        )
    }
}
