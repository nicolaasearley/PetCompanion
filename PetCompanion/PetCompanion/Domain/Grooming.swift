import Foundation

/// Grooming history types — F10, DM §11.1 grooming fields, US-076.
///
/// History only. `nextDueDate` is an optional owner-entered fact for display —
/// PetCompanion never computes a grooming schedule or clinical advice.
/// Dedicated file so Vaccinations / Notes Care WIP stay isolated.

enum GroomingActivityType: String, CaseIterable, Identifiable, Codable, Hashable {
    case brushing
    case nails
    case bath
    case teeth
    case ears
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .brushing: "Brushing"
        case .nails: "Nails"
        case .bath: "Bath"
        case .teeth: "Teeth"
        case .ears: "Ears"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .brushing: "comb"
        case .nails: "hand.raised"
        case .bath: "drop.fill"
        case .teeth: "face.smiling"
        case .ears: "ear"
        case .other: "ellipsis.circle"
        }
    }
}

struct GroomingRecord: Identifiable, Hashable {
    let id: UUID
    let activityType: GroomingActivityType
    let effectiveDate: Date
    /// Owner-entered next date when known. Never computed.
    let nextDueDate: Date?
    let note: String?
    let revision: Int
    let recordedByName: String?
}

struct GroomingDraft {
    var activityType: GroomingActivityType
    var effectiveDate: Date
    var nextDueDate: Date?
    var includeNextDue: Bool
    var note: String

    static func blank(anchorDate: Date = Date()) -> GroomingDraft {
        GroomingDraft(
            activityType: .brushing,
            effectiveDate: anchorDate,
            nextDueDate: nil,
            includeNextDue: false,
            note: ""
        )
    }

    static func from(_ record: GroomingRecord) -> GroomingDraft {
        GroomingDraft(
            activityType: record.activityType,
            effectiveDate: record.effectiveDate,
            nextDueDate: record.nextDueDate,
            includeNextDue: record.nextDueDate != nil,
            note: record.note ?? ""
        )
    }
}

/// Calm caregiver-facing errors for grooming reads/writes. Raw server
/// strings never reach the UI (same convention as `VaccinationError`).
enum GroomingError: LocalizedError, Equatable {
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
        if let typed = error as? GroomingError, let description = typed.errorDescription {
            return description
        }
        let raw = error.localizedDescription
        if looksLikeMissingSchema(raw) {
            return GroomingError.recordsUnavailable.errorDescription!
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return GroomingError.unexpected(code: "UNKNOWN").errorDescription!
    }

    static func fromTransportFailure(_ error: Error) -> Error {
        if error is GroomingError { return error }
        if looksLikeMissingSchema(error.localizedDescription)
            || looksLikeMissingSchema(String(describing: error))
        {
            return GroomingError.recordsUnavailable
        }
        return error
    }

    static func looksLikeMissingSchema(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("schema cache") { return true }
        if lower.contains("pgrst205") { return true }
        if lower.contains("could not find the table")
            && (lower.contains("grooming_records") || lower.contains("public."))
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
        case .recordsUnavailable:
            "Grooming records aren’t available on this backend yet."
        case .unexpected:
            "Something went wrong. Try again."
        }
    }
}
