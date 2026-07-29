import Foundation

/// Reads and writes for Life milestones (F12) including household-private photos.
///
/// Reads go to the RLS-protected `milestones` / `media` tables; mutations go
/// through the write-path edge function. Photo bytes upload to Storage only
/// after `prepare_milestone_media` mints an authorized path.
@MainActor
protocol LifeService: AnyObject {
    func loadMilestones(petId: UUID) async throws -> [Milestone]
    func createMilestone(_ draft: MilestoneDraft, petId: UUID) async throws -> UUID
    func editMilestone(
        milestoneId: UUID,
        expectedRevision: Int,
        draft: MilestoneDraft
    ) async throws
    func removeMilestone(milestoneId: UUID) async throws

    func prepareMilestoneMedia(
        milestoneId: UUID,
        mediaId: UUID,
        jpegData: Data,
        captureTime: Date?
    ) async throws -> MilestoneMediaUploadTarget

    func uploadMilestoneMedia(_ target: MilestoneMediaUploadTarget, data: Data) async throws

    func completeMilestoneMedia(mediaId: UUID, byteSize: Int) async throws
    func failMilestoneMedia(mediaId: UUID) async throws
    func removeMilestoneMedia(mediaId: UUID) async throws
    func downloadMilestoneMedia(_ media: MilestoneMedia) async throws -> Data
}

enum LifeServiceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}

/// In-memory Life service for mock builds and previews.
@MainActor
final class InMemoryLifeService: LifeService {
    private var milestones: [UUID: Milestone] = [:]
    private var milestonePet: [UUID: UUID] = [:]
    private var removed: Set<UUID> = []
    private var blobs: [UUID: Data] = [:]
    private let actorName: String

    init(
        actorName: String = "You",
        seeded: [(petId: UUID, milestone: Milestone)] = []
    ) {
        self.actorName = actorName
        for entry in seeded {
            milestones[entry.milestone.id] = entry.milestone
            milestonePet[entry.milestone.id] = entry.petId
        }
    }

    func seed(_ milestone: Milestone, petId: UUID) {
        milestones[milestone.id] = milestone
        milestonePet[milestone.id] = petId
        removed.remove(milestone.id)
    }

    func loadMilestones(petId: UUID) async throws -> [Milestone] {
        milestones.values
            .filter { milestonePet[$0.id] == petId && !removed.contains($0.id) }
            .sorted {
                if $0.effectiveDate != $1.effectiveDate {
                    return $0.effectiveDate > $1.effectiveDate
                }
                return $0.id.uuidString > $1.id.uuidString
            }
    }

    func createMilestone(_ draft: MilestoneDraft, petId: UUID) async throws -> UUID {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LifeError.invalidEntry }
        let id = UUID()
        milestones[id] = Milestone(
            id: id,
            title: title,
            effectiveDate: draft.effectiveDate,
            note: blankToNil(draft.note),
            mediaRefs: [],
            media: [],
            revision: 1,
            recordedByName: actorName
        )
        milestonePet[id] = petId
        return id
    }

    func editMilestone(
        milestoneId: UUID,
        expectedRevision: Int,
        draft: MilestoneDraft
    ) async throws {
        guard let existing = milestones[milestoneId], !removed.contains(milestoneId) else {
            throw LifeServiceError.unavailable("That milestone is no longer available.")
        }
        guard existing.revision == expectedRevision else {
            throw LifeError.changedElsewhere
        }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LifeError.invalidEntry }
        milestones[milestoneId] = Milestone(
            id: existing.id,
            title: title,
            effectiveDate: draft.effectiveDate,
            note: blankToNil(draft.note),
            mediaRefs: existing.mediaRefs,
            media: existing.media,
            revision: existing.revision + 1,
            recordedByName: existing.recordedByName
        )
    }

    func removeMilestone(milestoneId: UUID) async throws {
        removed.insert(milestoneId)
    }

    func prepareMilestoneMedia(
        milestoneId: UUID,
        mediaId: UUID,
        jpegData: Data,
        captureTime: Date?
    ) async throws -> MilestoneMediaUploadTarget {
        guard var existing = milestones[milestoneId], !removed.contains(milestoneId) else {
            throw LifeServiceError.unavailable("That milestone is no longer available.")
        }
        let media = MilestoneMedia(
            id: mediaId,
            storageBucket: "household-media",
            storagePath: "memory/\(mediaId.uuidString)",
            mimeType: "image/jpeg",
            byteSize: jpegData.count,
            captureTime: captureTime,
            status: .pendingUpload
        )
        existing = Milestone(
            id: existing.id,
            title: existing.title,
            effectiveDate: existing.effectiveDate,
            note: existing.note,
            mediaRefs: existing.mediaRefs + [mediaId],
            media: existing.media + [media],
            revision: existing.revision + 1,
            recordedByName: existing.recordedByName
        )
        milestones[milestoneId] = existing
        return MilestoneMediaUploadTarget(
            mediaId: mediaId,
            bucket: media.storageBucket,
            path: media.storagePath,
            upsert: true,
            mimeType: media.mimeType
        )
    }

    func uploadMilestoneMedia(_ target: MilestoneMediaUploadTarget, data: Data) async throws {
        blobs[target.mediaId] = data
    }

    func completeMilestoneMedia(mediaId: UUID, byteSize: Int) async throws {
        updateMedia(mediaId) { media in
            MilestoneMedia(
                id: media.id,
                storageBucket: media.storageBucket,
                storagePath: media.storagePath,
                mimeType: media.mimeType,
                byteSize: byteSize,
                captureTime: media.captureTime,
                status: .available
            )
        }
    }

    func failMilestoneMedia(mediaId: UUID) async throws {
        updateMedia(mediaId) { media in
            MilestoneMedia(
                id: media.id,
                storageBucket: media.storageBucket,
                storagePath: media.storagePath,
                mimeType: media.mimeType,
                byteSize: media.byteSize,
                captureTime: media.captureTime,
                status: .uploadFailed
            )
        }
    }

    func removeMilestoneMedia(mediaId: UUID) async throws {
        for (id, milestone) in milestones {
            guard milestone.mediaRefs.contains(mediaId) else { continue }
            milestones[id] = Milestone(
                id: milestone.id,
                title: milestone.title,
                effectiveDate: milestone.effectiveDate,
                note: milestone.note,
                mediaRefs: milestone.mediaRefs.filter { $0 != mediaId },
                media: milestone.media.filter { $0.id != mediaId },
                revision: milestone.revision + 1,
                recordedByName: milestone.recordedByName
            )
            blobs[mediaId] = nil
            return
        }
    }

    func downloadMilestoneMedia(_ media: MilestoneMedia) async throws -> Data {
        guard let data = blobs[media.id] else {
            throw LifeError.photoUploadFailed
        }
        return data
    }

    private func updateMedia(_ mediaId: UUID, transform: (MilestoneMedia) -> MilestoneMedia) {
        for (id, milestone) in milestones {
            guard let index = milestone.media.firstIndex(where: { $0.id == mediaId }) else { continue }
            var media = milestone.media
            media[index] = transform(media[index])
            milestones[id] = Milestone(
                id: milestone.id,
                title: milestone.title,
                effectiveDate: milestone.effectiveDate,
                note: milestone.note,
                mediaRefs: milestone.mediaRefs,
                media: media,
                revision: milestone.revision,
                recordedByName: milestone.recordedByName
            )
            return
        }
    }

    private func blankToNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
