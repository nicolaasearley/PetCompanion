import XCTest
@testable import PetCompanion

/// Care weight + providers store behavior (F10 / US-075 / CA-08–CA-09).
///
/// Mirrors SocializationTests' truthfulness contract: failures never look like
/// success, queued offline writes are a distinct outcome, and CareError never
/// leaks raw server text.
@MainActor
final class CareTests: XCTestCase {
    private let petId = UUID()
    private let householdId = UUID()

    private func makeWeightStore(service: any CareService) -> WeightStore {
        WeightStore(service: service, petId: petId, petName: "Maple")
    }

    private func makeProvidersStore(service: any CareService) -> ProvidersStore {
        ProvidersStore(service: service, householdId: householdId)
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

    // MARK: - CareError mapping

    func testCareErrorNeverLeaksServerMessageForUnknownCodes() {
        let error = CareError(code: "SOME_NEW_CODE", message: "raw postgres detail")
        XCTAssertEqual(error, .unexpected(code: "SOME_NEW_CODE"))
        XCTAssertEqual(error.errorDescription, "Something went wrong. Try again.")
        XCTAssertFalse(error.errorDescription?.contains("postgres") == true)
    }

    func testCareErrorMapsRevisionConflict() {
        let error = CareError(code: "REVISION_CONFLICT", message: "stale")
        XCTAssertEqual(error, .changedElsewhere)
        XCTAssertTrue(error.errorDescription?.contains("changed") == true)
    }

    func testSchemaCacheMissMapsToCalmBackendCopy() {
        let raw = "Could not find the table 'public.weight_measurements' in the schema cache"
        XCTAssertTrue(CareError.looksLikeMissingSchema(raw))
        XCTAssertEqual(
            CareError(code: "PGRST205", message: raw),
            .recordsUnavailable
        )
        XCTAssertEqual(
            CareError.displayMessage(for: CareServiceError.unavailable(raw)),
            CareError.recordsUnavailable.errorDescription
        )
        XCTAssertEqual(
            CareError.fromTransportFailure(CareServiceError.unavailable(raw)) as? CareError,
            .recordsUnavailable
        )
        // Unrelated failures stay generic / pass through — not permanently hidden.
        XCTAssertEqual(
            CareError.displayMessage(for: CareError.invalidEntry),
            CareError.invalidEntry.errorDescription
        )
    }

    func testLoadSurfacesCalmCopyForSchemaCacheMiss() async {
        let service = FailingCareService()
        service.weightError = CareServiceError.unavailable(
            "Could not find the table 'public.providers' in the schema cache"
        )
        let store = makeWeightStore(service: service)
        await store.load()
        XCTAssertEqual(store.errorMessage, CareError.recordsUnavailable.errorDescription)
        XCTAssertTrue(store.measurements.isEmpty)
    }

    // MARK: - Weight

    func testRecordWeightSucceedsAndReloads() async {
        let service = InMemoryCareService()
        let store = makeWeightStore(service: service)

        let saved = await store.record(
            WeightDraft(valueText: "6.4", unit: .kg, effectiveDate: Date(), note: "Clinic")
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(store.measurements.count, 1)
        XCTAssertEqual(store.measurements[0].value, Decimal(string: "6.4"))
        XCTAssertEqual(store.confirmationMessage, "Saved Maple's weight.")
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.queuedMessage)
    }

    func testFailedWeightSaveSurfacesErrorWithoutConfirmation() async {
        let service = FailingCareService()
        service.weightError = CareError.invalidEntry
        let store = makeWeightStore(service: service)

        let saved = await store.record(
            WeightDraft(valueText: "6.4", unit: .kg, effectiveDate: Date(), note: "")
        )

        XCTAssertFalse(saved)
        XCTAssertEqual(store.errorMessage, CareError.invalidEntry.errorDescription)
        XCTAssertNil(store.confirmationMessage)
        assertExactlyOneOutcome(
            error: store.errorMessage,
            queued: store.queuedMessage,
            confirmation: store.confirmationMessage
        )
    }

    func testQueuedWeightWriteIsDistinctFromConfirmedSuccess() async {
        let service = FailingCareService()
        service.weightError = OfflineMutationError.queued(operationId: UUID())
        let store = makeWeightStore(service: service)

        let saved = await store.record(
            WeightDraft(valueText: "6.4", unit: .kg, effectiveDate: Date(), note: "")
        )

        XCTAssertTrue(saved, "Queued acceptance is real — the caller may dismiss.")
        XCTAssertNotNil(store.queuedMessage)
        XCTAssertNil(store.confirmationMessage)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.measurements.isEmpty, "No optimistic placeholder row.")
    }

