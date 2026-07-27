import XCTest
@testable import PetCompanion

final class DomainTests: XCTestCase {
    func testFutureHomecomingAlwaysUsesPreparingStage() {
        let clock = HouseholdClock(timeZone: TimeZone(identifier: "America/Toronto")!)
        let today = clock.startOfDay(for: Date())
        let homecoming = clock.adding(.day, value: 7, to: today)
        let pet = Pet(
            householdId: UUID(),
            name: "Maple",
            birthInfo: .unknown,
            homecomingDate: homecoming
        )

        XCTAssertEqual(pet.stage(on: today, calendar: clock.calendar), .preparing)
        XCTAssertEqual(pet.ageDisplay(on: today, calendar: clock.calendar), "Age not set")
    }

    func testHomecomingTodayEntersSettlingStage() {
        let clock = HouseholdClock(timeZone: TimeZone(identifier: "Europe/Stockholm")!)
        let today = clock.startOfDay(for: Date())
        let birth = clock.adding(.weekOfYear, value: -12, to: today)
        let pet = Pet(
            householdId: UUID(),
            name: "Maple",
            birthInfo: .exact(birthDate: birth),
            homecomingDate: today
        )

        XCTAssertEqual(pet.stage(on: today, calendar: clock.calendar), .settlingIn)
    }

    func testUnknownBirthInfoRoundTripsWithoutInventingDate() throws {
        let pet = Pet(householdId: UUID(), name: "Maple", birthInfo: .unknown)
        let data = try JSONEncoder().encode(pet)
        let decoded = try JSONDecoder().decode(Pet.self, from: data)
        XCTAssertEqual(decoded.birthInfo, .unknown)
    }

    func testHouseholdClockUsesAuthoritativeCalendarDay() {
        let utcNoon = ISO8601DateFormatter().date(from: "2026-07-26T02:00:00Z")!
        let toronto = HouseholdClock(timeZone: TimeZone(identifier: "America/Toronto")!)
        let stockholm = HouseholdClock(timeZone: TimeZone(identifier: "Europe/Stockholm")!)

        XCTAssertNotEqual(
            toronto.calendar.component(.day, from: utcNoon),
            stockholm.calendar.component(.day, from: utcNoon)
        )
    }
}
