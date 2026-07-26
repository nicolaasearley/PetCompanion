import Foundation

/// In-memory stand-in for the Supabase backend, shared by the mock
/// services so auth, household, and plan state stay consistent.
///
/// Plan fixtures follow the engine spec doc 12 §26 example plans:
/// §26.1 (pre-arrival) and §26.2 (normal day with a 10-week-old puppy),
/// with the pet name "Maple".
@MainActor
final class MockBackend {
    // MARK: - State

    private(set) var users: [UUID: UserAccount] = [:]
    var currentUserId: UUID?
    var household: Household?
    private(set) var members: [HouseholdMember] = []
    private(set) var pets: [Pet] = []
    var routinePreferences: HouseholdPreference?

    private var snapshots: [String: PlanSnapshot] = [:]
    /// Full eligible recommendation pool per plan, so capacity changes can
    /// re-filter without regenerating obligations.
    private var recommendationPools: [String: [PlanItem]] = [:]
    /// The caregiver partner ("Sarah" in the §26 fixtures) used for
    /// attributed sample completions.
    private(set) var partnerId = UUID()
    /// The section an item lived in immediately before a completion moved
    /// it to `.completed`, keyed by `PlanItem.id` — so undoing a completion
    /// restores the original section (e.g. `recommended`) instead of always
    /// landing in `.today` (B5).
    private var preCompletionSection: [UUID: PlanSection] = [:]

    let calendar = Calendar.current

    var currentUser: UserAccount? {
        currentUserId.flatMap { users[$0] }
    }

    // MARK: - Auth

    /// Find-or-create by email; display name derived from the address.
    @discardableResult
    func signIn(email: String) -> UserAccount {
        let name = Self.displayName(fromEmail: email)
        if let existing = users.values.first(where: { $0.displayName == name }) {
            currentUserId = existing.id
            return existing
        }
        let user = UserAccount(displayName: name)
        users[user.id] = user
        currentUserId = user.id
        return user
    }

    static func displayName(fromEmail email: String) -> String {
        let local = email.split(separator: "@").first ?? "Caregiver"
        let first = local.split(whereSeparator: { ".+-_".contains($0) }).first ?? local
        return first.prefix(1).uppercased() + first.dropFirst().lowercased()
    }

    // MARK: - Household

    /// Idempotent per owner: retrying never produces a duplicate
    /// membership (US-010).
    @discardableResult
    func createHousehold(name: String, timeZone: String, ownerId: UUID) -> Household {
        if let household, household.createdBy == ownerId {
            return household
        }
        let created = Household(name: name, timeZone: timeZone, createdBy: ownerId)
        household = created

        let ownerName = users[ownerId]?.displayName ?? "Caregiver"
        let partnerName = ownerName == "Sarah" ? "Nic" : "Sarah"
        let partner = UserAccount(id: partnerId, displayName: partnerName)
        users[partner.id] = partner
        members = [
            HouseholdMember(userId: ownerId, displayName: ownerName, role: .owner),
            HouseholdMember(userId: partner.id, displayName: partnerName, role: .caregiver),
        ]
        return created
    }

    @discardableResult
    func createPet(name: String, birthInfo: BirthInfo, homecomingDate: Date?) -> Pet {
        guard let household else {
            preconditionFailure("Household must exist before creating a pet")
        }
        let pet = Pet(
            householdId: household.id,
            name: name,
            birthInfo: birthInfo,
            homecomingDate: homecomingDate
        )
        pets.append(pet)
        return pet
    }

    /// Slice A WP-2: registers an already-existing household/pet — from the
    /// real local Supabase backend, in `.local` mode — under their real
    /// ids. `PlanService` intentionally stays mock in every backend mode
    /// (plan generation isn't built yet, doc 17 WP-3/WP-4), so `AppModel`
    /// calls this whenever `household`/`activePet` change so `generatePlan`
    /// finds a pet with the id `HomeViewModel` actually requests instead of
    /// hitting the "must exist" precondition against an empty backend.
    /// This intentionally does NOT touch `members`/`users` — Home doesn't
    /// need them for the mock plan fixtures.
    func adopt(household: Household, pet: Pet) {
        self.household = household
        if let index = pets.firstIndex(where: { $0.id == pet.id }) {
            pets[index] = pet
        } else {
            pets.append(pet)
        }
    }

