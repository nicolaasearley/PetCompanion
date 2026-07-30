import SwiftUI
import Observation
import UIKit

/// State and interactions for HM-01. Server confirmation remains visible and
/// failures are never mistaken for successful household writes.
@MainActor
@Observable
final class HomeViewModel {
    private let model: AppModel

    /// Home does not own the plan. Planner acts on the same day's work, so
    /// the snapshot lives in shared app state and both surfaces observe the
    /// one value (doc 19).
    var snapshot: PlanSnapshot? {
        get { model.planState.snapshot }
        set { model.planState.snapshot = newValue }
    }

    var isLoading = false
    var errorMessage: String?
    /// Items currently playing the completing animation.
    var completingItemIds: Set<UUID> = []
    var completedExpanded = false
    /// Recommended / Coming up start collapsed so Today stays the first read.
    var recommendedExpanded = false
    var comingUpExpanded = false
    var showCapacitySheet = false
    var detailItem: PlanItem?
    var showAddTask = false
    var newTaskTitle = ""
    var isSubmitting = false
    /// US-033: after a completion, offer a short-lived visible undo on Home.
    var undoBanner: UndoBanner?
    /// Interim Care surface until engine medication obligations land.
    var upcomingCare: [UpcomingCareItem] = []
    var careDestination: CareDestination?

    struct UndoBanner: Equatable, Identifiable {
        let id: UUID
        let title: String
    }

    struct UpcomingCareItem: Identifiable, Equatable {
        enum Kind: Equatable {
            case medication
            case appointment
        }
        let id: UUID
        let kind: Kind
        let title: String
        let subtitle: String
    }

    enum CareDestination: Identifiable, Equatable {
        case medications
        case appointments

        var id: String {
            switch self {
            case .medications: "medications"
            case .appointments: "appointments"
            }
        }
    }

    private var memberNames: [UUID: String] = [:]
    private var lastVerifiedAt: Date?
    private var isStale = false
    private var undoBannerClearTask: Task<Void, Never>?

    var syncStatus: SyncStatus {
        if let pending = model.mutationQueue?.status.pendingCount, pending > 0 {
            return .queued(count: pending)
        }
        if isStale {
            return .stale(lastSynced: lastVerifiedAt ?? snapshot?.plan.generatedAt ?? .now)
        }
        return .current
    }

    init(model: AppModel) {
        self.model = model
    }

    var pet: Pet? { model.activePet }
    var greetingName: String? { model.currentUser?.displayName }
    var capacityMode: CapacityMode { snapshot?.plan.capacityModeApplied ?? .normal }
    private var clock: HouseholdClock {
        model.household?.clock ?? HouseholdClock(timeZone: .current)
    }
    var householdCalendar: Calendar { clock.calendar }
    var hasInitialLoadFailure: Bool {
        snapshot == nil && !isLoading && errorMessage != nil
    }

