import SwiftUI
import Observation
import UIKit

/// State and interactions for HM-01. Server confirmation remains visible and
/// failures are never mistaken for successful household writes.
@MainActor
@Observable
final class HomeViewModel {
    private let model: AppModel

    var snapshot: PlanSnapshot?
    var isLoading = false
    var errorMessage: String?
    /// Items currently playing the completing animation.
    var completingItemIds: Set<UUID> = []
    var completedExpanded = false
    var showCapacitySheet = false
    var detailItem: PlanItem?
    var showAddTask = false
    var newTaskTitle = ""
    var isSubmitting = false

    private var memberNames: [UUID: String] = [:]
    private var lastVerifiedAt: Date?
    private var isStale = false

    var syncStatus: SyncStatus {
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
        } catch {
            errorMessage = Self.displayMessage(for: error)
            if snapshot != nil {
                isStale = true
            }
        }
    }

    func retryInitialLoad() {
        Task { await loadInitial() }
    }

    func clearError() {
        errorMessage = nil
    }

    private func loadMembers() async {
        guard let household = model.household else { return }
        if let members = try? await model.households.members(householdId: household.id) {
            memberNames = Dictionary(uniqueKeysWithValues: members.map { ($0.userId, $0.displayName) })
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
                AccessibilityNotification.Announcement("\(item.title) completed").post()
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
                AccessibilityNotification.Announcement("\(item.title) completion undone").post()
            } catch {
                errorMessage = Self.displayMessage(for: error)
            }
        }
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
        if item.displayState == .stale {
            return .disabled
        }
        if completingItemIds.contains(item.id) {
            return .completing
        }
        if let snapshot, snapshot.isCompleted(item) {
            return .completed(attribution: attribution(for: item))
        }
        switch item.displayState {
        case .queued: return .queued
        case .stale: return .disabled
        case .normal: return .normal
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
            if let effort = item.effortBand {
                return "\(item.category.displayName) · \(effort.displayText)"
            }
            return item.category.displayName
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
            return item.category.displayName
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
            ? "PetCompanion couldn't update the household right now. Please try again."
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
