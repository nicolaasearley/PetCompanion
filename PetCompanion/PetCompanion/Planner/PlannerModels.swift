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

struct PlannerDayAgenda: Equatable, Sendable {
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
    var lastVerifiedAt: Date?
    var isStale: Bool
    var coverage: Coverage = .planned

    /// Calm, specific copy for a day the app cannot describe — never an
    /// error state, because nothing failed (doc 09 §10).
    func unplannedDayMessage(today: Date, calendar: Calendar) -> String? {
        guard coverage == .notGenerated else { return nil }
        return calendar.startOfDay(for: date) > calendar.startOfDay(for: today)
            ? "This day hasn't been planned yet. Its plan is prepared when the day begins."
            : "No plan was kept for this day, so PetCompanion can't say what was scheduled."
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

    private static func formatter(calendar: Calendar, template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
