import Foundation
import Observation

@MainActor
@Observable
final class PlannerStore {
    private let service: any PlannerService
    private let eventService: (any EventService)?
    private let householdId: UUID?

    private(set) var context: PlannerContext?
    /// Ordered local-day sections for the forward-scrolling PL-01 agenda.
    private(set) var days: [PlannerDayAgenda] = []
    private(set) var isLoading = false
    private(set) var isExtending = false
    private(set) var isSaving = false
    var errorMessage: String?
    var confirmationMessage: String?
    /// Anchor for the week rail / month jump; the agenda itself scrolls.
    var selectedDate: Date
    /// Ask the agenda `ScrollViewReader` to bring this local day on-screen.
    var scrollTargetDate: Date?
    var detailItem: PlannerAgendaItem?
    var detailEvent: PlannerAgendaEvent?
    var editorRoute: PlannerEditorRoute?
    var showMonthJump = false
    /// Days with tasks and/or confirmed events for the month-jump grid dots.
    /// Seeded from the loaded agenda window and refreshed for the visible month.
    private(set) var monthJumpContentDates: Set<Date> = []

    init(
        service: any PlannerService,
        eventService: (any EventService)? = nil,
        householdId: UUID? = nil,
        initialDate: Date = .now
    ) {
        self.service = service
        self.eventService = eventService
        self.householdId = householdId
        selectedDate = initialDate
    }

    var calendar: Calendar { context?.calendar ?? .current }
    var capabilities: PlannerCapabilities { context?.capabilities ?? [] }
    var pets: [Pet] { context?.pets ?? [] }
    var members: [PlannerMemberOption] { context?.members ?? [.anyone] }
    var items: [PlannerAgendaItem] { days.flatMap(\.items) }
    var isStale: Bool { days.contains(where: \.isStale) }
    var hasAgenda: Bool { !days.isEmpty }

    var lastVerifiedAt: Date? {
        days.compactMap(\.lastVerifiedAt).max()
    }

    var monthTitle: String {
        PlannerFormatters.month(selectedDate, calendar: calendar)
    }

    var weekNavigatorTitle: String {
        PlannerAgendaGrouping.weekNavigatorTitle(
            for: selectedDate,
            today: .now,
            calendar: calendar
        )
    }

    var weekDates: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start
            ?? calendar.startOfDay(for: selectedDate)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var isShowingCurrentWeek: Bool {
        calendar.isDate(selectedDate, equalTo: .now, toGranularity: .weekOfYear)
    }

    func start() async {
        guard context == nil else {
            await loadWindow(resetting: true)
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            context = try await service.context()
            selectedDate = calendar.startOfDay(for: selectedDate)
            await loadWindow(resetting: true, keepingLoadingState: true)
        } catch {
            errorMessage = displayMessage(for: error)
            isLoading = false
        }
    }

    /// Loads the forward window beginning at `selectedDate` (today after a
    /// jump-to-today). Replaces the in-memory days list.
    func loadWindow(
        resetting: Bool = false,
        keepingLoadingState: Bool = false
    ) async {
        guard context != nil else {
            await start()
            return
        }
        if !keepingLoadingState { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }

        let start = calendar.startOfDay(for: selectedDate)
        let end = PlannerAgendaGrouping.windowEnd(
            from: start,
            dayCount: PlannerAgendaGrouping.defaultForwardDayCount,
            calendar: calendar
        )
        do {
            let fetched = try await service.agenda(from: start, through: end)
            days = resetting
                ? fetched
                : PlannerAgendaGrouping.merging(days, with: fetched, calendar: calendar)
            await attachEvents()
            scrollTargetDate = start
        } catch {
            if days.isEmpty {
                errorMessage = displayMessage(for: error)
            } else {
                // Keep the cached window visible and surface a dismissible error.
                errorMessage = displayMessage(for: error)
            }
        }
    }

