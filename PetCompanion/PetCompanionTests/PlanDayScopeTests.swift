import Foundation
import XCTest
@testable import PetCompanion

/// A daily plan is addressed by a local day, and the household's time zone is
/// the only place that day is defined. These cover the boundary where a
/// device's calendar, a GMT-decoded SQL `date`, and the household's own day
/// disagree — and what the app is allowed to show for a day it has no plan
/// for (engine §10.1, §10.4; IA §15.1).
@MainActor
final class PlanDayScopeTests: XCTestCase {
    private let stockholm = TimeZone(identifier: "Europe/Stockholm")!
    private let toronto = TimeZone(identifier: "America/Toronto")!

    func testTheHouseholdTimeZoneDecidesWhichDayWasAskedFor() {
        // Midnight on 28 July in Stockholm, and mid-morning the same
        // Stockholm day. In Toronto the first instant is still the 27th.
        let requested = Date(timeIntervalSince1970: 1_785_189_600) // 2026-07-27T22:00Z
        let now = Date(timeIntervalSince1970: 1_785_232_800) // 2026-07-28T10:00Z

        XCTAssertTrue(
            RealPlanService.isSameLocalDay(requested, now, timeZone: stockholm),
            "Both instants are 28 July in the household's zone"
        )
        XCTAssertFalse(
            RealPlanService.isSameLocalDay(requested, now, timeZone: toronto),
            "Reading the same request in a device zone would send today's "
                + "request down the elapsed-day path"
        )
    }

    func testAnExplicitlyDatedRequestIsNeverConfusedWithToday() {
        let now = Date(timeIntervalSince1970: 1_785_232_800) // 2026-07-28T10:00Z
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = stockholm
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

        XCTAssertFalse(RealPlanService.isSameLocalDay(yesterday, now, timeZone: stockholm))
    }

    /// The bug this whole path exists to stop, held at the type level: a
    /// `plans.local_date` handed straight back as a "which day" argument
    /// loses a day for every household west of GMT.
    func testPlanLocalDateIsReAnchoredBeforeItIsUsedAsALocalDay() throws {
        let plan = try decodedPlan(localDate: "2026-07-28")
        var torontoCalendar = Calendar(identifier: .gregorian)
        torontoCalendar.timeZone = toronto

        XCTAssertEqual(
            torontoCalendar.component(.day, from: plan.localDate),
            27,
            "The raw decoded value really is the previous evening in Toronto"
        )
        XCTAssertEqual(
            SupabaseCoding.dateOnlyString(plan.localDayStart(in: toronto), timeZone: toronto),
            "2026-07-28"
        )
        XCTAssertEqual(
            SupabaseCoding.dateOnlyString(plan.localDayStart(in: stockholm), timeZone: stockholm),
            "2026-07-28"
        )
    }

    func testUnreadableDayAndUnplannedDayGetDifferentDeepLinkOutcomes() {
        XCTAssertEqual(
            NotificationDeepLinkResolver.failure(for: PlanServiceError.noPlanForDay),
            .targetNoLongerInPlan,
            "A day with no plan is a fact about the reminder, not an outage"
        )
        XCTAssertEqual(
            NotificationDeepLinkResolver.failure(for: PlanServiceError.planNotFound),
            .planUnavailable
        )
        XCTAssertEqual(
            NotificationDeepLinkResolver.failure(for: PlanServiceError.notSignedIn),
            .noAccess
        )
    }

    func testAQuietDayAndAnUnplannedDayNeverReadTheSame() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = stockholm
        let today = calendar.date(from: DateComponents(year: 2026, month: 7, day: 28))!

        let quiet = PlannerDayAgenda(
            date: today,
            items: [],
            lastVerifiedAt: .now,
            isStale: false
        )
        XCTAssertNil(
            quiet.unplannedDayMessage(today: today, calendar: calendar),
            "A day that was read and held nothing is a real empty day"
        )

        let future = PlannerDayAgenda(
            date: calendar.date(byAdding: .day, value: 3, to: today)!,
            items: [],
            lastVerifiedAt: nil,
            isStale: false,
            coverage: .notGenerated
        )
        XCTAssertEqual(
            future.unplannedDayMessage(today: today, calendar: calendar),
            "This day hasn't been planned yet. Its plan is prepared when the day begins."
        )

