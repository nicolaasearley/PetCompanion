import Foundation
import Observation

/// State behind care notes (CA-01 / US-077) including optional document attachments.
///
/// Text always saves independently of attachment upload (Scenario H). Never
/// diagnoses from note text.
@MainActor
@Observable
final class CareNoteStore {
    private let service: any CareNoteService
    let calendar: Calendar

    private(set) var notes: [CareNote] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    var confirmationMessage: String?
    var queuedMessage: String?

    let petId: UUID
    let petName: String

    init(
        service: any CareNoteService,
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
            notes = try await service.loadNotes(petId: petId)
        } catch {
            errorMessage = CareNoteError.displayMessage(for: error)
        }
    }

    func create(_ draft: CareNoteDraft) async -> Bool {
        isSaving = true
        errorMessage = nil
        queuedMessage = nil
        confirmationMessage = nil
        defer { isSaving = false }

        let noteId: UUID
        do {
            noteId = try await service.createNote(draft, petId: petId)
        } catch OfflineMutationError.queued {
            queuedMessage = "Saved on this device. It'll appear once you're back online."
            return true
        } catch {
            errorMessage = CareNoteError.displayMessage(for: error)
            return false
        }

        let label = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmation = label.isEmpty ? "Saved note." : "Saved \(label)."

        if let attachment = draft.pendingAttachment {
            let attachOk = await attachMedia(noteId: noteId, attachment: attachment)
            await load()
            if attachOk {
                confirmationMessage = confirmation
            } else {
                errorMessage = CareNoteError.photoUploadFailed.errorDescription
            }
            return true
        }

        await load()
        confirmationMessage = confirmation
        return true
    }

    func edit(_ note: CareNote, draft: CareNoteDraft) async -> Bool {
        isSaving = true
        errorMessage = nil
        queuedMessage = nil
        confirmationMessage = nil
        defer { isSaving = false }

        do {
            try await service.editNote(
                noteId: note.id,
                expectedRevision: note.revision,
                draft: draft
            )
        } catch OfflineMutationError.queued {
            queuedMessage = "Saved on this device. The update will apply once you're back online."
            return true
        } catch {
            errorMessage = CareNoteError.displayMessage(for: error)
            return false
        }

        if let attachment = draft.pendingAttachment {
            let attachOk = await attachMedia(noteId: note.id, attachment: attachment)
            await load()
            if attachOk {
                confirmationMessage = "Updated."
            } else {
                errorMessage = CareNoteError.photoUploadFailed.errorDescription
            }
            return true
        }

        await load()
        confirmationMessage = "Updated."
        return true
    }

    func remove(_ note: CareNote) async -> Bool {
        await perform(
            confirmation: "Removed.",
            queuedNotice: "Saved on this device. It'll be removed once you're back online."
        ) {
            try await self.service.removeNote(noteId: note.id)
        }
    }

    func retryAttachment(_ media: CareNoteMedia, data: Data) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let target = CareNoteMediaUploadTarget(
                mediaId: media.id,
                bucket: media.storageBucket,
                path: media.storagePath,
                upsert: true,
                mimeType: media.mimeType
            )
            try await service.uploadCareNoteMedia(target, data: data)
            try await service.completeCareNoteMedia(mediaId: media.id, byteSize: data.count)
            await load()
            confirmationMessage = "Attachment added."
            return true
        } catch {
            _ = try? await service.failCareNoteMedia(mediaId: media.id)
            await load()
            errorMessage = CareNoteError.photoUploadFailed.errorDescription
            return false
        }
    }

    func removeAttachment(_ media: CareNoteMedia) async -> Bool {
        await perform(
            confirmation: "Attachment removed from this note. The copy on your device is unchanged.",
            queuedNotice: "Saved on this device. The attachment will be detached once you're back online."
        ) {
            try await self.service.removeCareNoteMedia(mediaId: media.id)
        }
    }

    /// Backward-compatible alias used by older call sites / tests.
    func removePhoto(_ media: CareNoteMedia) async -> Bool {
        await removeAttachment(media)
    }

    func loadAttachmentData(_ media: CareNoteMedia) async -> Data? {
        do {
            return try await service.downloadCareNoteMedia(media)
        } catch {
            return nil
        }
    }

    func loadPhotoData(_ media: CareNoteMedia) async -> Data? {
        await loadAttachmentData(media)
    }

    private func attachMedia(
        noteId: UUID,
        attachment: CareNotePendingAttachment
    ) async -> Bool {
        let mediaId = UUID()
        do {
            let target = try await service.prepareCareNoteMedia(
                noteId: noteId,
                mediaId: mediaId,
                data: attachment.data,
                mimeType: attachment.mimeType,
                captureTime: attachment.captureTime
            )
            try await service.uploadCareNoteMedia(target, data: attachment.data)
            try await service.completeCareNoteMedia(
                mediaId: target.mediaId,
                byteSize: attachment.data.count
            )
            return true
        } catch OfflineMutationError.queued {
            errorMessage = CareNoteError.photoUploadFailed.errorDescription
            return false
        } catch {
            _ = try? await service.failCareNoteMedia(mediaId: mediaId)
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
            errorMessage = CareNoteError.displayMessage(for: error)
            return false
        }
    }
}
