import Foundation
import Observation

/// State behind grooming history (CA-01 / US-076).
///
/// Next-due is display of an owner-entered fact; this store never computes a
/// schedule or clinical cadence.
@MainActor
@Observable
final class GroomingStore {
    private let service: any GroomingService
    let calendar: Calendar

    private(set) var records: [GroomingRecord] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    var confirmationMessage: String?
    var queuedMessage: String?

    let petId: UUID
    let petName: String

    init(
        service: any GroomingService,
        petId: UUID,
        petName: String,
        calendar: Calendar = .current
    ) {
        self.service = service
        self.petId = petId
        self.petName = petName
        self.calendar = calendar
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            records = try await service.loadGrooming(petId: petId)
        } catch {
            errorMessage = GroomingError.displayMessage(for: error)
        }
    }

    func record(_ draft: GroomingDraft) async -> Bool {
        await perform(
            confirmation: "Saved \(draft.activityType.displayName.lowercased()).",
            queuedNotice: "Saved on this device. It'll appear once you're back online."
        ) {
            try await self.service.recordGrooming(draft, petId: self.petId)
        }
    }

    func edit(_ record: GroomingRecord, draft: GroomingDraft) async -> Bool {
        await perform(
            confirmation: "Updated.",
            queuedNotice: "Saved on this device. The update will apply once you're back online."
        ) {
            try await self.service.editGrooming(
                groomingId: record.id,
                expectedRevision: record.revision,
                draft: draft
            )
        }
    }

    func remove(_ record: GroomingRecord) async -> Bool {
        await perform(
            confirmation: "Removed.",
            queuedNotice: "Saved on this device. It'll be removed once you're back online."
        ) {
            try await self.service.removeGrooming(groomingId: record.id)
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
            errorMessage = GroomingError.displayMessage(for: error)
            return false
        }
    }
}