    var greeting: String {
        switch clock.calendar.component(.hour, from: Date()) {
        case ..<12: "Good morning"
        case ..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    var petAgeAndStage: String? {
        pet?.ageAndStageDisplay(calendar: clock.calendar)
    }

    var daysUntilHomecoming: Int? {
        pet?.daysUntilHomecoming(calendar: clock.calendar)
    }

    var todayDisplay: String {
        Self.dayDisplay(Date(), calendar: clock.calendar)
    }

    // MARK: - Loading

    /// First load of the day's plan — completed items stay in their
    /// generated sections.
    func loadInitial() async {
        guard snapshot == nil, !isLoading, let pet else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await loadMembers()
        do {
            snapshot = try await model.plans.plan(
                forPet: pet.id,
                on: Date(),
                resectioningCompleted: false
            )
            updateVerificationState()
            await loadUpcomingCare()
        } catch {
            errorMessage = Self.displayMessage(for: error)
        }
    }

    /// A natural list update (pull-to-refresh, returning to the tab):
    /// completed items move to the Completed section (doc 09 §8).
    func refresh() async {
        guard let pet else { return }
        errorMessage = nil
        await loadMembers()
        do {
            let refreshed = try await model.plans.plan(
                forPet: pet.id,
                on: Date(),
                resectioningCompleted: true
            )
            snapshot = refreshed
            updateVerificationState()
            await loadUpcomingCare()
        } catch {
            errorMessage = Self.displayMessage(for: error)
            if snapshot != nil {
                isStale = true
            }
            await loadUpcomingCare()
        }
    }

    /// SharedPlanState already holds the remote snapshot; refresh local
    /// verification bookkeeping so SyncStatus stays truthful.
    func acknowledgeRemoteReconciliation() {
        updateVerificationState()
        errorMessage = nil
    }

    func retryInitialLoad() {
        Task { await loadInitial() }
    }

    func clearError() {
        errorMessage = nil
    }

    /// Opens the detail for an item a caller has already resolved against the
    /// current plan (a tapped reminder, IA §10). The sheet shows whatever the
    /// plan says now — completed included — rather than what the reminder
    /// assumed when it was scheduled.
    func openDetail(itemId: UUID) {
        detailItem = snapshot?.items.first { $0.id == itemId }
    }

    private func loadMembers() async {
        guard let household = model.household else { return }
        if let members = try? await model.households.members(householdId: household.id) {
            memberNames = Dictionary(uniqueKeysWithValues: members.map { ($0.userId, $0.displayName) })
        }
    }

    /// Next medication dues + next confirmed appointment — Care/Events reads,
    /// not engine obligations (handoff: medication plan rules still deferred).
    private func loadUpcomingCare() async {
        var items: [UpcomingCareItem] = []
        let calendar = clock.calendar
        let today = calendar.startOfDay(for: Date())

        if let pet, let care = model.care,
           let schedules = try? await care.loadMedicationSchedules(petId: pet.id) {
            let upcoming = schedules
                .compactMap { schedule -> UpcomingCareItem? in
                    guard schedule.status == .active, let next = schedule.nextDue else { return nil }
                    return UpcomingCareItem(
                        id: next.occurrenceId,
                        kind: .medication,
                        title: schedule.medicationName,
                        subtitle: next.dueSummary(relativeTo: today, calendar: calendar)
                    )
                }
                .sorted { $0.subtitle < $1.subtitle }
                .prefix(2)
            items.append(contentsOf: upcoming)
        }

        if let household = model.household, let events = model.events,
           let loaded = try? await events.loadEvents(householdId: household.id) {
            let next = loaded
                .filter { !$0.isCancelled && calendar.startOfDay(for: $0.startDate) >= today }
                .sorted {
                    if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                    return ($0.startTime ?? "") < ($1.startTime ?? "")
                }
                .prefix(2)
                .map {
                    UpcomingCareItem(
                        id: $0.id,
                        kind: .appointment,
                        title: $0.title,
                        subtitle: $0.whenSummary
                    )
                }
            items.append(contentsOf: next)
        }

        upcomingCare = Array(items.prefix(3))
    }

    func openUpcomingCare(_ item: UpcomingCareItem) {
        switch item.kind {
        case .medication: careDestination = .medications
        case .appointment: careDestination = .appointments
        }
    }

    // MARK: - Complete / undo

    func toggleCompletion(of item: PlanItem) {
        guard let snapshot else { return }
        if snapshot.isCompleted(item) {
            undo(item)
        } else {
            complete(item)
        }
    }

    private func complete(_ item: PlanItem) {
        guard let pet, !completingItemIds.contains(item.id) else { return }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        completingItemIds.insert(item.id)
        Task {
            // Checkmark draw + settle (~200 ms); an instant state change
            // under reduced motion (doc 09 §8, US-105).
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(220))
            }
            do {
                snapshot = try await model.plans.completeItem(itemId: item.id, petId: pet.id, on: Date())
                updateVerificationState()
                presentUndoBanner(for: item)
                // If a natural list update already moved this into Completed,
                // expand so undo stays one tap away.
                if snapshot?.items.contains(where: { $0.id == item.id && $0.section == .completed }) == true {
                    completedExpanded = true
                }
                AccessibilityNotification.Announcement("\(item.title) completed. Undo available.").post()
            } catch {
                errorMessage = Self.displayMessage(for: error)
            }
            completingItemIds.remove(item.id)
        }
    }

    private func undo(_ item: PlanItem) {
        guard let pet else { return }
        Task {
            do {
                snapshot = try await model.plans.undoCompletion(itemId: item.id, petId: pet.id, on: Date())
                updateVerificationState()
                clearUndoBanner(matching: item.id)
                AccessibilityNotification.Announcement("\(item.title) completion undone").post()
            } catch {
                errorMessage = Self.displayMessage(for: error)
            }
        }
    }

    func undoFromBanner() {
        guard let banner = undoBanner,
              let item = snapshot?.items.first(where: { $0.id == banner.id })
        else {
            clearUndoBanner()
            return
        }
        undo(item)
    }

    func dismissUndoBanner() {
        clearUndoBanner()
    }

