import Foundation
import XCTest
@testable import PetCompanion

@MainActor
final class LocalNotificationsTests: XCTestCase {
    private final class NotificationCenter: LocalNotificationCenterClient {
        var currentPermission: NotificationPermission
        var permissionAfterRequest: NotificationPermission
        private(set) var requestCount = 0
        private(set) var replacements: [(String, [LocalNotificationRequest])] = []
        private(set) var removals: [String] = []

        init(
            permission: NotificationPermission,
            permissionAfterRequest: NotificationPermission = .denied
        ) {
            currentPermission = permission
            self.permissionAfterRequest = permissionAfterRequest
        }

        func permission() async -> NotificationPermission {
            currentPermission
        }

        func requestAuthorization() async throws -> Bool {
            requestCount += 1
            currentPermission = permissionAfterRequest
            return currentPermission == .authorized
        }

        func replacePending(
            namespace: String,
            requests: [LocalNotificationRequest]
        ) async throws {
            replacements.append((namespace, requests))
        }

        func removePending(namespace: String) async {
            removals.append(namespace)
        }
    }

    func testExactTimeCandidateUsesLeadTimeAndDeepLink() throws {
        let fixture = reminderFixture(hour: 15)
        var preferences = LocalNotificationPreferences.defaults
        preferences.enabled = true
        preferences.leadMinutes = 10

        let candidates = LocalNotificationCandidateBuilder.candidates(
            snapshot: fixture.snapshot,
            preferences: preferences,
            now: fixture.now
        )

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidate.deepLink.destination, .planItem)
        XCTAssertEqual(candidate.deepLink.planItemId, fixture.itemId)
        XCTAssertEqual(candidate.deepLink.petId, fixture.snapshot.plan.petId)
        XCTAssertEqual(
            candidate.fireDate.timeIntervalSince(fixture.dueDate),
            -600,
            accuracy: 1
        )
        // Name the failure directly: the reminder must fall on the occurrence's
        // own household-local day, not the one before it.
        var toronto = Calendar(identifier: .gregorian)
        toronto.timeZone = TimeZone(identifier: "America/Toronto")!
        XCTAssertEqual(
            toronto.dateComponents([.year, .month, .day], from: candidate.fireDate),
            DateComponents(year: 2026, month: 7, day: 27),
            "a household west of GMT must not have its reminder scheduled a day early"
        )
    }

    func testCandidateBuilderSuppressesQuietQueuedAndCompletedItems() {
        var quietPreferences = LocalNotificationPreferences.defaults
        quietPreferences.enabled = true
        quietPreferences.leadMinutes = 0
        XCTAssertTrue(
            LocalNotificationCandidateBuilder.candidates(
                snapshot: reminderFixture(hour: 22).snapshot,
                preferences: quietPreferences,
                now: reminderFixture(hour: 22).now
            ).isEmpty
        )

        let fixture = reminderFixture(hour: 15)
        var queued = fixture.snapshot
        queued.items[0].displayState = .queued
        XCTAssertTrue(
            LocalNotificationCandidateBuilder.candidates(
                snapshot: queued,
                preferences: quietPreferences,
                now: fixture.now
            ).isEmpty
        )

        var completed = fixture.snapshot
        completed.occurrences[0].state = .completed
        XCTAssertTrue(
            LocalNotificationCandidateBuilder.candidates(
                snapshot: completed,
                preferences: quietPreferences,
                now: fixture.now
            ).isEmpty
        )
    }

    func testAuthorizationPromptOccursAtMostOnce() async {
        let suiteName = "LocalNotificationsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = NotificationCenter(
            permission: .notDetermined,
            permissionAfterRequest: .denied
        )
        let service = LocalNotificationService(
            center: center,
            store: LocalNotificationPreferenceStore(defaults: defaults)
        )
        service.activate(accountId: UUID())

        _ = await service.setEnabled(true)
        _ = await service.setEnabled(true)

        XCTAssertEqual(center.requestCount, 1)
        XCTAssertFalse(service.preferences.enabled)
        XCTAssertEqual(service.permission, .denied)
    }

    func testAuthorizedServiceReconcilesNamespacedDiscreetRequests() async throws {
        let suiteName = "LocalNotificationsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountId = UUID()
        let center = NotificationCenter(permission: .authorized)
        let service = LocalNotificationService(
            center: center,
            store: LocalNotificationPreferenceStore(defaults: defaults)
        )
        service.activate(accountId: accountId)
        _ = await service.setEnabled(true)
        // Pin the clock to the fixture's own instant. Reconciling against the
        // real one made this pass only before the fixture's fire time had
        // elapsed, so it failed every afternoon.
        let fixture = reminderFixture(hour: 15)
        await service.reconcile(snapshot: fixture.snapshot, now: fixture.now)

        let replacement = try XCTUnwrap(center.replacements.last)
        XCTAssertEqual(replacement.0, "pc.local.\(accountId.uuidString).")
        XCTAssertEqual(replacement.1.count, 1)
        let request = try XCTUnwrap(replacement.1.first)
        XCTAssertTrue(request.identifier.hasPrefix(replacement.0))
        XCTAssertEqual(request.deepLink.destination, .planItem)
        XCTAssertEqual(center.requestCount, 0)

        let decoded = AppDeepLinkTarget(
            notificationUserInfo: request.deepLink.notificationUserInfo
        )
        XCTAssertEqual(decoded, request.deepLink)

        _ = await service.setEnabled(false)
        XCTAssertTrue(center.removals.contains(replacement.0))
    }

    private func reminderFixture(
        hour: Int
    ) -> (snapshot: PlanSnapshot, now: Date, dueDate: Date, itemId: UUID) {
        var householdCalendar = Calendar(identifier: .gregorian)
        householdCalendar.timeZone = TimeZone(identifier: "America/Toronto")!
        // A SQL `date` decodes onto midnight GMT, not a household-local
        // instant. Building this the convenient way — Toronto noon — hid a
        // real off-by-a-day: west of GMT, setting a wall time "of" the decoded
        // value lands on the previous day, and for today's plan that puts the
        // reminder in the past where it is silently dropped.
        var gmtCalendar = Calendar(identifier: .gregorian)
        gmtCalendar.timeZone = .gmt
        let localDate = gmtCalendar.date(
            from: DateComponents(year: 2026, month: 7, day: 27)
        )!
        let now = householdCalendar.date(
            from: DateComponents(year: 2026, month: 7, day: 27, hour: 10)
        )!
        let dueDate = householdCalendar.date(
            from: DateComponents(year: 2026, month: 7, day: 27, hour: hour)
        )!
        let deviceCalendar = Calendar.current
        let dueTime = deviceCalendar.date(
            from: DateComponents(year: 2026, month: 7, day: 27, hour: hour)
        )!
        let plan = Plan(
            householdId: UUID(),
            petId: UUID(),
            localDate: localDate,
            timeZoneSnapshot: "America/Toronto",
            stageSnapshot: StageSnapshot(stageKey: "foundations")
        )
        let occurrence = TaskOccurrence(
            occurrenceKey: "test-reminder",
            householdId: plan.householdId,
            petId: plan.petId,
            localDueDate: localDate,
            timePolicy: .exactTime,
            dueTime: dueTime,
            obligationClass: .scheduled,
            origin: .userCreated
        )
        let item = PlanItem(
            planId: plan.id,
            itemKey: "test-reminder",
            kind: .obligation,
            occurrenceId: occurrence.id,
            title: "Private task title",
            category: .health,
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
            now,
            dueDate,
            item.id
        )
    }
}
