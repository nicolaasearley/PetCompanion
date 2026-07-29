import Foundation

/// Reads and writes for care notes (F10 / US-077) including document photos.
///
/// Separate from `CareService` so Vaccinations / Grooming WIP stay isolated —
/// same pattern as `VaccinationService` / `GroomingService`.
@MainActor
protocol CareNoteService: AnyObject {
    func loadNotes(petId: UUID) async throws -> [CareNote]
    func createNote(_ draft: CareNoteDraft, petId: UUID) async throws -> UUID
    func editNote(
        noteId: UUID,
        expectedRevision: Int,
        draft: CareNoteDraft
    ) async throws
    func removeNote(noteId: UUID) async throws

    func prepareCareNoteMedia(
        noteId: UUID,
        mediaId: UUID,
        data: Data,
        mimeType: String,
        captureTime: Date?
    ) async throws -> CareNoteMediaUploadTarget

    func uploadCareNoteMedia(_ target: CareNoteMediaUploadTarget, data: Data) async throws
    func completeCareNoteMedia(mediaId: UUID, byteSize: Int) async throws
    func failCareNoteMedia(mediaId: UUID) async throws
    func removeCareNoteMedia(mediaId: UUID) async throws
    func downloadCareNoteMedia(_ media: CareNoteMedia) async throws -> Data
}

enum CareNoteServiceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}

/// In-memory implementation for mock builds and previews.
@MainActor
final class InMemoryCareNoteService: CareNoteService {
    private var notes: [UUID: CareNote] = [:]
    private var petOf: [UUID: UUID] = [:]
    private var removed: Set<UUID> = []
    private var blobs: [UUID: Data] = [:]
    private let actorName: String

    init(
        actorName: String = "You",
        seeded: [(petId: UUID, note: CareNote)] = []
    ) {
        self.actorName = actorName
        for entry in seeded {
            notes[entry.note.id] = entry.note
            petOf[entry.note.id] = entry.petId
        }
    }

    func seed(_ note: CareNote, petId: UUID) {
        notes[note.id] = note
        petOf[note.id] = petId
    }

    func loadNotes(petId: UUID) async throws -> [CareNote] {
        notes.values
            .filter { petOf[$0.id] == petId && !removed.contains($0.id) }
            .sorted {
                if $0.effectiveDate != $1.effectiveDate {
                    return $0.effectiveDate > $1.effectiveDate
                }
                return $0.body.localizedCaseInsensitiveCompare($1.body) == .orderedAscending
            }
    }

