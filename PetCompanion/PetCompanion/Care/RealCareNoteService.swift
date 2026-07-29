import Foundation
import OSLog
import Supabase

/// Supabase-backed care notes + household-private document attachments (F10 / US-077).
///
/// Reads are RLS-protected PostgREST queries; mutations go through write-path.
/// Image/PDF bytes upload to `household-media` only after prepare mints a path.
@MainActor
final class RealCareNoteService: CareNoteService {
    private let client: SupabaseClient
    private let decoder = SupabaseCoding.restDecoder
    private let operationQueue: OfflineOperationQueue?
    private let logger = Logger(subsystem: "com.nic.petcompanion", category: "care-notes")

    init(client: SupabaseClient, operationQueue: OfflineOperationQueue? = nil) {
        self.client = client
        self.operationQueue = operationQueue
    }

    private struct CareNoteRow: Decodable {
        let id: UUID
        let kind: String
        let title: String?
        let body: String
        let effective_date: Date
        let provenance: String
        let provider_id: UUID?
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

    func loadNotes(petId: UUID) async throws -> [CareNote] {
        do {
            let response = try await client
                .from("care_notes")
                .select(
                    "id, kind, title, body, effective_date, provenance, provider_id, media_refs, revision"
                )
                .eq("pet_id", value: petId)
                .is("deleted_at", value: nil)
                .order("effective_date", ascending: false)
                .execute()

            let rows = try decoder.decode([CareNoteRow].self, from: response.data)
            let mediaIds = rows.flatMap { row in
                (row.media_refs ?? []).compactMap(UUID.init(uuidString:))
            }
            let mediaById = try await loadMedia(ids: mediaIds)

            return rows.compactMap { row in
                guard let kind = CareNoteKind(rawValue: row.kind),
                      let provenance = CareNoteProvenance(rawValue: row.provenance)
                else {
                    return nil
                }
                let refs = (row.media_refs ?? []).compactMap(UUID.init(uuidString:))
                let media = refs.compactMap { mediaById[$0] }
                return CareNote(
                    id: row.id,
                    kind: kind,
                    title: row.title,
                    body: row.body,
                    effectiveDate: row.effective_date,
                    provenance: provenance,
                    providerId: row.provider_id,
                    mediaRefs: refs,
                    media: media,
                    revision: row.revision,
                    recordedByName: nil
                )
            }
        } catch {
            throw CareNoteError.fromTransportFailure(error)
        }
    }

