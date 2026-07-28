import Foundation

/// Who a task is for — Data Model doc 10 §9.2 `assignment_default` /
/// §9.3. Stored in SQL as two columns, `assignment_kind`
/// (`unassigned | member | anyone`) and `assignment_user_id` (uuid, set only
/// when `assignment_kind == member`) — this enum is the app-side
/// reconstruction of that pair.
enum Assignment: Equatable, Hashable, Sendable {
    case unassigned
    case anyone
    case member(UUID)

    /// Raw values match `public.assignment_kind`.
    enum Kind: String, Codable, Sendable {
        case unassigned, member, anyone
    }

    var kind: Kind {
        switch self {
        case .unassigned: .unassigned
        case .anyone: .anyone
        case .member: .member
        }
    }

    var userId: UUID? {
        if case .member(let uuid) = self { return uuid }
        return nil
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
        case id, state, origin, revision
        case window = "window_ref"
        case occurrenceKey = "occurrence_key"
        case householdId = "household_id"
        case petId = "pet_id"
        case scheduleId = "schedule_id"
        case localDueDate = "local_due_date"
        case originalLocalDueDate = "original_local_due_date"
        case timePolicy = "time_policy"
        case dueTime = "due_time"
        case obligationClass = "obligation_class"
        case assignmentKind = "assignment_kind"
        case assignmentUserId = "assignment_user_id"
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

    // MARK: - Codable (reconstructs `assignment` from the two SQL columns)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        occurrenceKey = try container.decode(String.self, forKey: .occurrenceKey)
        householdId = try container.decode(UUID.self, forKey: .householdId)
        petId = try container.decode(UUID.self, forKey: .petId)
        scheduleId = try container.decodeIfPresent(UUID.self, forKey: .scheduleId)
        localDueDate = try container.decode(Date.self, forKey: .localDueDate)
        originalLocalDueDate = try container.decode(Date.self, forKey: .originalLocalDueDate)
        timePolicy = try container.decode(TimePolicy.self, forKey: .timePolicy)
        dueTime = try container.decodeIfPresent(Date.self, forKey: .dueTime)
        // `window_ref`'s check constraint on `task_occurrences` allows
        // `sleep` (routine bedtime windows) alongside the four the domain
        // `PlanTimeWindow` models for plan display — decode permissively
        // rather than throw on a value this occurrence's own UI treatment
        // was never going to render as a window group anyway.
        window = (try? container.decodeIfPresent(String.self, forKey: .window))
            .flatMap { $0 }
            .flatMap(PlanTimeWindow.init(rawValue:))
        state = try container.decode(State.self, forKey: .state)
        obligationClass = try container.decode(ObligationClass.self, forKey: .obligationClass)
        origin = try container.decode(TaskOrigin.self, forKey: .origin)
        revision = try container.decode(Int.self, forKey: .revision)

        let assignmentKind = try container.decode(Assignment.Kind.self, forKey: .assignmentKind)
        let assignmentUserId = try container.decodeIfPresent(UUID.self, forKey: .assignmentUserId)
        switch assignmentKind {
        case .unassigned:
            assignment = .unassigned
        case .anyone:
            assignment = .anyone
        case .member:
            guard let assignmentUserId else {
                throw DecodingError.dataCorruptedError(
                    forKey: .assignmentUserId,
                    in: container,
                    debugDescription: "assignment_kind 'member' requires assignment_user_id"
                )
            }
            assignment = .member(assignmentUserId)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(occurrenceKey, forKey: .occurrenceKey)
        try container.encode(householdId, forKey: .householdId)
        try container.encode(petId, forKey: .petId)
        try container.encodeIfPresent(scheduleId, forKey: .scheduleId)
        try container.encode(localDueDate, forKey: .localDueDate)
        try container.encode(originalLocalDueDate, forKey: .originalLocalDueDate)
        try container.encode(timePolicy, forKey: .timePolicy)
        try container.encodeIfPresent(dueTime, forKey: .dueTime)
        try container.encodeIfPresent(window, forKey: .window)
        try container.encode(state, forKey: .state)
        try container.encode(obligationClass, forKey: .obligationClass)
        try container.encode(origin, forKey: .origin)
        try container.encode(revision, forKey: .revision)
        try container.encode(assignment.kind, forKey: .assignmentKind)
        try container.encodeIfPresent(assignment.userId, forKey: .assignmentUserId)
    }
}

extension TaskOccurrence {
    /// Midnight of this occurrence's due date, in the household's own zone.
    ///
    /// `task_occurrences.local_due_date` is a SQL `date` — a civil date with no
    /// zone — and `SupabaseCoding.restDecoder` lands it on midnight GMT, so its
    /// calendar components only read correctly in GMT. Anything that combines
    /// it with a household-local wall-clock time has to re-anchor it first:
    /// midnight GMT on the 28th is the evening of the 27th in Toronto, so
    /// setting an hour "of" that instant lands on the wrong day entirely. This
    /// is the occurrence-side twin of `Plan.localDayStart(in:)`.
    func localDayStart(in timeZone: TimeZone) -> Date {
        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = .gmt
        let day = gmt.dateComponents([.year, .month, .day], from: localDueDate)

        var household = Calendar(identifier: .gregorian)
        household.timeZone = timeZone
        return household.date(from: day) ?? localDueDate
    }
}