    func createNote(_ draft: CareNoteDraft, petId: UUID) async throws -> UUID {
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw CareNoteError.invalidEntry }
        if draft.kind == .document {
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw CareNoteError.invalidEntry }
        }
        let id = UUID()
        notes[id] = CareNote(
            id: id,
            kind: draft.kind,
            title: blankToNil(draft.title),
            body: body,
            effectiveDate: draft.effectiveDate,
            provenance: draft.provenance,
            providerId: draft.providerId,
            mediaRefs: [],
            media: [],
            revision: 1,
            recordedByName: actorName
        )
        petOf[id] = petId
        return id
    }

    func editNote(
        noteId: UUID,
        expectedRevision: Int,
        draft: CareNoteDraft
    ) async throws {
        guard let existing = notes[noteId], !removed.contains(noteId) else {
            throw CareNoteServiceError.unavailable("That note is no longer available.")
        }
        guard existing.revision == expectedRevision else {
            throw CareNoteError.changedElsewhere
        }
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw CareNoteError.invalidEntry }
        if existing.kind == .document {
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw CareNoteError.invalidEntry }
        }
        notes[noteId] = CareNote(
            id: existing.id,
            kind: existing.kind,
            title: blankToNil(draft.title),
            body: body,
            effectiveDate: draft.effectiveDate,
            provenance: draft.provenance,
            providerId: draft.providerId,
            mediaRefs: existing.mediaRefs,
            media: existing.media,
            revision: existing.revision + 1,
            recordedByName: existing.recordedByName
        )
    }

    func removeNote(noteId: UUID) async throws {
        removed.insert(noteId)
    }

    func prepareCareNoteMedia(
        noteId: UUID,
        mediaId: UUID,
        data: Data,
        mimeType: String,
        captureTime: Date?
    ) async throws -> CareNoteMediaUploadTarget {
        guard var note = notes[noteId], !removed.contains(noteId) else {
            throw CareNoteServiceError.unavailable("That note is no longer available.")
        }
        guard CareNoteAttachmentLimits.isAllowed(mimeType) else {
            throw CareNoteError.invalidEntry
        }
        guard data.count > 0, data.count <= CareNoteAttachmentLimits.maxBytes else {
            throw CareNoteError.invalidEntry
        }
        let media = CareNoteMedia(
            id: mediaId,
            storageBucket: "household-media",
            storagePath: "local/\(mediaId.uuidString)",
            mimeType: mimeType,
            byteSize: data.count,
            captureTime: captureTime,
            status: .pendingUpload
        )
        note = CareNote(
            id: note.id,
            kind: note.kind,
            title: note.title,
            body: note.body,
            effectiveDate: note.effectiveDate,
            provenance: note.provenance,
            providerId: note.providerId,
            mediaRefs: note.mediaRefs + [mediaId],
            media: note.media + [media],
            revision: note.revision + 1,
            recordedByName: note.recordedByName
        )
        notes[noteId] = note
        return CareNoteMediaUploadTarget(
            mediaId: mediaId,
            bucket: media.storageBucket,
            path: media.storagePath,
            upsert: true,
            mimeType: mimeType
        )
    }

    func uploadCareNoteMedia(_ target: CareNoteMediaUploadTarget, data: Data) async throws {
        blobs[target.mediaId] = data
    }

    func completeCareNoteMedia(mediaId: UUID, byteSize: Int) async throws {
        updateMediaStatus(mediaId: mediaId, status: .available, byteSize: byteSize)
    }

    func failCareNoteMedia(mediaId: UUID) async throws {
        updateMediaStatus(mediaId: mediaId, status: .uploadFailed, byteSize: nil)
    }

    func removeCareNoteMedia(mediaId: UUID) async throws {
        for (noteId, note) in notes {
            guard note.mediaRefs.contains(mediaId) else { continue }
            notes[noteId] = CareNote(
                id: note.id,
                kind: note.kind,
                title: note.title,
                body: note.body,
                effectiveDate: note.effectiveDate,
                provenance: note.provenance,
                providerId: note.providerId,
                mediaRefs: note.mediaRefs.filter { $0 != mediaId },
                media: note.media.filter { $0.id != mediaId },
                revision: note.revision + 1,
                recordedByName: note.recordedByName
            )
            blobs.removeValue(forKey: mediaId)
            return
        }
    }

    func downloadCareNoteMedia(_ media: CareNoteMedia) async throws -> Data {
        guard let data = blobs[media.id] else {
            throw CareNoteServiceError.unavailable("Photo isn’t available.")
        }
        return data
    }

    private func updateMediaStatus(mediaId: UUID, status: CareNoteMedia.Status, byteSize: Int?) {
        for (noteId, note) in notes {
            guard let index = note.media.firstIndex(where: { $0.id == mediaId }) else { continue }
            var media = note.media
            let existing = media[index]
            media[index] = CareNoteMedia(
                id: existing.id,
                storageBucket: existing.storageBucket,
                storagePath: existing.storagePath,
                mimeType: existing.mimeType,
                byteSize: byteSize ?? existing.byteSize,
                captureTime: existing.captureTime,
                status: status
            )
            notes[noteId] = CareNote(
                id: note.id,
                kind: note.kind,
                title: note.title,
                body: note.body,
                effectiveDate: note.effectiveDate,
                provenance: note.provenance,
                providerId: note.providerId,
                mediaRefs: note.mediaRefs,
                media: media,
                revision: note.revision,
                recordedByName: note.recordedByName
            )
            return
        }
    }

    private func blankToNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
