import Foundation

/// Care notes — F10, DM §11.1 general_note / document, US-077.
///
/// General observations and document references with optional household-private
/// attachments (images + PDF paperwork on `household-media`). Never diagnoses
/// or recommends treatment from note text. Kept in a dedicated file so sibling
/// Care WIP (vaccinations / grooming) stays isolated.

enum CareNoteKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case generalNote = "general_note"
    case document

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .generalNote: "Note"
        case .document: "Document"
        }
    }
}

enum CareNoteProvenance: String, CaseIterable, Identifiable, Codable, Hashable {
    case ownerEntered = "owner_entered"
    case professionalInstruction = "professional_instruction"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ownerEntered: "Entered by you"
        case .professionalInstruction: "From a professional"
        }
    }

    var shortBadge: String {
        switch self {
        case .ownerEntered: "Owner"
        case .professionalInstruction: "Pro"
        }
    }
}

struct CareNoteMedia: Identifiable, Hashable {
    enum Status: String, Hashable {
        case pendingUpload = "pending_upload"
        case available
        case uploadFailed = "upload_failed"
        case removed
    }

    let id: UUID
    let storageBucket: String
    let storagePath: String
    let mimeType: String
    let byteSize: Int
    let captureTime: Date?
    let status: Status
}

struct CareNoteMediaUploadTarget: Hashable {
    let mediaId: UUID
    let bucket: String
    let path: String
    let upsert: Bool
    let mimeType: String
}

struct CareNote: Identifiable, Hashable {
    let id: UUID
    let kind: CareNoteKind
    let title: String?
    let body: String
    let effectiveDate: Date
    let provenance: CareNoteProvenance
    let providerId: UUID?
    let mediaRefs: [UUID]
    let media: [CareNoteMedia]
    let revision: Int
    let recordedByName: String?
}

/// Pending local attachment to upload after the note text save (Scenario H).
struct CareNotePendingAttachment: Hashable {
    let data: Data
    let mimeType: String
    let captureTime: Date?
    let displayName: String?

    var isPDF: Bool { mimeType == "application/pdf" }
    var isImage: Bool { mimeType.hasPrefix("image/") }
}

struct CareNoteDraft {
    var kind: CareNoteKind
    var title: String
    var body: String
    var effectiveDate: Date
    var provenance: CareNoteProvenance
    var providerId: UUID?
    /// Local bytes to attach after the text save. Nil when no new attachment.
    var pendingAttachment: CareNotePendingAttachment? = nil

    /// Convenience for tests / callers that still build JPEG-only drafts.
    var photoJPEGData: Data? {
        get {
            guard let pendingAttachment, pendingAttachment.mimeType == "image/jpeg" else {
                return nil
            }
            return pendingAttachment.data
        }
        set {
            if let newValue {
                pendingAttachment = CareNotePendingAttachment(
                    data: newValue,
                    mimeType: "image/jpeg",
                    captureTime: pendingAttachment?.captureTime,
                    displayName: nil
                )
            } else if pendingAttachment?.mimeType == "image/jpeg" {
                pendingAttachment = nil
            }
        }
    }

    var photoCaptureTime: Date? {
        get { pendingAttachment?.captureTime }
        set {
            guard let existing = pendingAttachment else { return }
            pendingAttachment = CareNotePendingAttachment(
                data: existing.data,
                mimeType: existing.mimeType,
                captureTime: newValue,
                displayName: existing.displayName
            )
        }
    }

    static func blank(anchorDate: Date = Date()) -> CareNoteDraft {
        CareNoteDraft(
            kind: .generalNote,
            title: "",
            body: "",
            effectiveDate: anchorDate,
            provenance: .ownerEntered,
            providerId: nil
        )
    }

    static func from(_ note: CareNote) -> CareNoteDraft {
        CareNoteDraft(
            kind: note.kind,
            title: note.title ?? "",
            body: note.body,
            effectiveDate: note.effectiveDate,
            provenance: note.provenance,
            providerId: note.providerId
        )
    }
}

enum CareNoteAttachmentLimits {
    static let maxBytes = 10_485_760
    static let allowedImageMimeTypes: Set<String> = [
        "image/jpeg", "image/png", "image/heic", "image/webp",
    ]
    static let allowedMimeTypes: Set<String> = allowedImageMimeTypes.union(["application/pdf"])

    static func isAllowed(_ mimeType: String) -> Bool {
        allowedMimeTypes.contains(mimeType)
    }

    static var honestSizeCopy: String {
        "Attachments must be 10 MB or smaller."
    }
}

/// Calm caregiver-facing errors for care note reads/writes. Raw server
/// strings never reach the UI (same convention as `CareError`).
enum CareNoteError: LocalizedError, Equatable {
    case changedElsewhere
    case notSignedIn
    case invalidEntry
    case recordsUnavailable
    case photoUploadFailed
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
        if let typed = error as? CareNoteError, let description = typed.errorDescription {
            return description
        }
        let raw = error.localizedDescription
        if looksLikeMissingSchema(raw) {
            return CareNoteError.recordsUnavailable.errorDescription!
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return CareNoteError.unexpected(code: "UNKNOWN").errorDescription!
    }

    static func fromTransportFailure(_ error: Error) -> Error {
        if error is CareNoteError { return error }
        if looksLikeMissingSchema(error.localizedDescription)
            || looksLikeMissingSchema(String(describing: error))
        {
            return CareNoteError.recordsUnavailable
        }
        return error
    }

    static func looksLikeMissingSchema(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("schema cache") { return true }
        if lower.contains("pgrst205") { return true }
        if lower.contains("could not find the table")
            && (lower.contains("care_notes") || lower.contains("public."))
        {
            return true
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .changedElsewhere:
            "This note changed since you opened it. Reopen it to see the latest."
        case .notSignedIn:
            "You no longer have access to this household."
        case .invalidEntry:
            "Check the details and try again."
        case .recordsUnavailable:
            "Care notes aren’t available on this backend yet."
        case .photoUploadFailed:
            "The note was saved, but the attachment didn’t upload. You can try again."
        case .unexpected:
            "Something went wrong. Try again."
        }
    }
}
