import Foundation
import OSLog
import Supabase

/// Supabase-backed vaccination history (F10 / US-070).
///
/// Reads are RLS-protected PostgREST queries; mutations go through write-path.
/// `next_due_date` is stored and shown as entered — never computed.
@MainActor
final class RealVaccinationService: VaccinationService {
    private let client: SupabaseClient
    private let decoder = SupabaseCoding.restDecoder
    private let operationQueue: OfflineOperationQueue?
    private let logger = Logger(subsystem: "com.nic.petcompanion", category: "vaccinations")

    init(client: SupabaseClient, operationQueue: OfflineOperationQueue? = nil) {
        self.client = client
        self.operationQueue = operationQueue
    }

    private struct VaccinationRow: Decodable {
        let id: UUID
        let vaccine_name: String
        let effective_date: Date
        let next_due_date: Date?
        let provenance: String
        let provider_id: UUID?
        let note: String?
        let revision: Int
    }

    private struct Acknowledgement: Decodable {}

    func loadVaccinations(petId: UUID) async throws -> [VaccinationRecord] {
        do {
            let response = try await client
                .from("vaccination_records")
                .select(
                    "id, vaccine_name, effective_date, next_due_date, provenance, provider_id, note, revision"
                )
                .eq("pet_id", value: petId)
                .is("deleted_at", value: nil)
                .order("effective_date", ascending: false)
                .execute()

            let rows = try decoder.decode([VaccinationRow].self, from: response.data)
            return rows.compactMap { row in
                guard let provenance = VaccinationProvenance(rawValue: row.provenance) else {
                    return nil
                }
                return VaccinationRecord(
                    id: row.id,
                    vaccineName: row.vaccine_name,
                    effectiveDate: row.effective_date,
                    nextDueDate: row.next_due_date,
                    provenance: provenance,
                    providerId: row.provider_id,
                    note: row.note,
                    revision: row.revision,
                    recordedByName: nil
                )
            }
        } catch {
            throw VaccinationError.fromTransportFailure(error)
        }
    }

    func recordVaccination(_ draft: VaccinationDraft, petId: UUID) async throws {
        struct Payload: Encodable {
            let pet_id: String
            let vaccine_name: String
            let effective_date: String
            /// Empty string clears / omits next due (owner fact only).
            let next_due_date: String
            let provenance: String
            let provider_id: String?
            let note: String?
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "record_vaccination",
                payload: Payload(
                    pet_id: petId.uuidString,
                    vaccine_name: draft.vaccineName.trimmingCharacters(in: .whitespacesAndNewlines),
                    effective_date: CareCoding.localDate(draft.effectiveDate),
                    next_due_date: nextDuePayload(draft),
                    provenance: draft.provenance.rawValue,
                    provider_id: draft.providerId?.uuidString,
                    note: blankToNil(draft.note)
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw vaccinationError(from: error)
        }
    }

    func editVaccination(
        vaccinationId: UUID,
        expectedRevision: Int,
        draft: VaccinationDraft
    ) async throws {
        struct Payload: Encodable {
            let vaccination_id: String
            let expected_revision: Int
            let vaccine_name: String
            let effective_date: String
            let next_due_date: String
            let provenance: String
            let provider_id: String?
            let note: String?
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "edit_vaccination",
                payload: Payload(
                    vaccination_id: vaccinationId.uuidString,
                    expected_revision: expectedRevision,
                    vaccine_name: draft.vaccineName.trimmingCharacters(in: .whitespacesAndNewlines),
                    effective_date: CareCoding.localDate(draft.effectiveDate),
                    next_due_date: nextDuePayload(draft),
                    provenance: draft.provenance.rawValue,
                    provider_id: draft.providerId?.uuidString,
                    note: blankToNil(draft.note)
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw vaccinationError(from: error)
        }
    }

    func removeVaccination(vaccinationId: UUID) async throws {
        struct Payload: Encodable { let vaccination_id: String }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "remove_vaccination",
                payload: Payload(vaccination_id: vaccinationId.uuidString),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw vaccinationError(from: error)
        }
    }

    private func blankToNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Empty string means “no next-due fact” so edit can clear a prior value
    /// (optional JSON nil would omit the key and leave the old date).
    private func nextDuePayload(_ draft: VaccinationDraft) -> String {
        guard draft.includeNextDue, let next = draft.nextDueDate else { return "" }
        return CareCoding.localDate(next)
    }

    private func vaccinationError(from error: WritePathError) -> Error {
        switch error {
        case .server(let code, let message):
            let mapped = VaccinationError(code: code, message: message)
            if case .unexpected = mapped {
                logger.error(
                    "Unmapped vaccination write failure: code=\(code, privacy: .public) message=\(message, privacy: .public)"
                )
            }
            return mapped
        case .malformedResponse:
            logger.error("Malformed vaccination write response")
            return VaccinationError.unexpected(code: "MALFORMED_RESPONSE")
        }
    }
}
