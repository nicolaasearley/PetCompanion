import Foundation
import OSLog
import Supabase

/// Supabase-backed Life milestones + household-private media (F12 / DM §12.6).
///
/// Reads are direct RLS-protected PostgREST queries; every mutation goes
/// through the write-path edge function. Photo bytes upload to the private
/// `household-media` bucket only after prepare mints an authorized path.
@MainActor
final class RealLifeService: LifeService {
    private let client: SupabaseClient
    private let decoder = SupabaseCoding.restDecoder
    private let operationQueue: OfflineOperationQueue?
    private let logger = Logger(subsystem: "com.nic.petcompanion", category: "life")

    init(client: SupabaseClient, operationQueue: OfflineOperationQueue? = nil) {
        self.client = client
        self.operationQueue = operationQueue
    }

    private struct MilestoneRow: Decodable {
        let id: UUID
        let title: String
        let effective_date: Date
        let note: String?
        let media_refs: [String]?
        let revision: Int
    }

    private struct MediaRow: Decodable {
        let id: UUID
        let storage_bucket: String
        let storage_path: String
        let mime_type: String
        let byte_size: Int64
        let capture_time: Date?
        let status: String
    }

    private struct Acknowledgement: Decodable {}

    private struct PrepareResult: Decodable {
        struct MediaBody: Decodable { let id: UUID }
        struct UploadBody: Decodable {
            let bucket: String
            let path: String
            let upsert: Bool?
        }
        let media: MediaBody
        let upload: UploadBody
    }

    func loadMilestones(petId: UUID) async throws -> [Milestone] {
        do {
            let response = try await client
                .from("milestones")
                .select("id, title, effective_date, note, media_refs, revision")
                .eq("pet_id", value: petId)
                .is("deleted_at", value: nil)
                .order("effective_date", ascending: false)
                .execute()

            let rows = try decoder.decode([MilestoneRow].self, from: response.data)
            let mediaIds = rows.flatMap { row in
                (row.media_refs ?? []).compactMap(UUID.init(uuidString:))
            }
            let mediaById = try await loadMedia(ids: mediaIds)

            return rows.map { row in
                let refs = (row.media_refs ?? []).compactMap(UUID.init(uuidString:))
                let media = refs.compactMap { mediaById[$0] }
                return Milestone(
                    id: row.id,
                    title: row.title,
                    effectiveDate: row.effective_date,
                    note: row.note,
                    mediaRefs: refs,
                    media: media,
                    revision: row.revision,
                    recordedByName: nil
                )
            }
        } catch {
            throw LifeError.fromTransportFailure(error)
        }
    }