        let past = PlannerDayAgenda(
            date: calendar.date(byAdding: .day, value: -9, to: today)!,
            items: [],
            lastVerifiedAt: nil,
            isStale: false,
            coverage: .notGenerated
        )
        XCTAssertEqual(
            past.unplannedDayMessage(today: today, calendar: calendar),
            "No plan was kept for this day, so Settle can't say what was scheduled."
        )
    }

    // MARK: - Through the Planner adapter

    func testPlannerAsksForTheDayItIsShowingAndSaysSoWhenThereIsNone() async throws {
        let fixture = try adapterFixture()
        let service = PlanServicePlannerAdapter(model: fixture.model)
        _ = try await service.context()
        let calendar = fixture.model.household!.clock.calendar

        let today = try await service.agenda(on: Date())
        XCTAssertEqual(today.coverage, .planned)
        XCTAssertEqual(fixture.plans.requestedDates.count, 1)

        let future = calendar.date(byAdding: .day, value: 4, to: Date())!
        let futureAgenda = try await service.agenda(on: future)

        XCTAssertEqual(futureAgenda.coverage, .notGenerated)
        XCTAssertTrue(futureAgenda.items.isEmpty)
        XCTAssertEqual(
            fixture.plans.requestedDates.map { calendar.startOfDay(for: $0) },
            [calendar.startOfDay(for: Date()), calendar.startOfDay(for: future)],
            "Each day is fetched by its own date, not silently replaced by today"
        )
    }

    func testBrowsingAnotherDayNeverRewritesTheSharedPlanHomeIsShowing() async throws {
        let fixture = try adapterFixture()
        let service = PlanServicePlannerAdapter(model: fixture.model)
        _ = try await service.context()
        let calendar = fixture.model.household!.clock.calendar

        _ = try await service.agenda(on: Date())
        let publishedToday = try XCTUnwrap(fixture.model.planState.snapshot)

        _ = try await service.agenda(on: calendar.date(byAdding: .day, value: -2, to: Date())!)

        XCTAssertEqual(fixture.model.planState.snapshot, publishedToday)
    }

    // MARK: - Fixtures

    /// Answers only for the household's current local day, exactly as
    /// `RealPlanService` now does, and records every date it was asked for.
    private final class DayScopedPlanService: PlanService {
        let snapshot: PlanSnapshot
        let timeZone: TimeZone
        private(set) var requestedDates: [Date] = []

        init(snapshot: PlanSnapshot, timeZone: TimeZone) {
            self.snapshot = snapshot
            self.timeZone = timeZone
        }

        func plan(
            forPet petId: UUID,
            on date: Date,
            resectioningCompleted: Bool
        ) async throws -> PlanSnapshot {
            requestedDates.append(date)
            guard RealPlanService.isSameLocalDay(date, Date(), timeZone: timeZone) else {
                throw PlanServiceError.noPlanForDay
            }
            return snapshot
        }

        func completeItem(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot {
            throw PlanServiceError.itemNotFound
        }

        func acceptRecommendation(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot {
            throw PlanServiceError.itemNotFound
        }

        func undoCompletion(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot {
            throw PlanServiceError.itemNotFound
        }

        func setCapacity(
            _ mode: CapacityMode,
            scope: CapacityScope,
            petId: UUID,
            on date: Date
        ) async throws -> PlanSnapshot {
            throw PlanServiceError.planNotFound
        }

        func addOneTimeTask(title: String, petId: UUID, on date: Date) async throws -> PlanSnapshot {
            throw PlanServiceError.planNotFound
        }
    }

    private func adapterFixture() throws -> (model: AppModel, plans: DayScopedPlanService) {
        let seedModel = AppModel.preview()
        let household = try XCTUnwrap(seedModel.household)
        let pet = try XCTUnwrap(seedModel.activePet)
        let timeZone = household.clock.timeZone

        let plan = Plan(
            householdId: household.id,
            petId: pet.id,
            localDate: household.clock.startOfDay(for: Date()),
            timeZoneSnapshot: household.timeZone,
            stageSnapshot: StageSnapshot(stageKey: "stage.foundations")
        )
        let plans = DayScopedPlanService(
            snapshot: PlanSnapshot(plan: plan, items: [], occurrences: [], dispositions: []),
            timeZone: timeZone
        )
        let model = AppModel(
            auth: seedModel.auth,
            households: seedModel.households,
            plans: plans,
            training: MockTrainingService(backend: MockBackend())
        )
        model.currentUser = seedModel.currentUser
        model.household = household
        model.activePet = pet
        model.phase = .main
        return (model, plans)
    }

    private func decodedPlan(localDate: String) throws -> Plan {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "household_id": "\(UUID().uuidString)",
          "pet_id": "\(UUID().uuidString)",
          "local_date": "\(localDate)",
          "time_zone_snapshot": "America/Toronto",
          "stage_snapshot": {"stage_key": "stage.foundations", "version": 1},
          "capacity_mode_applied": "normal",
          "plan_version": 1,
          "status": "open",
          "generated_at": "2026-07-28T06:00:00Z"
        }
        """
        return try SupabaseCoding.restDecoder.decode(Plan.self, from: Data(json.utf8))
    }
}
