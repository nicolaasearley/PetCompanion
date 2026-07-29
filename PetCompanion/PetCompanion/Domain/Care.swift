import Foundation

/// Care domain types — F10, DM 10 §11.2–§11.4.
///
/// Weight, providers, and medication schedules (Accepted safety model,
/// docs/13 2026-07-29). Dose/name text is stored verbatim; occurrences come
/// only from explicit owner/professional schedules; neutral “Due in N days”
/// restates owner configuration — never packaging/breed inference.
///
/// Product rules expressed in the types:
///   * Weight stores original value + unit; conversion is display-only.
///   * Nothing here diagnoses, computes a dose, or advises missed doses.
///   * Visualization copy must never claim a clinical assessment (US-075).

enum WeightUnit: String, CaseIterable, Identifiable, Codable, Hashable {
    case kg
    case lb

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kg: "kg"
        case .lb: "lb"
        }
    }

    /// Approximate conversion for display toggles only — never written back.
    func convert(_ value: Decimal, to other: WeightUnit) -> Decimal {
        guard self != other else { return value }
        switch (self, other) {
        case (.kg, .lb): return value * Decimal(string: "2.2046226218")!
        case (.lb, .kg): return value / Decimal(string: "2.2046226218")!
        default: return value
        }
    }
}

enum ProviderKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case veterinarian
    case groomer
    case trainer
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .veterinarian: "Veterinarian"
        case .groomer: "Groomer"
        case .trainer: "Trainer"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .veterinarian: "cross.case"
        case .groomer: "comb"
        case .trainer: "figure.walk"
        case .other: "person.crop.circle"
        }
    }
}

struct WeightMeasurement: Identifiable, Hashable {
    let id: UUID
    let value: Decimal
    let unit: WeightUnit
    let effectiveDate: Date
    let note: String?
    let revision: Int
    let recordedByName: String?

    /// Formatted as entered (original unit).
    var displayValue: String {
        "\(Self.format(value)) \(unit.displayName)"
    }

    func displayValue(in displayUnit: WeightUnit) -> String {
        let converted = unit.convert(value, to: displayUnit)
        return "\(Self.format(converted)) \(displayUnit.displayName)"
    }

    static func format(_ value: Decimal) -> String {
        var copy = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &copy, 2, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }
}

struct CareProvider: Identifiable, Hashable {
    let id: UUID
    let name: String
    let kind: ProviderKind
    let phone: String?
    let address: String?
    let notes: String?
    let revision: Int
}

struct WeightDraft {
    var valueText: String
    var unit: WeightUnit
    var effectiveDate: Date
    var note: String
}

struct ProviderDraft {
    var name: String
    var kind: ProviderKind
    var phone: String
    var address: String
    var notes: String
}

// MARK: - Medications (DM §11.2 / CA-06–CA-07)

enum MedicationProvenance: String, CaseIterable, Identifiable, Codable, Hashable {
    case ownerEntered = "owner_entered"
    case professionalInstruction = "professional_instruction"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ownerEntered: "Entered by you"
        case .professionalInstruction: "From your vet’s instruction"
        }
    }
}

enum MedicationScheduleStatus: String, Codable, Hashable {
    case active
    case archived
    case superseded
}

enum MedicationRecurrenceType: String, CaseIterable, Identifiable, Codable, Hashable {
    case once
    case daily
    case everyNDays = "every_n_days"
    case weekly
    case intervalAfterCompletion = "interval_after_completion"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .once: "Once"
        case .daily: "Every day"
        case .everyNDays: "Every N days"
        case .weekly: "Weekly"
        case .intervalAfterCompletion: "Days after last given"
        }
    }
}

enum MedicationTimePolicy: String, CaseIterable, Identifiable, Codable, Hashable {
    case anytime
    case window
    case exactTime = "exact_time"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anytime: "Anytime"
        case .window: "Time of day"
        case .exactTime: "Exact time"
        }
    }
}

enum MedicationWindowRef: String, CaseIterable, Identifiable, Codable, Hashable {
    case morning
    case midday
    case afternoon
    case evening

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .morning: "Morning"
        case .midday: "Midday"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        }
    }
}

struct MedicationRecurrence: Hashable, Codable {
    var type: MedicationRecurrenceType
    var anchorDate: Date
    var interval: Int?
    var timePolicy: MedicationTimePolicy
    var exactTime: String?
    var windowRef: MedicationWindowRef?

    var summary: String {
        let timing: String = {
            switch timePolicy {
            case .anytime: return ""
            case .window: return windowRef.map { " · \($0.displayName.lowercased())" } ?? ""
            case .exactTime: return exactTime.map { " · \($0)" } ?? ""
            }
        }()
        switch type {
        case .once:
            return "Once\(timing)"
        case .daily:
            return "Every day\(timing)"
        case .everyNDays:
            let n = interval ?? 1
            return n == 1 ? "Every day\(timing)" : "Every \(n) days\(timing)"
        case .weekly:
            return "Weekly\(timing)"
        case .intervalAfterCompletion:
            let n = interval ?? 1
            return n == 1
                ? "1 day after last given\(timing)"
                : "\(n) days after last given\(timing)"
        }
    }
}

