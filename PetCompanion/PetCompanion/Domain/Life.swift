import Foundation

/// Life domain types — F12, DM 10 §12.5–12.6, LF-01–LF-03.
///
/// Milestones are calm first-year memories: title, date, optional note, and
/// optional household-private photos. Text always saves independently of photo
/// upload (Scenario H). No streaks, scores, or engagement metrics.

struct Milestone: Identifiable, Hashable {
    let id: UUID
    let title: String
    let effectiveDate: Date
    let note: String?
    let mediaRefs: [UUID]
    let media: [MilestoneMedia]
    let revision: Int
    let recordedByName: String?
}

struct MilestoneMedia: Identifiable, Hashable {
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

struct MilestoneDraft {
    var title: String
    var effectiveDate: Date
    var note: String
    /// Local JPEG bytes to attach after the text save. Nil when no new photo.
    var photoJPEGData: Data? = nil
    var photoCaptureTime: Date? = nil
}

struct MilestoneMediaUploadTarget: Hashable {
    let mediaId: UUID
    let bucket: String
    let path: String
    let upsert: Bool
    let mimeType: String
}

/// Suggested first-year moments — prompts only, never fabricated rows.
struct LifeMomentPrompt: Identifiable, Hashable {
    let id: String
    let icon: String
    let title: String

    static let firstYear: [LifeMomentPrompt] = [
        LifeMomentPrompt(id: "first-day-home", icon: "house", title: "First day home"),
        LifeMomentPrompt(id: "first-walk", icon: "figure.walk", title: "First walk outside"),
        LifeMomentPrompt(id: "first-swim", icon: "figure.pool.swim", title: "First swim"),
        LifeMomentPrompt(id: "puppy-class", icon: "graduationcap", title: "Puppy class graduation"),
        LifeMomentPrompt(id: "first-friend", icon: "pawprint", title: "Met a dog friend"),
        LifeMomentPrompt(id: "slept-through", icon: "moon.zzz", title: "Slept through the night"),
    ]
}

/// Calm caregiver-facing errors for Life reads/writes. Raw server strings never
/// reach the UI (same convention as Care/Socialization).
enum LifeError: LocalizedError, Equatable {
    case changedElsewhere
    case notSignedIn
    case invalidEntry
    /// PostgREST schema-cache miss (migration not applied on this backend).
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
        if let life = error as? LifeError, let description = life.errorDescription {
            return description
        }
        let raw = error.localizedDescription
        if looksLikeMissingSchema(raw) {
            return LifeError.recordsUnavailable.errorDescription!
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return LifeError.unexpected(code: "UNKNOWN").errorDescription!
    }

    static func fromTransportFailure(_ error: Error) -> Error {
        if error is LifeError { return error }
        if looksLikeMissingSchema(error.localizedDescription)
            || looksLikeMissingSchema(String(describing: error))
        {
            return LifeError.recordsUnavailable
        }
        return error
    }

    static func looksLikeMissingSchema(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("schema cache") { return true }
        if lower.contains("pgrst205") { return true }
        if lower.contains("could not find the table")
            && (lower.contains("milestones") || lower.contains("media") || lower.contains("public."))
        {
            return true
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .changedElsewhere:
            "This milestone changed since you opened it. Reopen it to see the latest."
        case .notSignedIn:
            "You no longer have access to this household."
        case .invalidEntry:
            "Check the details and try again."
        case .recordsUnavailable:
            "Life milestones aren’t available on this backend yet."
        case .photoUploadFailed:
            "The memory saved, but the photo didn’t finish uploading. You can retry it."
        case .unexpected:
            "Something went wrong. Try again."
        }
    }
}

enum LifeCoding {
    static func localDate(_ date: Date, calendar: Calendar = .current) -> String {
        SupabaseCoding.dateOnlyString(date, timeZone: calendar.timeZone)
    }
}
