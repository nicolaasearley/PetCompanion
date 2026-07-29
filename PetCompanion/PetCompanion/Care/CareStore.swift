import Foundation
import Observation

/// State behind CA-08 weight & growth.
@MainActor
@Observable
final class WeightStore {
    private let service: any CareService

    private(set) var measurements: [WeightMeasurement] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    var confirmationMessage: String?
    var queuedMessage: String?
    /// Display-only unit toggle (US-075). Never mutates stored values.
    private(set) var displayUnit: WeightUnit = .kg
    /// Once the caregiver picks a display unit, reloads must not clobber it
    /// with the latest entry’s unit (including an explicit kg choice).
    private var hasChosenDisplayUnit = false

    let petId: UUID
    let petName: String

    init(service: any CareService, petId: UUID, petName: String) {
        self.service = service
        self.petId = petId
        self.petName = petName
    }

    func setDisplayUnit(_ unit: WeightUnit) {
        displayUnit = unit
        hasChosenDisplayUnit = true
    }

    /// Soft outlier check vs the previous entry — review prompt only, never a
    /// health finding (CA-08 / US-075).
    func outlierPrompt(for draft: WeightDraft) -> String? {
        guard let next = CareCoding.decimal(from: draft.valueText), next > 0 else { return nil }
        guard let previous = measurements.first else { return nil }
        let previousInDraftUnit = previous.unit.convert(previous.value, to: draft.unit)
        guard previousInDraftUnit > 0 else { return nil }
        let ratio = next / previousInDraftUnit
        if ratio >= 8 || ratio <= Decimal(string: "0.125")! {
            let from = "\(WeightMeasurement.format(previousInDraftUnit)) \(draft.unit.displayName)"
            let to = "\(WeightMeasurement.format(next)) \(draft.unit.displayName)"
            return "\(from) → \(to) — is that right?"
        }
        return nil
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            measurements = try await service.loadWeights(petId: petId)
            if !hasChosenDisplayUnit, let latest = measurements.first {
                displayUnit = latest.unit
            }
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func record(_ draft: WeightDraft) async -> Bool {
        await perform(
            confirmation: "Saved \(petName)'s weight.",
            queuedNotice: "Saved on this device. It'll appear once you're back online."
        ) {
            try await self.service.recordWeight(draft, petId: self.petId)
        }
    }

    func edit(_ measurement: WeightMeasurement, draft: WeightDraft) async -> Bool {
        await perform(
            confirmation: "Updated.",
            queuedNotice: "Saved on this device. The update will apply once you're back online."
        ) {
            try await self.service.editWeight(
                measurementId: measurement.id,
                expectedRevision: measurement.revision,
                draft: draft
            )
        }
    }

    func remove(_ measurement: WeightMeasurement) async -> Bool {
        await perform(
            confirmation: "Removed.",
            queuedNotice: "Saved on this device. It'll be removed once you're back online."
        ) {
            try await self.service.removeWeight(measurementId: measurement.id)
        }
    }

    private func perform(
        confirmation: String,
        queuedNotice: String,
        _ work: @escaping () async throws -> Void
    ) async -> Bool {
        isSaving = true
        errorMessage = nil
        queuedMessage = nil
        confirmationMessage = nil
        defer { isSaving = false }
        do {
            try await work()
            await load()
            errorMessage = nil
            confirmationMessage = confirmation
            return true
        } catch OfflineMutationError.queued {
            queuedMessage = queuedNotice
            return true
        } catch {
            errorMessage = displayMessage(for: error)
            return false
        }
    }

    private func displayMessage(for error: Error) -> String {
        CareError.displayMessage(for: error)
    }
}

/// State behind CA-09 providers.
@MainActor
@Observable
final class ProvidersStore {
    private let service: any CareService

    private(set) var providers: [CareProvider] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    var confirmationMessage: String?
    var queuedMessage: String?

    let householdId: UUID

