import Foundation

@MainActor
protocol PlannerService: AnyObject {
    func context() async throws -> PlannerContext
    func agenda(on date: Date) async throws -> PlannerDayAgenda
    /// Inclusive multi-day agenda in the household calendar. Empty local days
    /// are still returned so PL-01 can render honest empties.
    func agenda(from start: Date, through end: Date) async throws -> [PlannerDayAgenda]
    func history(for item: PlannerAgendaItem) async throws -> [PlannerHistoryEntry]
    func save(
        _ draft: PlannerTaskDraft,
        scope: PlannerEditScope?
    ) async throws -> PlannerMutationState
    func perform(
        _ action: PlannerTaskAction,
        on item: PlannerAgendaItem
    ) async throws -> PlannerMutationState
}

/// Compatibility adapter for the Slice A `PlanService`. It makes the
/// currently implemented operations useful in Planner without claiming the
/// richer Slice B writes exist. The production backend adapter can replace
/// this type without changing Planner views.
@MainActor
final class PlanServicePlannerAdapter: PlannerService {
    private let model: AppModel
    private var snapshotsByDay: [Date: PlanSnapshot] = [:]
    private var memberNames: [UUID: String] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func context() async throws -> PlannerContext {
        guard let household = model.household else {
            throw PlannerServiceError.unavailable("Your household could not be loaded.")
        }
        let activeMembers = try await model.households.members(householdId: household.id)
            .filter { $0.status == .active }
        memberNames = Dictionary(uniqueKeysWithValues: activeMembers.map { ($0.userId, $0.displayName) })
        var memberOptions = [PlannerMemberOption.anyone]
        memberOptions.append(contentsOf: activeMembers.map {
            PlannerMemberOption(
                id: $0.userId.uuidString,
                name: $0.userId == model.currentUser?.id ? "Me" : $0.displayName,
                kind: .member($0.userId)
            )
        })
        let pets = try await model.households.pets(householdId: household.id)
            .filter { $0.status == .active }
        return PlannerContext(
            pets: pets,
            members: memberOptions,
            calendar: household.clock.calendar,
            capabilities: [
                .readAgenda, .createOneTime, .complete, .undoComplete, .history,
            ]
        )
    }

    func agenda(on date: Date) async throws -> PlannerDayAgenda {
        guard let pet = model.activePet else {
            throw PlannerServiceError.unavailable("Add a pet before creating a plan.")
        }
        let calendar = model.household?.clock.calendar ?? .current
        let snapshot: PlanSnapshot
        do {
            snapshot = try await model.plans.plan(
                forPet: pet.id,
                on: date,
                resectioningCompleted: true
            )
        } catch PlanServiceError.noPlanForDay {
            // Reported, not raised. The read succeeded; the day simply has
            // no plan, and Planner says so as an empty-day state rather than
            // as a failure with a retry that would never help.
            //
            // This replaces a guard that compared `plan.localDate` against
            // the requested date and rejected any mismatch. It was covering
            // for a read that ignored its date argument entirely, and it was
            // wrong in its own right: `localDate` decodes at GMT, so the
            // comparison rejected correct snapshots for every household west
            // of it. The service is now date-scoped, so a returned snapshot
            // is the requested day by construction.
            return PlannerDayAgenda(
                date: calendar.startOfDay(for: date),
                items: [],
                lastVerifiedAt: nil,
                isStale: false,
                coverage: .notGenerated
            )
        }
        snapshotsByDay[calendar.startOfDay(for: date)] = snapshot
        publishToSharedPlan(snapshot, for: date, calendar: calendar)

        let namesByPet = Dictionary(uniqueKeysWithValues: [pet].map { ($0.id, $0.name) })
        let items = snapshot.items.compactMap { planItem -> PlannerAgendaItem? in
            guard planItem.kind == .obligation,
                  let occurrence = snapshot.occurrence(for: planItem),
                  calendar.isDate(occurrence.localDueDate, inSameDayAs: date)
            else { return nil }
            return map(
                planItem: planItem,
                occurrence: occurrence,
                snapshot: snapshot,
                petName: namesByPet[occurrence.petId] ?? pet.name,
                calendar: calendar
            )
        }
        .sorted(by: agendaSort)

        return PlannerDayAgenda(
            date: calendar.startOfDay(for: date),
            items: items,
            lastVerifiedAt: snapshot.servedFromCacheAt ?? snapshot.plan.generatedAt,
            isStale: snapshot.servedFromCacheAt != nil
        )
    }

