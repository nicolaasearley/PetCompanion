import Foundation
import Observation

@MainActor
@Observable
final class PlannerStore {
    private let service: any PlannerService

    private(set) var context: PlannerContext?
    private(set) var agenda: PlannerDayAgenda?
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    var confirmationMessage: String?
    var selectedDate: Date
    var detailItem: PlannerAgendaItem?
    var editorRoute: PlannerEditorRoute?
    var showMonthJump = false

    init(service: any PlannerService, initialDate: Date = .now) {
        self.service = service
        selectedDate = initialDate
    }

    var calendar: Calendar { context?.calendar ?? .current }
    var capabilities: PlannerCapabilities { context?.capabilities ?? [] }
    var pets: [Pet] { context?.pets ?? [] }
    var members: [PlannerMemberOption] { context?.members ?? [.anyone] }
    var items: [PlannerAgendaItem] { agenda?.items ?? [] }
    var isStale: Bool { agenda?.isStale == true }

    var selectedDayTitle: String {
        PlannerFormatters.relativeDay(selectedDate, today: .now, calendar: calendar)
    }

    var selectedDaySubtitle: String {
        PlannerFormatters.fullDay(selectedDate, calendar: calendar)
    }

    var monthTitle: String {
        PlannerFormatters.month(selectedDate, calendar: calendar)
    }

    var weekDates: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start
            ?? calendar.startOfDay(for: selectedDate)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    func start() async {
        guard context == nil else {
            await loadSelectedDay()
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            context = try await service.context()
            selectedDate = calendar.startOfDay(for: selectedDate)
            await loadSelectedDay(keepingLoadingState: true)
        } catch {
            errorMessage = displayMessage(for: error)
            isLoading = false
        }
    }

    func loadSelectedDay(keepingLoadingState: Bool = false) async {
        guard context != nil else {
            await start()
            return
        }
        if !keepingLoadingState { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        do {
            agenda = try await service.agenda(on: selectedDate)
        } catch {
            agenda = nil
            errorMessage = displayMessage(for: error)
        }
    }

    func select(_ date: Date) {
        selectedDate = calendar.startOfDay(for: date)
        Task { await loadSelectedDay() }
    }

    func moveWeek(by value: Int) {
        guard let date = calendar.date(byAdding: .weekOfYear, value: value, to: selectedDate) else {
            return
        }
        select(date)
    }

    func moveDay(by value: Int) {
        guard let date = calendar.date(byAdding: .day, value: value, to: selectedDate) else {
            return
        }
        select(date)
    }

    func jumpToToday() {
        select(.now)
    }

    func newTask() {
        editorRoute = PlannerEditorRoute(
            draft: PlannerTaskDraft(
                petId: pets.count == 1 ? pets[0].id : nil,
                date: selectedDate
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
        await loadSelectedDay()
    }

    func perform(_ action: PlannerTaskAction, on item: PlannerAgendaItem) async throws {
        isSaving = true
        defer { isSaving = false }
        let result = try await service.perform(action, on: item)
        confirmationMessage = result == .queued
            ? "Change queued. It will sync when the household is reachable."
            : confirmation(for: action)
        await loadSelectedDay()
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
