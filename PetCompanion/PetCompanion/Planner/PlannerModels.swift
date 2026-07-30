import Foundation

/// Planner-owned view models. These deliberately describe product intent
/// rather than mirroring a transport payload, keeping PL-01/PL-02 independent
/// of the eventual Supabase adapter.

struct PlannerCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let readAgenda = PlannerCapabilities(rawValue: 1 << 0)
    static let createOneTime = PlannerCapabilities(rawValue: 1 << 1)
    static let createRecurring = PlannerCapabilities(rawValue: 1 << 2)
    static let editOccurrence = PlannerCapabilities(rawValue: 1 << 3)
    static let editSeries = PlannerCapabilities(rawValue: 1 << 4)
    static let complete = PlannerCapabilities(rawValue: 1 << 5)
    static let undoComplete = PlannerCapabilities(rawValue: 1 << 6)
    static let skip = PlannerCapabilities(rawValue: 1 << 7)
    static let undoSkip = PlannerCapabilities(rawValue: 1 << 8)
    static let snooze = PlannerCapabilities(rawValue: 1 << 9)
    static let reschedule = PlannerCapabilities(rawValue: 1 << 10)
    static let cancel = PlannerCapabilities(rawValue: 1 << 11)
    static let history = PlannerCapabilities(rawValue: 1 << 12)
    static let richTaskFields = PlannerCapabilities(rawValue: 1 << 13)
    static let taskNotes = PlannerCapabilities(rawValue: 1 << 14)

    static let fullTaskManagement: PlannerCapabilities = [
        .readAgenda, .createOneTime, .createRecurring, .editOccurrence,
        .editSeries, .complete, .undoComplete, .skip, .undoSkip, .snooze,
        .reschedule, .cancel, .history, .richTaskFields, .taskNotes,
    ]
}

enum PlannerMutationState: Equatable, Sendable {
    case confirmed
    case queued
}

enum PlannerWeekday: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: Int { rawValue }

    func displayName(calendar: Calendar, width: Date.FormatStyle.Symbol.Weekday = .wide) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        let symbols: [String]
        switch width {
        case .wide:
            symbols = formatter.weekdaySymbols
        case .abbreviated:
            symbols = formatter.shortWeekdaySymbols
        case .narrow:
            symbols = formatter.veryShortWeekdaySymbols
        case .short:
            symbols = formatter.shortStandaloneWeekdaySymbols
        default:
            symbols = formatter.weekdaySymbols
        }
        return symbols[rawValue - 1]
    }
}

enum PlannerRecurrence: Equatable, Hashable, Sendable {
    case once
    case daily
    case selectedWeekdays(Set<PlannerWeekday>)
    case everyNDays(Int)
    /// "Safe" means a short month uses its final day rather than creating an
    /// invalid date or silently dropping the occurrence.
    case monthlySafe(day: Int)

    var isRecurring: Bool {
        if case .once = self { return false }
        return true
    }

    func summary(starting date: Date, calendar: Calendar) -> String {
        let start = PlannerFormatters.day(date, calendar: calendar)
        switch self {
        case .once:
            return "Does not repeat"
        case .daily:
            return "Repeats every day starting \(start)"
        case .selectedWeekdays(let weekdays):
            let ordered = weekdays.sorted {
                weekdaySortIndex($0, calendar: calendar) < weekdaySortIndex($1, calendar: calendar)
            }
            let names = ordered.map { $0.displayName(calendar: calendar, width: .abbreviated) }
            let list = ListFormatter.localizedString(byJoining: names)
            return "Repeats on \(list) starting \(start)"
        case .everyNDays(let interval):
            return "Repeats every \(max(2, interval)) days starting \(start)"
        case .monthlySafe(let day):
            return "Repeats monthly on day \(min(max(day, 1), 31)); shorter months use their final day"
        }
    }

    private func weekdaySortIndex(_ weekday: PlannerWeekday, calendar: Calendar) -> Int {
        (weekday.rawValue - calendar.firstWeekday + 7) % 7
    }
}

