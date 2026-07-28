import Foundation
import Supabase

/// Supabase-backed socialization passport (F09).
///
/// Reads are direct RLS-protected PostgREST queries against
/// `socialization_records` / `socialization_exclusions`; every mutation goes
/// through the write-path edge function, which is the only caller permitted
/// to invoke the `write_path_*_socialization*` functions.
@MainActor
final class RealSocializationService: SocializationService {
    private let client: SupabaseClient
    private let decoder = SupabaseCoding.restDecoder
    private let operationQueue: OfflineOperationQueue?

    init(client: SupabaseClient, operationQueue: OfflineOperationQueue? = nil) {
        self.client = client
        self.operationQueue = operationQueue
    }

    // MARK: - Reads

    private struct RecordRow: Decodable {
        let id: UUID
        let experience_content_id: String?
        let custom_label: String?
        let category: String
        let effective_date: Date
        let context: String?
        let response: String
        let note: String?
        let revision: Int
    }

    private struct ExclusionRow: Decodable {
        let id: UUID
        let category: String?
        let experience_content_id: String?
        let reason: String
        let cleared_at: Date?
    }

    func load(petId: UUID) async throws -> SocializationSnapshot {
        async let recordResponse = client
            .from("socialization_records")
            .select("id, experience_content_id, custom_label, category, effective_date, context, response, note, revision")
            .eq("pet_id", value: petId)
            .is("deleted_at", value: nil)
            .order("effective_date", ascending: false)
            .execute()
        async let exclusionResponse = client
            .from("socialization_exclusions")
            .select("id, category, experience_content_id, reason, cleared_at")
            .eq("pet_id", value: petId)
            .execute()

        let recordRows = try decoder.decode([RecordRow].self, from: try await recordResponse.data)
        let exclusionRows = try decoder.decode([ExclusionRow].self, from: try await exclusionResponse.data)

        let records = recordRows.compactMap { row -> SocializationRecord? in
            // An unrecognized category or response can only mean the app is
            // older than the reviewed content. Dropping the row is the only
            // safe read: guessing a response would put a word in the owner's
            // mouth, and this vocabulary is never inferred.
            guard let category = SocializationCategory(rawValue: row.category),
                  let response = SocializationResponse(rawValue: row.response)
            else { return nil }
            let label = row.experience_content_id
                .flatMap { SocializationCatalogue.experience(contentId: $0)?.label }
                ?? row.custom_label
                ?? "Recorded experience"
            return SocializationRecord(
                id: row.id,
                experienceContentId: row.experience_content_id,
                label: label,
                category: category,
                effectiveDate: row.effective_date,
                context: row.context,
                response: response,
                note: row.note,
                revision: row.revision,
                recordedByName: nil
            )
        }

        let exclusions = exclusionRows.compactMap { row -> SocializationExclusion? in
            guard let reason = SocializationExclusionReason(rawValue: row.reason) else { return nil }
            return SocializationExclusion(
                id: row.id,
                category: row.category.flatMap(SocializationCategory.init(rawValue:)),
                experienceContentId: row.experience_content_id,
                reason: reason,
                isActive: row.cleared_at == nil
            )
        }

        return SocializationSnapshot(records: records, exclusions: exclusions)
    }

    // MARK: - Writes (write-path envelope)

    private struct Acknowledgement: Decodable {}

    func record(_ draft: SocializationDraft, petId: UUID) async throws {
        struct Payload: Encodable {
            let pet_id: String
            let experience_content_id: String?
            let custom_label: String?
            let category: String?
            let effective_date: String
            let context: String?
            let response: String
            let note: String?
        }

        let trimmedCustom = draft.customLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCatalogue = draft.experience != nil
        let _: Acknowledgement = try await WritePath.sendStable(
            client: client,
            command: "record_socialization",
            payload: Payload(
                pet_id: petId.uuidString,
                experience_content_id: draft.experience?.contentId,
                custom_label: isCatalogue ? nil : trimmedCustom,
                // A catalogue experience takes its category from the catalogue
                // server-side; sending one would be ignored anyway.
                category: isCatalogue ? nil : draft.category.rawValue,
                effective_date: SocializationCoding.localDate(draft.effectiveDate),
                context: draft.context.isEmpty ? nil : draft.context,
                response: draft.response.rawValue,
                note: draft.note.isEmpty ? nil : draft.note
            ),
            queue: operationQueue
        )
    }

    func editResponse(
        recordId: UUID,
        expectedRevision: Int,
        response: SocializationResponse,
        note: String?
    ) async throws {
        struct Payload: Encodable {
            let record_id: String
            let expected_revision: Int
            let response: String
            let note: String?
        }
        let _: Acknowledgement = try await WritePath.sendStable(
            client: client,
            command: "edit_socialization_record",
            payload: Payload(
                record_id: recordId.uuidString,
                expected_revision: expectedRevision,
                response: response.rawValue,
                note: note
            ),
            queue: operationQueue
        )
    }

    func remove(recordId: UUID) async throws {
        struct Payload: Encodable { let record_id: String }
        let _: Acknowledgement = try await WritePath.sendStable(
            client: client,
            command: "remove_socialization_record",
            payload: Payload(record_id: recordId.uuidString),
            queue: operationQueue
        )
    }

    func setExclusion(
        petId: UUID,
        category: SocializationCategory?,
        experienceContentId: String?,
        reason: SocializationExclusionReason
    ) async throws {
        struct Payload: Encodable {
            let pet_id: String
            let category: String?
            let experience_content_id: String?
            let reason: String
        }
        let _: Acknowledgement = try await WritePath.sendStable(
            client: client,
            command: "set_socialization_exclusion",
            payload: Payload(
                pet_id: petId.uuidString,
                category: category?.rawValue,
                experience_content_id: experienceContentId,
                reason: reason.rawValue
            ),
            queue: operationQueue
        )
    }

    func clearExclusion(exclusionId: UUID) async throws {
        struct Payload: Encodable { let exclusion_id: String }
        let _: Acknowledgement = try await WritePath.sendStable(
            client: client,
            command: "clear_socialization_exclusion",
            payload: Payload(exclusion_id: exclusionId.uuidString),
            queue: operationQueue
        )
    }
}

enum SocializationCoding {
    /// `effective_date` is a household-local calendar date (DM §8.2), so it is
    /// formatted in the device's current zone — the day the caregiver tapped
    /// is the day that is sent.
    static func localDate(_ date: Date) -> String {
        SupabaseCoding.dateOnlyString(date, timeZone: .current)
    }
}
