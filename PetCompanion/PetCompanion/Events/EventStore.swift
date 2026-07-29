import Foundation
import Observation

/// State behind the Appointments & events list (F11 / PL-03 foundation).
@MainActor
@Observable
final class EventStore {
    private let service: any EventService
    private let notifications: (any LocalNotificationServicing)?
    private let timeZoneId: String

    private(set) var events: [HouseholdEvent] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    var confirmationMessage: String?
    var queuedMessage: String?

    let householdId: UUID
    let pets: [(id: UUID, name: String)]
    let calendar: Calendar

    init(
        service: any EventService,
        householdId: UUID,
        pets: [(id: UUID, name: String)] = [],
        calendar: Calendar = .current,
        timeZoneId: String? = nil,
        notifications: (any LocalNotificationServicing)? = nil
    ) {
        self.service = service
        self.householdId = householdId
        self.pets = pets
        self.calendar = calendar
        self.timeZoneId = timeZoneId ?? calendar.timeZone.identifier
        self.notifications = notifications
    }

    var upcoming: [HouseholdEvent] {
        let today = calendar.startOfDay(for: Date())
        return events.filter { !$0.isCancelled && $0.startDate >= today }
    }

    var pastOrCancelled: [HouseholdEvent] {
        let today = calendar.startOfDay(for: Date())
        return events.filter { $0.isCancelled || $0.startDate < today }
    }

    func petName(for event: HouseholdEvent) -> String? {
        guard let petId = event.petId else { return nil }
        return pets.first(where: { $0.id == petId })?.name
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            events = try await service.loadEvents(householdId: householdId)
            await reconcileLocalReminders()
        } catch {
            errorMessage = EventError.displayMessage(for: error)
        }
    }

    /// Mirrors server `refresh_event_notification_candidates` on-device:
    /// create/edit/cancel/archive all end in `load()`, which replaces pending
    /// Event local reminders from the authoritative list.
    private func reconcileLocalReminders() async {
        await notifications?.reconcileEvents(events: events, timeZoneId: timeZoneId)
    }

    func create(_ draft: EventDraft) async -> Bool {
        guard validate(draft) else { return false }
        return await perform(
            confirmation: "Saved appointment.",
            queuedNotice: "Saved on this device. It'll appear once you're back online."
        ) {
            try await self.service.createEvent(draft, householdId: self.householdId)
        }
    }

    func edit(_ event: HouseholdEvent, draft: EventDraft) async -> Bool {
        guard validate(draft) else { return false }
        return await perform(
            confirmation: "Updated.",
            queuedNotice: "Saved on this device. The update will apply once you're back online."
        ) {
            try await self.service.editEvent(event: event, draft: draft)
        }
    }

    func cancel(_ event: HouseholdEvent) async -> Bool {
        await perform(
            confirmation: "Cancelled.",
            queuedNotice: "Saved on this device. Cancellation will apply once you're back online."
        ) {
            try await self.service.cancelEvent(event)
        }
    }

    func archive(_ event: HouseholdEvent) async -> Bool {
        await perform(
            confirmation: "Removed.",
            queuedNotice: "Saved on this device. It'll be removed once you're back online."
        ) {
            try await self.service.archiveEvent(event)
        }
    }

    private func validate(_ draft: EventDraft) -> Bool {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = EventError.invalidEntry.errorDescription
            return false
        }
        return true
    }

    private func perform(
        confirmation: String,
        queuedNotice: String,
        _ work: @escaping () async throws -> Void
    ) async -> Bool {
        isSaving = true
        errorMessage = nil
        queuedMessage = nil
        confirmationMessage = nil
        defer { isSaving = false }
        do {
            try await work()
            await load()
            errorMessage = nil
            confirmationMessage = confirmation
            return true
        } catch OfflineMutationError.queued {
            queuedMessage = queuedNotice
            return true
        } catch {
            errorMessage = EventError.displayMessage(for: error)
            return false
        }
    }
}