struct MedicationNextDue: Hashable, Identifiable {
    let occurrenceId: UUID
    let localDueDate: Date
    let originalLocalDueDate: Date
    let timePolicy: MedicationTimePolicy
    let dueTime: String?
    let windowRef: MedicationWindowRef?
    let occurrenceRevision: Int

    var id: UUID { occurrenceId }

    /// Neutral copy that restates the owner-entered schedule (docs/13).
    func dueSummary(relativeTo today: Date, calendar: Calendar) -> String {
        let startToday = calendar.startOfDay(for: today)
        let startDue = calendar.startOfDay(for: localDueDate)
        let days = calendar.dateComponents([.day], from: startToday, to: startDue).day ?? 0
        let timing = timingFragment
        if days == 0 { return "Due today\(timing)" }
        if days == 1 { return "Due tomorrow\(timing)" }
        if days > 1 { return "Due in \(days) days\(timing)" }
        if days == -1 { return "Due yesterday\(timing)" }
        return "Due \(abs(days)) days ago\(timing)"
    }

    private var timingFragment: String {
        switch timePolicy {
        case .anytime: return ""
        case .window: return windowRef.map { " · \($0.displayName.lowercased())" } ?? ""
        case .exactTime: return dueTime.map { " · \($0)" } ?? ""
        }
    }
}

struct MedicationLastCompletion: Hashable {
    let effectiveAt: Date
    let actorUserId: UUID?
    let actorName: String?
    let completedDueDate: Date?

    var attribution: String {
        let name = actorName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return "Last given \(CareCoding.displayDateTime(effectiveAt)) by \(name)"
        }
        return "Last given \(CareCoding.displayDateTime(effectiveAt))"
    }

    /// True when another caregiver completed within the recent window.
    func isRecentPartnerCompletion(
        relativeTo now: Date = Date(),
        currentUserId: UUID?,
        within hours: TimeInterval = 24 * 60 * 60
    ) -> Bool {
        guard now.timeIntervalSince(effectiveAt) <= hours else { return false }
        guard let actorUserId, let currentUserId else { return false }
        return actorUserId != currentUserId
    }
}

struct MedicationChangeEntry: Identifiable, Hashable {
    let id: UUID
    let occurredAt: Date
    let action: String
    let actorName: String?
    let summaryLabel: String
}

struct MedicationSchedule: Identifiable, Hashable {
    let id: UUID
    let petId: UUID
    let medicationName: String
    let doseText: String?
    let instructionsText: String?
    let provenance: MedicationProvenance
    let providerId: UUID?
    let recurrence: MedicationRecurrence
    let status: MedicationScheduleStatus
    let taskScheduleId: UUID
    let revision: Int
    let nextDue: MedicationNextDue?
    let lastCompletion: MedicationLastCompletion?
    let changeHistory: [MedicationChangeEntry]
    let createdByName: String?

    var listSubtitle: String {
        var parts: [String] = [recurrence.summary]
        if let lastCompletion {
            parts.append(lastCompletion.attribution)
        }
        return parts.joined(separator: " · ")
    }
}

struct MedicationDraft {
    var medicationName: String
    var doseText: String
    var instructionsText: String
    var provenance: MedicationProvenance
    var recurrenceType: MedicationRecurrenceType
    var anchorDate: Date
    var intervalDays: Int
    var timePolicy: MedicationTimePolicy
    var windowRef: MedicationWindowRef
    var exactTime: Date

    func validatedRecurrence(calendar: Calendar = .current) -> MedicationRecurrence? {
        let name = medicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if recurrenceType == .everyNDays || recurrenceType == .intervalAfterCompletion {
            guard intervalDays > 0 else { return nil }
        }
        var exact: String?
        var window: MedicationWindowRef?
        switch timePolicy {
        case .anytime:
            break
        case .window:
            window = windowRef
        case .exactTime:
            let comps = calendar.dateComponents([.hour, .minute], from: exactTime)
            guard let hour = comps.hour, let minute = comps.minute else { return nil }
            exact = String(format: "%02d:%02d", hour, minute)
        }
        return MedicationRecurrence(
            type: recurrenceType,
            anchorDate: anchorDate,
            interval: (recurrenceType == .everyNDays || recurrenceType == .intervalAfterCompletion)
                ? intervalDays : nil,
            timePolicy: timePolicy,
            exactTime: exact,
            windowRef: window
        )
    }

