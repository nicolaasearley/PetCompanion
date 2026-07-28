import XCTest
@testable import PetCompanion

@MainActor
final class PlannerTests: XCTestCase {
    func testSelectedWeekdaySummaryIsHumanReadableAndCalendarOrdered() {
        let calendar = testCalendar
        let recurrence = PlannerRecurrence.selectedWeekdays([.monday, .wednesday, .friday])
        let summary = recurrence.summary(starting: day(2026, 7, 27), calendar: calendar)

        XCTAssertTrue(summary.contains("Mon"))
        XCTAssertTrue(summary.contains("Wed"))
        XCTAssertTrue(summary.contains("Fri"))
        XCTAssertLessThan(
            summary.range(of: "Mon")!.lowerBound,
            summary.range(of: "Wed")!.lowerBound
        )
        XCTAssertLessThan(
            summary.range(of: "Wed")!.lowerBound,
            summary.range(of: "Fri")!.lowerBound
        )
    }

    func testSelectedWeekdayRecurrenceRequiresAtLeastOneDay() {
        let draft = PlannerTaskDraft(
            title: "Brush coat",
            petId: UUID(),
            date: day(2026, 7, 27),
            recurrence: .selectedWeekdays([])
        )

        XCTAssertEqual(
            draft.validationMessage(calendar: testCalendar, today: day(2026, 7, 27)),
            "Choose at least one weekday."
        )
    }

    func testRecurringEditRequiresExplicitScope() async throws {
        let fixture = fixture()
        let service = InMemoryPlannerService(
            context: fixture.context,
            items: [fixture.item]
        )
        var draft = fixture.item.editableDraft()
        draft.title = "Evening brush"

        do {
            _ = try await service.save(draft, scope: nil)
            XCTFail("A recurring edit must not silently choose a scope")
        } catch let error as PlannerServiceError {
            guard case .unavailable(let message) = error else {
                return XCTFail("Expected a scoped edit error")
            }
            XCTAssertTrue(message.contains("this and future"))
        }
    }

    func testThisOccurrenceEditMovesOnlySelectedOccurrence() async throws {
        let fixture = fixture()
        let service = InMemoryPlannerService(
            context: fixture.context,
            items: [fixture.item]
        )
        var draft = fixture.item.editableDraft()
        let movedDate = day(2026, 7, 29)
        draft.date = movedDate

        _ = try await service.save(draft, scope: .occurrenceOnly)

        let oldDay = try await service.agenda(on: fixture.item.date)
        let newDay = try await service.agenda(on: movedDate)
        XCTAssertTrue(oldDay.items.isEmpty)
        XCTAssertEqual(newDay.items.map(\.id), [fixture.item.id])
    }

    func testSkipAndUndoSkipRemainInHistory() async throws {
        let fixture = fixture()
        let service = InMemoryPlannerService(
            context: fixture.context,
            items: [fixture.item]
        )

        _ = try await service.perform(.skip(reason: "Too busy"), on: fixture.item)
        let skippedAgenda = try await service.agenda(on: fixture.item.date)
        let skipped = try XCTUnwrap(skippedAgenda.items.first)
        XCTAssertEqual(skipped.state, .skipped)

        _ = try await service.perform(.undoSkip, on: skipped)
        let restoredAgenda = try await service.agenda(on: fixture.item.date)
        let restored = try XCTUnwrap(restoredAgenda.items.first)
        XCTAssertEqual(restored.state, .pending)

        let history = try await service.history(for: restored)
        XCTAssertEqual(history.map(\.action), [.undoSkip, .skip])
        XCTAssertEqual(history.last?.detail, "Too busy")
    }

    func testSnoozeMustStayLaterOnCurrentDay() async throws {
        let calendar = testCalendar
        let now = Date()
        let householdId = UUID()
        let pet = Pet(
            householdId: householdId,
            name: "Maple",
            birthInfo: .unknown
        )
        let context = PlannerContext(
            pets: [pet],
            members: [.anyone],
            calendar: calendar,
            capabilities: .fullTaskManagement
        )
        let item = PlannerAgendaItem(
            id: UUID(),
            planItemId: nil,
            occurrenceId: UUID(),
            scheduleId: nil,
            title: "Potty break",
            petId: pet.id,
            petName: pet.name,
            date: now,
            time: .anytime,
            recurrence: .once,
            assignment: .anyone,
            reminder: .none,
            notes: "",
            state: .pending,
            obligationClass: .scheduled,
            origin: .userCreated,
            revision: 1,
            completionAttribution: nil,
            snoozedUntil: nil
        )
        let service = InMemoryPlannerService(context: context, items: [item])
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!

        do {
            _ = try await service.perform(.snooze(until: tomorrow), on: item)
            XCTFail("Snooze must not change the occurrence day")
        } catch let error as PlannerServiceError {
            XCTAssertEqual(error, .invalidSnooze)
        }
    }

    func testFutureOccurrenceDoesNotRequirePlanItemIdentity() async throws {
        let fixture = fixture()
        var item = fixture.item
        item.planItemId = nil
        let service = InMemoryPlannerService(
            context: fixture.context,
            items: [item]
        )

        _ = try await service.perform(.complete, on: item)

        let updatedAgenda = try await service.agenda(on: item.date)
        let updated = try XCTUnwrap(updatedAgenda.items.first)
        XCTAssertEqual(updated.state, .completed)
    }

    // MARK: - Optimistic queued work

