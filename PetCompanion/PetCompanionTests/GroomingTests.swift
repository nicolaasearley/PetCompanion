import XCTest
@testable import PetCompanion

/// Grooming history store behavior (F10 / US-076).
///
/// Mirrors VaccinationTests' truthfulness contract: failures never look like
/// success, queued offline writes are a distinct outcome, and GroomingError
/// never leaks raw server text. Next-due is never computed — only stored as entered.
@MainActor
final class GroomingTests: XCTestCase {
    private let petId = UUID()

    private func makeStore(service: any GroomingService) -> GroomingStore {
        GroomingStore(service: service, petId: petId, petName: "Maple")
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

    func testGroomingErrorNeverLeaksServerMessage() {
        let error = GroomingError(code: "SOME_NEW_CODE", message: "raw postgres detail")
        XCTAssertEqual(error, .unexpected(code: "SOME_NEW_CODE"))
        XCTAssertEqual(error.errorDescription, "Something went wrong. Try again.")
        XCTAssertFalse(error.errorDescription?.contains("postgres") == true)
    }

    func testSchemaCacheMissMapsToCalmCopy() {
        let raw = "Could not find the table 'public.grooming_records' in the schema cache"
        XCTAssertTrue(GroomingError.looksLikeMissingSchema(raw))
        XCTAssertEqual(
            GroomingError(code: "PGRST205", message: raw),
            .recordsUnavailable
        )
    }

    func testRecordGroomingSucceedsAndReloads() async {
        let service = InMemoryGroomingService()
        let store = makeStore(service: service)

        let saved = await store.record(
            GroomingDraft(
                activityType: .brushing,
                effectiveDate: Date(),
                nextDueDate: Calendar.current.date(byAdding: .day, value: 3, to: Date()),
                includeNextDue: true,
                note: "Short calm session"
            )
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].activityType, .brushing)
        XCTAssertNotNil(store.records[0].nextDueDate)
        XCTAssertEqual(store.confirmationMessage, "Saved brushing.")
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.queuedMessage)
    }

    func testRecordWithoutNextDueLeavesNil() async {
        let service = InMemoryGroomingService()
        let store = makeStore(service: service)

        _ = await store.record(
            GroomingDraft(
                activityType: .nails,
                effectiveDate: Date(),
                nextDueDate: Date(),
                includeNextDue: false,
                note: ""
            )
        )

        XCTAssertEqual(store.records.count, 1)
        XCTAssertNil(store.records[0].nextDueDate, "Toggle off means no next-due fact.")
    }

    func testFailedSaveSurfacesErrorWithoutConfirmation() async {
        let service = FailingGroomingService()
        service.error = GroomingError.invalidEntry
        let store = makeStore(service: service)

        let saved = await store.record(GroomingDraft.blank())

        XCTAssertFalse(saved)
        XCTAssertEqual(store.errorMessage, GroomingError.invalidEntry.errorDescription)
        XCTAssertNil(store.confirmationMessage)
        assertExactlyOneOutcome(
            error: store.errorMessage,
            queued: store.queuedMessage,
            confirmation: store.confirmationMessage
        )
    }

    func testQueuedWriteIsDistinctFromConfirmedSuccess() async {
        let service = FailingGroomingService()
        service.error = OfflineMutationError.queued(operationId: UUID())
        let store = makeStore(service: service)

        let saved = await store.record(GroomingDraft.blank())

        XCTAssertTrue(saved, "Queued acceptance is real — the caller may dismiss.")
        XCTAssertNotNil(store.queuedMessage)
        XCTAssertNil(store.confirmationMessage)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.records.isEmpty, "No optimistic placeholder row.")
    }

    func testEditBumpsRevisionViaService() async {
        let service = InMemoryGroomingService()
        let existing = GroomingRecord(
            id: UUID(),
            activityType: .bath,
            effectiveDate: Date(),
            nextDueDate: nil,
            note: nil,
            revision: 1,
            recordedByName: "You"
        )
        service.seed(existing, petId: petId)
        let store = makeStore(service: service)
        await store.load()

        var draft = GroomingDraft.from(existing)
        draft.activityType = .teeth
        draft.note = "Gentle"
        let saved = await store.edit(existing, draft: draft)

        XCTAssertTrue(saved)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].activityType, .teeth)
        XCTAssertEqual(store.records[0].revision, 2)
        XCTAssertEqual(store.records[0].note, "Gentle")
    }
}

@MainActor
private final class FailingGroomingService: GroomingService {
    var error: Error = GroomingError.unexpected(code: "TEST")

    func loadGrooming(petId: UUID) async throws -> [GroomingRecord] {
        throw error
    }

    func recordGrooming(_ draft: GroomingDraft, petId: UUID) async throws {
        throw error
    }

    func editGrooming(
        groomingId: UUID,
        expectedRevision: Int,
        draft: GroomingDraft
    ) async throws {
        throw error
    }

    func removeGrooming(groomingId: UUID) async throws {
        throw error
    }
}