    func createNote(_ draft: CareNoteDraft, petId: UUID) async throws -> UUID {
        struct Payload: Encodable {
            let pet_id: String
            let care_note_id: String
            let kind: String
            let title: String?
            let body: String
            let effective_date: String
            let provenance: String
            let provider_id: String?
        }

        let noteId = UUID()
        let title = blankToNil(draft.title)
        if draft.kind == .document, title == nil {
            throw CareNoteError.invalidEntry
        }

        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "create_care_note",
                payload: Payload(
                    pet_id: petId.uuidString,
                    care_note_id: noteId.uuidString,
                    kind: draft.kind.rawValue,
                    title: title,
                    body: draft.body.trimmingCharacters(in: .whitespacesAndNewlines),
                    effective_date: CareCoding.localDate(draft.effectiveDate),
                    provenance: draft.provenance.rawValue,
                    provider_id: draft.providerId?.uuidString
                ),
                queue: operationQueue
            )
            return noteId
        } catch let error as WritePathError {
            throw careNoteError(from: error)
        }
    }

    func editNote(
        noteId: UUID,
        expectedRevision: Int,
        draft: CareNoteDraft
    ) async throws {
        struct Payload: Encodable {
            let care_note_id: String
            let expected_revision: Int
            let title: String?
            let body: String
            let effective_date: String
            let provenance: String
            let provider_id: String?
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "edit_care_note",
                payload: Payload(
                    care_note_id: noteId.uuidString,
                    expected_revision: expectedRevision,
                    title: blankToNil(draft.title),
                    body: draft.body.trimmingCharacters(in: .whitespacesAndNewlines),
                    effective_date: CareCoding.localDate(draft.effectiveDate),
                    provenance: draft.provenance.rawValue,
                    provider_id: draft.providerId?.uuidString
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw careNoteError(from: error)
        }
    }

    func removeNote(noteId: UUID) async throws {
        struct Payload: Encodable { let care_note_id: String }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "remove_care_note",
                payload: Payload(care_note_id: noteId.uuidString),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw careNoteError(from: error)
        }
    }

    func prepareCareNoteMedia(
        noteId: UUID,
        mediaId: UUID,
        data: Data,
        mimeType: String,
        captureTime: Date?
    ) async throws -> CareNoteMediaUploadTarget {
        struct Payload: Encodable {
            let care_note_id: String
            let media_id: String
            let mime_type: String
            let byte_size: Int
            let capture_time: String?
        }

        guard CareNoteAttachmentLimits.isAllowed(mimeType) else {
            throw CareNoteError.invalidEntry
        }
        guard data.count > 0, data.count <= CareNoteAttachmentLimits.maxBytes else {
            throw CareNoteError.invalidEntry
        }

        do {
            let result: PrepareResult = try await WritePath.sendStable(
                client: client,
                command: "prepare_care_note_media",
                payload: Payload(
                    care_note_id: noteId.uuidString,
                    media_id: mediaId.uuidString,
                    mime_type: mimeType,
                    byte_size: data.count,
                    capture_time: captureTime.map { ISO8601DateFormatter().string(from: $0) }
                ),
                queue: nil
            )
            return CareNoteMediaUploadTarget(
                mediaId: result.media.id,
                bucket: result.upload.bucket,
                path: result.upload.path,
                upsert: result.upload.upsert ?? true,
                mimeType: mimeType
            )
        } catch let error as WritePathError {
            throw careNoteError(from: error)
        }
    }

    func uploadCareNoteMedia(_ target: CareNoteMediaUploadTarget, data: Data) async throws {
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
            logger.error("Care note media upload failed: \(error.localizedDescription, privacy: .public)")
            throw CareNoteError.photoUploadFailed
        }
    }

    func completeCareNoteMedia(mediaId: UUID, byteSize: Int) async throws {
        struct Payload: Encodable {
            let media_id: String
            let byte_size: Int
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "complete_care_note_media",
                payload: Payload(media_id: mediaId.uuidString, byte_size: byteSize),
                queue: nil
            )
        } catch let error as WritePathError {
            throw careNoteError(from: error)
        }
    }

    func failCareNoteMedia(mediaId: UUID) async throws {
        struct Payload: Encodable { let media_id: String }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "fail_care_note_media",
                payload: Payload(media_id: mediaId.uuidString),
                queue: nil
            )
        } catch let error as WritePathError {
            throw careNoteError(from: error)
        }
    }

    func removeCareNoteMedia(mediaId: UUID) async throws {
        struct Payload: Encodable { let media_id: String }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "remove_care_note_media",
                payload: Payload(media_id: mediaId.uuidString),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw careNoteError(from: error)
        }
    }

    func downloadCareNoteMedia(_ media: CareNoteMedia) async throws -> Data {
        do {
            return try await client.storage
                .from(media.storageBucket)
                .download(path: media.storagePath)
        } catch {
            throw CareNoteError.fromTransportFailure(error)
        }
    }

    private func loadMedia(ids: [UUID]) async throws -> [UUID: CareNoteMedia] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }

        let response = try await client
            .from("media")
            .select("id, storage_bucket, storage_path, mime_type, byte_size, capture_time, status")
            .in("id", values: unique.map(\.uuidString))
            .execute()

        let rows = try decoder.decode([MediaRow].self, from: response.data)
        var map: [UUID: CareNoteMedia] = [:]
        for row in rows {
            guard let status = CareNoteMedia.Status(rawValue: row.status) else { continue }
            map[row.id] = CareNoteMedia(
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

    private func blankToNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func careNoteError(from error: WritePathError) -> Error {
        switch error {
        case .server(let code, let message):
            let mapped = CareNoteError(code: code, message: message)
            if case .unexpected = mapped {
                logger.error(
                    "Unmapped care note write failure: code=\(code, privacy: .public) message=\(message, privacy: .public)"
                )
            }
            return mapped
        case .malformedResponse:
            logger.error("Malformed care note write response")
            return CareNoteError.unexpected(code: "MALFORMED_RESPONSE")
        }
    }
}
