import Foundation

/// Reads and writes for household Events (F11).
///
/// Reads go to the RLS-protected `events` table; mutations go through the
/// write-path edge function (`create_event` / `edit_event` / `cancel_event` /
/// `archive_event`).
@MainActor
protocol EventService: AnyObject {
    func loadEvents(householdId: UUID) async throws -> [HouseholdEvent]
    func createEvent(_ draft: EventDraft, householdId: UUID) async throws
    func editEvent(
        event: HouseholdEvent,
        draft: EventDraft
    ) async throws
    func cancelEvent(_ event: HouseholdEvent) async throws
    func archiveEvent(_ event: HouseholdEvent) async throws
}

enum EventServiceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}

/// In-memory Events service for mock builds and previews.
@MainActor
final class InMemoryEventService: EventService {
    private var events: [UUID: HouseholdEvent] = [:]
    private var removed: Set<UUID> = []

    init(seeded: [HouseholdEvent] = []) {
        for event in seeded {
            events[event.id] = event
        }
    }

    func loadEvents(householdId: UUID) async throws -> [HouseholdEvent] {
        events.values
            .filter { $0.householdId == householdId && !removed.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    func createEvent(_ draft: EventDraft, householdId: UUID) async throws {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw EventError.invalidEntry }
        let id = UUID()
        events[id] = HouseholdEvent(
            id: id,
            householdId: householdId,
            petId: draft.petId,
            kind: draft.kind,
            title: title,
            startDate: draft.startDate,
            startTime: draft.allDay ? nil : EventCoding.clockString(draft.startTime),
            endTime: nil,
            allDay: draft.allDay,
            locationText: trimmedOrNil(draft.locationText),
            providerId: nil,
            notes: trimmedOrNil(draft.notes),
            reminderLeadMinutes: draft.reminderLeadMinutes.sorted(),
            status: .confirmed,
            revision: 1
        )
    }

    func editEvent(event: HouseholdEvent, draft: EventDraft) async throws {
        guard var existing = events[event.id], !removed.contains(event.id) else {
            throw EventError.invalidEntry
        }
        guard existing.revision == event.revision else { throw EventError.changedElsewhere }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw EventError.invalidEntry }
        existing = HouseholdEvent(
            id: existing.id,
            householdId: existing.householdId,
            petId: draft.petId,
            kind: draft.kind,
            title: title,
            startDate: draft.startDate,
            startTime: draft.allDay ? nil : EventCoding.clockString(draft.startTime),
            endTime: nil,
            allDay: draft.allDay,
            locationText: trimmedOrNil(draft.locationText),
            providerId: existing.providerId,
            notes: trimmedOrNil(draft.notes),
            reminderLeadMinutes: draft.reminderLeadMinutes.sorted(),
            status: .confirmed,
            revision: existing.revision + 1
        )
        events[existing.id] = existing
    }

    func cancelEvent(_ event: HouseholdEvent) async throws {
        guard var existing = events[event.id], !removed.contains(event.id) else {
            throw EventError.invalidEntry
        }
        guard existing.revision == event.revision else { throw EventError.changedElsewhere }
        if existing.status == .cancelled { return }
        existing = HouseholdEvent(
            id: existing.id,
            householdId: existing.householdId,
            petId: existing.petId,
            kind: existing.kind,
            title: existing.title,
            startDate: existing.startDate,
            startTime: existing.startTime,
            endTime: existing.endTime,
            allDay: existing.allDay,
            locationText: existing.locationText,
            providerId: existing.providerId,
            notes: existing.notes,
            reminderLeadMinutes: existing.reminderLeadMinutes,
            status: .cancelled,
            revision: existing.revision + 1
        )
        events[existing.id] = existing
    }

    func archiveEvent(_ event: HouseholdEvent) async throws {
        guard let existing = events[event.id], !removed.contains(event.id) else {
            throw EventError.invalidEntry
        }
        guard existing.revision == event.revision else { throw EventError.changedElsewhere }
        removed.insert(event.id)
        events[event.id] = HouseholdEvent(
            id: existing.id,
            householdId: existing.householdId,
            petId: existing.petId,
            kind: existing.kind,
            title: existing.title,
            startDate: existing.startDate,
            startTime: existing.startTime,
            endTime: existing.endTime,
            allDay: existing.allDay,
            locationText: existing.locationText,
            providerId: existing.providerId,
            notes: existing.notes,
            reminderLeadMinutes: existing.reminderLeadMinutes,
            status: existing.status,
            revision: existing.revision + 1
        )
    }

    private func trimmedOrNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