enum PlannerTimeSelection: Equatable, Hashable, Sendable {
    case anytime
    case window(PlanTimeWindow)
    case exact(Date)

    func summary(calendar: Calendar) -> String {
        switch self {
        case .anytime:
            return "Anytime"
        case .window(let window):
            return window.displayName
        case .exact(let date):
            return PlannerFormatters.time(date, calendar: calendar)
        }
    }
}

enum PlannerReminder: String, CaseIterable, Identifiable, Sendable {
    case none
    case atTime
    case fifteenMinutesBefore
    case oneHourBefore
    case atWindow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "No reminder"
        case .atTime: "At the exact time"
        case .fifteenMinutesBefore: "15 minutes before"
        case .oneHourBefore: "1 hour before"
        case .atWindow: "At the start of the window"
        }
    }
}

enum PlannerEditScope: String, CaseIterable, Identifiable, Sendable {
    case occurrenceOnly
    case thisAndFuture

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .occurrenceOnly: "This occurrence only"
        case .thisAndFuture: "This and future"
        }
    }

    var explanation: String {
        switch self {
        case .occurrenceOnly:
            "Only this dated task changes. The routine stays the same."
        case .thisAndFuture:
            "Past tasks stay unchanged. This date begins the updated routine."
        }
    }
}

struct PlannerMemberOption: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case anyone
        case member(UUID)
    }

    let id: String
    var name: String
    var kind: Kind

    static let anyone = PlannerMemberOption(id: "anyone", name: "Anyone", kind: .anyone)
}

struct PlannerContext: Equatable, Sendable {
    var pets: [Pet]
    var members: [PlannerMemberOption]
    var calendar: Calendar
    var capabilities: PlannerCapabilities
}

struct PlannerTaskDraft: Identifiable, Equatable, Sendable {
    var id: UUID?
    var occurrenceId: UUID?
    var scheduleId: UUID?
    var revision: Int?
    var title: String
    var petId: UUID?
    var date: Date
    var time: PlannerTimeSelection
    var recurrence: PlannerRecurrence
    var assignment: PlannerMemberOption.Kind
    var reminder: PlannerReminder
    var notes: String

    var isEditing: Bool { id != nil }
    var isEditingRecurringTask: Bool { isEditing && scheduleId != nil }

    init(
        id: UUID? = nil,
        occurrenceId: UUID? = nil,
        scheduleId: UUID? = nil,
        revision: Int? = nil,
        title: String = "",
        petId: UUID? = nil,
        date: Date,
        time: PlannerTimeSelection = .anytime,
        recurrence: PlannerRecurrence = .once,
        assignment: PlannerMemberOption.Kind = .anyone,
        reminder: PlannerReminder = .none,
        notes: String = ""
    ) {
        self.id = id
        self.occurrenceId = occurrenceId
        self.scheduleId = scheduleId
        self.revision = revision
        self.title = title
        self.petId = petId
        self.date = date
        self.time = time
        self.recurrence = recurrence
        self.assignment = assignment
        self.reminder = reminder
        self.notes = notes
    }

    func validationMessage(calendar: Calendar, today: Date) -> String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a task title."
        }
        if petId == nil {
            return "Choose which pet this task is for."
        }
        if !isEditing && calendar.startOfDay(for: date) < calendar.startOfDay(for: today) {
            return "Choose today or a future date."
        }
        if case .everyNDays(let interval) = recurrence, !(2...30).contains(interval) {
            return "Choose an interval between 2 and 30 days."
        }
        if case .selectedWeekdays(let weekdays) = recurrence, weekdays.isEmpty {
            return "Choose at least one weekday."
        }
        if case .monthlySafe(let day) = recurrence, !(1...31).contains(day) {
            return "Choose a monthly day between 1 and 31."
        }
        return nil
    }
}

enum PlannerAgendaState: Equatable, Sendable {
    case pending
    case completed
    case skipped
    case cancelled
    case expired
    case queued
    case stale

    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .completed: "Completed"
        case .skipped: "Skipped"
        case .cancelled: "Cancelled"
        case .expired: "Expired"
        case .queued: "Change queued"
        case .stale: "Last synced"
        }
    }
}