    func testOutlierPromptTriggersOnTenfoldJump() async {
        let service = InMemoryCareService()
        let previous = WeightMeasurement(
            id: UUID(), value: Decimal(string: "6.4")!, unit: .kg,
            effectiveDate: Date(), note: nil, revision: 1, recordedByName: "You"
        )
        service.seedWeight(previous, petId: petId)
        let store = makeWeightStore(service: service)
        await store.load()

        let prompt = store.outlierPrompt(
            for: WeightDraft(valueText: "64", unit: .kg, effectiveDate: Date(), note: "")
        )
        XCTAssertEqual(prompt, "6.4 kg → 64 kg — is that right?")
    }

    func testDisplayConversionDoesNotChangeStoredUnit() {
        let measurement = WeightMeasurement(
            id: UUID(), value: Decimal(string: "6.4")!, unit: .kg,
            effectiveDate: Date(), note: nil, revision: 1, recordedByName: nil
        )
        XCTAssertEqual(measurement.displayValue, "6.4 kg")
        XCTAssertTrue(measurement.displayValue(in: .lb).contains("lb"))
        XCTAssertEqual(measurement.unit, .kg)
    }

    func testExplicitDisplayUnitSurvivesReload() async {
        let service = InMemoryCareService()
        let lbEntry = WeightMeasurement(
            id: UUID(), value: Decimal(string: "14")!, unit: .lb,
            effectiveDate: Date(), note: nil, revision: 1, recordedByName: nil
        )
        service.seedWeight(lbEntry, petId: petId)
        let store = makeWeightStore(service: service)

        await store.load()
        XCTAssertEqual(store.displayUnit, .lb, "First load may default to latest entry unit")

        store.setDisplayUnit(.kg)
        await store.load()
        XCTAssertEqual(store.displayUnit, .kg, "Explicit display preference must survive reload")
    }