    func testPlaceholderIsReleasedOnceItsOperationLeavesTheQueue() {
        let fixture = fixture()
        let operationId = UUID()
        var work = QueuedPlannerWork()
        work.addPlaceholder(fixture.item, operationId: operationId)

        // Still waiting: the placeholder is the only row the caregiver has.
        work.settle(against: [operation(id: operationId, state: .queued)])
        XCTAssertEqual(
            work.placeholderItems(on: fixture.item.date, calendar: testCalendar).map(\.id),
            [fixture.item.id]
        )

        // Replayed: the operation is gone from the queue and the real
        // occurrence now arrives from the server, so keeping the placeholder
        // would show the task twice.
        work.settle(against: [])
        XCTAssertTrue(
            work.placeholderItems(on: fixture.item.date, calendar: testCalendar).isEmpty
        )
    }

    func testRejectedCreateDoesNotLeaveAPlaceholderPretendingTheTaskExists() {
        let fixture = fixture()
        let operationId = UUID()
        var work = QueuedPlannerWork()
        work.addPlaceholder(fixture.item, operationId: operationId)

        work.settle(against: [operation(id: operationId, state: .rejected)])

        XCTAssertTrue(
            work.placeholderItems(on: fixture.item.date, calendar: testCalendar).isEmpty
        )
    }

    func testQueuedBadgeClearsWithTheOperationThatOwedTheConfirmation() {
        let occurrenceId = UUID()
        let operationId = UUID()
        var work = QueuedPlannerWork()
        work.badge(occurrenceId: occurrenceId, operationId: operationId)

        work.settle(against: [operation(id: operationId, state: .failed)])
        XCTAssertTrue(work.isBadged(occurrenceId: occurrenceId))

        work.settle(against: [])
        XCTAssertFalse(work.isBadged(occurrenceId: occurrenceId))
    }

    // MARK: - Shared plan state

    func testQueuedWorkDoesNotRefreshTheSharedPlanButConfirmedWorkDoes() {
        let petId = UUID()
        let today = day(2026, 7, 27)

        XCTAssertFalse(
            RealPlannerService.sharedPlanNeedsRefresh(
                after: .queued,
                petId: petId,
                date: today,
                activePetId: petId,
                calendar: testCalendar,
                today: today
            ),
            "A queued change has nothing confirmed for Home to read yet"
        )
        XCTAssertTrue(
            RealPlannerService.sharedPlanNeedsRefresh(
                after: .confirmed,
                petId: petId,
                date: today,
                activePetId: petId,
                calendar: testCalendar,
                today: today
            )
        )
        XCTAssertFalse(
            RealPlannerService.sharedPlanNeedsRefresh(
                after: .confirmed,
                petId: petId,
                date: day(2026, 7, 29),
                activePetId: petId,
                calendar: testCalendar,
                today: today
            ),
            "Home renders today; another day's change must not replace it"
        )
        XCTAssertFalse(
            RealPlannerService.sharedPlanNeedsRefresh(
                after: .confirmed,
                petId: petId,
                date: today,
                activePetId: UUID(),
                calendar: testCalendar,
                today: today
            ),
            "Home renders the active pet only"
        )
    }

    /// The claim in doc 19 that Home and Planner share one plan state, held to
    /// through the adapter the app actually runs in mock/compat mode.
    func testCompletingInPlannerLeavesHomeConsistent() async throws {
        let model = AppModel.preview()
        let home = HomeViewModel(model: model)
        await home.loadInitial()
        let service = PlanServicePlannerAdapter(model: model)
        _ = try await service.context()

        let agenda = try await service.agenda(on: Date())
        let target = try XCTUnwrap(
            agenda.items.first { $0.state == .pending && $0.planItemId != nil }
        )
        XCTAssertEqual(home.snapshot?.occurrences.first { $0.id == target.occurrenceId }?.state, .pending)

        _ = try await service.perform(.complete, on: target)

        let completed = try XCTUnwrap(
            home.snapshot?.occurrences.first { $0.id == target.occurrenceId }
        )
        XCTAssertEqual(completed.state, .completed)
    }

    func testSignOutClearsThePlanTheNextAccountMustNotSee() async {
        let model = AppModel.preview()
        let home = HomeViewModel(model: model)
        await home.loadInitial()
        XCTAssertNotNil(home.snapshot)

        model.signOut()

        XCTAssertNil(model.planState.snapshot)
        XCTAssertNil(home.snapshot)
    }

    private func operation(
        id: UUID,
        state: OfflineOperation.State
    ) -> OfflineOperation {
        OfflineOperation(
            id: id,
            accountId: UUID(),
            command: "create_recurring_task",
            payload: .object([:]),
            payloadFingerprint: id.uuidString,
            clientIdempotencyKey: UUID().uuidString,
            recordedAt: SupabaseCoding.iso8601Now(),
            effectiveAt: nil,
            createdAt: .now,
            updatedAt: .now,
            state: state,
            attemptCount: 0
        )
    }

    private var testCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_CA")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        testCalendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func fixture() -> (context: PlannerContext, item: PlannerAgendaItem) {
        let householdId = UUID()
        let pet = Pet(
            householdId: householdId,
            name: "Maple",
            birthInfo: .unknown
        )
        let context = PlannerContext(
            pets: [pet],
            members: [.anyone],
            calendar: testCalendar,
            capabilities: .fullTaskManagement
        )
        let id = UUID()
        let item = PlannerAgendaItem(
            id: id,
            planItemId: nil,
            occurrenceId: id,
            scheduleId: UUID(),
            title: "Brush coat",
            petId: pet.id,
            petName: pet.name,
            date: day(2026, 7, 27),
            time: .window(.evening),
            recurrence: .selectedWeekdays([.monday, .wednesday, .friday]),
            assignment: .anyone,
            reminder: .atWindow,
            notes: "Use the soft brush.",
            state: .pending,
            obligationClass: .scheduled,
            origin: .recurringSchedule,
            revision: 1,
            completionAttribution: nil,
            snoozedUntil: nil
        )
        return (context, item)
    }
}
