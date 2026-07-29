import XCTest
@testable import PetCompanion

/// Vaccination history store behavior (F10 / US-070).
///
/// Mirrors CareTests' truthfulness contract: failures never look like success,
/// queued offline writes are a distinct outcome, and VaccinationError never
/// leaks raw server text. Next-due is never computed — only stored as entered.
@MainActor
final class VaccinationTests: XCTestCase {
    private let petId = UUID()

    private func makeStore(service: any VaccinationService) -> VaccinationStore {
        VaccinationStore(service: service, petId: petId, petName: "Maple")
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

    func testVaccinationErrorNeverLeaksServerMessage() {
        let error = VaccinationError(code: "SOME_NEW_CODE", message: "raw postgres detail")
        XCTAssertEqual(error, .unexpected(code: "SOME_NEW_CODE"))
        XCTAssertEqual(error.errorDescription, "Something went wrong. Try again.")
        XCTAssertFalse(error.errorDescription?.contains("postgres") == true)
    }

    func testSchemaCacheMissMapsToCalmCopy() {
        let raw = "Could not find the table 'public.vaccination_records' in the schema cache"
        XCTAssertTrue(VaccinationError.looksLikeMissingSchema(raw))
        XCTAssertEqual(
            VaccinationError(code: "PGRST205", message: raw),
            .recordsUnavailable
        )
    }

    func testRecordVaccinationSucceedsAndReloads() async {
        let service = InMemoryVaccinationService()
        let store = makeStore(service: service)

        let saved = await store.record(
            VaccinationDraft(
                vaccineName: "DHPP",
                effectiveDate: Date(),
                nextDueDate: Calendar.current.date(byAdding: .day, value: 365, to: Date()),
                includeNextDue: true,
                provenance: .professionalInstruction,
                providerId: nil,
                note: "Clinic card"
            )
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].vaccineName, "DHPP")
        XCTAssertNotNil(store.records[0].nextDueDate)
        XCTAssertEqual(store.confirmationMessage, "Saved DHPP.")
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.queuedMessage)
    }

    func testRecordWithoutNextDueLeavesNil() async {
        let service = InMemoryVaccinationService()
        let store = makeStore(service: service)

        _ = await store.record(
            VaccinationDraft(
                vaccineName: "Rabies",
                effectiveDate: Date(),
                nextDueDate: Date(),
                includeNextDue: false,
                provenance: .ownerEntered,
                providerId: nil,
                note: ""
            )
        )

        XCTAssertEqual(store.records.count, 1)
        XCTAssertNil(store.records[0].nextDueDate, "Toggle off means no next-due fact.")
    }

    func testFailedSaveSurfacesErrorWithoutConfirmation() async {
        let service = FailingVaccinationService()
        service.error = VaccinationError.invalidEntry
        let store = makeStore(service: service)

        let saved = await store.record(VaccinationDraft.blank())

        XCTAssertFalse(saved)
        XCTAssertEqual(store.errorMessage, VaccinationError.invalidEntry.errorDescription)
        XCTAssertNil(store.confirmationMessage)
        assertExactlyOneOutcome(
            error: store.errorMessage,
            queued: store.queuedMessage,
            confirmation: store.confirmationMessage
        )
    }

    func testQueuedWriteIsDistinctFromConfirmedSuccess() async {
        let service = FailingVaccinationService()
        service.error = OfflineMutationError.queued(operationId: UUID())
        let store = makeStore(service: service)

        var draft = VaccinationDraft.blank()
        draft.vaccineName = "DHPP"
        let saved = await store.record(draft)

        XCTAssertTrue(saved, "Queued acceptance is real — the caller may dismiss.")
        XCTAssertNotNil(store.queuedMessage)
        XCTAssertNil(store.confirmationMessage)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.records.isEmpty, "No optimistic placeholder row.")
    }

    func testDuplicatePromptWithinWindow() async {
        let service = InMemoryVaccinationService()
        let previous = VaccinationRecord(
            id: UUID(),
            vaccineName: "DHPP",
            effectiveDate: Calendar.current.date(byAdding: .day, value: -3, to: Date())!,
            nextDueDate: nil,
            provenance: .ownerEntered,
            providerId: nil,
            note: nil,
            revision: 1,
            recordedByName: "You"
        )
        service.seed(previous, petId: petId)
        let store = makeStore(service: service)
        await store.load()

        var draft = VaccinationDraft.blank()
        draft.vaccineName = "dhpp"
        draft.effectiveDate = Date()
        let prompt = store.duplicatePrompt(for: draft)
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt?.contains("DHPP") == true)
    }

    func testDuplicatePromptIgnoresDistantDates() async {
        let service = InMemoryVaccinationService()
        let previous = VaccinationRecord(
            id: UUID(),
            vaccineName: "DHPP",
            effectiveDate: Calendar.current.date(byAdding: .day, value: -60, to: Date())!,
            nextDueDate: nil,
            provenance: .ownerEntered,
            providerId: nil,
            note: nil,
            revision: 1,
            recordedByName: "You"
        )
        service.seed(previous, petId: petId)
        let store = makeStore(service: service)
        await store.load()

        var draft = VaccinationDraft.blank()
        draft.vaccineName = "DHPP"
        XCTAssertNil(store.duplicatePrompt(for: draft))
    }
}

@MainActor
private final class FailingVaccinationService: VaccinationService {
    var error: Error = VaccinationError.unexpected(code: "TEST")

    func loadVaccinations(petId: UUID) async throws -> [VaccinationRecord] {
        throw error
    }

    func recordVaccination(_ draft: VaccinationDraft, petId: UUID) async throws {
        throw error
    }

    func editVaccination(
        vaccinationId: UUID,
        expectedRevision: Int,
        draft: VaccinationDraft
    ) async throws {
        throw error
    }

    func removeVaccination(vaccinationId: UUID) async throws {
        throw error
    }
}
