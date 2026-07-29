import Foundation
import Supabase

/// Planner's optimistic state for work the local queue has accepted but the
/// server has not confirmed.
///
/// Every entry is owned by exactly one queued operation. When that operation
/// leaves the queue — replayed, so the real row now arrives from the server,
/// or set aside as rejected, so it never will — the placeholder row or queued
/// badge it justified has to go with it. Left behind, a placeholder outlives
/// the row that replaced it and Planner shows the same task twice.
struct QueuedPlannerWork: Equatable {
    /// Synthesised agenda rows for creates that have no server row yet, keyed
    /// by the operation that will produce one.
    private(set) var placeholders: [UUID: PlannerAgendaItem] = [:]
    /// Occurrences currently showing a queued badge, mapped to the operation
    /// that still owes them a confirmation.
    private(set) var badgedOccurrences: [UUID: UUID] = [:]

    mutating func addPlaceholder(_ item: PlannerAgendaItem, operationId: UUID) {
        placeholders[operationId] = item
    }

    mutating func badge(occurrenceId: UUID, operationId: UUID) {
        badgedOccurrences[occurrenceId] = operationId
    }

    mutating func clearBadge(occurrenceId: UUID) {
        badgedOccurrences.removeValue(forKey: occurrenceId)
    }

    func isBadged(occurrenceId: UUID) -> Bool {
        badgedOccurrences[occurrenceId] != nil
    }

    func placeholderItems(on date: Date, calendar: Calendar) -> [PlannerAgendaItem] {
        placeholders.values.filter { calendar.isDate($0.date, inSameDayAs: date) }
    }

    /// Releases everything whose operation the queue no longer holds as
    /// outstanding work. Rejected operations are released too: they are
    /// retained for review in Settings, not as an agenda row that pretends
    /// the task exists.
    mutating func settle(against operations: [OfflineOperation]) {
        let outstanding = Set(
            operations.filter { $0.state != .rejected }.map(\.id)
        )
        placeholders = placeholders.filter { outstanding.contains($0.key) }
        badgedOccurrences = badgedOccurrences.filter { outstanding.contains($0.value) }
    }
}

/// Supabase-backed Planner adapter for Slice B. Reads use RLS-protected
/// tables; every invariant-bearing mutation goes through `write-path`.
@MainActor
final class RealPlannerService: PlannerService {
    private let client: SupabaseClient
    private unowned let model: AppModel
    private let operationQueue: OfflineOperationQueue
    private let decoder = SupabaseCoding.restDecoder

    private var memberNames: [UUID: String] = [:]
    private var scheduleRevisions: [UUID: Int] = [:]
    private var knownItems: [UUID: PlannerAgendaItem] = [:]
    private var queuedWork = QueuedPlannerWork()

    init(
        client: SupabaseClient,
        model: AppModel,
        operationQueue: OfflineOperationQueue
    ) {
        self.client = client
        self.model = model
        self.operationQueue = operationQueue
    }

