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

    func testEventCandidateUsesEachLeadAndDiscreetCopy() throws {
        // Start tomorrow so a 1-day lead still fires after `now`.
        let fixture = eventReminderFixture(
            hour: 15,
            leads: [60, 1440],
            startDay: 28
        )
        var preferences = LocalNotificationPreferences.defaults
        preferences.enabled = true

        let candidates = EventLocalNotificationCandidateBuilder.candidates(
            events: [fixture.event],
            timeZoneId: "America/Toronto",
            preferences: preferences,
            now: fixture.now
        )

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(
            Set(candidates.map(\.body)),
            [LocalNotificationCandidate.eventBody]
        )
        XCTAssertTrue(candidates.allSatisfy { $0.deepLink.destination == .event })
        XCTAssertTrue(candidates.allSatisfy { $0.deepLink.eventId == fixture.event.id })
        XCTAssertFalse(
            candidates.contains(where: {
                $0.body.localizedCaseInsensitiveContains("vet")
                    || $0.body.localizedCaseInsensitiveContains(fixture.event.title)
            })
        )

        let hourLead = try XCTUnwrap(candidates.first { $0.id.hasSuffix(":60") })
        XCTAssertEqual(
            hourLead.fireDate.timeIntervalSince(fixture.startInstant),
            -3600,
            accuracy: 1
        )
        let dayLead = try XCTUnwrap(candidates.first { $0.id.hasSuffix(":1440") })
        XCTAssertEqual(
            dayLead.fireDate.timeIntervalSince(fixture.startInstant),
            -86_400,
            accuracy: 1
        )

        var toronto = Calendar(identifier: .gregorian)
        toronto.timeZone = TimeZone(identifier: "America/Toronto")!
        XCTAssertEqual(
            toronto.dateComponents([.year, .month, .day], from: hourLead.fireDate),
            DateComponents(year: 2026, month: 7, day: 28),
            "west-of-GMT households must not schedule event reminders a day early"
        )
    }

    func testEventCandidateBuilderSkipsCancelledQuietAndEmptyLeads() {
        var preferences = LocalNotificationPreferences.defaults
        preferences.enabled = true
        preferences.quietHoursStart = 21
        preferences.quietHoursEnd = 7

        let quiet = eventReminderFixture(hour: 22, leads: [0])
        XCTAssertTrue(
            EventLocalNotificationCandidateBuilder.candidates(
                events: [quiet.event],
                timeZoneId: "America/Toronto",
                preferences: preferences,
                now: quiet.now
            ).isEmpty
        )

        let cancelled = eventReminderFixture(hour: 15, leads: [60], status: .cancelled)
        XCTAssertTrue(
            EventLocalNotificationCandidateBuilder.candidates(
                events: [cancelled.event],
                timeZoneId: "America/Toronto",
                preferences: preferences,
                now: cancelled.now
            ).isEmpty
        )

        let noLeads = eventReminderFixture(hour: 15, leads: [])
        XCTAssertTrue(
            EventLocalNotificationCandidateBuilder.candidates(
                events: [noLeads.event],
                timeZoneId: "America/Toronto",
                preferences: preferences,
                now: noLeads.now
            ).isEmpty
        )
    }

    func testEventReconcileUsesSeparateNamespaceAndCancelClearsBoth() async throws {
        let suiteName = "LocalNotificationsTests-events-\(UUID().uuidString)"
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

        let planFixture = reminderFixture(hour: 15)
        await service.reconcile(snapshot: planFixture.snapshot, now: planFixture.now)

        let eventFixture = eventReminderFixture(hour: 16, leads: [60])
        await service.reconcileEvents(
            events: [eventFixture.event],
            timeZoneId: "America/Toronto",
            now: eventFixture.now
        )

        let planNamespace = "pc.local.\(accountId.uuidString)."
        let eventNamespace = "pc.event.\(accountId.uuidString)."
        XCTAssertEqual(center.replacements.map(\.0), [planNamespace, eventNamespace])

        let eventReplacement = try XCTUnwrap(center.replacements.last)
        XCTAssertEqual(eventReplacement.1.count, 1)
        let request = try XCTUnwrap(eventReplacement.1.first)
        XCTAssertTrue(request.identifier.hasPrefix(eventNamespace))
        XCTAssertEqual(request.body, LocalNotificationCandidate.eventBody)
        XCTAssertEqual(request.deepLink.destination, .event)

        // Plan reconcile must not wipe the event namespace.
        await service.reconcile(snapshot: planFixture.snapshot, now: planFixture.now)
        XCTAssertEqual(center.replacements.map(\.0).filter { $0 == eventNamespace }.count, 1)

        // Cancelled event replaces with empty event namespace.
        let cancelled = eventReminderFixture(
            hour: 16,
            leads: [60],
            status: .cancelled,
            id: eventFixture.event.id
        )
        await service.reconcileEvents(
            events: [cancelled.event],
            timeZoneId: "America/Toronto",
            now: eventFixture.now
        )
        let cleared = try XCTUnwrap(center.replacements.last)
        XCTAssertEqual(cleared.0, eventNamespace)
        XCTAssertTrue(cleared.1.isEmpty)

        await service.cancelPending()
        XCTAssertTrue(center.removals.contains(planNamespace))
        XCTAssertTrue(center.removals.contains(eventNamespace))
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

    private func eventReminderFixture(
        hour: Int,
        leads: [Int],
        status: EventStatus = .confirmed,
        id: UUID = UUID(),
        startDay: Int = 27
    ) -> (event: HouseholdEvent, now: Date, startInstant: Date) {
        var householdCalendar = Calendar(identifier: .gregorian)
        householdCalendar.timeZone = TimeZone(identifier: "America/Toronto")!
        var gmtCalendar = Calendar(identifier: .gregorian)
        gmtCalendar.timeZone = .gmt
        let startDate = gmtCalendar.date(
            from: DateComponents(year: 2026, month: 7, day: startDay)
        )!
        let now = householdCalendar.date(
            from: DateComponents(year: 2026, month: 7, day: 27, hour: 10)
        )!
        let startInstant = householdCalendar.date(
            from: DateComponents(year: 2026, month: 7, day: startDay, hour: hour)
        )!
        let event = HouseholdEvent(
            id: id,
            householdId: UUID(),
            petId: UUID(),
            kind: .vetAppointment,
            title: "Private vet notes must stay off banners",
            startDate: startDate,
            startTime: String(format: "%02d:00", hour),
            endTime: nil,
            allDay: false,
            locationText: nil,
            providerId: nil,
            notes: "Sensitive health detail",
            reminderLeadMinutes: leads,
            status: status,
            revision: 1
        )
        return (event, now, startInstant)
    }
}
