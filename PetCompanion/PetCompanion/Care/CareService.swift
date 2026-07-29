import Foundation

/// Reads and writes for Care weight, providers, and medications (F10).
///
/// Reads go to RLS-protected tables; mutations go through the write-path edge
/// function. Dose text is never computed or normalized.
@MainActor
protocol CareService: AnyObject {
    func loadWeights(petId: UUID) async throws -> [WeightMeasurement]
    func recordWeight(_ draft: WeightDraft, petId: UUID) async throws
    func editWeight(
        measurementId: UUID,
        expectedRevision: Int,
        draft: WeightDraft
    ) async throws
    func removeWeight(measurementId: UUID) async throws

    func loadProviders(householdId: UUID) async throws -> [CareProvider]
    func createProvider(_ draft: ProviderDraft, householdId: UUID) async throws
    func editProvider(
        providerId: UUID,
        expectedRevision: Int,
        draft: ProviderDraft
    ) async throws
    func removeProvider(providerId: UUID) async throws

    func loadMedicationSchedules(petId: UUID) async throws -> [MedicationSchedule]
    func createMedicationSchedule(_ draft: MedicationDraft, petId: UUID) async throws
    func editMedicationSchedule(
        schedule: MedicationSchedule,
        draft: MedicationDraft
    ) async throws
    func archiveMedicationSchedule(_ schedule: MedicationSchedule) async throws
    func completeMedicationOccurrence(
        occurrenceId: UUID,
        acknowledgedRecentCompletion: Bool
    ) async throws
}

enum CareServiceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}

/// In-memory Care service for mock builds and previews.
@MainActor
final class InMemoryCareService: CareService {
    private var weights: [UUID: WeightMeasurement] = [:]
    private var weightPet: [UUID: UUID] = [:]
    private var removedWeights: Set<UUID> = []
    private var providers: [UUID: CareProvider] = [:]
    private var providerHousehold: [UUID: UUID] = [:]
    private var removedProviders: Set<UUID> = []
    private var medications: [UUID: MedicationSchedule] = [:]
    private var medicationPet: [UUID: UUID] = [:]
    let actorUserId: UUID
    private let actorName: String
    /// When set, the next complete call without acknowledgement throws
    /// `CareError.recentCompletionNeedsConfirm`.
    var pendingRecentPartnerCompletion: MedicationLastCompletion?

    init(
        actorName: String = "You",
        actorUserId: UUID = UUID(),
        seededWeights: [(petId: UUID, measurement: WeightMeasurement)] = [],
        seededProviders: [(householdId: UUID, provider: CareProvider)] = [],
        seededMedications: [(petId: UUID, schedule: MedicationSchedule)] = []
    ) {
        self.actorName = actorName
        self.actorUserId = actorUserId
        for entry in seededWeights {
            weights[entry.measurement.id] = entry.measurement
            weightPet[entry.measurement.id] = entry.petId
        }
        for entry in seededProviders {
            providers[entry.provider.id] = entry.provider
            providerHousehold[entry.provider.id] = entry.householdId
        }
        for entry in seededMedications {
            medications[entry.schedule.id] = entry.schedule
            medicationPet[entry.schedule.id] = entry.petId
        }
    }

    func seedWeight(_ measurement: WeightMeasurement, petId: UUID) {
        weights[measurement.id] = measurement
        weightPet[measurement.id] = petId
    }

    func seedProvider(_ provider: CareProvider, householdId: UUID) {
        providers[provider.id] = provider
        providerHousehold[provider.id] = householdId
    }

    func seedMedication(_ schedule: MedicationSchedule, petId: UUID) {
        medications[schedule.id] = schedule
        medicationPet[schedule.id] = petId
    }

    func loadWeights(petId: UUID) async throws -> [WeightMeasurement] {
        weights.values
            .filter { weightPet[$0.id] == petId && !removedWeights.contains($0.id) }
            .sorted {
                if $0.effectiveDate != $1.effectiveDate {
                    return $0.effectiveDate > $1.effectiveDate
                }
                return $0.id.uuidString > $1.id.uuidString
            }
    }

    func recordWeight(_ draft: WeightDraft, petId: UUID) async throws {
        guard let value = CareCoding.decimal(from: draft.valueText), value > 0 else {
            throw CareError.invalidEntry
        }
        let id = UUID()
        let measurement = WeightMeasurement(
            id: id,
            value: value,
            unit: draft.unit,
            effectiveDate: draft.effectiveDate,
            note: draft.note.isEmpty ? nil : draft.note,
            revision: 1,
            recordedByName: actorName
        )
        weights[id] = measurement
        weightPet[id] = petId
    }