    func context() async throws -> PlannerContext {
        guard let household = model.household else {
            throw PlannerServiceError.unavailable("Your household could not be loaded.")
        }
        let activeMembers = try await model.households.members(householdId: household.id)
            .filter { $0.status == .active }
        memberNames = Dictionary(uniqueKeysWithValues: activeMembers.map { ($0.userId, $0.displayName) })

        var members = [PlannerMemberOption.anyone]
        members.append(contentsOf: activeMembers.map {
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
            members: members,
            calendar: household.clock.calendar,
            capabilities: .fullTaskManagement.subtracting(.taskNotes)
        )
    }

    func agenda(on date: Date) async throws -> PlannerDayAgenda {
        let days = try await agenda(from: date, through: date)
        guard let day = days.first else {
            let calendar = model.household?.clock.calendar ?? .current
            return PlannerDayAgenda(
                date: calendar.startOfDay(for: date),
                items: [],
                lastVerifiedAt: nil,
                isStale: false,
                coverage: .notGenerated
            )
        }
        return day
    }

    func agenda(from start: Date, through end: Date) async throws -> [PlannerDayAgenda] {
        guard let household = model.household else {
            throw PlannerServiceError.unavailable("Your household could not be loaded.")
        }
        // Optimistic rows and badges only survive while their operation does.
        queuedWork.settle(against: operationQueue.operations)
        let calendar = household.clock.calendar
        let dayStarts = PlannerAgendaGrouping.dayStarts(from: start, through: end, calendar: calendar)
        guard let first = dayStarts.first, let last = dayStarts.last else { return [] }

        let startString = SupabaseCoding.dateOnlyString(first, timeZone: calendar.timeZone)
        let endString = SupabaseCoding.dateOnlyString(last, timeZone: calendar.timeZone)

        let response = try await client
            .from("task_occurrences")
            .select()
            .eq("household_id", value: household.id)
            .gte("local_due_date", value: startString)
            .lte("local_due_date", value: endString)
            .order("local_due_date")
            .order("due_time", nullsFirst: false)
            .order("occurrence_key")
            .execute()
        let rows = try decoder.decode([OccurrenceRow].self, from: response.data)
        let scheduleIds = Array(Set(rows.compactMap(\.scheduleId)))
        let schedules = try await readSchedules(ids: scheduleIds)
        scheduleRevisions.merge(
            Dictionary(uniqueKeysWithValues: schedules.map { ($0.id, $0.revision) })
        ) { _, newest in newest }

        let definitionIds = Array(Set(schedules.map(\.taskDefinitionId)))
        let definitions = try await readDefinitions(ids: definitionIds)
        let titleBySchedule = Dictionary(uniqueKeysWithValues: schedules.compactMap { schedule in
            definitions[schedule.taskDefinitionId].map { (schedule.id, $0) }
        })
        let pets = try await model.households.pets(householdId: household.id)
        let petNames = Dictionary(uniqueKeysWithValues: pets.map { ($0.id, $0.name) })
        let dispositions = try await readDispositions(occurrenceIds: rows.map(\.id))

        var itemsByDay: [Date: [PlannerAgendaItem]] = Dictionary(
            uniqueKeysWithValues: dayStarts.map { ($0, []) }
        )
        for row in rows {
            let item = map(
                row: row,
                schedule: row.scheduleId.flatMap { id in schedules.first { $0.id == id } },
                title: row.titleOverride
                    ?? row.scheduleId.flatMap { titleBySchedule[$0] }
                    ?? "Household task",
                petName: petNames[row.petId] ?? "Pet",
                dispositions: dispositions.filter { $0.occurrenceId == row.id },
                calendar: calendar
            )
            let day = calendar.startOfDay(for: item.date)
            itemsByDay[day, default: []].append(item)
        }

        var days: [PlannerDayAgenda] = []
        for day in dayStarts {
            var items = itemsByDay[day] ?? []
            items.append(contentsOf: queuedWork.placeholderItems(on: day, calendar: calendar))
            items.sort(by: agendaSort)
            knownItems.merge(Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })) {
                _, newest in newest
            }
            days.append(
                PlannerDayAgenda(
                    date: day,
                    items: items,
                    lastVerifiedAt: .now,
                    isStale: false
                )
            )
        }
        return days
    }

    func history(for item: PlannerAgendaItem) async throws -> [PlannerHistoryEntry] {
        guard let occurrenceId = item.occurrenceId else { return [] }
        let dispositions = try await readDispositions(occurrenceIds: [occurrenceId])
        return dispositions
            .sorted { $0.effectiveAt > $1.effectiveAt }
            .map {
                PlannerHistoryEntry(
                    id: $0.id,
                    action: $0.action,
                    actorName: memberNames[$0.actorUserId] ?? "a caregiver",
                    effectiveAt: $0.effectiveAt,
                    detail: historyDetail($0),
                    isQueued: false
                )
            }
    }

    func save(
        _ draft: PlannerTaskDraft,
        scope: PlannerEditScope?
    ) async throws -> PlannerMutationState {
        guard let household = model.household, let petId = draft.petId else {
            throw PlannerServiceError.unavailable("Choose a pet before saving.")
        }
        if let message = draft.validationMessage(
            calendar: household.clock.calendar,
            today: .now
        ) {
            throw PlannerServiceError.unavailable(message)
        }

        if !draft.isEditing {
            let outcome = try await create(draft, petId: petId, calendar: household.clock.calendar)
            if case .queued(let operationId) = outcome {
                queuedWork.addPlaceholder(
                    queuedItem(id: UUID(), draft: draft),
                    operationId: operationId
                )
            }
            let state = outcome.mutationState
            await refreshSharedPlan(
                after: state,
                petId: petId,
                on: draft.date,
                regeneratingPlan: true
            )
            return state
        }

        guard let occurrenceId = draft.occurrenceId,
              let original = knownItems[occurrenceId]
        else { throw PlannerServiceError.missingOccurrence }

        if draft.isEditingRecurringTask, scope == nil {
            throw PlannerServiceError.unavailable("Choose which occurrences this change applies to.")
        }
        let state: PlannerMutationState
        if scope == .thisAndFuture {
            guard let scheduleId = draft.scheduleId else {
                throw PlannerServiceError.missingOccurrence
            }
            state = try await editFuture(
                draft,
                scheduleId: scheduleId,
                splitDate: original.date,
                calendar: household.clock.calendar
            )
        } else {
            state = try await editOccurrence(
                draft,
                original: original,
                calendar: household.clock.calendar
            )
        }
        // An edit can move work onto or off today, so Home needs the plan
        // regenerated rather than the same items re-read.
        await refreshSharedPlan(
            after: state,
            petId: original.petId,
            on: original.date,
            regeneratingPlan: true
        )
        return state
    }

    func perform(
        _ action: PlannerTaskAction,
        on item: PlannerAgendaItem
    ) async throws -> PlannerMutationState {
        guard let occurrenceId = item.occurrenceId,
              let household = model.household
        else { throw PlannerServiceError.missingOccurrence }
        let calendar = household.clock.calendar
        let outcome: SendOutcome

        switch action {
        case .complete:
            outcome = try await send(
                command: "complete_occurrence",
                payload: OccurrenceOnlyPayload(occurrence_id: occurrenceId)
            )
        case .undoComplete:
            outcome = try await send(
                command: "undo_completion",
                payload: OccurrenceOnlyPayload(occurrence_id: occurrenceId)
            )
        case .skip(let reason):
            outcome = try await send(
                command: "skip_item",
                payload: SkipPayload(
                    occurrence_id: occurrenceId,
                    skip_reason: skipReason(reason),
                    confirm_required: item.obligationClass == .required
                )
            )
        case .undoSkip:
            outcome = try await send(
                command: "undo_skip",
                payload: OccurrenceOnlyPayload(occurrence_id: occurrenceId)
            )
        case .snooze(let until):
            guard calendar.isDate(until, inSameDayAs: item.date), until > .now else {
                throw PlannerServiceError.invalidSnooze
            }
            outcome = try await send(
                command: "snooze_occurrence",
                payload: SnoozePayload(
                    occurrence_id: occurrenceId,
                    snooze_until: SupabaseCoding.iso8601String(until)
                )
            )
        case .reschedule(let date, let time, let scope):
            if scope == .thisAndFuture, let scheduleId = item.scheduleId {
                let recurrence = recurrencePayload(
                    item.recurrence,
                    date: date,
                    time: time,
                    calendar: calendar
                )
                outcome = try await send(
                    command: "edit_schedule_future",
                    payload: EditFuturePayload(
                        schedule_id: scheduleId,
                        expected_revision: scheduleRevisions[scheduleId] ?? 1,
                        split_date: dateString(date, calendar: calendar),
                        recurrence: recurrence,
                        title: nil,
                        assignment: nil,
                        reminder_config: nil
                    )
                )
            } else {
                outcome = try await send(
                    command: "reschedule_occurrence",
                    payload: ReschedulePayload(
                        occurrence_id: occurrenceId,
                        expected_revision: item.revision,
                        local_due_date: dateString(date, calendar: calendar),
                        timing: timingPayload(time, calendar: calendar)
                    )
                )
            }
        case .cancel(let scope):
            if scope == .thisAndFuture, let scheduleId = item.scheduleId {
                outcome = try await send(
                    command: "archive_schedule",
                    payload: ArchivePayload(
                        schedule_id: scheduleId,
                        expected_revision: scheduleRevisions[scheduleId] ?? 1,
                        confirm_required: true
                    )
                )
            } else {
                outcome = try await send(
                    command: "cancel_occurrence",
                    payload: CancelPayload(
                        occurrence_id: occurrenceId,
                        expected_revision: item.revision,
                        confirm_required: true
                    )
                )
            }
        }

        if case .queued(let operationId) = outcome {
            queuedWork.badge(occurrenceId: occurrenceId, operationId: operationId)
        } else {
            queuedWork.clearBadge(occurrenceId: occurrenceId)
        }
        let state = outcome.mutationState
        await refreshSharedPlan(
            after: state,
            petId: item.petId,
            on: item.date,
            regeneratingPlan: Self.changesDayComposition(action)
        )
        return state
    }

    // MARK: - Mutations

    private func create(
        _ draft: PlannerTaskDraft,
        petId: UUID,
        calendar: Calendar
    ) async throws -> SendOutcome {
        let payload = CreatePayload(
            pet_id: petId,
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            recurrence: recurrencePayload(
                draft.recurrence,
                date: draft.date,
                time: draft.time,
                calendar: calendar
            ),
            assignment: assignmentPayload(draft.assignment),
            category: "household",
            obligation_class: "scheduled",
            reminder_config: reminderPayload(draft.reminder)
        )
        return try await send(command: "create_recurring_task", payload: payload)
    }

    private func editOccurrence(
        _ draft: PlannerTaskDraft,
        original: PlannerAgendaItem,
        calendar: Calendar
    ) async throws -> PlannerMutationState {
        guard let occurrenceId = draft.occurrenceId else {
            throw PlannerServiceError.missingOccurrence
        }
        var revision = draft.revision ?? original.revision
        var result = PlannerMutationState.confirmed
        // An edit can send two commands; the badge belongs to whichever one
        // the queue is still holding.
        var queuedOperationId: UUID?
        if !calendar.isDate(draft.date, inSameDayAs: original.date) {
            let outcome = try await send(
                command: "reschedule_occurrence",
                payload: ReschedulePayload(
                    occurrence_id: occurrenceId,
                    expected_revision: revision,
                    local_due_date: dateString(draft.date, calendar: calendar),
                    timing: timingPayload(draft.time, calendar: calendar)
                )
            )
            if case .queued(let operationId) = outcome { queuedOperationId = operationId }
            result = outcome.mutationState
            revision += 1
        }
        let needsDetails = draft.title != original.title
            || draft.assignment != original.assignment
            || draft.time != original.time
        if needsDetails {
            let outcome = try await send(
                command: "edit_occurrence",
                payload: EditOccurrencePayload(
                    occurrence_id: occurrenceId,
                    expected_revision: revision,
                    title: draft.title == original.title ? nil : draft.title,
                    timing: timingPayload(draft.time, calendar: calendar),
                    assignment: assignmentPayload(draft.assignment)
                )
            )
            if case .queued(let operationId) = outcome {
                queuedOperationId = operationId
                result = .queued
            }
        }
        if let queuedOperationId {
            queuedWork.badge(occurrenceId: occurrenceId, operationId: queuedOperationId)
        } else {
            queuedWork.clearBadge(occurrenceId: occurrenceId)
        }
        return result
    }

    private func editFuture(
        _ draft: PlannerTaskDraft,
        scheduleId: UUID,
        splitDate: Date,
        calendar: Calendar
    ) async throws -> PlannerMutationState {
        let outcome = try await send(
            command: "edit_schedule_future",
            payload: EditFuturePayload(
                schedule_id: scheduleId,
                expected_revision: scheduleRevisions[scheduleId] ?? 1,
                split_date: dateString(splitDate, calendar: calendar),
                recurrence: recurrencePayload(
                    draft.recurrence,
                    date: draft.date,
                    time: draft.time,
                    calendar: calendar
                ),
                title: draft.title,
                assignment: assignmentPayload(draft.assignment),
                reminder_config: reminderPayload(draft.reminder)
            )
        )
        if let occurrenceId = draft.occurrenceId {
            if case .queued(let operationId) = outcome {
                queuedWork.badge(occurrenceId: occurrenceId, operationId: operationId)
            } else {
                queuedWork.clearBadge(occurrenceId: occurrenceId)
            }
        }
        return outcome.mutationState
    }

    /// The queued case carries its operation id so optimistic Planner state
    /// can be tied to — and later released by — the exact operation the queue
    /// is holding.
    private enum SendOutcome {
        case confirmed
        case queued(operationId: UUID)

        var mutationState: PlannerMutationState {
            switch self {
            case .confirmed: .confirmed
            case .queued: .queued
            }
        }
    }

    private func send<Payload: Encodable>(
        command: String,
        payload: Payload
    ) async throws -> SendOutcome {
        do {
            let _: JSONValue = try await WritePath.sendStable(
                client: client,
                command: command,
                payload: payload,
                queue: operationQueue
            )
            return .confirmed
        } catch OfflineMutationError.queued(let operationId) {
            return .queued(operationId: operationId)
        } catch WritePathError.server(let code, _) where code == "REVISION_CONFLICT" {
            throw PlannerServiceError.itemChanged
        }
    }

    // MARK: - Shared plan state

    /// Home renders the same household day from the same rows, so a change
    /// Planner confirmed has to leave the shared plan consistent. Without
    /// this, completing a task in Planner leaves Home showing pre-action
    /// state until Home happens to refetch (doc 19).
    ///
    /// Queued work is deliberately excluded: the server has nothing new to
    /// tell Home yet, and re-reading would only overwrite the shared plan
    /// with the state the caregiver just acted against.
    static func sharedPlanNeedsRefresh(
        after state: PlannerMutationState,
        petId: UUID,
        date: Date,
        activePetId: UUID?,
        calendar: Calendar,
        today: Date
    ) -> Bool {
        state == .confirmed
            && petId == activePetId
            && calendar.isDate(date, inSameDayAs: today)
    }

    /// Complete/undo/skip/snooze only change an occurrence's state, which a
    /// plain read already reflects. Rescheduling and cancelling change which
    /// items belong to the day, and a read cannot show that honestly — those
    /// need the plan regenerated.
    private static func changesDayComposition(_ action: PlannerTaskAction) -> Bool {
        switch action {
        case .reschedule, .cancel: true
        case .complete, .undoComplete, .skip, .undoSkip, .snooze: false
        }
    }

    private func refreshSharedPlan(
        after state: PlannerMutationState,
        petId: UUID,
        on date: Date,
        regeneratingPlan: Bool
    ) async {
        guard let household = model.household,
              model.planState.snapshot != nil,
              Self.sharedPlanNeedsRefresh(
                after: state,
                petId: petId,
                date: date,
                activePetId: model.activePet?.id,
                calendar: household.clock.calendar,
                today: .now
              )
        else { return }
        // A failed refresh leaves the previous shared plan in place rather
        // than blanking Home: the change was confirmed, the re-read was not.
        guard let refreshed = try? await model.plans.plan(
            forPet: petId,
            on: date,
            resectioningCompleted: regeneratingPlan
        ) else { return }
        model.planState.snapshot = refreshed
    }

    // MARK: - Reads

    private func readSchedules(ids: [UUID]) async throws -> [ScheduleRow] {
        guard !ids.isEmpty else { return [] }
        let response = try await client
            .from("task_schedules")
            .select()
            .in("id", values: ids.map(\.uuidString))
            .execute()
        return try decoder.decode([ScheduleRow].self, from: response.data)
    }

    private func readDefinitions(ids: [UUID]) async throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        let response = try await client
            .from("task_definitions")
            .select("id,title")
            .in("id", values: ids.map(\.uuidString))
            .execute()
        let rows = try decoder.decode([DefinitionRow].self, from: response.data)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.title) })
    }

    private func readDispositions(occurrenceIds: [UUID]) async throws -> [Disposition] {
        guard !occurrenceIds.isEmpty else { return [] }
        let response = try await client
            .from("dispositions")
            .select()
            .in("occurrence_id", values: occurrenceIds.map(\.uuidString))
            .order("effective_at")
            .execute()
        return try decoder.decode([Disposition].self, from: response.data)
    }

    // MARK: - Mapping

    private func map(
        row: OccurrenceRow,
        schedule: ScheduleRow?,
        title: String,
        petName: String,
        dispositions: [Disposition],
        calendar: Calendar
    ) -> PlannerAgendaItem {
        let state: PlannerAgendaState
        if queuedWork.isBadged(occurrenceId: row.id) {
            state = .queued
        } else {
            state = switch row.state {
            case .pending, .rescheduled: .pending
            case .completed: .completed
            case .skipped: .skipped
            case .cancelled: .cancelled
            case .expired: .expired
            }
        }
        let completion = dispositions
            .filter { $0.action == .complete && !$0.superseded }
            .max { $0.effectiveAt < $1.effectiveAt }
        let snooze = dispositions
            .filter { $0.action == .snooze && !$0.superseded }
            .compactMap(\.snoozeUntil)
            .max()
        return PlannerAgendaItem(
            id: row.id,
            planItemId: nil,
            occurrenceId: row.id,
            scheduleId: row.scheduleId,
            title: title,
            petId: row.petId,
            petName: petName,
            date: Self.localDate(row.localDueDate, calendar: calendar) ?? .now,
            time: timeSelection(row: row, calendar: calendar),
            recurrence: schedule.map(recurrenceFromSchedule) ?? .once,
            assignment: assignment(row.assignmentKind, userId: row.assignmentUserId),
            reminder: schedule.map(reminderFromSchedule) ?? .none,
            notes: "",
            state: state,
            obligationClass: row.obligationClass,
            origin: row.origin,
            revision: row.revision,
            completionAttribution: completion.map {
                "by \(memberNames[$0.actorUserId] ?? "a caregiver"), \(PlannerFormatters.time($0.effectiveAt, calendar: calendar))"
            },
            snoozedUntil: snooze
        )
    }

    private func queuedItem(id: UUID, draft: PlannerTaskDraft) -> PlannerAgendaItem {
        let pet = model.activePet
        return PlannerAgendaItem(
            id: id,
            planItemId: nil,
            occurrenceId: nil,
            scheduleId: nil,
            title: draft.title,
            petId: draft.petId ?? pet?.id ?? UUID(),
            petName: pet?.name ?? "Pet",
            date: draft.date,
            time: draft.time,
            recurrence: draft.recurrence,
            assignment: draft.assignment,
            reminder: draft.reminder,
            notes: "",
            state: .queued,
            obligationClass: .scheduled,
            origin: .userCreated,
            revision: 1,
            completionAttribution: nil,
            snoozedUntil: nil
        )
    }

    private func recurrenceFromSchedule(_ schedule: ScheduleRow) -> PlannerRecurrence {
        switch schedule.recurrence.type {
        case "daily":
            return .daily
        case "weekly":
            let anchor = Self.localDate(
                schedule.recurrence.anchorDate,
                calendar: model.household?.clock.calendar ?? .current
            ) ?? .now
            let weekday = model.household.map {
                $0.clock.calendar.component(.weekday, from: anchor)
            }.flatMap(PlannerWeekday.init(rawValue:))
            return .selectedWeekdays(Set([weekday].compactMap { $0 }))
        case "weekdays":
            let weekdays = schedule.recurrence.weekdays ?? []
            return .selectedWeekdays(Set(weekdays.compactMap(Self.plannerWeekday(isoValue:))))
        case "every_n_days":
            return .everyNDays(schedule.recurrence.interval ?? 2)
        case "monthly_safe":
            return .monthlySafe(day: schedule.recurrence.dayOfMonth ?? 1)
        default:
            return .once
        }
    }

    private func reminderFromSchedule(_ schedule: ScheduleRow) -> PlannerReminder {
        guard let lead = schedule.reminderConfig?.leadMinutes.first else { return .none }
        if schedule.recurrence.timePolicy == "window", lead == 0 { return .atWindow }
        switch lead {
        case 0: return .atTime
        case 15: return .fifteenMinutesBefore
        case 60: return .oneHourBefore
        default: return .none
        }
    }

    private func timeSelection(row: OccurrenceRow, calendar: Calendar) -> PlannerTimeSelection {
        guard let localDueDate = Self.localDate(row.localDueDate, calendar: calendar) else {
            return .anytime
        }
        switch row.timePolicy {
        case .exactTime:
            guard let dueTime = row.dueTime,
                  let components = Self.timeComponents(dueTime),
                  let date = calendar.date(
                    bySettingHour: components.hour ?? 0,
                    minute: components.minute ?? 0,
                    second: 0,
                    of: localDueDate
                  )
            else { return .anytime }
            return .exact(date)
        case .window:
            return row.window.flatMap(PlanTimeWindow.init(rawValue:)).map(PlannerTimeSelection.window)
                ?? .anytime
        case .anytime:
            return .anytime
        }
    }

    private func historyDetail(_ disposition: Disposition) -> String? {
        switch disposition.action {
        case .skip: disposition.skipReason
        case .snooze:
            disposition.snoozeUntil.map {
                PlannerFormatters.time($0, calendar: model.household?.clock.calendar ?? .current)
            }
        case .reschedule:
            disposition.rescheduleTo.map {
                PlannerFormatters.day($0, calendar: model.household?.clock.calendar ?? .current)
            }
        default: disposition.note
        }
    }

    private func agendaSort(_ lhs: PlannerAgendaItem, _ rhs: PlannerAgendaItem) -> Bool {
        switch (lhs.time, rhs.time) {
        case (.exact(let left), .exact(let right)): left < right
        case (.exact, _): true
        case (_, .exact): false
        default:
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    // MARK: - Payload mapping

    private func recurrencePayload(
        _ recurrence: PlannerRecurrence,
        date: Date,
        time: PlannerTimeSelection,
        calendar: Calendar
    ) -> RecurrencePayload {
        let timing = timingPayload(time, calendar: calendar)
        let type: String
        var interval: Int?
        var weekdays: [Int]?
        var dayOfMonth: Int?
        switch recurrence {
        case .once:
            type = "once"
        case .daily:
            type = "daily"
        case .selectedWeekdays(let selection):
            if selection.count == 1,
               selection.first?.rawValue == calendar.component(.weekday, from: date) {
                type = "weekly"
            } else {
                type = "weekdays"
                weekdays = selection.map(Self.isoWeekday).sorted()
            }
        case .everyNDays(let value):
            type = "every_n_days"
            interval = value
        case .monthlySafe(let day):
            type = "monthly_safe"
            dayOfMonth = day
        }
        return RecurrencePayload(
            type: type,
            anchor_date: dateString(date, calendar: calendar),
            interval: interval,
            weekdays: weekdays,
            day_of_month: dayOfMonth,
            timing: timing
        )
    }

    private func timingPayload(
        _ time: PlannerTimeSelection,
        calendar: Calendar
    ) -> TimingPayload {
        switch time {
        case .anytime:
            return TimingPayload(time_policy: "anytime")
        case .window(let window):
            return TimingPayload(time_policy: "window", window_ref: window.rawValue)
        case .exact(let date):
            let components = calendar.dateComponents([.hour, .minute], from: date)
            return TimingPayload(
                time_policy: "exact_time",
                exact_time: String(
                    format: "%02d:%02d",
                    components.hour ?? 0,
                    components.minute ?? 0
                )
            )
        }
    }

    private func assignmentPayload(_ assignment: PlannerMemberOption.Kind) -> String {
        switch assignment {
        case .anyone: "anyone"
        case .member(let id): "member:\(id.uuidString)"
        }
    }

    private func assignment(_ kind: String, userId: UUID?) -> PlannerMemberOption.Kind {
        kind == "member" && userId != nil ? .member(userId!) : .anyone
    }

    private func reminderPayload(_ reminder: PlannerReminder) -> ReminderPayload? {
        switch reminder {
        case .none: nil
        case .atTime, .atWindow: ReminderPayload(lead_minutes: [0])
        case .fifteenMinutesBefore: ReminderPayload(lead_minutes: [15])
        case .oneHourBefore: ReminderPayload(lead_minutes: [60])
        }
    }

    private func dateString(_ date: Date, calendar: Calendar) -> String {
        SupabaseCoding.dateOnlyString(date, timeZone: calendar.timeZone)
    }

    private func skipReason(_ value: String?) -> String? {
        switch value {
        case "Not relevant today": "not_relevant_today"
        case "Already did this": "already_did_this"
        case "Too busy": "too_busy"
        default: nil
        }
    }

    private static func timeComponents(_ value: String) -> DateComponents? {
        let pieces = value.split(separator: ":")
        guard pieces.count >= 2,
              let hour = Int(pieces[0]),
              let minute = Int(pieces[1])
        else { return nil }
        return DateComponents(hour: hour, minute: minute)
    }

    /// SQL `date` values are civil dates, not instants. Decode them with the
    /// household calendar so a Toronto date cannot silently become the
    /// previous day when represented as midnight UTC.
    private static func localDate(_ value: String, calendar: Calendar) -> Date? {
        let pieces = value.split(separator: "-")
        guard pieces.count == 3,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let day = Int(pieces[2])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func isoWeekday(_ weekday: PlannerWeekday) -> Int {
        weekday == .sunday ? 7 : weekday.rawValue - 1
    }

    private static func plannerWeekday(isoValue: Int) -> PlannerWeekday? {
        PlannerWeekday(rawValue: isoValue == 7 ? 1 : isoValue + 1)
    }
}

// MARK: - Read rows

private struct OccurrenceRow: Decodable {
    let id: UUID
    let petId: UUID
    let scheduleId: UUID?
    let localDueDate: String
    let timePolicy: TimePolicy
    let dueTime: String?
    let window: String?
    let assignmentKind: String
    let assignmentUserId: UUID?
    let state: TaskOccurrence.State
    let obligationClass: ObligationClass
    let origin: TaskOrigin
    let titleOverride: String?
    let revision: Int

    enum CodingKeys: String, CodingKey {
        case id, state, origin, revision
        case petId = "pet_id"
        case scheduleId = "schedule_id"
        case localDueDate = "local_due_date"
        case timePolicy = "time_policy"
        case dueTime = "due_time"
        case window = "window_ref"
        case assignmentKind = "assignment_kind"
        case assignmentUserId = "assignment_user_id"
        case obligationClass = "obligation_class"
        case titleOverride = "title_override"
    }
}

private struct ScheduleRow: Decodable {
    let id: UUID
    let taskDefinitionId: UUID
    let recurrence: RecurrenceRow
    let reminderConfig: ReminderPayload?
    let revision: Int

    enum CodingKeys: String, CodingKey {
        case id, recurrence, revision
        case taskDefinitionId = "task_definition_id"
        case reminderConfig = "reminder_config"
    }
}

private struct DefinitionRow: Decodable {
    let id: UUID
    let title: String
}

private struct RecurrenceRow: Decodable {
    let type: String
    let anchorDate: String
    let interval: Int?
    let weekdays: [Int]?
    let dayOfMonth: Int?
    let timePolicy: String

    enum CodingKeys: String, CodingKey {
        case type, interval, weekdays
        case anchorDate = "anchor_date"
        case dayOfMonth = "day_of_month"
        case timePolicy = "time_policy"
    }
}

// MARK: - Command payloads

private struct TimingPayload: Encodable {
    let time_policy: String
    var window_ref: String?
    var exact_time: String?
}

private struct RecurrencePayload: Encodable {
    let type: String
    let anchor_date: String
    var interval: Int?
    var weekdays: [Int]?
    var day_of_month: Int?
    let time_policy: String
    var window_ref: String?
    var exact_time: String?

    init(
        type: String,
        anchor_date: String,
        interval: Int?,
        weekdays: [Int]?,
        day_of_month: Int?,
        timing: TimingPayload
    ) {
        self.type = type
        self.anchor_date = anchor_date
        self.interval = interval
        self.weekdays = weekdays
        self.day_of_month = day_of_month
        time_policy = timing.time_policy
        window_ref = timing.window_ref
        exact_time = timing.exact_time
    }
}

private struct ReminderPayload: Codable {
    let leadMinutes: [Int]

    enum CodingKeys: String, CodingKey {
        case leadMinutes = "lead_minutes"
    }

    init(lead_minutes: [Int]) {
        leadMinutes = lead_minutes
    }
}

private struct CreatePayload: Encodable {
    let pet_id: UUID
    let title: String
    let recurrence: RecurrencePayload
    let assignment: String
    let category: String
    let obligation_class: String
    let reminder_config: ReminderPayload?
}

private struct OccurrenceOnlyPayload: Encodable {
    let occurrence_id: UUID
}

private struct SkipPayload: Encodable {
    let occurrence_id: UUID
    let skip_reason: String?
    let confirm_required: Bool
}

private struct SnoozePayload: Encodable {
    let occurrence_id: UUID
    let snooze_until: String
}

private struct CancelPayload: Encodable {
    let occurrence_id: UUID
    let expected_revision: Int
    let confirm_required: Bool
}

private struct ArchivePayload: Encodable {
    let schedule_id: UUID
    let expected_revision: Int
    let confirm_required: Bool
}

private struct ReschedulePayload: Encodable {
    let occurrence_id: UUID
    let expected_revision: Int
    let local_due_date: String
    let time_policy: String
    let window_ref: String?
    let exact_time: String?

    init(
        occurrence_id: UUID,
        expected_revision: Int,
        local_due_date: String,
        timing: TimingPayload
    ) {
        self.occurrence_id = occurrence_id
        self.expected_revision = expected_revision
        self.local_due_date = local_due_date
        time_policy = timing.time_policy
        window_ref = timing.window_ref
        exact_time = timing.exact_time
    }
}

private struct EditOccurrencePayload: Encodable {
    let occurrence_id: UUID
    let expected_revision: Int
    let title: String?
    let time_policy: String
    let window_ref: String?
    let exact_time: String?
    let assignment: String?

    init(
        occurrence_id: UUID,
        expected_revision: Int,
        title: String?,
        timing: TimingPayload,
        assignment: String?
    ) {
        self.occurrence_id = occurrence_id
        self.expected_revision = expected_revision
        self.title = title
        time_policy = timing.time_policy
        window_ref = timing.window_ref
        exact_time = timing.exact_time
        self.assignment = assignment
    }
}

private struct EditFuturePayload: Encodable {
    let schedule_id: UUID
    let expected_revision: Int
    let split_date: String
    let recurrence: RecurrencePayload
    let title: String?
    let assignment: String?
    let reminder_config: ReminderPayload?
}