    /// Append the next page of future days when the caregiver scrolls near the end.
    func extendForward() async {
        guard context != nil, !isLoading, !isExtending, let last = days.last else { return }
        guard let nextStart = calendar.date(byAdding: .day, value: 1, to: last.date) else {
            return
        }
        isExtending = true
        defer { isExtending = false }
        let end = PlannerAgendaGrouping.windowEnd(
            from: nextStart,
            dayCount: PlannerAgendaGrouping.pageDayCount,
            calendar: calendar
        )
        do {
            let fetched = try await service.agenda(from: nextStart, through: end)
            days = PlannerAgendaGrouping.merging(days, with: fetched, calendar: calendar)
            await attachEvents()
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    /// Prepend previous local days (PL-01 pull-past history).
    func extendBackward() async {
        guard context != nil, !isLoading, !isExtending, let first = days.first else { return }
        guard let previousEnd = calendar.date(byAdding: .day, value: -1, to: first.date) else {
            return
        }
        // pageDayCount local days ending at the day before the current first.
        let pageStart = calendar.date(
            byAdding: .day,
            value: -(PlannerAgendaGrouping.pageDayCount - 1),
            to: previousEnd
        ) ?? previousEnd

        isExtending = true
        defer { isExtending = false }
        do {
            let fetched = try await service.agenda(from: pageStart, through: previousEnd)
            days = PlannerAgendaGrouping.merging(days, with: fetched, calendar: calendar)
            await attachEvents()
            scrollTargetDate = previousEnd
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func select(_ date: Date) {
        selectedDate = calendar.startOfDay(for: date)
        if let existing = days.first(where: { calendar.isDate($0.date, inSameDayAs: selectedDate) }) {
            scrollTargetDate = existing.date
            return
        }
        Task { await loadWindow(resetting: true) }
    }

    func moveWeek(by value: Int) {
        guard let date = calendar.date(byAdding: .weekOfYear, value: value, to: selectedDate) else {
            return
        }
        // Week arrows re-anchor the forward window so browsing stays coherent.
        selectedDate = calendar.startOfDay(for: date)
        Task { await loadWindow(resetting: true) }
    }

    func moveDay(by value: Int) {
        guard let date = calendar.date(byAdding: .day, value: value, to: selectedDate) else {
            return
        }
        select(date)
    }

    func jumpToToday() {
        selectedDate = calendar.startOfDay(for: .now)
        Task { await loadWindow(resetting: true) }
    }

    func consumeScrollTarget() {
        scrollTargetDate = nil
    }

    func newTask(on date: Date? = nil) {
        let taskDate = calendar.startOfDay(for: date ?? selectedDate)
        editorRoute = PlannerEditorRoute(
            draft: PlannerTaskDraft(
                petId: pets.count == 1 ? pets[0].id : nil,
                date: taskDate
            ),
            scope: nil
        )
    }

    func edit(_ item: PlannerAgendaItem) {
        editorRoute = PlannerEditorRoute(
            draft: item.editableDraft(),
            scope: item.isRecurring ? .occurrenceOnly : nil
        )
    }

    func save(_ draft: PlannerTaskDraft, scope: PlannerEditScope?) async throws {
        isSaving = true
        defer { isSaving = false }
        let result = try await service.save(draft, scope: scope)
        confirmationMessage = result == .queued
            ? "Change queued. It will sync when the household is reachable."
            : draft.isEditing ? "Task updated." : "Task added."
        await refreshVisibleWindow()
    }

    func perform(_ action: PlannerTaskAction, on item: PlannerAgendaItem) async throws {
        isSaving = true
        defer { isSaving = false }
        let result = try await service.perform(action, on: item)
        confirmationMessage = result == .queued
            ? "Change queued. It will sync when the household is reachable."
            : confirmation(for: action)
        await refreshVisibleWindow()
    }

    func history(for item: PlannerAgendaItem) async throws -> [PlannerHistoryEntry] {
        try await service.history(for: item)
    }

    func can(_ action: PlannerTaskAction, for item: PlannerAgendaItem) -> Bool {
        if item.state == .stale { return false }
        switch action {
        case .complete:
            return capabilities.contains(.complete) && item.state == .pending
        case .undoComplete:
            return capabilities.contains(.undoComplete) && item.state == .completed
        case .skip:
            return capabilities.contains(.skip) && item.state == .pending
        case .undoSkip:
            return capabilities.contains(.undoSkip) && item.state == .skipped
        case .snooze:
            return capabilities.contains(.snooze) && item.state == .pending
        case .reschedule:
            return capabilities.contains(.reschedule) && item.state == .pending
        case .cancel:
            return capabilities.contains(.cancel)
                && item.state != .cancelled
                && item.state != .completed
        }
    }

    func assignmentName(for kind: PlannerMemberOption.Kind) -> String {
        members.first(where: { $0.kind == kind })?.name ?? "Anyone"
    }

    func clearError() {
        errorMessage = nil
    }

    func clearConfirmation() {
        confirmationMessage = nil
    }

    /// Seeds month-jump dots from the loaded window, then fetches the visible
    /// month so days outside the current agenda still show markers.
    func refreshMonthJumpMarkers(for month: Date) async {
        var content = PlannerAgendaGrouping.datesWithContent(from: days, calendar: calendar)
        // Publish the loaded-window seed immediately so the sheet is not blank
        // while the month fetch is in flight.
        monthJumpContentDates = content

        guard context != nil,
              let bounds = PlannerAgendaGrouping.monthBounds(for: month, calendar: calendar)
        else { return }

        do {
            let fetched = try await service.agenda(from: bounds.start, through: bounds.end)
            content.formUnion(
                PlannerAgendaGrouping.datesWithContent(from: fetched, calendar: calendar)
            )

            if let eventService, let householdId {
                let loaded = try await eventService.loadEvents(householdId: householdId)
                let projected = loaded.map {
                    PlannerAgendaEvent.from($0, petName: nil, calendar: calendar)
                }
                content.formUnion(
                    PlannerAgendaGrouping.eventContentDates(
                        from: projected,
                        from: bounds.start,
                        through: bounds.end,
                        calendar: calendar
                    )
                )
            }
            monthJumpContentDates = content
        } catch {
            // Keep the loaded-window seed; month fetch is best-effort.
        }
    }

    func sectionHeading(for day: PlannerDayAgenda) -> String {
        PlannerAgendaGrouping.sectionHeading(for: day.date, today: .now, calendar: calendar)
    }

    func allowsInlineAdd(on day: PlannerDayAgenda) -> Bool {
        capabilities.contains(.createOneTime)
            && PlannerAgendaGrouping.allowsInlineAdd(on: day.date, today: .now, calendar: calendar)
    }

    func entries(for day: PlannerDayAgenda) -> [PlannerAgendaEntry] {
        PlannerAgendaGrouping.entries(for: day, calendar: calendar)
    }

    /// Reload the currently visible range after a mutation or pull-to-refresh
    /// without jumping the caregiver back to the window start.
    func refreshVisibleWindow() async {
        guard let first = days.first, let last = days.last else {
            await loadWindow(resetting: true)
            return
        }
        do {
            let fetched = try await service.agenda(from: first.date, through: last.date)
            days = fetched
            await attachEvents()
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    /// Pull-past history page, then re-read the visible range.
    func refreshFromPull() async {
        await extendBackward()
        await refreshVisibleWindow()
    }

    /// Overlays confirmed household events onto the loaded day window.
    /// Failures are soft: task rows stay; events simply omit rather than
    /// replacing a healthy agenda with an error empty state.
    private func attachEvents() async {
        guard let eventService, let householdId, !days.isEmpty else {
            // Clear stale event rows when the service is unavailable.
            if eventService == nil || householdId == nil {
                days = days.map { day in
                    var copy = day
                    copy.events = []
                    return copy
                }
            }
            return
        }
        do {
            let loaded = try await eventService.loadEvents(householdId: householdId)
            let petNames = Dictionary(uniqueKeysWithValues: pets.map { ($0.id, $0.name) })
            let projected = loaded.map { event in
                PlannerAgendaEvent.from(
                    event,
                    petName: event.petId.flatMap { petNames[$0] },
                    calendar: calendar
                )
            }
            days = PlannerAgendaGrouping.attaching(
                events: projected,
                to: days,
                calendar: calendar
            )
        } catch {
            // Keep any previously attached events if a refresh fails mid-session.
        }
    }

    private func confirmation(for action: PlannerTaskAction) -> String {
        switch action {
        case .complete: "Task completed."
        case .undoComplete: "Completion undone."
        case .skip: "Skipped. It won't carry over."
        case .undoSkip: "Skip undone."
        case .snooze: "Reminder emphasis moved later today."
        case .reschedule: "Task rescheduled."
        case .cancel: "Task cancelled. Its history is still available."
        }
    }

    private func displayMessage(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty
            ? "Planner couldn't confirm that change. Nothing was replaced."
            : message
    }
}

struct PlannerEditorRoute: Identifiable, Equatable {
    let id = UUID()
    var draft: PlannerTaskDraft
    var scope: PlannerEditScope?
}
