import Foundation

/// The append-only record of every user action on an occurrence — Data
/// Model doc 10 §9.4. The household's trustworthy shared history and the
/// basis of attribution ("Completed by Sarah at 7:42 AM").
struct Disposition: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let occurrenceId: UUID
    var action: Action
    var actorUserId: UUID
    /// When the action was logged (UTC).
    var recordedAt: Date
    /// When it actually happened; defaults to `recordedAt` (doc 10 §8.3).
    var effectiveAt: Date
    var note: String?
    var skipReason: String?
    var snoozeUntil: Date?
    var rescheduleTo: Date?
    /// Idempotency key: the server treats repeated keys as the same
    /// operation (US-107).
    var clientIdempotencyKey: String
    /// True for duplicate completions kept for audit but invisible in
    /// normal UI (engine §18.3).
    var superseded: Bool

    enum Action: String, Codable, Sendable {
        case complete
        case undoComplete = "undo_complete"
        case skip
        case undoSkip = "undo_skip"
        case snooze
        case reschedule
        case cancel
        case dismissRequired = "dismiss_required"
    }

    enum CodingKeys: String, CodingKey {
        case id, action, note, superseded
        case occurrenceId = "occurrence_id"
        case actorUserId = "actor_user_id"
        case recordedAt = "recorded_at"
        case effectiveAt = "effective_at"
        case skipReason = "skip_reason"
        case snoozeUntil = "snooze_until"
        case rescheduleTo = "reschedule_to"
        case clientIdempotencyKey = "client_idempotency_key"
    }

    init(
        id: UUID = UUID(),
        occurrenceId: UUID,
        action: Action,
        actorUserId: UUID,
        recordedAt: Date = Date(),
        effectiveAt: Date? = nil,
        note: String? = nil,
        skipReason: String? = nil,
        snoozeUntil: Date? = nil,
        rescheduleTo: Date? = nil,
        clientIdempotencyKey: String = UUID().uuidString,
        superseded: Bool = false
    ) {
        self.id = id
        self.occurrenceId = occurrenceId
        self.action = action
        self.actorUserId = actorUserId
        self.recordedAt = recordedAt
        self.effectiveAt = effectiveAt ?? recordedAt
        self.note = note
        self.skipReason = skipReason
        self.snoozeUntil = snoozeUntil
        self.rescheduleTo = rescheduleTo
        self.clientIdempotencyKey = clientIdempotencyKey
        self.superseded = superseded
    }
}