    // MARK: - Plans

    private func planKey(petId: UUID, date: Date) -> String {
        "\(petId.uuidString)|\(calendar.startOfDay(for: date).timeIntervalSinceReferenceDate)"
    }

    func planSnapshot(petId: UUID, date: Date, resectioningCompleted: Bool) -> PlanSnapshot {
        let key = planKey(petId: petId, date: date)
        var snapshot = snapshots[key] ?? generatePlan(petId: petId, date: date)
        if resectioningCompleted {
            resection(&snapshot)
            snapshots[key] = snapshot
        }
        return snapshot
    }

    /// The "next natural list update": completed items move to the
    /// Completed section; undone items return to their original section —
    /// `.today` for an obligation, `.recommended` for an accepted
    /// recommendation (doc 09 §8, B5).
    private func resection(_ snapshot: inout PlanSnapshot) {
        for index in snapshot.items.indices {
            guard let occurrence = snapshot.occurrence(for: snapshot.items[index]),
                  snapshot.items[index].kind != .upcomingPreview,
                  snapshot.items[index].kind != .informational
            else { continue }
            let itemId = snapshot.items[index].id
            if occurrence.state == .completed {
                if snapshot.items[index].section != .completed {
                    preCompletionSection[itemId] = snapshot.items[index].section
                }
                snapshot.items[index].section = .completed
            } else if occurrence.state == .pending, snapshot.items[index].section == .completed {
                snapshot.items[index].section = preCompletionSection.removeValue(forKey: itemId) ?? .today
            }
        }
    }

    func complete(itemId: UUID, petId: UUID, date: Date) throws -> PlanSnapshot {
        guard let actorId = currentUserId else { throw PlanServiceError.notSignedIn }
        let key = planKey(petId: petId, date: date)
        guard var snapshot = snapshots[key] else { throw PlanServiceError.planNotFound }
        guard let index = snapshot.items.firstIndex(where: { $0.id == itemId }) else {
            throw PlanServiceError.itemNotFound
        }

        var item = snapshot.items[index]

        // Accepting a recommendation promotes it to a real occurrence so all
        // completions share one history and attribution model (doc 10 §10.3).
        if item.occurrenceId == nil {
            let origin: TaskOrigin = switch item.category {
            case .training: .trainingProgram
            case .socialization: .socializationRule
            default: .developmentRule
            }
            let occurrence = TaskOccurrence(
                occurrenceKey: "accepted:\(item.itemKey)",
                householdId: snapshot.plan.householdId,
                petId: petId,
                localDueDate: calendar.startOfDay(for: date),
                timePolicy: .anytime,
                window: item.timeWindow,
                obligationClass: item.obligationClass,
                origin: origin
            )
            snapshot.occurrences.append(occurrence)
            item.occurrenceId = occurrence.id
        }

        guard let occurrenceIndex = snapshot.occurrences.firstIndex(where: { $0.id == item.occurrenceId }) else {
            throw PlanServiceError.itemNotFound
        }
        snapshot.occurrences[occurrenceIndex].state = .completed
        snapshot.dispositions.append(
            Disposition(occurrenceId: snapshot.occurrences[occurrenceIndex].id, action: .complete, actorUserId: actorId)
        )
        // The item keeps its section: a completed card stays inline until
        // the next natural list update (engine §4.3, doc 09 §8).
        snapshot.items[index] = item
        snapshots[key] = snapshot
        return snapshot
    }