    func editWeight(
        measurementId: UUID,
        expectedRevision: Int,
        draft: WeightDraft
    ) async throws {
        guard let existing = weights[measurementId], !removedWeights.contains(measurementId) else {
            throw CareServiceError.unavailable("That weight entry is no longer available.")
        }
        guard existing.revision == expectedRevision else {
            throw CareError.changedElsewhere
        }
        guard let value = CareCoding.decimal(from: draft.valueText), value > 0 else {
            throw CareError.invalidEntry
        }
        weights[measurementId] = WeightMeasurement(
            id: existing.id,
            value: value,
            unit: draft.unit,
            effectiveDate: draft.effectiveDate,
            note: draft.note.isEmpty ? nil : draft.note,
            revision: existing.revision + 1,
            recordedByName: existing.recordedByName
        )
    }

    func removeWeight(measurementId: UUID) async throws {
        removedWeights.insert(measurementId)
    }

    func loadProviders(householdId: UUID) async throws -> [CareProvider] {
        providers.values
            .filter { providerHousehold[$0.id] == householdId && !removedProviders.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func createProvider(_ draft: ProviderDraft, householdId: UUID) async throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CareError.invalidEntry }
        let id = UUID()
        providers[id] = CareProvider(
            id: id,
            name: name,
            kind: draft.kind,
            phone: blankToNil(draft.phone),
            address: blankToNil(draft.address),
            notes: blankToNil(draft.notes),
            revision: 1
        )
        providerHousehold[id] = householdId
    }

