import Foundation
import OSLog
import Supabase

/// Supabase-backed Care weight, providers, and medications (F10).
///
/// Reads are direct RLS-protected PostgREST queries (or authorized read RPCs);
/// every mutation goes through the write-path edge function. Dose text is
/// stored verbatim — never computed or normalized.
@MainActor
final class RealCareService: CareService {
    private let client: SupabaseClient
    private let decoder = SupabaseCoding.restDecoder
    private let operationQueue: OfflineOperationQueue?
    private let logger = Logger(subsystem: "com.nic.petcompanion", category: "care")

    init(client: SupabaseClient, operationQueue: OfflineOperationQueue? = nil) {
        self.client = client
        self.operationQueue = operationQueue
    }

    // MARK: - Weight reads

    private struct WeightRow: Decodable {
        let id: UUID
        /// Selected as `value::text` so JSON never goes through Double.
        let value: String
        let unit: String
        let effective_date: Date
        let note: String?
        let revision: Int
    }

    func loadWeights(petId: UUID) async throws -> [WeightMeasurement] {
        do {
            let response = try await client
                .from("weight_measurements")
                .select("id, value::text, unit, effective_date, note, revision")
                .eq("pet_id", value: petId)
                .is("deleted_at", value: nil)
                .order("effective_date", ascending: false)
                .execute()

            let rows = try decoder.decode([WeightRow].self, from: response.data)
            return rows.compactMap { row in
                guard let unit = WeightUnit(rawValue: row.unit),
                      let value = CareCoding.weightValue(fromJSONText: row.value)
                else { return nil }
                return WeightMeasurement(
                    id: row.id,
                    value: value,
                    unit: unit,
                    effectiveDate: row.effective_date,
                    note: row.note,
                    revision: row.revision,
                    recordedByName: nil
                )
            }
        } catch {
            throw CareError.fromTransportFailure(error)
        }
    }

    // MARK: - Provider reads

    private struct ProviderRow: Decodable {
        let id: UUID
        let name: String
        let kind: String
        let phone: String?
        let address: String?
        let notes: String?
        let revision: Int
    }

    func loadProviders(householdId: UUID) async throws -> [CareProvider] {
        do {
            let response = try await client
                .from("providers")
                .select("id, name, kind, phone, address, notes, revision")
                .eq("household_id", value: householdId)
                .is("deleted_at", value: nil)
                .order("name", ascending: true)
                .execute()

            let rows = try decoder.decode([ProviderRow].self, from: response.data)
            return rows.compactMap { row in
                guard let kind = ProviderKind(rawValue: row.kind) else { return nil }
                return CareProvider(
                    id: row.id,
                    name: row.name,
                    kind: kind,
                    phone: row.phone,
                    address: row.address,
                    notes: row.notes,
                    revision: row.revision
                )
            }
        } catch {
            throw CareError.fromTransportFailure(error)
        }
    }

    // MARK: - Writes

    private struct Acknowledgement: Decodable {}

