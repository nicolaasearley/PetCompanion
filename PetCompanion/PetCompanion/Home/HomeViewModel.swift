import SwiftUI
import Observation
import UIKit

/// State and interactions for HM-01. Optimistic-by-design: actions render
/// instantly against the mock service and the same call sites will drive
/// the queued write path later (US-107).
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

    private var memberNames: [UUID: String] = [:]

    /// Single-user mock state is always verified; the line stays silent
    /// (doc 09 §7.8). The stale/queued cases light up with the real sync
    /// layer in WP-5.
    let syncStatus: SyncStatus = .current

    init(model: AppModel) {
        self.model = model
    }

    var pet: Pet? { model.activePet }
    var greetingName: String? { model.currentUser?.displayName }
    var capacityMode: CapacityMode { snapshot?.plan.capacityModeApplied ?? .normal }

    var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case ..<12: "Good morning"
        case ..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    // MARK: - Loading

    /// First load of the day's plan — completed items stay in their
    /// generated sections.
    func loadInitial() async {
        guard snapshot == nil, let pet else { return }
        isLoading = true
        defer { isLoading = false }
        await loadMembers()
        snapshot = try? await model.plans.plan(forPet: pet.id, on: Date(), resectioningCompleted: false)
    }

    /// A natural list update (pull-to-refresh, returning to the tab):
    /// completed items move to the Completed section (doc 09 §8).
    func refresh() async {
        guard let pet else { return }
        await loadMembers()
        if let refreshed = try? await model.plans.plan(forPet: pet.id, on: Date(), resectioningCompleted: true) {
            snapshot = refreshed
        }
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
                AccessibilityNotification.Announcement("\(item.title) completed").post()
            } catch {
                errorMessage = error.localizedDescription
            }
            completingItemIds.remove(item.id)
        }
    }

    private func undo(_ item: PlanItem) {
        guard let pet else { return }
        Task {
            do {
                snapshot = try await model.plans.undoCompletion(itemId: item.id, petId: pet.id, on: Date())
                AccessibilityNotification.Announcement("\(item.title) completion undone").post()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Capacity (HM-04)

    func applyCapacity(_ mode: CapacityMode, scope: CapacityScope) {
        guard let pet else { return }
        Task {
            do {
                snapshot = try await model.plans.setCapacity(mode, scope: scope, petId: pet.id, on: Date())
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Quick add (US-050 minimal path)

    func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        newTaskTitle = ""
        guard !title.isEmpty, let pet else { return }
        Task {
            do {
                snapshot = try await model.plans.addOneTimeTask(title: title, petId: pet.id, on: Date())
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func signOut() {
        model.signOut()
    }

    // MARK: - Display helpers

    func cardState(for item: PlanItem) -> PlanItemCard.CardState {
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
        let time = completion.effectiveAt.formatted(date: .omitted, time: .shortened)
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
            let day = Self.upcomingDayText(occurrence.localDueDate)
            if occurrence.timePolicy == .exactTime, let dueTime = occurrence.dueTime {
                return "\(day) \(dueTime.formatted(date: .omitted, time: .shortened))"
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
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
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