    func testWeightJSONTextDecodingPreservesPrecisionThatDoubleCorrupts() throws {
        // RealCareService selects `value::text` and decodes String → Decimal.
        // A JSON number field would decode through Double and is rejected here.
        struct TextWeightValue: Decodable {
            let value: String
        }
        let decoder = JSONDecoder()

        for text in ["6.4", "0.85"] {
            let data = Data("{\"value\":\"\(text)\"}".utf8)
            let row = try decoder.decode(TextWeightValue.self, from: data)
            let decoded = CareCoding.weightValue(fromJSONText: row.value)
            XCTAssertEqual(decoded, Decimal(string: text))
            XCTAssertEqual(WeightMeasurement.format(decoded!), text)
        }

        XCTAssertThrowsError(
            try decoder.decode(TextWeightValue.self, from: Data(#"{"value":6.4}"#.utf8)),
            "Numeric JSON must not decode as the weight value field (Double path)"
        )
        XCTAssertThrowsError(
            try decoder.decode(TextWeightValue.self, from: Data(#"{"value":0.85}"#.utf8)),
            "Numeric JSON must not decode as the weight value field (Double path)"
        )
    }

    // MARK: - Providers

    func testCreateProviderSucceedsAndReloads() async {
        let service = InMemoryCareService()
        let store = makeProvidersStore(service: service)

        let saved = await store.create(
            ProviderDraft(
                name: "Riverside Vet",
                kind: .veterinarian,
                phone: "+1-555-0100",
                address: "",
                notes: ""
            )
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(store.providers.count, 1)
        XCTAssertEqual(store.providers[0].name, "Riverside Vet")
        XCTAssertEqual(store.confirmationMessage, "Provider saved.")
    }

    func testQueuedProviderWriteIsDistinctFromConfirmedSuccess() async {
        let service = FailingCareService()
        service.providerError = OfflineMutationError.queued(operationId: UUID())
        let store = makeProvidersStore(service: service)

        let saved = await store.create(
            ProviderDraft(name: "Park Groomer", kind: .groomer, phone: "", address: "", notes: "")
        )

        XCTAssertTrue(saved)
        XCTAssertNotNil(store.queuedMessage)
        XCTAssertNil(store.confirmationMessage)
        XCTAssertTrue(store.providers.isEmpty)
    }

    func testFailedProviderEditSurfacesRevisionConflictCopy() async {
        let existing = CareProvider(
            id: UUID(), name: "Riverside Vet", kind: .veterinarian,
            phone: nil, address: nil, notes: nil, revision: 2
        )
        let service = FailingCareService(seededProviders: [existing])
        service.providerError = CareError.changedElsewhere
        let store = makeProvidersStore(service: service)
        await store.load()

        let saved = await store.edit(
            existing,
            draft: ProviderDraft(name: "Riverside Vet", kind: .veterinarian, phone: "", address: "", notes: "x")
        )

        XCTAssertFalse(saved)
        XCTAssertEqual(store.errorMessage, CareError.changedElsewhere.errorDescription)
        XCTAssertNil(store.confirmationMessage)
    }

    // MARK: - Medications

    func testCreateMedicationPreservesDoseVerbatim() async {
        let service = InMemoryCareService()
        let store = MedicationsStore(service: service, petId: petId, petName: "Maple")
        var draft = MedicationDraft.blank()
        draft.medicationName = "Worming treatment"
        draft.doseText = "1 tablet (as written)"
        draft.recurrenceType = .everyNDays
        draft.intervalDays = 14

        let saved = await store.create(draft)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.schedules.count, 1)
        XCTAssertEqual(store.schedules[0].doseText, "1 tablet (as written)")
        XCTAssertEqual(store.schedules[0].medicationName, "Worming treatment")
        XCTAssertNotNil(store.schedules[0].nextDue)
    }

    func testNeutralDueSummaryFromOwnerSchedule() {
        let calendar = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 29
        let today = calendar.date(from: comps)!
        comps.day = 34
        let due = calendar.date(from: comps)!
        let next = MedicationNextDue(
            occurrenceId: UUID(),
            localDueDate: due,
            originalLocalDueDate: due,
            timePolicy: .anytime,
            dueTime: nil,
            windowRef: nil,
            occurrenceRevision: 1
        )
        XCTAssertEqual(next.dueSummary(relativeTo: today, calendar: calendar), "Due in 5 days")
    }

    func testCompleteRequiresExtraConfirmForRecentPartner() async {
        let me = UUID()
        let service = InMemoryCareService(actorUserId: me)
        let store = MedicationsStore(
            service: service, petId: petId, petName: "Maple",
            currentUserId: me
        )
        var draft = MedicationDraft.blank()
        draft.medicationName = "Flea & Tick Prevention"
        draft.doseText = "1 pipette"
        draft.recurrenceType = .intervalAfterCompletion
        draft.intervalDays = 30
        _ = await store.create(draft)
        let schedule = store.schedules[0]

        service.pendingRecentPartnerCompletion = MedicationLastCompletion(
            effectiveAt: Date(),
            actorUserId: UUID(),
            actorName: "Sarah",
            completedDueDate: schedule.nextDue?.localDueDate
        )

        let blocked = await store.complete(schedule, acknowledgedRecentCompletion: false)
        XCTAssertFalse(blocked)
        XCTAssertNotNil(store.recentCompletionNotice)
        XCTAssertNil(store.confirmationMessage)

        let saved = await store.complete(schedule, acknowledgedRecentCompletion: true)
        XCTAssertTrue(saved)
        XCTAssertNil(store.recentCompletionNotice)
        XCTAssertEqual(store.confirmationMessage, "Recorded for Maple.")
        XCTAssertEqual(store.schedules[0].lastCompletion?.actorName, "You")
    }

    func testRequiredConfirmationMapsCalmly() {
        let error = CareError(
            code: "REQUIRED_CONFIRMATION",
            message: "another caregiver recently recorded this medication (Sarah)."
        )
        if case .recentCompletionNeedsConfirm(let message) = error {
            XCTAssertTrue(message.contains("Sarah"))
        } else {
            XCTFail("Expected recentCompletionNeedsConfirm")
        }
    }

    func testArchiveMedicationRemovesFromActiveList() async {
        let service = InMemoryCareService()
        let store = MedicationsStore(service: service, petId: petId, petName: "Maple")
        var draft = MedicationDraft.blank()
        draft.medicationName = "Antibiotics"
        draft.recurrenceType = .once
        _ = await store.create(draft)
        let schedule = store.schedules[0]
        let archived = await store.archive(schedule)
        XCTAssertTrue(archived)
        XCTAssertTrue(store.schedules.isEmpty)
    }

    func testSchemaCacheMissMentionsMedicationTables() {
        let raw = "Could not find the table 'public.medication_schedules' in the schema cache"
        XCTAssertTrue(CareError.looksLikeMissingSchema(raw))
    }
}

/// In-memory CareService double that can fail on demand.
@MainActor
private final class FailingCareService: CareService {
    var weightError: Error?
    var providerError: Error?
    var medicationError: Error?
    private var providers: [CareProvider]
    private let inner = InMemoryCareService()

    init(seededProviders: [CareProvider] = []) {
        self.providers = seededProviders
    }

    func loadWeights(petId: UUID) async throws -> [WeightMeasurement] {
        if let weightError { throw weightError }
        return try await inner.loadWeights(petId: petId)
    }

    func recordWeight(_ draft: WeightDraft, petId: UUID) async throws {
        if let weightError { throw weightError }
        try await inner.recordWeight(draft, petId: petId)
    }

    func editWeight(measurementId: UUID, expectedRevision: Int, draft: WeightDraft) async throws {
        if let weightError { throw weightError }
        try await inner.editWeight(measurementId: measurementId, expectedRevision: expectedRevision, draft: draft)
    }

    func removeWeight(measurementId: UUID) async throws {
        if let weightError { throw weightError }
        try await inner.removeWeight(measurementId: measurementId)
    }

    func loadProviders(householdId: UUID) async throws -> [CareProvider] {
        if let providerError { throw providerError }
        return providers
    }

    func createProvider(_ draft: ProviderDraft, householdId: UUID) async throws {
        if let providerError { throw providerError }
        try await inner.createProvider(draft, householdId: householdId)
    }

    func editProvider(providerId: UUID, expectedRevision: Int, draft: ProviderDraft) async throws {
        if let providerError { throw providerError }
        try await inner.editProvider(providerId: providerId, expectedRevision: expectedRevision, draft: draft)
    }

    func removeProvider(providerId: UUID) async throws {
        if let providerError { throw providerError }
        try await inner.removeProvider(providerId: providerId)
    }

    func loadMedicationSchedules(petId: UUID) async throws -> [MedicationSchedule] {
        if let medicationError { throw medicationError }
        return try await inner.loadMedicationSchedules(petId: petId)
    }

    func createMedicationSchedule(_ draft: MedicationDraft, petId: UUID) async throws {
        if let medicationError { throw medicationError }
        try await inner.createMedicationSchedule(draft, petId: petId)
    }

    func editMedicationSchedule(schedule: MedicationSchedule, draft: MedicationDraft) async throws {
        if let medicationError { throw medicationError }
        try await inner.editMedicationSchedule(schedule: schedule, draft: draft)
    }

    func archiveMedicationSchedule(_ schedule: MedicationSchedule) async throws {
        if let medicationError { throw medicationError }
        try await inner.archiveMedicationSchedule(schedule)
    }

    func completeMedicationOccurrence(
        occurrenceId: UUID,
        acknowledgedRecentCompletion: Bool
    ) async throws {
        if let medicationError { throw medicationError }
        try await inner.completeMedicationOccurrence(
            occurrenceId: occurrenceId,
            acknowledgedRecentCompletion: acknowledgedRecentCompletion
        )
    }
}
