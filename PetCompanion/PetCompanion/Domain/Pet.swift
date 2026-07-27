import Foundation

/// Birth information is a tagged structure, never a bare date — Data Model
/// doc 10 §8.2.
enum BirthInfo: Equatable, Hashable, Sendable {
    /// `birth_date` is authoritative; age derives from it.
    case exact(birthDate: Date)
    /// Stored as an age **as of** a reference date; the estimate ages
    /// correctly without pretending a birthday exists. Display language
    /// must qualify: "about 9 weeks" (US-021).
    case estimated(ageWeeks: Int, asOfDate: Date)
    /// Permitted before arrival when the caregiver genuinely does not know
    /// the puppy's age yet. No synthetic birthday is invented.
    case unknown

    var isEstimated: Bool {
        if case .estimated = self { return true }
        return false
    }

    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

/// Development stage display helper.
///
/// Raw values match the seeded `development_stages.stage_key` values exactly
/// (content catalogue doc 15 §4) so this enum decodes straight from the
/// backend; bands are approximate, overlapping, and adaptable (F07) — this
/// is an eligibility/display input, not a hard boundary.
enum DevelopmentStage: String, Codable, CaseIterable, Sendable {
    /// Client-safe fallback when age and arrival context are insufficient.
    case unknown
    case preparing
    case settlingIn = "settling_in"
    case foundations
    case exploration
    case teething
    case earlyAdolescence = "early_adolescence"
    case adolescence
    case adulthood

    /// Derives the stage from age-since-homecoming context (content
    /// catalogue doc 15 §4 bands). `daysUntilHomecoming` takes precedence:
    /// a future homecoming date always means `preparing`, regardless of
    /// age (birth dates are frequently estimated pre-arrival).
    static func forAge(
        weeks: Int,
        daysSinceHomecoming: Int? = nil,
        daysUntilHomecoming: Int? = nil
    ) -> DevelopmentStage {
        if daysUntilHomecoming != nil {
            return .preparing
        }
        if let daysSinceHomecoming, daysSinceHomecoming < 14 {
            return .settlingIn
        }
        return switch weeks {
        case ..<8: .settlingIn
        case 8..<12: .foundations
        case 12..<16: .exploration
        case 16..<24: .teething
        case 24..<39: .earlyAdolescence // ~6-9 months
        case 39..<78: .adolescence // ~9-18 months
        default: .adulthood // 18+ months
        }
    }

    var displayName: String {
        switch self {
        case .unknown: "Stage not set"
        case .preparing: "Preparing for arrival"
        case .settlingIn: "Settling in"
        case .foundations: "Foundations"
        case .exploration: "Exploration and socialization"
        case .teething: "Teething"
        case .earlyAdolescence: "Early adolescence"
        case .adolescence: "Adolescence"
        case .adulthood: "Adulthood"
        }
    }
}

/// The subject of all care, training, and memory records — Data Model
/// doc 10 §7.5. Slice A subset plus derived display helpers.
struct Pet: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var householdId: UUID
    var name: String
    var species: String
    var breedText: String?
    var sex: String?
    var birthInfo: BirthInfo
    /// May be in the future — drives the pre-arrival plan variant (US-022).
    var homecomingDate: Date?
    var stageOverride: DevelopmentStage?
    var status: Status
    var revision: Int

    enum Status: String, Codable, Sendable {
        case active, archived
    }

    init(
        id: UUID = UUID(),
        householdId: UUID,
        name: String,
        species: String = "dog",
        breedText: String? = nil,
        sex: String? = nil,
        birthInfo: BirthInfo,
        homecomingDate: Date? = nil,
        stageOverride: DevelopmentStage? = nil,
        status: Status = .active,
        revision: Int = 1
    ) {
        self.id = id
        self.householdId = householdId
        self.name = name
        self.species = species
        self.breedText = breedText
        self.sex = sex
        self.birthInfo = birthInfo
        self.homecomingDate = homecomingDate
        self.stageOverride = stageOverride
        self.status = status
        self.revision = revision
    }

    // MARK: - Codable (flattens BirthInfo into the data-model field names)

    enum CodingKeys: String, CodingKey {
        case id, name, species, sex, status, revision
        case householdId = "household_id"
        case breedText = "breed_text"
        case birthDateKind = "birth_date_kind"
        case birthDate = "birth_date"
        case estimatedAgeWeeks = "estimated_age_weeks"
        case estimatedAsOfDate = "estimated_as_of_date"
        case homecomingDate = "homecoming_date"
        case stageOverride = "stage_override"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        householdId = try container.decode(UUID.self, forKey: .householdId)
        name = try container.decode(String.self, forKey: .name)
        species = try container.decode(String.self, forKey: .species)
        breedText = try container.decodeIfPresent(String.self, forKey: .breedText)
        sex = try container.decodeIfPresent(String.self, forKey: .sex)
        homecomingDate = try container.decodeIfPresent(Date.self, forKey: .homecomingDate)
        // `stage_override` is free text in SQL (not an enum column) — an
        // unrecognized value must decode to nil, never throw.
        stageOverride = try container.decodeIfPresent(String.self, forKey: .stageOverride)
            .flatMap { DevelopmentStage(rawValue: $0) }
        status = try container.decode(Status.self, forKey: .status)
        revision = try container.decode(Int.self, forKey: .revision)