    func undoCompletion(itemId: UUID, petId: UUID, date: Date) throws -> PlanSnapshot {
        guard let actorId = currentUserId else { throw PlanServiceError.notSignedIn }
        let key = planKey(petId: petId, date: date)
        guard var snapshot = snapshots[key] else { throw PlanServiceError.planNotFound }
        guard let item = snapshot.items.first(where: { $0.id == itemId }),
              let occurrenceIndex = snapshot.occurrences.firstIndex(where: { $0.id == item.occurrenceId })
        else { throw PlanServiceError.itemNotFound }

        let occurrenceId = snapshot.occurrences[occurrenceIndex].id
        for index in snapshot.dispositions.indices
        where snapshot.dispositions[index].occurrenceId == occurrenceId
            && snapshot.dispositions[index].action == .complete {
            snapshot.dispositions[index].superseded = true
        }
        snapshot.dispositions.append(
            Disposition(occurrenceId: occurrenceId, action: .undoComplete, actorUserId: actorId)
        )
        snapshot.occurrences[occurrenceIndex].state = .pending
        snapshots[key] = snapshot
        return snapshot
    }

    func setCapacity(_ mode: CapacityMode, scope: CapacityScope, petId: UUID, date: Date) -> PlanSnapshot {
        if scope == .householdDefault {
            household?.defaultCapacityMode = mode
        }
        let key = planKey(petId: petId, date: date)
        var snapshot = snapshots[key] ?? generatePlan(petId: petId, date: date)
        snapshot.plan.capacityModeApplied = mode
        snapshot.plan.planVersion += 1

        // Re-filter unaccepted recommendations against the new budget.
        // Accepted (promoted) recommendations and all required/scheduled
        // items are visibly unaffected (HM-04).
        let pool = recommendationPools[key] ?? []
        let acceptedIds = Set(
            snapshot.items
                .filter { $0.kind == .recommendation && $0.occurrenceId != nil }
                .map(\.id)
        )
        let budgetLeft = max(0, mode.recommendationBudget - acceptedIds.count)
        let visible = pool.filter { !acceptedIds.contains($0.id) }.prefix(budgetLeft)
        snapshot.items.removeAll { $0.kind == .recommendation && $0.occurrenceId == nil }
        snapshot.items.append(contentsOf: visible)

        snapshots[key] = snapshot
        return snapshot
    }

    func addOneTimeTask(title: String, petId: UUID, date: Date) throws -> PlanSnapshot {
        let key = planKey(petId: petId, date: date)
        var snapshot = snapshots[key] ?? generatePlan(petId: petId, date: date)
        let localDate = calendar.startOfDay(for: date)
        let occurrence = TaskOccurrence(
            occurrenceKey: "user:\(UUID().uuidString)",
            householdId: snapshot.plan.householdId,
            petId: petId,
            localDueDate: localDate,
            timePolicy: .anytime,
            window: .anytime,
            obligationClass: .scheduled,
            origin: .userCreated
        )
        snapshot.occurrences.append(occurrence)
        snapshot.items.append(
            PlanItem(
                planId: snapshot.plan.id,
                itemKey: "occ:\(occurrence.occurrenceKey)",
                kind: .obligation,
                occurrenceId: occurrence.id,
                title: title,
                category: .household,
                obligationClass: .scheduled,
                priorityTier: .p2,
                section: .today,
                timeWindow: .anytime
            )
        )
        snapshot.plan.planVersion += 1
        snapshots[key] = snapshot
        return snapshot
    }

    // MARK: - Fixture generation

    private func generatePlan(petId: UUID, date: Date) -> PlanSnapshot {
        guard let household, let pet = pets.first(where: { $0.id == petId }) else {
            preconditionFailure("Household and pet must exist before generating a plan")
        }
        let localDate = calendar.startOfDay(for: date)
        let plan = Plan(
            householdId: household.id,
            petId: petId,
            localDate: localDate,
            timeZoneSnapshot: household.timeZone,
            stageSnapshot: StageSnapshot(stageKey: pet.stage(on: date).rawValue),
            capacityModeApplied: household.defaultCapacityMode
        )
        let snapshot = pet.isPreArrival(on: date)
            ? preArrivalFixture(plan: plan, pet: pet, date: date)
            : normalDayFixture(plan: plan, pet: pet, date: date)

        let key = planKey(petId: petId, date: date)
        snapshots[key] = snapshot

        // Apply the initial capacity budget through the same path a
        // capacity change uses.
        if plan.capacityModeApplied != .normal {
            return setCapacity(plan.capacityModeApplied, scope: .todayOnly, petId: petId, date: date)
        }
        return snapshot
    }

