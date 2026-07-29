import Foundation

/// Vaccination history types — F10, DM §11.1 vaccination fields, US-070.
///
/// History only. `nextDueDate` is an optional owner/vet-entered fact for
/// display — PetCompanion never computes a schedule, dose, or clinical advice.
/// Kept in a dedicated file so Care medications WIP can continue on Care.swift.

enum VaccinationProvenance: String, CaseIterable, Identifiable, Codable, Hashable {
    case ownerEntered = "owner_entered"
    case professionalInstruction = "professional_instruction"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ownerEntered: "Entered by you"
        case .professionalInstruction: "From your vet’s records"
        }
    }

    var shortBadge: String {
        switch self {
        case .ownerEntered: "Owner"
        case .professionalInstruction: "Vet"
        }
    }
}

struct VaccinationRecord: Identifiable, Hashable {
    let id: UUID
    let vaccineName: String
    let effectiveDate: Date
    /// Owner/vet-entered next due when explicitly known. Never computed.
    let nextDueDate: Date?
    let provenance: VaccinationProvenance
    let providerId: UUID?
    let note: String?
    let revision: Int
    let recordedByName: String?
}

struct VaccinationDraft {
    var vaccineName: String
    var effectiveDate: Date
    var nextDueDate: Date?
    var includeNextDue: Bool
    var provenance: VaccinationProvenance
    var providerId: UUID?
    var note: String

    static func blank(anchorDate: Date = Date()) -> VaccinationDraft {
        VaccinationDraft(
            vaccineName: "",
            effectiveDate: anchorDate,
            nextDueDate: nil,
            includeNextDue: false,
            provenance: .ownerEntered,
            providerId: nil,
            note: ""
        )
    }

    static func from(_ record: VaccinationRecord) -> VaccinationDraft {
        VaccinationDraft(
            vaccineName: record.vaccineName,
            effectiveDate: record.effectiveDate,
            nextDueDate: record.nextDueDate,
            includeNextDue: record.nextDueDate != nil,
            provenance: record.provenance,
            providerId: record.providerId,
            note: record.note ?? ""
        )
    }
}

/// Calm caregiver-facing errors for vaccination reads/writes. Raw server
/// strings never reach the UI (same convention as `CareError`).
enum VaccinationError: LocalizedError, Equatable {
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
        if let typed = error as? VaccinationError, let description = typed.errorDescription {
            return description
        }
        let raw = error.localizedDescription
        if looksLikeMissingSchema(raw) {
            return VaccinationError.recordsUnavailable.errorDescription!
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return VaccinationError.unexpected(code: "UNKNOWN").errorDescription!
    }

    static func fromTransportFailure(_ error: Error) -> Error {
        if error is VaccinationError { return error }
        if looksLikeMissingSchema(error.localizedDescription)
            || looksLikeMissingSchema(String(describing: error))
        {
            return VaccinationError.recordsUnavailable
        }
        return error
    }

    static func looksLikeMissingSchema(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("schema cache") { return true }
        if lower.contains("pgrst205") { return true }
        if lower.contains("could not find the table")
            && (lower.contains("vaccination_records") || lower.contains("public."))
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
            "Vaccination records aren’t available on this backend yet."
        case .unexpected:
            "Something went wrong. Try again."
        }
    }
}
