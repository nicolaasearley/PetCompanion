import Foundation
import Observation

/// State behind vaccination history (CA-01 / US-070).
///
/// Soft duplicate notice only — never auto-merges. Next-due is display of an
/// owner-entered fact; this store never computes a schedule.
@MainActor
@Observable
final class VaccinationStore {
    /// Same vaccine name within this many days surfaces a review prompt (US-070).
    static let duplicateWindowDays = 14

    private let service: any VaccinationService
    let calendar: Calendar

    private(set) var records: [VaccinationRecord] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    var confirmationMessage: String?
    var queuedMessage: String?

    let petId: UUID
    let petName: String

    init(
        service: any VaccinationService,
        petId: UUID,
        petName: String,
        calendar: Calendar = .current
    ) {
        self.service = service
        self.petId = petId
        self.petName = petName
        self.calendar = calendar
    }

    /// Soft duplicate check for review — never blocks or auto-merges (US-070).
    func duplicatePrompt(for draft: VaccinationDraft, excluding id: UUID? = nil) -> String? {
        let name = draft.vaccineName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let match = records.first { record in
            if let id, record.id == id { return false }
            guard record.vaccineName.caseInsensitiveCompare(name) == .orderedSame else {
                return false
            }
            let days = abs(
                calendar.dateComponents([.day], from: record.effectiveDate, to: draft.effectiveDate).day
                    ?? Int.max
            )
            return days <= Self.duplicateWindowDays
        }
        guard let match else { return nil }
        let when = CareCoding.displayDate(match.effectiveDate, calendar: calendar)
        return "You already have \(match.vaccineName) recorded on \(when). Save anyway?"
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            records = try await service.loadVaccinations(petId: petId)
        } catch {
            errorMessage = VaccinationError.displayMessage(for: error)
        }
    }

    func record(_ draft: VaccinationDraft) async -> Bool {
        await perform(
            confirmation: "Saved \(draft.vaccineName.trimmingCharacters(in: .whitespacesAndNewlines)).",
            queuedNotice: "Saved on this device. It'll appear once you're back online."
        ) {
            try await self.service.recordVaccination(draft, petId: self.petId)
        }
    }

    func edit(_ record: VaccinationRecord, draft: VaccinationDraft) async -> Bool {
        await perform(
            confirmation: "Updated.",
            queuedNotice: "Saved on this device. The update will apply once you're back online."
        ) {
            try await self.service.editVaccination(
                vaccinationId: record.id,
                expectedRevision: record.revision,
                draft: draft
            )
        }
    }

    func remove(_ record: VaccinationRecord) async -> Bool {
        await perform(
            confirmation: "Removed.",
            queuedNotice: "Saved on this device. It'll be removed once you're back online."
        ) {
            try await self.service.removeVaccination(vaccinationId: record.id)
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
            errorMessage = VaccinationError.displayMessage(for: error)
            return false
        }
    }
}