    func agenda(from start: Date, through end: Date) async throws -> [PlannerDayAgenda] {
        let calendar = model.household?.clock.calendar ?? .current
        var result: [PlannerDayAgenda] = []
        for day in PlannerAgendaGrouping.dayStarts(from: start, through: end, calendar: calendar) {
            result.append(try await agenda(on: day))
        }
        return result
    }

    func history(for item: PlannerAgendaItem) async throws -> [PlannerHistoryEntry] {
        guard let occurrenceId = item.occurrenceId else { return [] }
        return snapshotsByDay.values
            .flatMap(\.dispositions)
            .filter { $0.occurrenceId == occurrenceId && !$0.superseded }
            .sorted { $0.effectiveAt > $1.effectiveAt }
            .map {
                PlannerHistoryEntry(
                    id: $0.id,
                    action: $0.action,
                    actorName: memberNames[$0.actorUserId] ?? "a caregiver",
                    effectiveAt: $0.effectiveAt,
                    detail: historyDetail(for: $0),
                    isQueued: false
                )
            }
    }

    func save(
        _ draft: PlannerTaskDraft,
        scope: PlannerEditScope?
    ) async throws -> PlannerMutationState {
        guard !draft.isEditing,
              draft.recurrence == .once,
              draft.time == .anytime,
              draft.assignment == .anyone,
              draft.reminder == .none,
              draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let petId = draft.petId
        else {
            throw PlannerServiceError.unavailable(
                "Recurring schedules and detailed task edits need the Slice B Planner adapter."
            )
        }
        let snapshot = try await model.plans.addOneTimeTask(
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            petId: petId,
            on: draft.date
        )
        let calendar = model.household?.clock.calendar ?? .current
        snapshotsByDay[calendar.startOfDay(for: draft.date)] = snapshot
        publishToSharedPlan(snapshot, for: draft.date, calendar: calendar)
        return .confirmed
    }

    func perform(
        _ action: PlannerTaskAction,
        on item: PlannerAgendaItem
    ) async throws -> PlannerMutationState {
        let snapshot: PlanSnapshot
        guard let planItemId = item.planItemId else {
            throw PlannerServiceError.unavailable(
                "This occurrence is not in a generated Daily Plan yet."
            )
        }
        switch action {
        case .complete:
            snapshot = try await model.plans.completeItem(
                itemId: planItemId,
                petId: item.petId,
                on: item.date
            )
        case .undoComplete:
            snapshot = try await model.plans.undoCompletion(
                itemId: planItemId,
                petId: item.petId,
                on: item.date
            )
        case .skip, .undoSkip, .snooze, .reschedule, .cancel:
            throw PlannerServiceError.unavailable(
                "This action needs the Slice B Planner write adapter."
            )
        }
        let calendar = model.household?.clock.calendar ?? .current
        snapshotsByDay[calendar.startOfDay(for: item.date)] = snapshot
        publishToSharedPlan(snapshot, for: item.date, calendar: calendar)
        return .confirmed
    }

    /// Home renders today for the active pet, so only today's snapshot may
    /// replace the shared one — otherwise browsing Planner backwards would
    /// quietly rewrite Home with another day's plan.
    private func publishToSharedPlan(
        _ snapshot: PlanSnapshot,
        for date: Date,
        calendar: Calendar
    ) {
        guard calendar.isDateInToday(date) else { return }
        model.planState.snapshot = snapshot
    }

