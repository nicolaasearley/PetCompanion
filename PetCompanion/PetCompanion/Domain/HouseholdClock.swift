import Foundation

/// Calendar-day operations in the household's authoritative IANA time zone.
/// Domain dates such as birth and homecoming are calendar dates, not device
/// instants, so callers should use this instead of `Calendar.current`.
struct HouseholdClock: Equatable, Sendable {
    let timeZone: TimeZone

    init(timeZoneID: String) {
        self.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
    }

    init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    func startOfDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    func adding(_ component: Calendar.Component, value: Int, to date: Date) -> Date {
        calendar.date(byAdding: component, value: value, to: date) ?? date
    }

    func ordered(_ earlier: Date, beforeOrSameAs later: Date) -> Bool {
        startOfDay(for: earlier) <= startOfDay(for: later)
    }
}

extension Household {
    var clock: HouseholdClock { HouseholdClock(timeZoneID: timeZone) }
}