    func recordWeight(_ draft: WeightDraft, petId: UUID) async throws {
        struct Payload: Encodable {
            let pet_id: String
            let value: String
            let unit: String
            let effective_date: String
            let note: String?
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "record_weight",
                payload: Payload(
                    pet_id: petId.uuidString,
                    value: draft.valueText.trimmingCharacters(in: .whitespacesAndNewlines),
                    unit: draft.unit.rawValue,
                    effective_date: CareCoding.localDate(draft.effectiveDate),
                    note: draft.note.isEmpty ? nil : draft.note
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw careError(from: error)
        }
    }

    func editWeight(
        measurementId: UUID,
        expectedRevision: Int,
        draft: WeightDraft
    ) async throws {
        struct Payload: Encodable {
            let measurement_id: String
            let expected_revision: Int
            let value: String
            let unit: String
            let effective_date: String
            let note: String?
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "edit_weight",
                payload: Payload(
                    measurement_id: measurementId.uuidString,
                    expected_revision: expectedRevision,
                    value: draft.valueText.trimmingCharacters(in: .whitespacesAndNewlines),
                    unit: draft.unit.rawValue,
                    effective_date: CareCoding.localDate(draft.effectiveDate),
                    note: draft.note.isEmpty ? nil : draft.note
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw careError(from: error)
        }
    }

    func removeWeight(measurementId: UUID) async throws {
        struct Payload: Encodable { let measurement_id: String }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "remove_weight",
                payload: Payload(measurement_id: measurementId.uuidString),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw careError(from: error)
        }
    }

    func createProvider(_ draft: ProviderDraft, householdId: UUID) async throws {
        struct Payload: Encodable {
            let household_id: String
            let name: String
            let kind: String
            let phone: String?
            let address: String?
            let notes: String?
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "create_provider",
                payload: Payload(
                    household_id: householdId.uuidString,
                    name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: draft.kind.rawValue,
                    phone: blankToNil(draft.phone),
                    address: blankToNil(draft.address),
                    notes: blankToNil(draft.notes)
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw careError(from: error)
        }
    }

    func editProvider(
        providerId: UUID,
        expectedRevision: Int,
        draft: ProviderDraft
    ) async throws {
        struct Payload: Encodable {
            let provider_id: String
            let expected_revision: Int
            let name: String
            let kind: String
            let phone: String?
            let address: String?
            let notes: String?
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "edit_provider",
                payload: Payload(
                    provider_id: providerId.uuidString,
                    expected_revision: expectedRevision,
                    name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: draft.kind.rawValue,
                    phone: blankToNil(draft.phone),
                    address: blankToNil(draft.address),
                    notes: blankToNil(draft.notes)
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw careError(from: error)
        }
    }

    func removeProvider(providerId: UUID) async throws {
        struct Payload: Encodable { let provider_id: String }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "remove_provider",
                payload: Payload(provider_id: providerId.uuidString),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw careError(from: error)
        }
    }

    // MARK: - Medication reads

    private struct MedicationJSON: Decodable {
        let id: UUID
        let pet_id: UUID
        let medication_name: String
        let dose_text: String?
        let instructions_text: String?
        let provenance: String
        let provider_id: UUID?
        let recurrence: RecurrenceJSON
        let status: String
        let task_schedule_id: UUID
        let revision: Int
        let created_by_name: String?
        let next_due: NextDueJSON?
        let last_completion: LastCompletionJSON?
        let change_history: [ChangeHistoryJSON]?
    }

    private struct RecurrenceJSON: Decodable {
        let type: String
        let anchor_date: Date
        let interval: Int?
        let time_policy: String
        let exact_time: String?
        let window_ref: String?
    }

    private struct NextDueJSON: Decodable {
        let occurrence_id: UUID
        let local_due_date: Date
        let original_local_due_date: Date
        let time_policy: String
        let due_time: String?
        let window_ref: String?
        let occurrence_revision: Int
    }

    private struct LastCompletionJSON: Decodable {
        let effective_at: Date
        let actor_user_id: UUID?
        let actor_name: String?
        let completed_due_date: Date?
    }

    private struct ChangeHistoryJSON: Decodable {
        let occurred_at: Date
        let action: String
        let actor_name: String?
        let summary: [String: SupabaseJSONValue]?
    }

    /// Minimal JSON value for decoding audit summary blobs we don't render fully.
    private enum SupabaseJSONValue: Decodable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: SupabaseJSONValue])
        case array([SupabaseJSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            if let v = try? container.decode(Bool.self) { self = .bool(v); return }
            if let v = try? container.decode(Double.self) { self = .number(v); return }
            if let v = try? container.decode(String.self) { self = .string(v); return }
            if let v = try? container.decode([String: SupabaseJSONValue].self) { self = .object(v); return }
            if let v = try? container.decode([SupabaseJSONValue].self) { self = .array(v); return }
            self = .null
        }
    }

    func loadMedicationSchedules(petId: UUID) async throws -> [MedicationSchedule] {
        do {
            let response = try await client
                .rpc("list_medication_schedules_for_pet", params: ["target_pet_id": petId.uuidString])
                .execute()
            let rows = try decoder.decode([MedicationJSON].self, from: response.data)
            return rows.compactMap(decodeMedication(_:))
        } catch {
            throw CareError.fromTransportFailure(error)
        }
    }

    private func decodeMedication(_ row: MedicationJSON) -> MedicationSchedule? {
        guard let provenance = MedicationProvenance(rawValue: row.provenance),
              let status = MedicationScheduleStatus(rawValue: row.status),
              let recurrence = decodeRecurrence(row.recurrence)
        else { return nil }
        return MedicationSchedule(
            id: row.id,
            petId: row.pet_id,
            medicationName: row.medication_name,
            doseText: row.dose_text,
            instructionsText: row.instructions_text,
            provenance: provenance,
            providerId: row.provider_id,
            recurrence: recurrence,
            status: status,
            taskScheduleId: row.task_schedule_id,
            revision: row.revision,
            nextDue: row.next_due.flatMap(decodeNextDue(_:)),
            lastCompletion: row.last_completion.map {
                MedicationLastCompletion(
                    effectiveAt: $0.effective_at,
                    actorUserId: $0.actor_user_id,
                    actorName: $0.actor_name,
                    completedDueDate: $0.completed_due_date
                )
            },
            changeHistory: (row.change_history ?? []).map { entry in
                MedicationChangeEntry(
                    id: UUID(),
                    occurredAt: entry.occurred_at,
                    action: entry.action,
                    actorName: entry.actor_name,
                    summaryLabel: Self.changeHistoryLabel(action: entry.action)
                )
            },
            createdByName: row.created_by_name
        )
    }

    private func decodeRecurrence(_ row: RecurrenceJSON) -> MedicationRecurrence? {
        guard let type = MedicationRecurrenceType(rawValue: row.type),
              let timePolicy = MedicationTimePolicy(rawValue: row.time_policy)
        else { return nil }
        return MedicationRecurrence(
            type: type,
            anchorDate: row.anchor_date,
            interval: row.interval,
            timePolicy: timePolicy,
            exactTime: row.exact_time.map { String($0.prefix(5)) },
            windowRef: row.window_ref.flatMap(MedicationWindowRef.init(rawValue:))
        )
    }

