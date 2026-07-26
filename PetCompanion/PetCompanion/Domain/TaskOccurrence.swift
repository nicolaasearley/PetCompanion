import Foundation

/// Who a task is for — Data Model doc 10 §9.2 `assignment_default` /
/// §9.3 `assignment`. Serialized as a single string
/// ("unassigned" | "anyone" | "member:<user_id>").
enum Assignment: Equatable, Hashable, Codable, Sendable {
    case unassigned
    case anyone
    case member(UUID)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "unassigned":
            self = .unassigned
        case "anyone":
            self = .anyone
        default:
            guard raw.hasPrefix("member:"),
                  let uuid = UUID(uuidString: String(raw.dropFirst("member:".count)))
            else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown assignment value: \(raw)"
                )
            }
            self = .member(uuid)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .unassigned: try container.encode("unassigned")
        case .anyone: try container.encode("anyone")
        case .member(let uuid): try container.encode("member:\(uuid.uuidString)")
        }
    }

    var displayText: String {
        switch self {
        case .unassigned, .anyone: "anyone"
        case .member: "assigned"
        }
    }
}

/// One dated instance that can be acted on — Data Model doc 10 §9.3.
struct TaskOccurrence: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// Deterministic identity per doc 10 §8.6; regeneration can never
    /// duplicate (US-041).
    var occurrenceKey: String
    var householdId: UUID
    var petId: UUID
    var scheduleId: UUID?
    /// Local date (day granularity) in the household time zone.
    var localDueDate: Date
    /// The rule-generated date — part of the occurrence key; equals
    /// `localDueDate` until rescheduled.
    var originalLocalDueDate: Date
    var timePolicy: TimePolicy
    /// Resolved exact due time (when `timePolicy == .exactTime`).
    var dueTime: Date?
    /// Resolved broad window (when `timePolicy == .window`).
    var window: PlanTimeWindow?
    var assignment: Assignment
    var state: State
    var obligationClass: ObligationClass
    var origin: TaskOrigin
    var revision: Int

    /// Lifecycle states — engine §16.1. `needs_attention` is derived
    /// presentation state and `snoozed` is a pending occurrence with an
    /// active snooze annotation; neither is a stored lifecycle state
    /// (doc 10 §9.3).
    enum State: String, Codable, Sendable {
        case pending, completed, skipped, rescheduled, cancelled, expired
    }

    enum CodingKeys: String, CodingKey {
        case id, state, origin, revision, assignment, window
        case occurrenceKey = "occurrence_key"
        case householdId = "household_id"
        case petId = "pet_id"
        case scheduleId = "schedule_id"
        case localDueDate = "local_due_date"
        case originalLocalDueDate = "original_local_due_date"
        case timePolicy = "time_policy"
        case dueTime = "due_time"
        case obligationClass = "obligation_class"
    }

    init(
        id: UUID = UUID(),
        occurrenceKey: String,
        householdId: UUID,
        petId: UUID,
        scheduleId: UUID? = nil,
        localDueDate: Date,
        originalLocalDueDate: Date? = nil,
        timePolicy: TimePolicy = .anytime,
        dueTime: Date? = nil,
        window: PlanTimeWindow? = nil,
        assignment: Assignment = .anyone,
        state: State = .pending,
        obligationClass: ObligationClass,
        origin: TaskOrigin,
        revision: Int = 1
    ) {
        self.id = id
        self.occurrenceKey = occurrenceKey
        self.householdId = householdId
        self.petId = petId
        self.scheduleId = scheduleId
        self.localDueDate = localDueDate
        self.originalLocalDueDate = originalLocalDueDate ?? localDueDate
        self.timePolicy = timePolicy
        self.dueTime = dueTime
        self.window = window
        self.assignment = assignment
        self.state = state
        self.obligationClass = obligationClass
        self.origin = origin
        self.revision = revision
    }
}