    private func map(
        planItem: PlanItem,
        occurrence: TaskOccurrence,
        snapshot: PlanSnapshot,
        petName: String,
        calendar: Calendar
    ) -> PlannerAgendaItem {
        let state: PlannerAgendaState
        // Cache-served plans stay interactive so complete/undo can queue
        // (US-058). Day-level `isStale` still drives the sync line.
        if planItem.displayState == .queued {
            state = .queued
        } else {
            state = switch occurrence.state {
            case .pending, .rescheduled: .pending
            case .completed: .completed
            case .skipped: .skipped
            case .cancelled: .cancelled
            case .expired: .expired
            }
        }
        let time: PlannerTimeSelection
        switch occurrence.timePolicy {
        case .exactTime:
            time = occurrence.dueTime.map(PlannerTimeSelection.exact) ?? .anytime
        case .window:
            time = .window(occurrence.window ?? .anytime)
        case .anytime:
            time = .anytime
        }
        let attribution = snapshot.effectiveCompletion(for: planItem).map {
            let actor = memberNames[$0.actorUserId] ?? "a caregiver"
            return "by \(actor), \(PlannerFormatters.time($0.effectiveAt, calendar: calendar))"
        }
        let activeSnooze = snapshot.dispositions
            .filter { $0.occurrenceId == occurrence.id && $0.action == .snooze }
            .sorted { $0.recordedAt > $1.recordedAt }
            .first?.snoozeUntil

        return PlannerAgendaItem(
            id: occurrence.id,
            planItemId: planItem.id,
            occurrenceId: occurrence.id,
            scheduleId: occurrence.scheduleId,
            title: planItem.title,
            petId: occurrence.petId,
            petName: petName,
            date: occurrence.localDueDate,
            time: time,
            recurrence: .once,
            assignment: memberOptionKind(for: occurrence.assignment),
            reminder: .none,
            notes: "",
            state: state,
            obligationClass: occurrence.obligationClass,
            origin: occurrence.origin,
            revision: occurrence.revision,
            completionAttribution: attribution,
            snoozedUntil: activeSnooze
        )
    }

    private func memberOptionKind(for assignment: Assignment) -> PlannerMemberOption.Kind {
        switch assignment {
        case .unassigned, .anyone: .anyone
        case .member(let id): .member(id)
        }
    }

