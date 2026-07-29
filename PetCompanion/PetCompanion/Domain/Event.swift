import Foundation

/// Household calendar events — F11, DM 10 §11.5.
///
/// Vet appointments, classes, grooming visits, and other dated commitments.
/// Preparation tasks are a later slice. Server `event_reminder` candidates
/// refresh on write-path (US-086); on-device local reminders schedule from the
/// same confirmed + `reminder_config.lead_minutes` surface.

enum EventKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case vetAppointment = "vet_appointment"
    case classSession = "class"
    case groomingVisit = "grooming_visit"
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vetAppointment: "Vet appointment"
        case .classSession: "Class"
        case .groomingVisit: "Grooming"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .vetAppointment: "cross.case"
        case .classSession: "graduationcap"
        case .groomingVisit: "comb"
        case .other: "calendar"
        }
    }
}

enum EventStatus: String, Codable, Hashable {
    case confirmed
    case cancelled
}

struct HouseholdEvent: Identifiable, Hashable {
    let id: UUID
    let householdId: UUID
    let petId: UUID?
    let kind: EventKind
    let title: String
    let startDate: Date
    let startTime: String?
    let endTime: String?
    let allDay: Bool
    let locationText: String?
    let providerId: UUID?
    let notes: String?
    let reminderLeadMinutes: [Int]
    let status: EventStatus
    let revision: Int

    var isCancelled: Bool { status == .cancelled }

    var whenSummary: String {
        let date = EventCoding.displayDate(startDate)
        if allDay { return date }
        if let startTime {
            return "\(date) · \(EventCoding.displayClock(startTime))"
        }
        return date
    }
}

struct EventDraft: Equatable {
    var title: String = ""
    var kind: EventKind = .vetAppointment
    var petId: UUID?
    var startDate: Date = Date()
    var allDay: Bool = true
    var startTime: Date = Calendar.current.date(
        bySettingHour: 14, minute: 0, second: 0, of: Date()
    ) ?? Date()
    var locationText: String = ""
    var notes: String = ""
    var reminderLeadMinutes: [Int] = [60, 1440]

    static let reminderOptions: [(minutes: Int, label: String)] = [
        (0, "At time"),
        (15, "15 minutes before"),
        (60, "1 hour before"),
        (1440, "1 day before"),
        (2880, "2 days before"),
    ]
}

enum EventError: LocalizedError, Equatable {
    case changedElsewhere
    case notSignedIn
    case invalidEntry
    case recordsUnavailable
    case unexpected(code: String)

    init(code: String, message: String) {
        switch code {
        case "REVISION_CONFLICT": self = .changedElsewhere
        case "FORBIDDEN": self = .notSignedIn
        case "VALIDATION_FAILED": self = .invalidEntry
        default:
            if Self.looksLikeMissingSchema(message) || Self.looksLikeMissingSchema(code) {
                self = .recordsUnavailable
            } else {
                self = .unexpected(code: code)
            }
        }
    }

    static func displayMessage(for error: Error) -> String {
        if let event = error as? EventError, let description = event.errorDescription {
            return description
        }
        let raw = error.localizedDescription
        if looksLikeMissingSchema(raw) {
            return EventError.recordsUnavailable.errorDescription!
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return EventError.unexpected(code: "UNKNOWN").errorDescription!
    }

    static func fromTransportFailure(_ error: Error) -> Error {
        if error is EventError { return error }
        if looksLikeMissingSchema(error.localizedDescription)
            || looksLikeMissingSchema(String(describing: error))
        {
            return EventError.recordsUnavailable
        }
        return error
    }

    static func looksLikeMissingSchema(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("schema cache") { return true }
        if lower.contains("pgrst205") { return true }
        if lower.contains("could not find the table")
            && (lower.contains("events") || lower.contains("public."))
        {
            return true
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .changedElsewhere:
            "This event changed since you opened it. Reopen it to see the latest."
        case .notSignedIn:
            "You no longer have access to this household."
        case .invalidEntry:
            "Check the details and try again."
        case .recordsUnavailable:
            "Appointments aren’t available on this backend yet."
        case .unexpected:
            "Something went wrong. Try again."
        }
    }
}

enum EventCoding {
    static func localDate(_ date: Date, calendar: Calendar = .current) -> String {
        SupabaseCoding.dateOnlyString(date, timeZone: calendar.timeZone)
    }

    static func clockString(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", hour, minute)
    }

    static func displayDate(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func displayClock(_ hhmm: String) -> String {
        let parts = hhmm.split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1])
        else { return hhmm }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let calendar = Calendar.current
        guard let date = calendar.date(from: components) else { return hhmm }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func leadMinutes(from reminderConfig: [String: Any]?) -> [Int] {
        guard let raw = reminderConfig?["lead_minutes"] as? [Any] else { return [] }
        return raw.compactMap { value in
            if let int = value as? Int { return int }
            if let number = value as? NSNumber { return number.intValue }
            return nil
        }
    }
}