    func editProvider(
        providerId: UUID,
        expectedRevision: Int,
        draft: ProviderDraft
    ) async throws {
        guard let existing = providers[providerId], !removedProviders.contains(providerId) else {
            throw CareServiceError.unavailable("That provider is no longer available.")
        }
        guard existing.revision == expectedRevision else {
            throw CareError.changedElsewhere
        }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CareError.invalidEntry }
        providers[providerId] = CareProvider(
            id: existing.id,
            name: name,
            kind: draft.kind,
            phone: blankToNil(draft.phone),
            address: blankToNil(draft.address),
            notes: blankToNil(draft.notes),
            revision: existing.revision + 1
        )
    }

    func removeProvider(providerId: UUID) async throws {
        removedProviders.insert(providerId)
    }

    func loadMedicationSchedules(petId: UUID) async throws -> [MedicationSchedule] {
        medications.values
            .filter {
                medicationPet[$0.id] == petId
                    && $0.status == .active
            }
            .sorted {
                $0.medicationName.localizedCaseInsensitiveCompare($1.medicationName) == .orderedAscending
            }
    }

    func createMedicationSchedule(_ draft: MedicationDraft, petId: UUID) async throws {
        guard let recurrence = draft.validatedRecurrence() else {
            throw CareError.invalidEntry
        }
        let name = draft.medicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        let occurrenceId = UUID()
        let schedule = MedicationSchedule(
            id: id,
            petId: petId,
            medicationName: name,
            doseText: blankToNil(draft.doseText),
            instructionsText: blankToNil(draft.instructionsText),
            provenance: draft.provenance,
            providerId: nil,
            recurrence: recurrence,
            status: .active,
            taskScheduleId: UUID(),
            revision: 1,
            nextDue: MedicationNextDue(
                occurrenceId: occurrenceId,
                localDueDate: recurrence.anchorDate,
                originalLocalDueDate: recurrence.anchorDate,
                timePolicy: recurrence.timePolicy,
                dueTime: recurrence.exactTime,
                windowRef: recurrence.windowRef,
                occurrenceRevision: 1
            ),
            lastCompletion: nil,
            changeHistory: [
                MedicationChangeEntry(
                    id: UUID(),
                    occurredAt: Date(),
                    action: "care.medication_schedule_created",
                    actorName: actorName,
                    summaryLabel: "Created"
                ),
            ],
            createdByName: actorName
        )
        medications[id] = schedule
        medicationPet[id] = petId
    }

    func editMedicationSchedule(
        schedule: MedicationSchedule,
        draft: MedicationDraft
    ) async throws {
        guard var existing = medications[schedule.id], existing.status == .active else {
            throw CareServiceError.unavailable("That medication schedule is no longer available.")
        }
        guard existing.revision == schedule.revision else {
            throw CareError.changedElsewhere
        }
        guard let recurrence = draft.validatedRecurrence() else {
            throw CareError.invalidEntry
        }
        let name = draft.medicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        existing = MedicationSchedule(
            id: existing.id,
            petId: existing.petId,
            medicationName: name,
            doseText: blankToNil(draft.doseText),
            instructionsText: blankToNil(draft.instructionsText),
            provenance: draft.provenance,
            providerId: existing.providerId,
            recurrence: recurrence,
            status: .active,
            taskScheduleId: existing.taskScheduleId,
            revision: existing.revision + 1,
            nextDue: MedicationNextDue(
                occurrenceId: existing.nextDue?.occurrenceId ?? UUID(),
                localDueDate: recurrence.anchorDate,
                originalLocalDueDate: recurrence.anchorDate,
                timePolicy: recurrence.timePolicy,
                dueTime: recurrence.exactTime,
                windowRef: recurrence.windowRef,
                occurrenceRevision: (existing.nextDue?.occurrenceRevision ?? 0) + 1
            ),
            lastCompletion: existing.lastCompletion,
            changeHistory: existing.changeHistory + [
                MedicationChangeEntry(
                    id: UUID(),
                    occurredAt: Date(),
                    action: "care.medication_schedule_edited",
                    actorName: actorName,
                    summaryLabel: "Updated"
                ),
            ],
            createdByName: existing.createdByName
        )
        medications[schedule.id] = existing
    }

    func archiveMedicationSchedule(_ schedule: MedicationSchedule) async throws {
        guard let existing = medications[schedule.id] else {
            throw CareServiceError.unavailable("That medication schedule is no longer available.")
        }
        guard existing.revision == schedule.revision else {
            throw CareError.changedElsewhere
        }
        medications[schedule.id] = MedicationSchedule(
            id: existing.id,
            petId: existing.petId,
            medicationName: existing.medicationName,
            doseText: existing.doseText,
            instructionsText: existing.instructionsText,
            provenance: existing.provenance,
            providerId: existing.providerId,
            recurrence: existing.recurrence,
            status: .archived,
            taskScheduleId: existing.taskScheduleId,
            revision: existing.revision + 1,
            nextDue: nil,
            lastCompletion: existing.lastCompletion,
            changeHistory: existing.changeHistory + [
                MedicationChangeEntry(
                    id: UUID(),
                    occurredAt: Date(),
                    action: "care.medication_schedule_archived",
                    actorName: actorName,
                    summaryLabel: "Archived"
                ),
            ],
            createdByName: existing.createdByName
        )
    }

    func completeMedicationOccurrence(
        occurrenceId: UUID,
        acknowledgedRecentCompletion: Bool
    ) async throws {
        guard let entry = medications.first(where: { $0.value.nextDue?.occurrenceId == occurrenceId })
        else {
            throw CareServiceError.unavailable("That dose is no longer available.")
        }
        if let pending = pendingRecentPartnerCompletion, !acknowledgedRecentCompletion {
            throw CareError.recentCompletionNeedsConfirm(
                message: pending.attribution + ". Confirm before recording again."
            )
        }
        pendingRecentPartnerCompletion = nil
        let existing = entry.value
        let completion = MedicationLastCompletion(
            effectiveAt: Date(),
            actorUserId: actorUserId,
            actorName: actorName,
            completedDueDate: existing.nextDue?.localDueDate
        )
        let nextDate: Date = {
            switch existing.recurrence.type {
            case .intervalAfterCompletion, .everyNDays:
                let days = existing.recurrence.interval ?? 1
                return Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
            case .once:
                return existing.recurrence.anchorDate
            case .daily:
                return Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            case .weekly:
                return Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
            }
        }()
        let nextDue: MedicationNextDue? = existing.recurrence.type == .once
            ? nil
            : MedicationNextDue(
                occurrenceId: UUID(),
                localDueDate: nextDate,
                originalLocalDueDate: nextDate,
                timePolicy: existing.recurrence.timePolicy,
                dueTime: existing.recurrence.exactTime,
                windowRef: existing.recurrence.windowRef,
                occurrenceRevision: 1
            )
        medications[existing.id] = MedicationSchedule(
            id: existing.id,
            petId: existing.petId,
            medicationName: existing.medicationName,
            doseText: existing.doseText,
            instructionsText: existing.instructionsText,
            provenance: existing.provenance,
            providerId: existing.providerId,
            recurrence: existing.recurrence,
            status: .active,
            taskScheduleId: existing.taskScheduleId,
            revision: existing.revision,
            nextDue: nextDue,
            lastCompletion: completion,
            changeHistory: existing.changeHistory,
            createdByName: existing.createdByName
        )
    }

    private func blankToNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