    private func agendaSort(_ lhs: PlannerAgendaItem, _ rhs: PlannerAgendaItem) -> Bool {
        switch (lhs.time, rhs.time) {
        case (.exact(let left), .exact(let right)):
            left < right
        case (.exact, _):
            true
        case (_, .exact):
            false
        default:
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func historyDetail(for disposition: Disposition) -> String? {
        switch disposition.action {
        case .skip:
            disposition.skipReason
        case .snooze:
            disposition.snoozeUntil.map { PlannerFormatters.time($0, calendar: model.household?.clock.calendar ?? .current) }
        case .reschedule:
            disposition.rescheduleTo.map { PlannerFormatters.day($0, calendar: model.household?.clock.calendar ?? .current) }
        default:
            disposition.note
        }
    }
}

/// Deterministic full-capability service for previews and focused Planner
/// tests. It is never selected by the app runtime.
@MainActor
final class InMemoryPlannerService: PlannerService {
    private var plannerContext: PlannerContext
    private var items: [PlannerAgendaItem]
    private var histories: [UUID: [PlannerHistoryEntry]]
    private let actorName: String

    init(
        context: PlannerContext,
        items: [PlannerAgendaItem] = [],
        histories: [UUID: [PlannerHistoryEntry]] = [:],
        actorName: String = "You"
    ) {
        plannerContext = context
        self.items = items
        self.histories = histories
        self.actorName = actorName
    }

    static func preview(model: AppModel, date: Date = .now) -> InMemoryPlannerService {
        let calendar = model.household?.clock.calendar ?? .current
        let pet = model.activePet ?? Pet(
            householdId: UUID(),
            name: "Maple",
            birthInfo: .unknown
        )
        let context = PlannerContext(
            pets: [pet],
            members: [
                .anyone,
                PlannerMemberOption(
                    id: model.currentUser?.id.uuidString ?? UUID().uuidString,
                    name: "Me",
                    kind: .member(model.currentUser?.id ?? UUID())
                ),
            ],
            calendar: calendar,
            capabilities: .fullTaskManagement
        )
        let breakfastId = UUID()
        let brushId = UUID()
        let vetPrepId = UUID()
        let dayAfter = calendar.date(byAdding: .day, value: 2, to: date) ?? date
        let items = [
            PlannerAgendaItem(
                id: breakfastId,
                planItemId: breakfastId,
                occurrenceId: breakfastId,
                scheduleId: UUID(),
                title: "Breakfast",
                petId: pet.id,
                petName: pet.name,
                date: date,
                time: .window(.morning),
                recurrence: .daily,
                assignment: .anyone,
                reminder: .atWindow,
                notes: "",
                state: .completed,
                obligationClass: .scheduled,
                origin: .recurringSchedule,
                revision: 1,
                completionAttribution: "by You, 7:42 AM",
                snoozedUntil: nil
            ),
            PlannerAgendaItem(
                id: brushId,
                planItemId: nil,
                occurrenceId: brushId,
                scheduleId: UUID(),
                title: "Brush coat",
                petId: pet.id,
                petName: pet.name,
                date: date,
                time: .window(.evening),
                recurrence: .selectedWeekdays([.monday, .wednesday, .friday]),
                assignment: .anyone,
                reminder: .atWindow,
                notes: "Keep it short and comfortable.",
                state: .pending,
                obligationClass: .scheduled,
                origin: .recurringSchedule,
                revision: 2,
                completionAttribution: nil,
                snoozedUntil: nil
            ),
            PlannerAgendaItem(
                id: vetPrepId,
                planItemId: nil,
                occurrenceId: vetPrepId,
                scheduleId: nil,
                title: "Bring health records",
                petId: pet.id,
                petName: pet.name,
                date: dayAfter,
                time: .exact(
                    calendar.date(bySettingHour: 14, minute: 0, second: 0, of: dayAfter) ?? dayAfter
                ),
                recurrence: .once,
                assignment: .anyone,
                reminder: .oneHourBefore,
                notes: "",
                state: .pending,
                obligationClass: .scheduled,
                origin: .userCreated,
                revision: 1,
                completionAttribution: nil,
                snoozedUntil: nil
            ),
        ]
        // Deliberately leave tomorrow empty so the forward agenda shows an
        // inline empty-day add between today and the day-after prep task.
        return InMemoryPlannerService(context: context, items: items)
    }

    func context() async throws -> PlannerContext { plannerContext }

    func agenda(on date: Date) async throws -> PlannerDayAgenda {
        let calendar = plannerContext.calendar
        return PlannerDayAgenda(
            date: calendar.startOfDay(for: date),
            items: items
                .filter { calendar.isDate($0.date, inSameDayAs: date) }
                .sorted {
                    if $0.time == $1.time {
                        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                    return timeRank($0.time, calendar: calendar) < timeRank($1.time, calendar: calendar)
                },
            lastVerifiedAt: .now,
            isStale: false
        )
    }

    func agenda(from start: Date, through end: Date) async throws -> [PlannerDayAgenda] {
        let calendar = plannerContext.calendar
        var result: [PlannerDayAgenda] = []
        for day in PlannerAgendaGrouping.dayStarts(from: start, through: end, calendar: calendar) {
            result.append(try await agenda(on: day))
        }
        return result
    }

    func history(for item: PlannerAgendaItem) async throws -> [PlannerHistoryEntry] {
        histories[item.id, default: []].sorted { $0.effectiveAt > $1.effectiveAt }
    }

    func save(
        _ draft: PlannerTaskDraft,
        scope: PlannerEditScope?
    ) async throws -> PlannerMutationState {
        if let validation = draft.validationMessage(calendar: plannerContext.calendar, today: .now) {
            throw PlannerServiceError.unavailable(validation)
        }
        if draft.isEditingRecurringTask && scope == nil {
            throw PlannerServiceError.unavailable("Choose whether this change applies once or to this and future tasks.")
        }

        if let id = draft.id, let index = items.firstIndex(where: { $0.id == id }) {
            guard draft.revision == items[index].revision else {
                throw PlannerServiceError.itemChanged
            }
            items[index].title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            items[index].petId = draft.petId ?? items[index].petId
            items[index].date = draft.date
            items[index].time = draft.time
            items[index].recurrence = draft.recurrence
            items[index].assignment = draft.assignment
            items[index].reminder = draft.reminder
            items[index].notes = draft.notes
            items[index].revision += 1
            appendHistory(.reschedule, to: id, detail: scope?.displayName ?? "Task edited")
        } else {
            let id = UUID()
            let petId = draft.petId!
            let petName = plannerContext.pets.first(where: { $0.id == petId })?.name ?? "Pet"
            items.append(
                PlannerAgendaItem(
                    id: id,
                    planItemId: id,
                    occurrenceId: id,
                    scheduleId: draft.recurrence.isRecurring ? UUID() : nil,
                    title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    petId: petId,
                    petName: petName,
                    date: draft.date,
                    time: draft.time,
                    recurrence: draft.recurrence,
                    assignment: draft.assignment,
                    reminder: draft.reminder,
                    notes: draft.notes,
                    state: .pending,
                    obligationClass: .scheduled,
                    origin: draft.recurrence.isRecurring ? .recurringSchedule : .userCreated,
                    revision: 1,
                    completionAttribution: nil,
                    snoozedUntil: nil
                )
            )
        }
        return .confirmed
    }

    func perform(
        _ action: PlannerTaskAction,
        on item: PlannerAgendaItem
    ) async throws -> PlannerMutationState {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            throw PlannerServiceError.missingOccurrence
        }
        let calendar = plannerContext.calendar
        switch action {
        case .complete:
            items[index].state = .completed
            items[index].completionAttribution = "by \(actorName), \(PlannerFormatters.time(.now, calendar: calendar))"
            items[index].snoozedUntil = nil
            appendHistory(.complete, to: item.id)
        case .undoComplete:
            items[index].state = .pending
            items[index].completionAttribution = nil
            appendHistory(.undoComplete, to: item.id)
        case .skip(let reason):
            items[index].state = .skipped
            appendHistory(.skip, to: item.id, detail: reason)
        case .undoSkip:
            items[index].state = .pending
            appendHistory(.undoSkip, to: item.id)
        case .snooze(let until):
            guard until > Date(), calendar.isDate(until, inSameDayAs: Date()) else {
                throw PlannerServiceError.invalidSnooze
            }
            items[index].snoozedUntil = until
            appendHistory(.snooze, to: item.id, detail: PlannerFormatters.time(until, calendar: calendar))
        case .reschedule(let date, let time, let scope):
            items[index].date = date
            items[index].time = time
            items[index].revision += 1
            appendHistory(.reschedule, to: item.id, detail: "\(scope.displayName) · \(PlannerFormatters.day(date, calendar: calendar))")
        case .cancel(let scope):
            items[index].state = .cancelled
            appendHistory(.cancel, to: item.id, detail: scope.displayName)
        }
        return .confirmed
    }

    private func appendHistory(
        _ action: Disposition.Action,
        to itemId: UUID,
        detail: String? = nil
    ) {
        histories[itemId, default: []].append(
            PlannerHistoryEntry(
                id: UUID(),
                action: action,
                actorName: actorName,
                effectiveAt: .now,
                detail: detail,
                isQueued: false
            )
        )
    }

    private func timeRank(_ selection: PlannerTimeSelection, calendar: Calendar) -> Int {
        switch selection {
        case .exact(let date):
            return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        case .window(let window):
            return 1_500 + (PlanTimeWindow.allCases.firstIndex(of: window) ?? 0)
        case .anytime:
            return 2_000
        }
    }
}
