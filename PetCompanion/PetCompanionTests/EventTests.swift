import XCTest
@testable import PetCompanion

/// Events store behavior (F11 / US-081).
@MainActor
final class EventTests: XCTestCase {
    private let householdId = UUID()
    private let petId = UUID()

    private func makeStore(service: any EventService) -> EventStore {
        EventStore(
            service: service,
            householdId: householdId,
            pets: [(petId, "Maple")],
            calendar: Calendar(identifier: .gregorian)
        )
    }

    private func assertExactlyOneOutcome(
        error: String?,
        queued: String?,
        confirmation: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let set = [error, queued, confirmation].compactMap { $0 }
        XCTAssertEqual(
            set.count, 1,
            "Expected exactly one outcome banner, found \(set.count): \(set)",
            file: file, line: line
        )
    }

    func testEventErrorNeverLeaksServerMessage() {
        let error = EventError(code: "SOME_NEW_CODE", message: "raw postgres detail")
        XCTAssertEqual(error, .unexpected(code: "SOME_NEW_CODE"))
        XCTAssertEqual(error.errorDescription, "Something went wrong. Try again.")
        XCTAssertFalse(error.errorDescription?.contains("postgres") == true)
    }

    func testSchemaCacheMissMapsToCalmCopy() {
        let raw = "Could not find the table 'public.events' in the schema cache"
        XCTAssertTrue(EventError.looksLikeMissingSchema(raw))
        XCTAssertEqual(
            EventError(code: "PGRST205", message: raw),
            .recordsUnavailable
        )
    }

    func testCreateEventSucceedsAndReloads() async {
        let service = InMemoryEventService()
        let store = makeStore(service: service)

        var draft = EventDraft()
        draft.title = "Vet checkup"
        draft.kind = .vetAppointment
        draft.petId = petId
        draft.allDay = false
        draft.startDate = Date()

        let saved = await store.create(draft)

        XCTAssertTrue(saved)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].title, "Vet checkup")
        XCTAssertEqual(store.events[0].kind, .vetAppointment)
        XCTAssertEqual(store.confirmationMessage, "Saved appointment.")
        XCTAssertNil(store.errorMessage)
        assertExactlyOneOutcome(
            error: store.errorMessage,
            queued: store.queuedMessage,
            confirmation: store.confirmationMessage
        )
    }

    func testCreateRejectsEmptyTitle() async {
        let store = makeStore(service: InMemoryEventService())
        var draft = EventDraft()
        draft.title = "   "
        let saved = await store.create(draft)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.errorMessage, EventError.invalidEntry.errorDescription)
        XCTAssertTrue(store.events.isEmpty)
    }

    func testEditBumpsThroughServiceRevisionCheck() async {
        let event = HouseholdEvent(
            id: UUID(),
            householdId: householdId,
            petId: petId,
            kind: .classSession,
            title: "Puppy class",
            startDate: Date(),
            startTime: nil,
            endTime: nil,
            allDay: true,
            locationText: nil,
            providerId: nil,
            notes: nil,
            reminderLeadMinutes: [60],
            status: .confirmed,
            revision: 1
        )
        let service = InMemoryEventService(seeded: [event])
        let store = makeStore(service: service)
        await store.load()

        var draft = EventDraft()
        draft.title = "Puppy class (moved)"
        draft.kind = .classSession
        draft.petId = petId
        draft.allDay = true
        draft.startDate = event.startDate

        let ok = await store.edit(store.events[0], draft: draft)
        XCTAssertTrue(ok)
        XCTAssertEqual(store.events[0].title, "Puppy class (moved)")
        XCTAssertEqual(store.events[0].revision, 2)
    }

    func testCancelMarksCancelled() async {
        let event = HouseholdEvent(
            id: UUID(),
            householdId: householdId,
            petId: nil,
            kind: .other,
            title: "Photo day",
            startDate: Date(),
            startTime: nil,
            endTime: nil,
            allDay: true,
            locationText: nil,
            providerId: nil,
            notes: nil,
            reminderLeadMinutes: [],
            status: .confirmed,
            revision: 1
        )
        let service = InMemoryEventService(seeded: [event])
        let store = makeStore(service: service)
        await store.load()

        let ok = await store.cancel(store.events[0])
        XCTAssertTrue(ok)
        XCTAssertTrue(store.events[0].isCancelled)
        XCTAssertEqual(store.confirmationMessage, "Cancelled.")
    }

    func testArchiveRemovesFromList() async {
        let event = HouseholdEvent(
            id: UUID(),
            householdId: householdId,
            petId: petId,
            kind: .groomingVisit,
            title: "Grooming",
            startDate: Date(),
            startTime: nil,
            endTime: nil,
            allDay: true,
            locationText: nil,
            providerId: nil,
            notes: nil,
            reminderLeadMinutes: [],
            status: .confirmed,
            revision: 1
        )
        let service = InMemoryEventService(seeded: [event])
        let store = makeStore(service: service)
        await store.load()
        XCTAssertEqual(store.events.count, 1)

        let ok = await store.archive(store.events[0])
        XCTAssertTrue(ok)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.confirmationMessage, "Removed.")
    }

    func testStaleRevisionSurfacesChangedElsewhere() async {
        let event = HouseholdEvent(
            id: UUID(),
            householdId: householdId,
            petId: petId,
            kind: .vetAppointment,
            title: "Vet",
            startDate: Date(),
            startTime: "10:00",
            endTime: nil,
            allDay: false,
            locationText: nil,
            providerId: nil,
            notes: nil,
            reminderLeadMinutes: [],
            status: .confirmed,
            revision: 1
        )
        let service = InMemoryEventService(seeded: [event])
        let store = makeStore(service: service)
        await store.load()

        // Simulate another caregiver's edit bumping revision underneath.
        var draft = EventDraft()
        draft.title = "Vet (partner)"
        draft.kind = .vetAppointment
        draft.petId = petId
        draft.allDay = false
        draft.startDate = event.startDate
        _ = await store.edit(store.events[0], draft: draft)

        let stale = event // revision 1
        draft.title = "Vet (stale)"
        let failed = await store.edit(stale, draft: draft)
        XCTAssertFalse(failed)
        XCTAssertEqual(store.errorMessage, EventError.changedElsewhere.errorDescription)
    }
}