    /// Engine §26.1 — pre-arrival plan. No feeding/potty/routine items
    /// appear unless manually scheduled; preparation recommendations key
    /// off the homecoming date.
    private func preArrivalFixture(plan: Plan, pet: Pet, date: Date) -> PlanSnapshot {
        let localDate = calendar.startOfDay(for: date)
        let homecoming = pet.homecomingDate ?? localDate
        let daysAway = pet.daysUntilHomecoming(from: date) ?? 0
        let firstVetVisit = calendar.date(byAdding: .day, value: 3, to: homecoming) ?? homecoming

        func occurrence(
            _ keySuffix: String,
            due: Date,
            timePolicy: TimePolicy = .anytime,
            dueTime: Date? = nil,
            window: PlanTimeWindow? = nil,
            obligation: ObligationClass,
            origin: TaskOrigin
        ) -> TaskOccurrence {
            TaskOccurrence(
                occurrenceKey: "\(plan.id.uuidString)/\(keySuffix)",
                householdId: plan.householdId,
                petId: pet.id,
                localDueDate: calendar.startOfDay(for: due),
                timePolicy: timePolicy,
                dueTime: dueTime,
                window: window,
                obligationClass: obligation,
                origin: origin
            )
        }

        let confirmVet = occurrence(
            "confirm-vet", due: localDate,
            obligation: .scheduled, origin: .userCreated
        )
        let secureCords = occurrence(
            "secure-cords", due: localDate,
            obligation: .scheduled, origin: .systemPreparationRule
        )
        let homecomingOcc = occurrence(
            "homecoming", due: homecoming,
            obligation: .informational, origin: .systemPreparationRule
        )
        let firstVetOcc = occurrence(
            "first-vet-visit", due: firstVetVisit,
            obligation: .scheduled, origin: .calendarEvent
        )

        let items: [PlanItem] = [
            PlanItem(
                planId: plan.id, itemKey: "occ:confirm-vet", kind: .obligation,
                occurrenceId: confirmVet.id,
                title: "Confirm first veterinary appointment",
                category: .preparation, obligationClass: .scheduled,
                priorityTier: .p2, section: .today, timeWindow: .anytime
            ),
            PlanItem(
                planId: plan.id, itemKey: "occ:secure-cords", kind: .obligation,
                occurrenceId: secureCords.id,
                title: "Finish securing electrical cords",
                category: .preparation, obligationClass: .scheduled,
                priorityTier: .p2, section: .today, timeWindow: .anytime
            ),
            PlanItem(
                planId: plan.id, itemKey: "up:homecoming", kind: .upcomingPreview,
                occurrenceId: homecomingOcc.id,
                title: "\(pet.name) comes home",
                category: .life, obligationClass: .informational,
                priorityTier: .p4, section: .comingUp
            ),
            PlanItem(
                planId: plan.id, itemKey: "up:first-vet-visit", kind: .upcomingPreview,
                occurrenceId: firstVetOcc.id,
                title: "First veterinary appointment",
                category: .event, obligationClass: .scheduled,
                priorityTier: .p4, section: .comingUp
            ),
        ]

        let pool: [PlanItem] = [
            PlanItem(
                planId: plan.id, itemKey: "rec:sleeping-setup", kind: .recommendation,
                recommendationRuleRef: "rule.prep_window@1",
                title: "Choose the first-night sleeping setup",
                category: .preparation, obligationClass: .recommended,
                priorityTier: .p3, section: .recommended,
                effortBand: .moderate,
                explanationText: "Homecoming is \(daysAway) days away. Deciding where \(pet.name) sleeps makes the first evening calmer. Takes about 10 minutes."
            ),
            PlanItem(
                planId: plan.id, itemKey: "rec:potty-routine-review", kind: .recommendation,
                recommendationRuleRef: "rule.homecoming_routine@1",
                title: "Review the household potty routine",
                category: .preparation, obligationClass: .recommended,
                priorityTier: .p3, section: .recommended,
                effortBand: .short,
                explanationText: "Agreeing on one potty routine before homecoming helps every caregiver respond the same way. Takes a few minutes."
            ),
        ]
        recommendationPools[planKey(petId: pet.id, date: date)] = pool

        return PlanSnapshot(
            plan: plan,
            items: Array(items.prefix(2)) + pool + Array(items.suffix(2)),
            occurrences: [confirmVet, secureCords, homecomingOcc, firstVetOcc],
            dispositions: []
        )
    }