        let kind = try container.decode(String.self, forKey: .birthDateKind)
        switch kind {
        case "exact":
            birthInfo = .exact(birthDate: try container.decode(Date.self, forKey: .birthDate))
        case "estimated":
            birthInfo = .estimated(
                ageWeeks: try container.decode(Int.self, forKey: .estimatedAgeWeeks),
                asOfDate: try container.decode(Date.self, forKey: .estimatedAsOfDate)
            )
        case "unknown":
            birthInfo = .unknown
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .birthDateKind,
                in: container,
                debugDescription: "Unknown birth_date_kind: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(householdId, forKey: .householdId)
        try container.encode(name, forKey: .name)
        try container.encode(species, forKey: .species)
        try container.encodeIfPresent(breedText, forKey: .breedText)
        try container.encodeIfPresent(sex, forKey: .sex)
        try container.encodeIfPresent(homecomingDate, forKey: .homecomingDate)
        try container.encodeIfPresent(stageOverride, forKey: .stageOverride)
        try container.encode(status, forKey: .status)
        try container.encode(revision, forKey: .revision)

        switch birthInfo {
        case .exact(let birthDate):
            try container.encode("exact", forKey: .birthDateKind)
            try container.encode(birthDate, forKey: .birthDate)
        case .estimated(let ageWeeks, let asOfDate):
            try container.encode("estimated", forKey: .birthDateKind)
            try container.encode(ageWeeks, forKey: .estimatedAgeWeeks)
            try container.encode(asOfDate, forKey: .estimatedAsOfDate)
        case .unknown:
            try container.encode("unknown", forKey: .birthDateKind)
        }
    }

    // MARK: - Derived age, stage, and arrival helpers

    /// Age in whole weeks on `date`. For estimates, elapses time from the
    /// reference date (doc 10 §8.2).
    func ageInWeeks(on date: Date = Date(), calendar: Calendar = .current) -> Int {
        func days(from start: Date, to end: Date) -> Int {
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: start),
                to: calendar.startOfDay(for: end)
            ).day ?? 0
        }
        switch birthInfo {
        case .exact(let birthDate):
            return max(0, days(from: birthDate, to: date) / 7)
        case .estimated(let ageWeeks, let asOfDate):
            return max(0, ageWeeks + days(from: asOfDate, to: date) / 7)
        case .unknown:
            return 0
        }
    }

    /// "12 wks" (exact) or "about 9 weeks" (estimated — always qualified,
    /// US-021, doc 09 §9).
    func ageDisplay(on date: Date = Date(), calendar: Calendar = .current) -> String {
        let weeks = ageInWeeks(on: date, calendar: calendar)
        switch birthInfo {
        case .exact:
            return "\(weeks) wks"
        case .estimated:
            return "about \(weeks) weeks"
        case .unknown:
            return "Age not set"
        }
    }

    func stage(on date: Date = Date(), calendar: Calendar = .current) -> DevelopmentStage {
        if let stageOverride { return stageOverride }
        var daysSinceHomecoming: Int?
        if let homecomingDate, daysUntilHomecoming(from: date, calendar: calendar) == nil {
            daysSinceHomecoming = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: homecomingDate),
                to: calendar.startOfDay(for: date)
            ).day
        }
        if case .unknown = birthInfo {
            if daysUntilHomecoming(from: date, calendar: calendar) != nil {
                return .preparing
            }
            if let daysSinceHomecoming, daysSinceHomecoming < 14 {
                return .settlingIn
            }
            return .unknown
        }
        return .forAge(
            weeks: ageInWeeks(on: date, calendar: calendar),
            daysSinceHomecoming: daysSinceHomecoming,
            daysUntilHomecoming: daysUntilHomecoming(from: date, calendar: calendar)
        )
    }

    /// Header line: "12 wks · Foundations".
    func ageAndStageDisplay(on date: Date = Date(), calendar: Calendar = .current) -> String {
        "\(ageDisplay(on: date, calendar: calendar)) · \(stage(on: date, calendar: calendar).displayName)"
    }

    /// Whole days until homecoming; nil when no homecoming date is set or
    /// it has passed.
    func daysUntilHomecoming(from date: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let homecomingDate else { return nil }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: homecomingDate)
        ).day ?? 0
        return days > 0 ? days : nil
    }

    /// Pre-arrival mode is driven by a homecoming date in the future
    /// (IA §14). On the homecoming local date itself the pet counts as home.
    func isPreArrival(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        daysUntilHomecoming(from: date, calendar: calendar) != nil
    }
}
