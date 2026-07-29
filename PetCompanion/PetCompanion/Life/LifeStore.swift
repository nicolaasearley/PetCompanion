import Foundation
import Observation

/// State behind LF-01 timeline and LF-03 milestone editor (text + photo attach).
@MainActor
@Observable
final class LifeStore {
    private let service: any LifeService
    private let calendar: Calendar

    private(set) var milestones: [Milestone] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    var confirmationMessage: String?
    /// Distinct from confirmation — durable queue acceptance, not server save.
    var queuedMessage: String?

    let petId: UUID
    let petName: String

    init(
        service: any LifeService,
        petId: UUID,
        petName: String,
        calendar: Calendar = .current
    ) {
        self.service = service
        self.petId = petId
        self.petName = petName
        self.calendar = calendar
    }

    /// Reverse-chronological month groups for LF-01.
    var timelineSections: [LifeTimelineSection] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")

        var sections: [LifeTimelineSection] = []
        var currentKey: String?
        var currentTitle: String?
        var currentItems: [Milestone] = []

        for milestone in milestones {
            let comps = calendar.dateComponents([.year, .month], from: milestone.effectiveDate)
            let key = "\(comps.year ?? 0)-\(comps.month ?? 0)"
            let title = formatter.string(from: milestone.effectiveDate)
            if key != currentKey {
                if let currentTitle, !currentItems.isEmpty {
                    sections.append(LifeTimelineSection(id: currentKey ?? currentTitle, title: currentTitle, milestones: currentItems))
                }
                currentKey = key
                currentTitle = title
                currentItems = [milestone]
            } else {
                currentItems.append(milestone)
            }
        }
        if let currentTitle, let currentKey, !currentItems.isEmpty {
            sections.append(LifeTimelineSection(id: currentKey, title: currentTitle, milestones: currentItems))
        }
        return sections
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            milestones = try await service.loadMilestones(petId: petId)
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func create(_ draft: MilestoneDraft) async -> Bool {
        isSaving = true
        errorMessage = nil
        queuedMessage = nil
        confirmationMessage = nil
        defer { isSaving = false }

        let milestoneId: UUID
        do {
            milestoneId = try await service.createMilestone(draft, petId: petId)
        } catch OfflineMutationError.queued {
            queuedMessage = "Saved on this device. It'll appear in \(petName)'s story once you're back online."
            return true
        } catch {
            errorMessage = displayMessage(for: error)
            return false
        }

        if let photo = draft.photoJPEGData {
            let photoOk = await attachPhoto(
                milestoneId: milestoneId,
                jpegData: photo,
                captureTime: draft.photoCaptureTime
            )
            await load()
            if photoOk {
                confirmationMessage = "Saved to \(petName)'s story."
            } else {
                // Scenario H: text already saved; keep a calm retryable notice.
                errorMessage = LifeError.photoUploadFailed.errorDescription
            }
            return true
        }

        await load()
        confirmationMessage = "Saved to \(petName)'s story."
        return true
    }

    func edit(_ milestone: Milestone, draft: MilestoneDraft) async -> Bool {
        isSaving = true
        errorMessage = nil
        queuedMessage = nil
        confirmationMessage = nil
        defer { isSaving = false }

        do {
            try await service.editMilestone(
                milestoneId: milestone.id,
                expectedRevision: milestone.revision,
                draft: draft
            )
        } catch OfflineMutationError.queued {
            queuedMessage = "Saved on this device. The update will apply once you're back online."
            return true
        } catch {
            errorMessage = displayMessage(for: error)
            return false
        }

        if let photo = draft.photoJPEGData {
            let photoOk = await attachPhoto(
                milestoneId: milestone.id,
                jpegData: photo,
                captureTime: draft.photoCaptureTime
            )
            await load()
            if photoOk {
                confirmationMessage = "Updated."
            } else {
                errorMessage = LifeError.photoUploadFailed.errorDescription
            }
            return true
        }

        await load()
        confirmationMessage = "Updated."
        return true
    }

    func remove(_ milestone: Milestone) async -> Bool {
        await perform(
            confirmation: "Removed from the timeline.",
            queuedNotice: "Saved on this device. It'll be removed once you're back online."
        ) {
            try await self.service.removeMilestone(milestoneId: milestone.id)
        }
    }

    func retryPhoto(_ media: MilestoneMedia, jpegData: Data) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let target = MilestoneMediaUploadTarget(
                mediaId: media.id,
                bucket: media.storageBucket,
                path: media.storagePath,
                upsert: true,
                mimeType: "image/jpeg"
            )
            try await service.uploadMilestoneMedia(target, data: jpegData)
            try await service.completeMilestoneMedia(mediaId: media.id, byteSize: jpegData.count)
            await load()
            confirmationMessage = "Photo added."
            return true
        } catch {
            _ = try? await service.failMilestoneMedia(mediaId: media.id)
            await load()
            errorMessage = LifeError.photoUploadFailed.errorDescription
            return false
        }
    }

    func removePhoto(_ media: MilestoneMedia) async -> Bool {
        await perform(
            confirmation: "Photo removed from this memory. The copy on your device is unchanged.",
            queuedNotice: "Saved on this device. The photo will be detached once you're back online."
        ) {
            try await self.service.removeMilestoneMedia(mediaId: media.id)
        }
    }

    func loadPhotoData(_ media: MilestoneMedia) async -> Data? {
        do {
            return try await service.downloadMilestoneMedia(media)
        } catch {
            return nil
        }
    }

    private func attachPhoto(
        milestoneId: UUID,
        jpegData: Data,
        captureTime: Date?
    ) async -> Bool {
        let mediaId = UUID()
        do {
            let target = try await service.prepareMilestoneMedia(
                milestoneId: milestoneId,
                mediaId: mediaId,
                jpegData: jpegData,
                captureTime: captureTime
            )
            try await service.uploadMilestoneMedia(target, data: jpegData)
            try await service.completeMilestoneMedia(mediaId: target.mediaId, byteSize: jpegData.count)
            return true
        } catch OfflineMutationError.queued {
            // prepare/upload are online-only; treat as photo failure, text remains.
            errorMessage = LifeError.photoUploadFailed.errorDescription
            return false
        } catch {
            _ = try? await service.failMilestoneMedia(mediaId: mediaId)
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
        LifeError.displayMessage(for: error)
    }
}

struct LifeTimelineSection: Identifiable, Hashable {
    let id: String
    let title: String
    let milestones: [Milestone]
}