    /// Engine §26.2 — normal day with a 10-week-old puppy. Breakfast is
    /// already completed by the partner caregiver at 7:42 AM and stays
    /// inline in Today until the next natural list update.
    private func normalDayFixture(plan: Plan, pet: Pet, date: Date) -> PlanSnapshot {
        let localDate = calendar.startOfDay(for: date)
        let vetDay = calendar.date(byAdding: .day, value: 3, to: localDate) ?? localDate
        let vetTime = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: vetDay)
        let prepDay = calendar.date(byAdding: .day, value: 2, to: localDate) ?? localDate
        let breakfastTime = calendar.date(bySettingHour: 7, minute: 42, second: 0, of: localDate) ?? localDate

        func occurrence(
            _ keySuffix: String,
            due: Date,
            timePolicy: TimePolicy = .window,
            dueTime: Date? = nil,
            window: PlanTimeWindow? = nil,
            state: TaskOccurrence.State = .pending,
            obligation: ObligationClass,
            origin: TaskOrigin
        ) -> TaskOccurrence {
            TaskOccurrence(
                occurrenceKey: "\(plan.id.uuidString)/\(keySuffix)",
                householdId: plan.householdId,
                petId: pet.id,
                localDueDate: calendar.startOfDay(for: due),
                timePolicy: timePolicy,
                dueTime: dueTime,
                window: window,
                state: state,
                obligationClass: obligation,
                origin: origin
            )
        }

        let breakfast = occurrence(
            "breakfast", due: localDate, window: .morning,
            state: .completed, obligation: .scheduled, origin: .recurringSchedule
        )
        let potty = occurrence(
            "morning-potty", due: localDate, window: .morning,
            obligation: .scheduled, origin: .recurringSchedule
        )
        let eveningMeal = occurrence(
            "evening-meal", due: localDate, window: .evening,
            obligation: .scheduled, origin: .recurringSchedule
        )
        let vetAppointment = occurrence(
            "vet-appointment", due: vetDay, timePolicy: .exactTime, dueTime: vetTime,
            obligation: .required, origin: .calendarEvent
        )
        let bringRecords = occurrence(
            "bring-records", due: prepDay, timePolicy: .anytime,
            obligation: .scheduled, origin: .calendarEvent
        )

        let breakfastDone = Disposition(
            occurrenceId: breakfast.id,
            action: .complete,
            actorUserId: partnerId,
            recordedAt: breakfastTime
        )