    func createMilestone(_ draft: MilestoneDraft, petId: UUID) async throws -> UUID {
        struct Payload: Encodable {
            let pet_id: String
            let milestone_id: String
            let title: String
            let effective_date: String
            let note: String?
        }

        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LifeError.invalidEntry }
        let milestoneId = UUID()

        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "create_milestone",
                payload: Payload(
                    pet_id: petId.uuidString,
                    milestone_id: milestoneId.uuidString,
                    title: title,
                    effective_date: LifeCoding.localDate(draft.effectiveDate),
                    note: blankToNil(draft.note)
                ),
                queue: operationQueue
            )
            return milestoneId
        } catch let error as WritePathError {
            throw lifeError(from: error)
        }
    }

    func editMilestone(
        milestoneId: UUID,
        expectedRevision: Int,
        draft: MilestoneDraft
    ) async throws {
        struct Payload: Encodable {
            let milestone_id: String
            let expected_revision: Int
            let title: String
            let effective_date: String
            let note: String?
        }

        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LifeError.invalidEntry }

        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "edit_milestone",
                payload: Payload(
                    milestone_id: milestoneId.uuidString,
                    expected_revision: expectedRevision,
                    title: title,
                    effective_date: LifeCoding.localDate(draft.effectiveDate),
                    note: blankToNil(draft.note)
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw lifeError(from: error)
        }
    }

    func removeMilestone(milestoneId: UUID) async throws {
        struct Payload: Encodable { let milestone_id: String }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "remove_milestone",
                payload: Payload(milestone_id: milestoneId.uuidString),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw lifeError(from: error)
        }
    }

    func prepareMilestoneMedia(
        milestoneId: UUID,
        mediaId: UUID,
        jpegData: Data,
        captureTime: Date?
    ) async throws -> MilestoneMediaUploadTarget {
        struct Payload: Encodable {
            let milestone_id: String
            let media_id: String
            let mime_type: String
            let byte_size: Int
            let capture_time: String?
        }

        do {
            // Media prepare must hit the network now — offline queue cannot
            // authorize a Storage path the client needs immediately.
            let result: PrepareResult = try await WritePath.sendStable(
                client: client,
                command: "prepare_milestone_media",
                payload: Payload(
                    milestone_id: milestoneId.uuidString,
                    media_id: mediaId.uuidString,
                    mime_type: "image/jpeg",
                    byte_size: jpegData.count,
                    capture_time: captureTime.map { ISO8601DateFormatter().string(from: $0) }
                ),
                queue: nil
            )
            return MilestoneMediaUploadTarget(
                mediaId: result.media.id,
                bucket: result.upload.bucket,
                path: result.upload.path,
                upsert: result.upload.upsert ?? true,
                mimeType: "image/jpeg"
            )
        } catch let error as WritePathError {
            throw lifeError(from: error)
        }
    }

    func uploadMilestoneMedia(_ target: MilestoneMediaUploadTarget, data: Data) async throws {
        do {
            try await client.storage
                .from(target.bucket)
                .upload(
                    target.path,
                    data: data,
                    options: FileOptions(
                        cacheControl: "3600",
                        contentType: target.mimeType,
                        upsert: target.upsert
                    )
                )
        } catch {
            logger.error("Milestone media upload failed: \(error.localizedDescription, privacy: .public)")
            throw LifeError.photoUploadFailed
        }
    }

    func completeMilestoneMedia(mediaId: UUID, byteSize: Int) async throws {
        struct Payload: Encodable {
            let media_id: String
            let byte_size: Int
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "complete_milestone_media",
                payload: Payload(media_id: mediaId.uuidString, byte_size: byteSize),
                queue: nil
            )
        } catch let error as WritePathError {
            throw lifeError(from: error)
        }
    }

    func failMilestoneMedia(mediaId: UUID) async throws {
        struct Payload: Encodable { let media_id: String }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "fail_milestone_media",
                payload: Payload(media_id: mediaId.uuidString),
                queue: nil
            )
        } catch let error as WritePathError {
            throw lifeError(from: error)
        }
    }

    func removeMilestoneMedia(mediaId: UUID) async throws {
        struct Payload: Encodable { let media_id: String }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "remove_milestone_media",
                payload: Payload(media_id: mediaId.uuidString),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw lifeError(from: error)
        }
    }

    func downloadMilestoneMedia(_ media: MilestoneMedia) async throws -> Data {
        do {
            return try await client.storage
                .from(media.storageBucket)
                .download(path: media.storagePath)
        } catch {
            throw LifeError.fromTransportFailure(error)
        }
    }

    private func loadMedia(ids: [UUID]) async throws -> [UUID: MilestoneMedia] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }

        let response = try await client
            .from("media")
            .select("id, storage_bucket, storage_path, mime_type, byte_size, capture_time, status")
            .in("id", values: unique.map(\.uuidString))
            .execute()

        let rows = try decoder.decode([MediaRow].self, from: response.data)
        var map: [UUID: MilestoneMedia] = [:]
        for row in rows {
            guard let status = MilestoneMedia.Status(rawValue: row.status) else { continue }
            map[row.id] = MilestoneMedia(
                id: row.id,
                storageBucket: row.storage_bucket,
                storagePath: row.storage_path,
                mimeType: row.mime_type,
                byteSize: Int(row.byte_size),
                captureTime: row.capture_time,
                status: status
            )
        }
        return map
    }

    private func lifeError(from error: WritePathError) -> Error {
        switch error {
        case .server(let code, let message):
            let mapped = LifeError(code: code, message: message)
            if case .unexpected = mapped {
                logger.error("Unmapped life write failure: code=\(code, privacy: .public) message=\(message, privacy: .public)")
            }
            return mapped
        case .malformedResponse:
            logger.error("Malformed life write response")
            return LifeError.unexpected(code: "MALFORMED_RESPONSE")
        }
    }

    private func blankToNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