    static func blank(anchorDate: Date = Date()) -> MedicationDraft {
        MedicationDraft(
            medicationName: "",
            doseText: "",
            instructionsText: "",
            provenance: .ownerEntered,
            recurrenceType: .intervalAfterCompletion,
            anchorDate: anchorDate,
            intervalDays: 30,
            timePolicy: .anytime,
            windowRef: .morning,
            exactTime: anchorDate
        )
    }

    static func from(_ schedule: MedicationSchedule, calendar: Calendar = .current) -> MedicationDraft {
        var exactTime = schedule.recurrence.anchorDate
        if let time = schedule.recurrence.exactTime,
           let parsed = CareCoding.parseHHMM(time, on: schedule.recurrence.anchorDate, calendar: calendar)
        {
            exactTime = parsed
        }
        return MedicationDraft(
            medicationName: schedule.medicationName,
            doseText: schedule.doseText ?? "",
            instructionsText: schedule.instructionsText ?? "",
            provenance: schedule.provenance,
            recurrenceType: schedule.recurrence.type,
            anchorDate: schedule.recurrence.anchorDate,
            intervalDays: schedule.recurrence.interval ?? 30,
            timePolicy: schedule.recurrence.timePolicy,
            windowRef: schedule.recurrence.windowRef ?? .morning,
            exactTime: exactTime
        )
    }
}

/// Calm caregiver-facing errors for Care reads/writes. Raw server strings never
/// reach the UI (same convention as `SocializationError`).
enum CareError: LocalizedError, Equatable {
    case changedElsewhere
    case notSignedIn
    case invalidEntry
    /// Recent partner completion — UI must show extra confirm, then retry.
    case recentCompletionNeedsConfirm(message: String)
    /// PostgREST schema-cache miss (migration not applied on this backend).
    case recordsUnavailable
    case unexpected(code: String)

    init(code: String, message: String) {
        switch code {
        case "REVISION_CONFLICT": self = .changedElsewhere
        case "FORBIDDEN": self = .notSignedIn
        case "VALIDATION_FAILED": self = .invalidEntry
        case "REQUIRED_CONFIRMATION":
            self = .recentCompletionNeedsConfirm(
                message: message.isEmpty
                    ? "Another caregiver recently recorded this medication. Confirm before recording again."
                    : message
            )
        default:
            if Self.looksLikeMissingSchema(message) || Self.looksLikeMissingSchema(code) {
                self = .recordsUnavailable
            } else {
                self = .unexpected(code: code)
            }
        }
    }

    /// Maps a thrown failure to caregiver copy. Schema-missing / PostgREST
    /// cache errors get a calm backend message; other `LocalizedError`s keep
    /// their description; everything else stays generic.
    static func displayMessage(for error: Error) -> String {
        if let care = error as? CareError, let description = care.errorDescription {
            return description
        }
        let raw = error.localizedDescription
        if looksLikeMissingSchema(raw) {
            return CareError.recordsUnavailable.errorDescription!
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return CareError.unexpected(code: "UNKNOWN").errorDescription!
    }

    /// Prefer throwing a typed Care error from RealCareService reads so stores
    /// never surface raw PostgREST schema-cache strings.
    static func fromTransportFailure(_ error: Error) -> Error {
        if error is CareError { return error }
        if looksLikeMissingSchema(error.localizedDescription)
            || looksLikeMissingSchema(String(describing: error))
        {
            return CareError.recordsUnavailable
        }
        return error
    }

    static func looksLikeMissingSchema(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("schema cache") { return true }
        if lower.contains("pgrst205") { return true }
        if lower.contains("could not find the table")
            && (lower.contains("weight_measurements")
                || lower.contains("providers")
                || lower.contains("medication_schedules")
                || lower.contains("public."))
        {
            return true
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .changedElsewhere:
            "This record changed since you opened it. Reopen it to see the latest."
        case .notSignedIn:
            "You no longer have access to this household."
        case .invalidEntry:
            "Check the details and try again."
        case .recentCompletionNeedsConfirm(let message):
            message
        case .recordsUnavailable:
            "Care records aren’t available on this backend yet."
        case .unexpected:
            "Something went wrong. Try again."
        }
    }
}

enum CareCoding {
    static func localDate(_ date: Date, calendar: Calendar = .current) -> String {
        SupabaseCoding.dateOnlyString(date, timeZone: calendar.timeZone)
    }

    static func decimal(from text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// PostgREST `numeric` must be selected as text (`value::text`) and parsed
    /// here — never via `Double`, which rewrites entered precision (US-075).
    static func weightValue(fromJSONText text: String) -> Decimal? {
        decimal(from: text)
    }

    static func displayDate(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func displayDateTime(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func parseHHMM(_ text: String, on day: Date, calendar: Calendar) -> Date? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1])
        else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps)
    }
}