        let items: [PlanItem] = [
            PlanItem(
                planId: plan.id, itemKey: "occ:breakfast", kind: .obligation,
                occurrenceId: breakfast.id,
                title: "Breakfast",
                category: .feeding, obligationClass: .scheduled,
                priorityTier: .p2, section: .today, timeWindow: .morning
            ),
            PlanItem(
                planId: plan.id, itemKey: "occ:morning-potty", kind: .obligation,
                occurrenceId: potty.id,
                title: "Morning potty routine",
                category: .routine, obligationClass: .scheduled,
                priorityTier: .p2, section: .today, timeWindow: .morning
            ),
            PlanItem(
                planId: plan.id, itemKey: "occ:evening-meal", kind: .obligation,
                occurrenceId: eveningMeal.id,
                title: "Evening meal",
                category: .feeding, obligationClass: .scheduled,
                priorityTier: .p2, section: .today, timeWindow: .evening
            ),
            PlanItem(
                planId: plan.id, itemKey: "up:vet-appointment", kind: .upcomingPreview,
                occurrenceId: vetAppointment.id,
                title: "Veterinary appointment",
                category: .event, obligationClass: .required,
                priorityTier: .p4, section: .comingUp
            ),
            PlanItem(
                planId: plan.id, itemKey: "up:bring-records", kind: .upcomingPreview,
                occurrenceId: bringRecords.id,
                title: "Bring existing health records",
                category: .preparation, obligationClass: .scheduled,
                priorityTier: .p4, section: .comingUp
            ),
        ]

        // Paw handling is excluded because it was practiced yesterday
        // (engine §26.2 expected behavior — cooldown).
        let pool: [PlanItem] = [
            PlanItem(
                planId: plan.id, itemKey: "rec:name-response", kind: .recommendation,
                recommendationRuleRef: "rule.start_next_skill@1",
                title: "Practice name response",
                category: .training, obligationClass: .recommended,
                priorityTier: .p3, section: .recommended,
                effortBand: .short,
                explanationText: "Name response is part of \(pet.name)'s foundations stage, and it hasn't been practiced in the last few days. Takes about 3 minutes."
            ),
            PlanItem(
                planId: plan.id, itemKey: "rec:new-environment", kind: .recommendation,
                recommendationRuleRef: "rule.socialization_breadth@1",
                title: "Calmly observe one new environment",
                category: .socialization, obligationClass: .recommended,
                priorityTier: .p3, section: .recommended,
                effortBand: .short,
                explanationText: "Gentle new experiences during \(pet.name)'s socialization window build confidence. Takes about 5 minutes."
            ),
            PlanItem(
                planId: plan.id, itemKey: "rec:brushing", kind: .recommendation,
                recommendationRuleRef: "rule.brushing@1",
                title: "Brief brushing session",
                category: .grooming, obligationClass: .recommended,
                priorityTier: .p3, section: .recommended,
                effortBand: .tiny,
                explanationText: "Short, positive brushing sessions build tolerance for grooming handling. Takes a minute or two."
            ),
        ]
        recommendationPools[planKey(petId: pet.id, date: date)] = pool

        return PlanSnapshot(
            plan: plan,
            items: Array(items.prefix(3)) + pool + Array(items.suffix(2)),
            occurrences: [breakfast, potty, eveningMeal, vetAppointment, bringRecords],
            dispositions: [breakfastDone]
        )
    }

    // MARK: - Preview seeding

    struct PreviewSeed {
        let user: UserAccount
        let household: Household
        let pet: Pet
    }

    /// Seeds a signed-in household for SwiftUI previews.
    func seedForPreview(preArrival: Bool) -> PreviewSeed {
        let user = signIn(email: "sarah@example.com")
        let household = createHousehold(
            name: "Earley Household",
            timeZone: TimeZone.current.identifier,
            ownerId: user.id
        )
        let today = Date()
        let pet: Pet
        if preArrival {
            let birth = calendar.date(byAdding: .weekOfYear, value: -8, to: today) ?? today
            let homecoming = calendar.date(byAdding: .day, value: 13, to: today) ?? today
            pet = createPet(name: "Maple", birthInfo: .exact(birthDate: birth), homecomingDate: homecoming)
        } else {
            let birth = calendar.date(byAdding: .weekOfYear, value: -10, to: today) ?? today
            let homecoming = calendar.date(byAdding: .weekOfYear, value: -2, to: today)
            pet = createPet(name: "Maple", birthInfo: .exact(birthDate: birth), homecomingDate: homecoming)
        }
        return PreviewSeed(user: user, household: household, pet: pet)
    }
}