struct PlannerAgendaItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var planItemId: UUID?
    var occurrenceId: UUID?
    var scheduleId: UUID?
    var title: String
    var petId: UUID
    var petName: String
    var date: Date
    var time: PlannerTimeSelection
    var recurrence: PlannerRecurrence
    var assignment: PlannerMemberOption.Kind
    var reminder: PlannerReminder
    var notes: String
    var state: PlannerAgendaState
    var obligationClass: ObligationClass
    var origin: TaskOrigin
    var revision: Int
    var completionAttribution: String?
    var snoozedUntil: Date?

    var isRecurring: Bool { scheduleId != nil && recurrence.isRecurring }

    func editableDraft() -> PlannerTaskDraft {
        PlannerTaskDraft(
            id: id,
            occurrenceId: occurrenceId,
            scheduleId: scheduleId,
            revision: revision,
            title: title,
            petId: petId,
            date: date,
            time: time,
            recurrence: recurrence,
            assignment: assignment,
            reminder: reminder,
            notes: notes
        )
    }
}

/// Agenda projection of a household Event for PL-01 / US-080.
///
/// Distinct from `PlannerAgendaItem`: events are commitments, not completable
/// task occurrences. Source records still live in Care → Appointments.
struct PlannerAgendaEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: EventKind
    var title: String
    var petId: UUID?
    var petName: String?
    var date: Date
    var startTime: String?
    var allDay: Bool
    var locationText: String?
    var notes: String?
    var status: EventStatus
    var revision: Int

    var isCancelled: Bool { status == .cancelled }

    var timeSummary: String {
        if allDay || startTime == nil { return "All day" }
        return EventCoding.displayClock(startTime!)
    }

    static func from(
        _ event: HouseholdEvent,
        petName: String?,
        calendar: Calendar
    ) -> PlannerAgendaEvent {
        PlannerAgendaEvent(
            id: event.id,
            kind: event.kind,
            title: event.title,
            petId: event.petId,
            petName: petName,
            date: calendar.startOfDay(for: event.startDate),
            startTime: event.startTime,
            allDay: event.allDay,
            locationText: event.locationText,
            notes: event.notes,
            status: event.status,
            revision: event.revision
        )
    }
}

/// One visible row in a day section — task occurrence or calendar event.
enum PlannerAgendaEntry: Identifiable, Equatable, Sendable {
    case occurrence(PlannerAgendaItem)
    case event(PlannerAgendaEvent)

    var id: UUID {
        switch self {
        case .occurrence(let item): item.id
        case .event(let event): event.id
        }
    }

    var title: String {
        switch self {
        case .occurrence(let item): item.title
        case .event(let event): event.title
        }
    }
}

/// PL-01 schedule-first filter — appointments/timed care vs household routines.
enum PlannerAgendaFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case schedule
    case routines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .schedule: "Schedule"
        case .routines: "Routines"
        }
    }
}

struct PlannerDayAgenda: Equatable, Sendable, Identifiable {
    /// How much this agenda is able to say about its day.
    ///
    /// "Nothing is scheduled" and "nobody knows what was scheduled" are
    /// different facts and must not share a rendering (IA §15.1). A day with
    /// no plan is the second: reading it produced no items because there was
    /// nothing to read, not because the day was quiet.
    enum Coverage: Equatable, Sendable {
        /// The day was read. Whatever it holds is what it holds — including
        /// nothing, which is then a real empty day (IA §15.2).
        case planned
        /// No plan exists for this day. Days are planned when their local
        /// day begins (engine §10.1), so a future date has not been reached
        /// yet and a past one predates this pet's plans.
        case notGenerated
    }

    var date: Date
    var items: [PlannerAgendaItem]
    /// Confirmed household events for this local day (US-080). Independent of
    /// plan coverage — an unplanned day can still hold appointments.
    var events: [PlannerAgendaEvent] = []
    var lastVerifiedAt: Date?
    var isStale: Bool
    var coverage: Coverage = .planned

