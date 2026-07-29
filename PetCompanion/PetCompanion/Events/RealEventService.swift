import Foundation
import OSLog
import Supabase

/// Supabase-backed household Events (F11).
@MainActor
final class RealEventService: EventService {
    private let client: SupabaseClient
    private let decoder = SupabaseCoding.restDecoder
    private let operationQueue: OfflineOperationQueue?
    private let logger = Logger(subsystem: "com.nic.petcompanion", category: "events")

    init(
        client: SupabaseClient,
        operationQueue: OfflineOperationQueue? = nil
    ) {
        self.client = client
        self.operationQueue = operationQueue
    }

    private struct EventRow: Decodable {
        let id: UUID
        let household_id: UUID
        let pet_id: UUID?
        let kind: String
        let title: String
        let start_date: Date
        let start_time: String?
        let end_time: String?
        let all_day: Bool
        let location_text: String?
        let provider_id: UUID?
        let notes: String?
        let reminder_config: ReminderConfigDTO?
        let status: String
        let revision: Int
    }

    private struct ReminderConfigDTO: Decodable {
        let lead_minutes: [Int]?
    }

    private struct Acknowledgement: Decodable {}

    func loadEvents(householdId: UUID) async throws -> [HouseholdEvent] {
        do {
            let response = try await client
                .from("events")
                .select(
                    """
                    id, household_id, pet_id, kind, title, start_date, start_time, end_time, \
                    all_day, location_text, provider_id, notes, reminder_config, status, revision
                    """
                )
                .eq("household_id", value: householdId)
                .is("deleted_at", value: nil)
                .order("start_date", ascending: true)
                .execute()

            let rows = try decoder.decode([EventRow].self, from: response.data)
            return rows.compactMap(mapRow)
        } catch {
            throw EventError.fromTransportFailure(error)
        }
    }

    func createEvent(_ draft: EventDraft, householdId: UUID) async throws {
        struct Payload: Encodable {
            let household_id: String
            let pet_id: String?
            let kind: String
            let title: String
            let start_date: String
            let all_day: Bool
            let start_time: String?
            let location_text: String?
            let notes: String?
            let reminder_config: ReminderConfigPayload?
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "create_event",
                payload: Payload(
                    household_id: householdId.uuidString,
                    pet_id: draft.petId?.uuidString,
                    kind: draft.kind.rawValue,
                    title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    start_date: EventCoding.localDate(draft.startDate),
                    all_day: draft.allDay,
                    start_time: draft.allDay ? nil : EventCoding.clockString(draft.startTime),
                    location_text: trimmedOrNil(draft.locationText),
                    notes: trimmedOrNil(draft.notes),
                    reminder_config: ReminderConfigPayload(lead_minutes: draft.reminderLeadMinutes)
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw eventError(from: error)
        }
    }

    func editEvent(event: HouseholdEvent, draft: EventDraft) async throws {
        struct Payload: Encodable {
            let event_id: String
            let expected_revision: Int
            let pet_id: String?
            let kind: String
            let title: String
            let start_date: String
            let all_day: Bool
            let start_time: String?
            let location_text: String?
            let notes: String?
            let reminder_config: ReminderConfigPayload?
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "edit_event",
                payload: Payload(
                    event_id: event.id.uuidString,
                    expected_revision: event.revision,
                    pet_id: draft.petId?.uuidString,
                    kind: draft.kind.rawValue,
                    title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    start_date: EventCoding.localDate(draft.startDate),
                    all_day: draft.allDay,
                    start_time: draft.allDay ? nil : EventCoding.clockString(draft.startTime),
                    location_text: trimmedOrNil(draft.locationText),
                    notes: trimmedOrNil(draft.notes),
                    reminder_config: ReminderConfigPayload(lead_minutes: draft.reminderLeadMinutes)
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw eventError(from: error)
        }
    }

    func cancelEvent(_ event: HouseholdEvent) async throws {
        struct Payload: Encodable {
            let event_id: String
            let expected_revision: Int
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "cancel_event",
                payload: Payload(
                    event_id: event.id.uuidString,
                    expected_revision: event.revision
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw eventError(from: error)
        }
    }

    func archiveEvent(_ event: HouseholdEvent) async throws {
        struct Payload: Encodable {
            let event_id: String
            let expected_revision: Int
        }
        do {
            let _: Acknowledgement = try await WritePath.sendStable(
                client: client,
                command: "archive_event",
                payload: Payload(
                    event_id: event.id.uuidString,
                    expected_revision: event.revision
                ),
                queue: operationQueue
            )
        } catch let error as WritePathError {
            throw eventError(from: error)
        }
    }

    private struct ReminderConfigPayload: Encodable {
        let lead_minutes: [Int]
    }

    private func mapRow(_ row: EventRow) -> HouseholdEvent? {
        guard let kind = EventKind(rawValue: row.kind),
              let status = EventStatus(rawValue: row.status)
        else { return nil }
        return HouseholdEvent(
            id: row.id,
            householdId: row.household_id,
            petId: row.pet_id,
            kind: kind,
            title: row.title,
            startDate: row.start_date,
            startTime: row.start_time.map { String($0.prefix(5)) },
            endTime: row.end_time.map { String($0.prefix(5)) },
            allDay: row.all_day,
            locationText: row.location_text,
            providerId: row.provider_id,
            notes: row.notes,
            reminderLeadMinutes: row.reminder_config?.lead_minutes ?? [],
            status: status,
            revision: row.revision
        )
    }

    private func trimmedOrNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func eventError(from error: WritePathError) -> EventError {
        switch error {
        case .server(let code, let message):
            let mapped = EventError(code: code, message: message)
            if case .unexpected = mapped {
                logger.error("Unmapped event write failure: code=\(code, privacy: .public) message=\(message, privacy: .public)")
            }
            return mapped
        case .malformedResponse:
            logger.error("Malformed event write response")
            return .unexpected(code: "MALFORMED_RESPONSE")
        }
    }
}
