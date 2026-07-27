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
