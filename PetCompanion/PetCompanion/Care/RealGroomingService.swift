import Foundation
import OSLog
import Supabase

/// Supabase-backed grooming history (F10 / US-076).
///
/// Reads are RLS-protected PostgREST queries; mutations go through write-path.
/// `next_due_date` is stored and shown as entered — never computed.
@MainActor
final class RealGroomingService: GroomingService {
    private let client: SupabaseClient
    private let decoder = SupabaseCoding.restDecoder
    private let operationQueue: OfflineOperationQueue?
    private let logger = Logger(subsystem: "com.nic.petcompanion", category: "grooming")

    init(client: SupabaseClient, operationQueue: OfflineOperationQueue? = nil) {
        self.client = client
        self.operationQueue = operationQueue
    }

    private struct GroomingRow: Decodable {
        let id: UUID
        let activity_type: String
        let effective_date: Date
        let next_due_date: Date?
        let note: String?
        let revision: Int
    }

    private struct Acknowledgement: Decodable {}

    func loadGrooming(petId: UUID) async throws -> [GroomingRecord] {
        do {
            let response = try await client
                .from("grooming_records")
                .select("id, activity_type, effective_date, next_due_date, note, revision")
                .eq("pet_id", value: petId)
                .is("deleted_at", value: nil)
                .order("effective_date", ascending: false)
                .execute()

            let rows = try decoder.decode([GroomingRow].self, from: response.data)
            return rows.compactMap { row in
                guard let activity = GroomingActivityType(rawValue: row.activity_type) else {
                    return nil
                }
                return GroomingRecord(
                    id: row.id,
                    activityType: activity,
                    effectiveDate: row.effective_date,
                    nextDueDate: row.next_due_date,
                    note: row.note,
                    revision: row.revision,
                    recordedByName: nil
                )
            }
        } catch {
            throw GroomingError.fromTransportFailure(error)
        }
    }

    func recordGrooming(_ draft: GroomingDraft, petId: UUID) async throws {
        struct Payload: Encodable {
            let pet_id: String
            let activity_type: String
            let effective_date: String
            /// Empty string clears / omits next due (owner fact only).
            let next_due_date: String
            let note: String?
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "record_grooming",
                payload: Payload(
                    pet_id: petId.uuidString,
                    activity_type: draft.activityType.rawValue,
                    effective_date: CareCoding.localDate(draft.effectiveDate),
                    next_due_date: nextDuePayload(draft),
                    note: blankToNil(draft.note)
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw groomingError(from: error)
        }
    }

    func editGrooming(
        groomingId: UUID,
        expectedRevision: Int,
        draft: GroomingDraft
    ) async throws {
        struct Payload: Encodable {
            let grooming_id: String
            let expected_revision: Int
            let activity_type: String
            let effective_date: String
            let next_due_date: String
            let note: String?
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "edit_grooming",
                payload: Payload(
                    grooming_id: groomingId.uuidString,
                    expected_revision: expectedRevision,
                    activity_type: draft.activityType.rawValue,
                    effective_date: CareCoding.localDate(draft.effectiveDate),
                    next_due_date: nextDuePayload(draft),
                    note: blankToNil(draft.note)
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw groomingError(from: error)
        }
    }

    func removeGrooming(groomingId: UUID) async throws {
        struct Payload: Encodable { let grooming_id: String }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "remove_grooming",
                payload: Payload(grooming_id: groomingId.uuidString),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw groomingError(from: error)
        }
    }

    private func blankToNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Empty string means “no next-due fact” so edit can clear a prior value
    /// (optional JSON nil would omit the key and leave the old date).
    private func nextDuePayload(_ draft: GroomingDraft) -> String {
        guard draft.includeNextDue, let next = draft.nextDueDate else { return "" }
        return CareCoding.localDate(next)
    }

    private func groomingError(from error: WritePathError) -> Error {
        switch error {
        case .server(let code, let message):
            let mapped = GroomingError(code: code, message: message)
            if case .unexpected = mapped {
                logger.error(
                    "Unmapped grooming write failure: code=\(code, privacy: .public) message=\(message, privacy: .public)"
                )
            }
            return mapped
        case .malformedResponse:
            logger.error("Malformed grooming write response")
            return GroomingError.unexpected(code: "MALFORMED_RESPONSE")
        }
    }
}