    var id: Date { date }

    var hasContent: Bool { !items.isEmpty || !events.isEmpty }

    /// Calm, specific copy for a day the app cannot describe — never an
    /// error state, because nothing failed (doc 09 §10).
    ///
    /// Suppressed when the day already has events: appointments are real
    /// content even when the Daily Plan has not been generated yet.
    func unplannedDayMessage(today: Date, calendar: Calendar) -> String? {
        guard coverage == .notGenerated, events.isEmpty else { return nil }
        return calendar.startOfDay(for: date) > calendar.startOfDay(for: today)
            ? "This day hasn't been planned yet. Its plan is prepared when the day begins."
            : "No plan was kept for this day, so Settle can't say what was scheduled."
    }
}

/// Pure date/window helpers for PL-01's forward-scrolling agenda. Kept free of
/// store/UI so household-calendar grouping can be unit-tested without spinning
/// up a service.
enum PlannerAgendaGrouping {
    /// Initial forward window from the anchor day (today by default).
    static let defaultForwardDayCount = 14
    /// How many days to append when the caregiver scrolls near the end.
    static let pageDayCount = 7

    /// Inclusive local-day starts from `start` through `end` in `calendar`.
    static func dayStarts(
        from start: Date,
        through end: Date,
        calendar: Calendar
    ) -> [Date] {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard first <= last else { return [] }
        var days: [Date] = []
        var cursor = first
        while cursor <= last {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// End of a forward window that begins on `start` and spans `dayCount`
    /// local days (count includes the start day).
    static func windowEnd(
        from start: Date,
        dayCount: Int,
        calendar: Calendar
    ) -> Date {
        let clamped = max(dayCount, 1)
        return calendar.date(
            byAdding: .day,
            value: clamped - 1,
            to: calendar.startOfDay(for: start)
        ) ?? calendar.startOfDay(for: start)
    }

    /// Whether the day is before the household's local today — previous days
    /// are history (PL-01 pull-past), so inline add stays off them.
    static func isPastDay(_ date: Date, today: Date, calendar: Calendar) -> Bool {
        calendar.startOfDay(for: date) < calendar.startOfDay(for: today)
    }

    static func allowsInlineAdd(on date: Date, today: Date, calendar: Calendar) -> Bool {
        !isPastDay(date, today: today, calendar: calendar)
    }

    /// Day section heading before `SectionHeader` uppercases it
    /// (`TODAY · WED JUL 29` / `THU JUL 30`).
    static func sectionHeading(for date: Date, today: Date, calendar: Calendar) -> String {
        PlannerFormatters.agendaSection(date, today: today, calendar: calendar)
    }

    /// Week-rail title: "This week" while the anchor stays in the current
    /// household week; otherwise a short inclusive range.
    static func weekNavigatorTitle(
        for anchor: Date,
        today: Date,
        calendar: Calendar
    ) -> String {
        if calendar.isDate(anchor, equalTo: today, toGranularity: .weekOfYear) {
            return "This week"
        }
        let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start
            ?? calendar.startOfDay(for: anchor)
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        return PlannerFormatters.weekRange(from: start, through: end, calendar: calendar)
    }

    /// Merge a fetched page into an existing ordered day list without
    /// duplicating local days. Newer fetch wins for a matching day.
    /// Incoming task pages replace the day's items/coverage; events are
    /// reattached afterward via `attaching(events:to:calendar:)`.
    static func merging(
        _ existing: [PlannerDayAgenda],
        with incoming: [PlannerDayAgenda],
        calendar: Calendar
    ) -> [PlannerDayAgenda] {
        var byDay: [Date: PlannerDayAgenda] = [:]
        for day in existing {
            byDay[calendar.startOfDay(for: day.date)] = day
        }
        for day in incoming {
            let key = calendar.startOfDay(for: day.date)
            var merged = day
            // Preserve already-attached events until the next attach pass
            // rewrites the full window (avoids a blank flash mid-merge).
            if merged.events.isEmpty, let prior = byDay[key]?.events, !prior.isEmpty {
                merged.events = prior
            }
            byDay[key] = merged
        }
        return byDay.keys.sorted().compactMap { byDay[$0] }
    }

    /// Place confirmed events onto matching local-day sections inside the
    /// visible window. Cancelled events stay off the agenda (US-080).
    static func attaching(
        events: [PlannerAgendaEvent],
        to days: [PlannerDayAgenda],
        calendar: Calendar
    ) -> [PlannerDayAgenda] {
        guard let first = days.first, let last = days.last else { return days }
        let windowStart = calendar.startOfDay(for: first.date)
        let windowEnd = calendar.startOfDay(for: last.date)

        var byDay: [Date: [PlannerAgendaEvent]] = [:]
        for event in events where !event.isCancelled {
            let day = calendar.startOfDay(for: event.date)
            guard day >= windowStart, day <= windowEnd else { continue }
            byDay[day, default: []].append(event)
        }

        return days.map { day in
            var copy = day
            let key = calendar.startOfDay(for: day.date)
            copy.events = (byDay[key] ?? []).sorted { lhs, rhs in
                entrySortKey(.event(lhs), calendar: calendar)
                    < entrySortKey(.event(rhs), calendar: calendar)
            }
            return copy
        }
    }

    /// Local-day starts that already carry tasks and/or confirmed events —
    /// shared by the week-rail dots and the month-jump grid.
    static func datesWithContent(
        from days: [PlannerDayAgenda],
        calendar: Calendar
    ) -> Set<Date> {
        Set(
            days
                .filter(\.hasContent)
                .map { calendar.startOfDay(for: $0.date) }
        )
    }

    /// Confirmed (non-cancelled) event day starts inside an inclusive local
    /// range. Used when the month-jump sheet fetches a month outside the
    /// currently loaded agenda window.
    static func eventContentDates(
        from events: [PlannerAgendaEvent],
        from start: Date,
        through end: Date,
        calendar: Calendar
    ) -> Set<Date> {
        let windowStart = calendar.startOfDay(for: start)
        let windowEnd = calendar.startOfDay(for: end)
        var dates = Set<Date>()
        for event in events where !event.isCancelled {
            let day = calendar.startOfDay(for: event.date)
            guard day >= windowStart, day <= windowEnd else { continue }
            dates.insert(day)
        }
        return dates
    }

    /// Inclusive local start/end for the month containing `month`.
    static func monthBounds(
        for month: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date)? {
        guard let interval = calendar.dateInterval(of: .month, for: month) else {
            return nil
        }
        let start = calendar.startOfDay(for: interval.start)
        let end = calendar.date(byAdding: .day, value: -1, to: interval.end)
            .map { calendar.startOfDay(for: $0) } ?? start
        return (start, end)
    }

    /// Seven-column month cells aligned to `calendar.firstWeekday`. Leading
    /// and trailing `nil` pads keep the grid rectangular for the jump sheet.
    static func monthGridDays(
        for month: Date,
        calendar: Calendar
    ) -> [Date?] {
        guard let bounds = monthBounds(for: month, calendar: calendar) else {
            return []
        }
        let weekday = calendar.component(.weekday, from: bounds.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        var cursor = bounds.start
        while cursor <= bounds.end {
            cells.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }
        while cells.count % 7 != 0 {
            cells.append(nil)
        }
        return cells
    }

    /// Weekday column labels in calendar order (narrow width), matching the
    /// month-jump grid columns.
    static func monthWeekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        guard !symbols.isEmpty else { return [] }
        let offset = calendar.firstWeekday - 1
        return (0..<7).map { symbols[($0 + offset) % symbols.count] }
    }

    /// Mixed day-section rows: timed events and exact-time tasks first, then
    /// windowed tasks, then anytime / all-day. Title breaks ties.
    static func entries(
        for day: PlannerDayAgenda,
        calendar: Calendar
    ) -> [PlannerAgendaEntry] {
        let mixed: [PlannerAgendaEntry] =
            day.items.map(PlannerAgendaEntry.occurrence)
            + day.events.map(PlannerAgendaEntry.event)
        return mixed.sorted { lhs, rhs in
            let left = entrySortKey(lhs, calendar: calendar)
            let right = entrySortKey(rhs, calendar: calendar)
            if left != right { return left < right }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// Minutes-from-midnight sort key. Exact clocks and event start times
    /// occupy 0…1439; windows and anytime/all-day sort after.
    static func entrySortKey(_ entry: PlannerAgendaEntry, calendar: Calendar) -> Int {
        switch entry {
        case .occurrence(let item):
            switch item.time {
            case .exact(let date):
                return calendar.component(.hour, from: date) * 60
                    + calendar.component(.minute, from: date)
            case .window(let window):
                return 1_500 + (PlanTimeWindow.allCases.firstIndex(of: window) ?? 0)
            case .anytime:
                return 2_000
            }
        case .event(let event):
            if event.allDay || event.startTime == nil { return 2_000 }
            let parts = event.startTime!.split(separator: ":")
            guard parts.count >= 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1])
            else { return 2_000 }
            return hour * 60 + minute
        }
    }
}

struct PlannerHistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var action: Disposition.Action
    var actorName: String
    var effectiveAt: Date
    var detail: String?
    var isQueued: Bool

    var actionText: String {
        switch action {
        case .complete: "Completed"
        case .undoComplete: "Completion undone"
        case .skip: "Skipped"
        case .undoSkip: "Skip undone"
        case .snooze: "Snoozed"
        case .reschedule: "Rescheduled"
        case .cancel: "Cancelled"
        case .dismissRequired: "Resolved"
        }
    }
}

enum PlannerTaskAction: Equatable, Sendable {
    case complete
    case undoComplete
    case skip(reason: String?)
    case undoSkip
    case snooze(until: Date)
    case reschedule(to: Date, time: PlannerTimeSelection, scope: PlannerEditScope)
    case cancel(scope: PlannerEditScope)
}

enum PlannerServiceError: LocalizedError, Equatable {
    case unavailable(String)
    case itemChanged
    case invalidSnooze
    case missingOccurrence

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            message
        case .itemChanged:
            "This task changed in the household. Review the latest version before saving."
        case .invalidSnooze:
            "Choose a snooze time later today."
        case .missingOccurrence:
            "This task is no longer available. Refresh the Planner."
        }
    }
}

