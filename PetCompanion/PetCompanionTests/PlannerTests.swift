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

    // MARK: - Forward agenda grouping (PL-01)

    func testAgendaWindowDayStartsAreInclusiveAndHouseholdLocal() {
        let calendar = testCalendar
        let start = day(2026, 7, 29)
        let end = PlannerAgendaGrouping.windowEnd(from: start, dayCount: 14, calendar: calendar)
        let days = PlannerAgendaGrouping.dayStarts(from: start, through: end, calendar: calendar)

        XCTAssertEqual(days.count, 14)
        XCTAssertEqual(days.first, start)
        XCTAssertEqual(days.last, day(2026, 8, 11))
        XCTAssertEqual(
            PlannerAgendaGrouping.windowEnd(from: start, dayCount: 1, calendar: calendar),
            start
        )
    }

    func testAgendaSectionHeadingsDistinguishToday() {
        let calendar = testCalendar
        let today = day(2026, 7, 29)
        let tomorrow = day(2026, 7, 30)

        let todayHeading = PlannerAgendaGrouping.sectionHeading(
            for: today,
            today: today,
            calendar: calendar
        )
        let tomorrowHeading = PlannerAgendaGrouping.sectionHeading(
            for: tomorrow,
            today: today,
            calendar: calendar
        )
        XCTAssertTrue(todayHeading.hasPrefix("Today · "), todayHeading)
        XCTAssertFalse(tomorrowHeading.hasPrefix("Today"), tomorrowHeading)
        XCTAssertTrue(tomorrowHeading.localizedCaseInsensitiveContains("Jul"))
    }

    func testPastDaysRejectInlineAddWhileTodayAndFutureAllowIt() {
        let calendar = testCalendar
        let today = day(2026, 7, 29)
        XCTAssertFalse(
            PlannerAgendaGrouping.allowsInlineAdd(on: day(2026, 7, 28), today: today, calendar: calendar)
        )
        XCTAssertTrue(
            PlannerAgendaGrouping.allowsInlineAdd(on: today, today: today, calendar: calendar)
        )
        XCTAssertTrue(
            PlannerAgendaGrouping.allowsInlineAdd(on: day(2026, 8, 1), today: today, calendar: calendar)
        )
    }

    func testWeekNavigatorTitleUsesThisWeekInsideCurrentWeek() {
        let calendar = testCalendar
        let today = day(2026, 7, 29) // Wednesday
        XCTAssertEqual(
            PlannerAgendaGrouping.weekNavigatorTitle(for: today, today: today, calendar: calendar),
            "This week"
        )
        let nextWeek = day(2026, 8, 5)
        let title = PlannerAgendaGrouping.weekNavigatorTitle(
            for: nextWeek,
            today: today,
            calendar: calendar
        )
        XCTAssertNotEqual(title, "This week")
        XCTAssertTrue(title.contains("–"))
    }

    func testMergingAgendaPagesKeepsOrderAndPrefersIncoming() {
        let calendar = testCalendar
        let monday = day(2026, 7, 27)
        let tuesday = day(2026, 7, 28)
        let existing = [
            PlannerDayAgenda(date: monday, items: [], lastVerifiedAt: nil, isStale: false),
            PlannerDayAgenda(date: tuesday, items: [], lastVerifiedAt: nil, isStale: true),
        ]
        let incoming = [
            PlannerDayAgenda(date: tuesday, items: [], lastVerifiedAt: .now, isStale: false),
            PlannerDayAgenda(date: day(2026, 7, 29), items: [], lastVerifiedAt: .now, isStale: false),
        ]
        let merged = PlannerAgendaGrouping.merging(existing, with: incoming, calendar: calendar)
        XCTAssertEqual(merged.map(\.date), [monday, tuesday, day(2026, 7, 29)])
        XCTAssertEqual(merged[1].isStale, false)
    }

    func testDatesWithContentIncludesTasksAndEvents() {
        let calendar = testCalendar
        let monday = day(2026, 7, 27)
        let tuesday = day(2026, 7, 28)
        let wednesday = day(2026, 7, 29)
        var tuesdayAgenda = PlannerDayAgenda(
            date: tuesday,
            items: [],
            lastVerifiedAt: nil,
            isStale: false
        )
        tuesdayAgenda.events = [
            agendaEvent(title: "Class", kind: .classSession, date: tuesday, startTime: "18:00", allDay: false)
        ]
        let days = [
            PlannerDayAgenda(
                date: monday,
                items: [fixture().item],
                lastVerifiedAt: nil,
                isStale: false
            ),
            tuesdayAgenda,
            PlannerDayAgenda(date: wednesday, items: [], lastVerifiedAt: nil, isStale: false),
        ]

        let content = PlannerAgendaGrouping.datesWithContent(from: days, calendar: calendar)
        XCTAssertEqual(content, [monday, tuesday])
    }

    func testEventContentDatesSkipsCancelledAndOutsideRange() {
        let calendar = testCalendar
        let dates = PlannerAgendaGrouping.eventContentDates(
            from: [
                agendaEvent(
                    title: "In range",
                    kind: .vetAppointment,
                    date: day(2026, 7, 15),
                    startTime: nil,
                    allDay: true
                ),
                agendaEvent(
                    title: "Cancelled",
                    kind: .other,
                    date: day(2026, 7, 16),
                    startTime: nil,
                    allDay: true,
                    status: .cancelled
                ),
                agendaEvent(
                    title: "Next month",
                    kind: .other,
                    date: day(2026, 8, 1),
                    startTime: nil,
                    allDay: true
                ),
            ],
            from: day(2026, 7, 1),
            through: day(2026, 7, 31),
            calendar: calendar
        )
        XCTAssertEqual(dates, [day(2026, 7, 15)])
    }

    func testMonthGridDaysAlignToFirstWeekdayAndPadWeeks() {
        let calendar = testCalendar
        // July 2026 starts on Wednesday. With firstWeekday = Monday, that is
        // two leading pads (Mon/Tue empty).
        let cells = PlannerAgendaGrouping.monthGridDays(for: day(2026, 7, 1), calendar: calendar)
        XCTAssertEqual(cells.count % 7, 0)
        XCTAssertNil(cells[0])
        XCTAssertNil(cells[1])
        XCTAssertEqual(cells[2], day(2026, 7, 1))
        XCTAssertEqual(cells.compactMap { $0 }.count, 31)
        XCTAssertEqual(cells.compactMap { $0 }.last, day(2026, 7, 31))

        let bounds = PlannerAgendaGrouping.monthBounds(for: day(2026, 7, 15), calendar: calendar)
        XCTAssertEqual(bounds?.start, day(2026, 7, 1))
        XCTAssertEqual(bounds?.end, day(2026, 7, 31))

        let symbols = PlannerAgendaGrouping.monthWeekdaySymbols(calendar: calendar)
        XCTAssertEqual(symbols.count, 7)
        XCTAssertEqual(symbols.first, calendar.veryShortWeekdaySymbols[calendar.firstWeekday - 1])
    }

    func testMonthJumpMarkersIncludeLoadedTasksAndFetchedMonthEvents() async throws {
        let fixture = fixture()
        let householdId = fixture.context.pets[0].householdId
        let farEvent = HouseholdEvent(
            id: UUID(),
            householdId: householdId,
            petId: fixture.item.petId,
            kind: .vetAppointment,
            title: "August checkup",
            startDate: day(2026, 8, 20),
            startTime: "10:00",
            endTime: nil,
            allDay: false,
            locationText: nil,
            providerId: nil,
            notes: nil,
            reminderLeadMinutes: [],
            status: .confirmed,
            revision: 1
        )
        let service = InMemoryPlannerService(
            context: fixture.context,
            items: [fixture.item]
        )
        let store = PlannerStore(
            service: service,
            eventService: InMemoryEventService(seeded: [farEvent]),
            householdId: householdId,
            initialDate: day(2026, 7, 27)
        )
        await store.start()

        await store.refreshMonthJumpMarkers(for: day(2026, 8, 1))
        XCTAssertTrue(
            store.monthJumpContentDates.contains(day(2026, 7, 27)),
            "Loaded-window task days remain marked while browsing another month"
        )
        XCTAssertTrue(
            store.monthJumpContentDates.contains(day(2026, 8, 20)),
            "Confirmed events in the visible month should appear as dots"
        )
    }

    func testMultiDayAgendaReturnsEmptySlotsBetweenItems() async throws {
        let fixture = fixture()
        let calendar = fixture.context.calendar
        let laterId = UUID()
        let later = PlannerAgendaItem(
            id: laterId,
            planItemId: nil,
            occurrenceId: laterId,
            scheduleId: nil,
            title: "Vet prep",
            petId: fixture.item.petId,
            petName: fixture.item.petName,
            date: day(2026, 7, 29),
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

        let service = InMemoryPlannerService(
            context: fixture.context,
            items: [fixture.item, later]
        )
        let days = try await service.agenda(from: day(2026, 7, 27), through: day(2026, 7, 29))
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[0].items.map(\.title), ["Brush coat"])
        XCTAssertTrue(days[1].items.isEmpty, "Middle day must still render as an honest empty")
        XCTAssertEqual(days[2].items.map(\.title), ["Vet prep"])
        XCTAssertEqual(
            days.map { calendar.startOfDay(for: $0.date) },
            [day(2026, 7, 27), day(2026, 7, 28), day(2026, 7, 29)]
        )
    }

    func testPlannerStoreLoadsAForwardWindowNotASingleDay() async throws {
        let fixture = fixture()
        let secondId = UUID()
        let second = PlannerAgendaItem(
            id: secondId,
            planItemId: nil,
            occurrenceId: secondId,
            scheduleId: nil,
            title: "Nail trim",
            petId: fixture.item.petId,
            petName: fixture.item.petName,
            date: day(2026, 7, 30),
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

        let service = InMemoryPlannerService(
            context: fixture.context,
            items: [fixture.item, second]
        )
        let store = PlannerStore(service: service, initialDate: day(2026, 7, 27))
        await store.start()

        XCTAssertEqual(store.days.count, PlannerAgendaGrouping.defaultForwardDayCount)
        XCTAssertEqual(store.days.first?.date, day(2026, 7, 27))
        XCTAssertEqual(
            store.days.first(where: { $0.date == day(2026, 7, 27) })?.items.map(\.title),
            ["Brush coat"]
        )
        XCTAssertEqual(
            store.days.first(where: { $0.date == day(2026, 7, 30) })?.items.map(\.title),
            ["Nail trim"]
        )
        XCTAssertTrue(
            store.days.contains(where: { $0.date == day(2026, 7, 28) && !$0.hasContent })
        )
    }

    // MARK: - Event rows on the agenda (US-080)

    func testAttachingEventsPlacesConfirmedOnesOnMatchingDays() {
        let calendar = testCalendar
        let monday = day(2026, 7, 27)
        let tuesday = day(2026, 7, 28)
        let wednesday = day(2026, 7, 29)
        let days = [
            PlannerDayAgenda(date: monday, items: [], lastVerifiedAt: nil, isStale: false),
            PlannerDayAgenda(date: tuesday, items: [], lastVerifiedAt: nil, isStale: false),
            PlannerDayAgenda(date: wednesday, items: [], lastVerifiedAt: nil, isStale: false),
        ]
        let events = [
            agendaEvent(
                title: "Puppy class",
                kind: .classSession,
                date: tuesday,
                startTime: "18:30",
                allDay: false
            ),
            agendaEvent(
                title: "Cancelled grooming",
                kind: .groomingVisit,
                date: tuesday,
                startTime: "10:00",
                allDay: false,
                status: .cancelled
            ),
            agendaEvent(
                title: "Vet visit",
                kind: .vetAppointment,
                date: wednesday,
                startTime: nil,
                allDay: true
            ),
            agendaEvent(
                title: "Outside window",
                kind: .other,
                date: day(2026, 8, 1),
                startTime: "09:00",
                allDay: false
            ),
        ]

        let attached = PlannerAgendaGrouping.attaching(events: events, to: days, calendar: calendar)
        XCTAssertTrue(attached[0].events.isEmpty)
        XCTAssertEqual(attached[1].events.map(\.title), ["Puppy class"])
        XCTAssertEqual(attached[2].events.map(\.title), ["Vet visit"])
        XCTAssertTrue(attached[1].hasContent)
    }

    func testMixingEventsAndTasksSortsByClockThenWindows() {
        let calendar = testCalendar
        let today = day(2026, 7, 29)
        let eveningTask = PlannerAgendaItem(
            id: UUID(),
            planItemId: nil,
            occurrenceId: UUID(),
            scheduleId: nil,
            title: "Evening meal",
            petId: UUID(),
            petName: "Maple",
            date: today,
            time: .window(.evening),
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
        let morningTask = PlannerAgendaItem(
            id: UUID(),
            planItemId: nil,
            occurrenceId: UUID(),
            scheduleId: nil,
            title: "Morning meal",
            petId: eveningTask.petId,
            petName: "Maple",
            date: today,
            time: .window(.morning),
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
        let exactTask = PlannerAgendaItem(
            id: UUID(),
            planItemId: nil,
            occurrenceId: UUID(),
            scheduleId: nil,
            title: "Bring health records",
            petId: eveningTask.petId,
            petName: "Maple",
            date: today,
            time: .exact(calendar.date(bySettingHour: 13, minute: 45, second: 0, of: today)!),
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
        let classEvent = agendaEvent(
            title: "Puppy class",
            kind: .classSession,
            date: today,
            startTime: "18:30",
            allDay: false
        )
        let vetEvent = agendaEvent(
            title: "Vet appointment",
            kind: .vetAppointment,
            date: today,
            startTime: "14:00",
            allDay: false
        )
        let dayAgenda = PlannerDayAgenda(
            date: today,
            items: [eveningTask, morningTask, exactTask],
            events: [classEvent, vetEvent],
            lastVerifiedAt: .now,
            isStale: false
        )

        let titles = PlannerAgendaGrouping.entries(for: dayAgenda, calendar: calendar).map(\.title)
        XCTAssertEqual(
            titles,
            [
                "Bring health records", // 13:45
                "Vet appointment",      // 14:00
                "Puppy class",          // 18:30
                "Morning meal",         // morning window
                "Evening meal",         // evening window
            ]
        )
    }

    func testUnplannedDayWithEventsIsNotEmptyAndSuppressesUnplannedCopy() {
        let calendar = testCalendar
        let today = day(2026, 7, 29)
        let future = day(2026, 8, 2)
        var dayAgenda = PlannerDayAgenda(
            date: future,
            items: [],
            lastVerifiedAt: nil,
            isStale: false,
            coverage: .notGenerated
        )
        XCTAssertNotNil(dayAgenda.unplannedDayMessage(today: today, calendar: calendar))

        dayAgenda.events = [
            agendaEvent(
                title: "Class",
                kind: .classSession,
                date: future,
                startTime: "17:00",
                allDay: false
            ),
        ]
        XCTAssertTrue(dayAgenda.hasContent)
        XCTAssertNil(
            dayAgenda.unplannedDayMessage(today: today, calendar: calendar),
            "Events are real content even when the Daily Plan is not generated"
        )
    }

    func testPlannerStoreAttachesEventsIntoTheForwardWindow() async throws {
        let fixture = fixture()
        let householdId = fixture.context.pets[0].householdId
        let event = HouseholdEvent(
            id: UUID(),
            householdId: householdId,
            petId: fixture.item.petId,
            kind: .classSession,
            title: "Puppy class",
            startDate: day(2026, 7, 28),
            startTime: "18:30",
            endTime: nil,
            allDay: false,
            locationText: "Community hall",
            providerId: nil,
            notes: nil,
            reminderLeadMinutes: [60],
            status: .confirmed,
            revision: 1
        )
        let service = InMemoryPlannerService(
            context: fixture.context,
            items: [fixture.item]
        )
        let store = PlannerStore(
            service: service,
            eventService: InMemoryEventService(seeded: [event]),
            householdId: householdId,
            initialDate: day(2026, 7, 27)
        )
        await store.start()

        let tuesday = store.days.first { $0.date == day(2026, 7, 28) }
        XCTAssertEqual(tuesday?.events.map(\.title), ["Puppy class"])
        XCTAssertEqual(tuesday?.events.first?.locationText, "Community hall")
        XCTAssertTrue(tuesday?.hasContent == true)

        let mondayEntries = store.entries(
            for: try XCTUnwrap(store.days.first { $0.date == day(2026, 7, 27) })
        )
        XCTAssertEqual(mondayEntries.map(\.title), ["Brush coat"])
        guard case .occurrence = mondayEntries.first else {
            return XCTFail("Monday should remain a task occurrence row")
        }
    }

    private func agendaEvent(
        title: String,
        kind: EventKind,
        date: Date,
        startTime: String?,
        allDay: Bool,
        status: EventStatus = .confirmed
    ) -> PlannerAgendaEvent {
        PlannerAgendaEvent(
            id: UUID(),
            kind: kind,
            title: title,
            petId: nil,
            petName: nil,
            date: date,
            startTime: startTime,
            allDay: allDay,
            locationText: nil,
            notes: nil,
            status: status,
            revision: 1
        )
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