    private func decodeNextDue(_ row: NextDueJSON) -> MedicationNextDue? {
        guard let timePolicy = MedicationTimePolicy(rawValue: row.time_policy) else { return nil }
        return MedicationNextDue(
            occurrenceId: row.occurrence_id,
            localDueDate: row.local_due_date,
            originalLocalDueDate: row.original_local_due_date,
            timePolicy: timePolicy,
            dueTime: row.due_time.map { String($0.prefix(5)) },
            windowRef: row.window_ref.flatMap(MedicationWindowRef.init(rawValue:)),
            occurrenceRevision: row.occurrence_revision
        )
    }

    private static func changeHistoryLabel(action: String) -> String {
        switch action {
        case "care.medication_schedule_created": return "Created"
        case "care.medication_schedule_edited": return "Updated"
        case "care.medication_schedule_archived": return "Archived"
        case "care.medication_occurrence_completed": return "Dose recorded"
        default: return "Updated"
        }
    }

    // MARK: - Medication writes

    private struct RecurrencePayload: Encodable {
        let type: String
        let anchor_date: String
        let interval: Int?
        let time_policy: String
        let exact_time: String?
        let window_ref: String?

        init(_ recurrence: MedicationRecurrence) {
            type = recurrence.type.rawValue
            anchor_date = CareCoding.localDate(recurrence.anchorDate)
            interval = recurrence.interval
            time_policy = recurrence.timePolicy.rawValue
            exact_time = recurrence.exactTime
            window_ref = recurrence.windowRef?.rawValue
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(anchor_date, forKey: .anchor_date)
            try container.encode(time_policy, forKey: .time_policy)
            if let interval { try container.encode(interval, forKey: .interval) }
            if let exact_time { try container.encode(exact_time, forKey: .exact_time) }
            if let window_ref { try container.encode(window_ref, forKey: .window_ref) }
        }

        private enum CodingKeys: String, CodingKey {
            case type, anchor_date, interval, time_policy, exact_time, window_ref
        }
    }

    func createMedicationSchedule(_ draft: MedicationDraft, petId: UUID) async throws {
        guard let recurrence = draft.validatedRecurrence() else { throw CareError.invalidEntry }
        struct Payload: Encodable {
            let pet_id: String
            let medication_name: String
            let dose_text: String?
            let instructions_text: String?
            let provenance: String
            let recurrence: RecurrencePayload
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "create_medication_schedule",
                payload: Payload(
                    pet_id: petId.uuidString,
                    medication_name: draft.medicationName.trimmingCharacters(in: .whitespacesAndNewlines),
                    dose_text: blankToNil(draft.doseText),
                    instructions_text: blankToNil(draft.instructionsText),
                    provenance: draft.provenance.rawValue,
                    recurrence: RecurrencePayload(recurrence)
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw careError(from: error)
        }
    }

    func editMedicationSchedule(
        schedule: MedicationSchedule,
        draft: MedicationDraft
    ) async throws {
        guard let recurrence = draft.validatedRecurrence() else { throw CareError.invalidEntry }
        struct Payload: Encodable {
            let medication_schedule_id: String
            let expected_revision: Int
            let medication_name: String
            let dose_text: String?
            let instructions_text: String?
            let provenance: String
            let recurrence: RecurrencePayload
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "edit_medication_schedule",
                payload: Payload(
                    medication_schedule_id: schedule.id.uuidString,
                    expected_revision: schedule.revision,
                    medication_name: draft.medicationName.trimmingCharacters(in: .whitespacesAndNewlines),
                    dose_text: blankToNil(draft.doseText),
                    instructions_text: blankToNil(draft.instructionsText),
                    provenance: draft.provenance.rawValue,
                    recurrence: RecurrencePayload(recurrence)
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw careError(from: error)
        }
    }

    func archiveMedicationSchedule(_ schedule: MedicationSchedule) async throws {
        struct Payload: Encodable {
            let medication_schedule_id: String
            let expected_revision: Int
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "archive_medication_schedule",
                payload: Payload(
                    medication_schedule_id: schedule.id.uuidString,
                    expected_revision: schedule.revision
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw careError(from: error)
        }
    }

    func completeMedicationOccurrence(
        occurrenceId: UUID,
        acknowledgedRecentCompletion: Bool
    ) async throws {
        struct Payload: Encodable {
            let occurrence_id: String
            let acknowledged_recent_completion: Bool
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "complete_medication_occurrence",
                payload: Payload(
                    occurrence_id: occurrenceId.uuidString,
                    acknowledged_recent_completion: acknowledgedRecentCompletion
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw careError(from: error)
        }
    }

    private func careError(from error: WritePathError) -> Error {
        switch error {
        case .server(let code, let message):
            let mapped = CareError(code: code, message: message)
            if case .unexpected = mapped {
                logger.error("Unmapped care write failure: code=\(code, privacy: .public) message=\(message, privacy: .public)")
            }
            return mapped
        case .malformedResponse:
            logger.error("Malformed care write response")
            return CareError.unexpected(code: "MALFORMED_RESPONSE")
        }
    }

    private func blankToNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