enum PlannerFormatters {
    static func day(_ date: Date, calendar: Calendar) -> String {
        formatter(calendar: calendar, template: "EEE MMM d").string(from: date)
    }

    static func fullDay(_ date: Date, calendar: Calendar) -> String {
        formatter(calendar: calendar, template: "EEEE MMMM d").string(from: date)
    }

    static func month(_ date: Date, calendar: Calendar) -> String {
        formatter(calendar: calendar, template: "MMMM yyyy").string(from: date)
    }

    static func time(_ date: Date, calendar: Calendar) -> String {
        formatter(calendar: calendar, template: "jm").string(from: date)
    }

    static func weekdayNarrow(_ date: Date, calendar: Calendar) -> String {
        formatter(calendar: calendar, template: "EEEEE").string(from: date)
    }

    static func relativeDay(_ date: Date, today: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: today) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        return day(date, calendar: calendar)
    }

    /// PL-01 day-section label before uppercasing: today keeps an explicit
    /// "Today · …" lead-in; other days stay weekday + month day.
    static func agendaSection(_ date: Date, today: Date, calendar: Calendar) -> String {
        let stamped = day(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: today) {
            return "Today · \(stamped)"
        }
        return stamped
    }

    static func weekRange(from start: Date, through end: Date, calendar: Calendar) -> String {
        let left = formatter(calendar: calendar, template: "MMM d").string(from: start)
        let right = formatter(calendar: calendar, template: "MMM d").string(from: end)
        return "\(left) – \(right)"
    }

    private static func formatter(calendar: Calendar, template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