    private func presentUndoBanner(for item: PlanItem) {
        undoBannerClearTask?.cancel()
        undoBanner = UndoBanner(id: item.id, title: item.title)
        undoBannerClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            if undoBanner?.id == item.id {
                undoBanner = nil
            }
        }
    }

    private func clearUndoBanner(matching id: UUID? = nil) {
        if let id, undoBanner?.id != id { return }
        undoBannerClearTask?.cancel()
        undoBannerClearTask = nil
        undoBanner = nil
    }

    // MARK: - Capacity (HM-04)

    func applyCapacity(_ mode: CapacityMode, scope: CapacityScope) {
        guard let pet, !isSubmitting else { return }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                snapshot = try await model.plans.setCapacity(mode, scope: scope, petId: pet.id, on: Date())
                updateVerificationState()
            } catch {
                errorMessage = Self.displayMessage(for: error)
            }
        }
    }

    // MARK: - Recommendation acceptance

    func acceptRecommendation(_ item: PlanItem) async throws {
        guard let pet,
              item.kind == .recommendation,
              item.occurrenceId == nil,
              !isSubmitting
        else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            snapshot = try await model.plans.acceptRecommendation(
                itemId: item.id,
                petId: pet.id,
                on: Date()
            )
            updateVerificationState()
            AccessibilityNotification.Announcement("\(item.title) added to today").post()
        } catch {
            errorMessage = Self.displayMessage(for: error)
            throw error
        }
    }

    // MARK: - Quick add (US-050 minimal path)

    func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let pet, !isSubmitting else { return }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                snapshot = try await model.plans.addOneTimeTask(title: title, petId: pet.id, on: Date())
                newTaskTitle = ""
                updateVerificationState()
                AccessibilityNotification.Announcement("\(title) added to today").post()
            } catch {
                errorMessage = Self.displayMessage(for: error)
            }
        }
    }

    func signOut() {
        model.signOut()
    }

    // MARK: - Display helpers

    func cardState(for item: PlanItem) -> PlanItemCard.CardState {
        // Cache-served items are marked `.stale` for sync honesty, but
        // complete/undo must still queue (US-058). Never map that cue to
        // `.disabled` for actionable plan rows.
        if completingItemIds.contains(item.id) {
            return .completing
        }
        if let snapshot, snapshot.isCompleted(item) {
            return .completed(attribution: attribution(for: item))
        }
        switch item.displayState {
        case .queued: return .queued
        case .stale, .normal: return .normal
        }
    }

    /// "by Sarah, 7:42 AM" — factual attribution copy (doc 09 §9).
    func attribution(for item: PlanItem) -> String? {
        guard let snapshot, let completion = snapshot.effectiveCompletion(for: item) else {
            return nil
        }
        let name = memberNames[completion.actorUserId] ?? "a caregiver"
        let time = Self.timeDisplay(completion.effectiveAt, calendar: clock.calendar)
        return "by \(name), \(time)"
    }

    func meta(for item: PlanItem) -> String? {
        guard let snapshot else { return nil }
        if snapshot.isCompleted(item) {
            return nil // attribution renders in the meta position
        }
        switch item.section {
        case .recommended:
            // Category lives in the leading glyph; keep meta to effort only.
            return item.effortBand?.displayText
        case .comingUp:
            guard let occurrence = snapshot.occurrence(for: item) else { return nil }
            let day = Self.upcomingDayText(occurrence.localDueDate, calendar: clock.calendar)
            if occurrence.timePolicy == .exactTime, let dueTime = occurrence.dueTime {
                return "\(day) \(Self.timeDisplay(dueTime, calendar: clock.calendar))"
            }
            if item.category == .preparation {
                return "prepare by \(day)"
            }
            return day
        case .needsAttention:
            return nil
        case .today, .completed:
            return nil
        }
    }

    /// "Fri" within the next week, "Aug 8" beyond it.
    private static func upcomingDayText(_ date: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        if days < 7 {
            return dayFormatter(calendar: calendar, template: "EEE").string(from: date)
        }
        return dayFormatter(calendar: calendar, template: "MMM d").string(from: date)
    }

    private static func dayDisplay(_ date: Date, calendar: Calendar) -> String {
        dayFormatter(calendar: calendar, template: "EEEE MMMM d").string(from: date)
    }

    private static func timeDisplay(_ date: Date, calendar: Calendar) -> String {
        dayFormatter(calendar: calendar, template: "jm").string(from: date)
    }

    private static func dayFormatter(calendar: Calendar, template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static func displayMessage(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty
            ? "Settle couldn't update the household right now. Please try again."
            : message
    }

    private func updateVerificationState() {
        isStale = snapshot?.servedFromCacheAt != nil
        if !isStale {
            lastVerifiedAt = .now
        } else if lastVerifiedAt == nil {
            lastVerifiedAt = snapshot?.plan.generatedAt
        }
    }

    /// Today items grouped into broad windows when useful (engine §6.2).
    func windowGroups(for items: [PlanItem]) -> [(window: PlanTimeWindow?, items: [PlanItem])] {
        if items.allSatisfy({ $0.timeWindow == nil }) {
            return [(nil, items)]
        }
        var groups: [(PlanTimeWindow?, [PlanItem])] = []
        for window in PlanTimeWindow.allCases {
            let windowItems = items.filter { $0.timeWindow == window }
            if !windowItems.isEmpty {
                groups.append((window, windowItems))
            }
        }
        let unwindowed = items.filter { $0.timeWindow == nil }
        if !unwindowed.isEmpty {
            groups.append((nil, unwindowed))
        }
        return groups
    }
}