    init(service: any CareService, householdId: UUID) {
        self.service = service
        self.householdId = householdId
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            providers = try await service.loadProviders(householdId: householdId)
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func create(_ draft: ProviderDraft) async -> Bool {
        await perform(
            confirmation: "Provider saved.",
            queuedNotice: "Saved on this device. It'll appear once you're back online."
        ) {
            try await self.service.createProvider(draft, householdId: self.householdId)
        }
    }

    func edit(_ provider: CareProvider, draft: ProviderDraft) async -> Bool {
        await perform(
            confirmation: "Updated.",
            queuedNotice: "Saved on this device. The update will apply once you're back online."
        ) {
            try await self.service.editProvider(
                providerId: provider.id,
                expectedRevision: provider.revision,
                draft: draft
            )
        }
    }

    func remove(_ provider: CareProvider) async -> Bool {
        await perform(
            confirmation: "Removed.",
            queuedNotice: "Saved on this device. It'll be removed once you're back online."
        ) {
            try await self.service.removeProvider(providerId: provider.id)
        }
    }

    private func perform(
        confirmation: String,
        queuedNotice: String,
        _ work: @escaping () async throws -> Void
    ) async -> Bool {
        isSaving = true
        errorMessage = nil
        queuedMessage = nil
        confirmationMessage = nil
        defer { isSaving = false }
        do {
            try await work()
            await load()
            errorMessage = nil
            confirmationMessage = confirmation
            return true
        } catch OfflineMutationError.queued {
            queuedMessage = queuedNotice
            return true
        } catch {
            errorMessage = displayMessage(for: error)
            return false
        }
    }

    private func displayMessage(for error: Error) -> String {
        CareError.displayMessage(for: error)
    }
}

/// State behind CA-06 / CA-07 medication schedules.
@MainActor
@Observable
final class MedicationsStore {
    private let service: any CareService

    private(set) var schedules: [MedicationSchedule] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    var confirmationMessage: String?
    var queuedMessage: String?
    /// Set when complete needs an extra confirm after a recent partner dose.
    var recentCompletionNotice: String?

    let petId: UUID
    let petName: String
    let calendar: Calendar
    let currentUserId: UUID?

    init(
        service: any CareService,
        petId: UUID,
        petName: String,
        calendar: Calendar = .current,
        currentUserId: UUID? = nil
    ) {
        self.service = service
        self.petId = petId
        self.petName = petName
        self.calendar = calendar
        self.currentUserId = currentUserId
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            schedules = try await service.loadMedicationSchedules(petId: petId)
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func create(_ draft: MedicationDraft) async -> Bool {
        await perform(
            confirmation: "Saved \(draft.medicationName.trimmingCharacters(in: .whitespacesAndNewlines)).",
            queuedNotice: "Saved on this device. It'll appear once you're back online."
        ) {
            try await self.service.createMedicationSchedule(draft, petId: self.petId)
        }
    }

    func edit(_ schedule: MedicationSchedule, draft: MedicationDraft) async -> Bool {
        await perform(
            confirmation: "Updated.",
            queuedNotice: "Saved on this device. The update will apply once you're back online."
        ) {
            try await self.service.editMedicationSchedule(schedule: schedule, draft: draft)
        }
    }

    func archive(_ schedule: MedicationSchedule) async -> Bool {
        await perform(
            confirmation: "Archived. Future reminders stop; history is kept.",
            queuedNotice: "Saved on this device. It'll archive once you're back online."
        ) {
            try await self.service.archiveMedicationSchedule(schedule)
        }
    }

    /// Returns true on success. On recent-partner confirmation needed, sets
    /// `recentCompletionNotice` and returns false without a generic error.
    func complete(
        _ schedule: MedicationSchedule,
        acknowledgedRecentCompletion: Bool
    ) async -> Bool {
        guard schedule.nextDue?.occurrenceId != nil else {
            errorMessage = CareError.invalidEntry.errorDescription
            return false
        }
        isSaving = true
        errorMessage = nil
        queuedMessage = nil
        confirmationMessage = nil
        if !acknowledgedRecentCompletion {
            recentCompletionNotice = nil
        }
        defer { isSaving = false }
        do {
            try await service.completeMedicationOccurrence(
                occurrenceId: schedule.nextDue!.occurrenceId,
                acknowledgedRecentCompletion: acknowledgedRecentCompletion
            )
            await load()
            recentCompletionNotice = nil
            confirmationMessage = "Recorded for \(petName)."
            return true
        } catch OfflineMutationError.queued {
            queuedMessage = "Saved on this device. It'll sync once you're back online."
            recentCompletionNotice = nil
            return true
        } catch let error as CareError {
            if case .recentCompletionNeedsConfirm(let message) = error {
                recentCompletionNotice = message
                return false
            }
            errorMessage = displayMessage(for: error)
            return false
        } catch {
            errorMessage = displayMessage(for: error)
            return false
        }
    }

    private func perform(
        confirmation: String,
        queuedNotice: String,
        _ work: @escaping () async throws -> Void
    ) async -> Bool {
        isSaving = true
        errorMessage = nil
        queuedMessage = nil
        confirmationMessage = nil
        defer { isSaving = false }
        do {
            try await work()
            await load()
            errorMessage = nil
            confirmationMessage = confirmation
            return true
        } catch OfflineMutationError.queued {
            queuedMessage = queuedNotice
            return true
        } catch {
            errorMessage = displayMessage(for: error)
            return false
        }
    }

    private func displayMessage(for error: Error) -> String {
        CareError.displayMessage(for: error)
    }
}
