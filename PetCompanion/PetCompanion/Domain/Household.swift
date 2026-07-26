import Foundation

/// The shared tenancy unit — Data Model doc 10 §7.2.
struct Household: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// IANA identifier, e.g. "Europe/Stockholm". Plans and reminders use
    /// this time zone (US-010).
    var timeZone: String
    var status: Status
    var defaultCapacityMode: CapacityMode
    var createdAt: Date
    var createdBy: UUID

    enum Status: String, Codable, Sendable {
        case active, closed
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case timeZone = "time_zone"
        case defaultCapacityMode = "default_capacity_mode"
        case createdAt = "created_at"
        case createdBy = "created_by"
    }

    init(
        id: UUID = UUID(),
        name: String,
        timeZone: String,
        status: Status = .active,
        defaultCapacityMode: CapacityMode = .normal,
        createdAt: Date = Date(),
        createdBy: UUID
    ) {
        self.id = id
        self.name = name
        self.timeZone = timeZone
        self.status = status
        self.defaultCapacityMode = defaultCapacityMode
        self.createdAt = createdAt
        self.createdBy = createdBy
    }
}

/// A member as surfaced to the UI: the membership edge (doc 10 §7.3) joined
/// with the user's display name — the only user fields other members may
/// see (§7.1).
struct HouseholdMember: Codable, Identifiable, Equatable, Sendable {
    var id: UUID { userId }
    let userId: UUID
    var displayName: String
    var role: Role
    var status: Status

    enum Role: String, Codable, Sendable {
        case owner, caregiver
    }

    enum Status: String, Codable, Sendable {
        case active, removed, left
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case role, status
    }

    init(userId: UUID, displayName: String, role: Role, status: Status = .active) {
        self.userId = userId
        self.displayName = displayName
        self.role = role
        self.status = status
    }
}

/// A broad local-time band ("6–9") — HouseholdPreference routine windows,
/// doc 10 §7.6. Exact times stay optional except for explicitly timed care.
struct TimeBand: Codable, Equatable, Hashable, Sendable {
    var startHour: Int
    var endHour: Int

    enum CodingKeys: String, CodingKey {
        case startHour = "start_hour"
        case endHour = "end_hour"
    }

    init(startHour: Int, endHour: Int) {
        self.startHour = startHour
        self.endHour = endHour
    }

    var displayText: String { "\(startHour)–\(endHour)" }
}

/// Routine windows and meal template — Data Model doc 10 §7.6 (ON-08).
/// The wireframe surfaces morning/midday/evening/sleep; `afternoon` exists
/// in the model and keeps its reviewed default when not surfaced.
struct HouseholdPreference: Codable, Equatable, Sendable {
    var morning = TimeBand(startHour: 6, endHour: 9)
    var midday = TimeBand(startHour: 11, endHour: 13)
    var afternoon = TimeBand(startHour: 13, endHour: 17)
    var evening = TimeBand(startHour: 17, endHour: 21)
    var sleep = TimeBand(startHour: 22, endHour: 6)
    var mealsPerDay = 3

    enum CodingKeys: String, CodingKey {
        case morning, midday, afternoon, evening, sleep
        case mealsPerDay = "meals_per_day"
    }

    /// Reviewed stage-appropriate defaults applied when ON-08 is skipped
    /// (engine §19.3).
    static let reviewedDefaults = HouseholdPreference()
}
