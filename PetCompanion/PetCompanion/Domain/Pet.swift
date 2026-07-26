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

    var isEstimated: Bool {
        if case .estimated = self { return true }
        return false
    }
}

/// Development stage display helper.
///
/// Real stage definitions are versioned global content
/// (DevelopmentStageDefinition, doc 10 §10.5) that ships with the content
/// catalogue; this enum is the UI-foundation placeholder with age *bands,
/// not hard boundaries*, sufficient for the header chip and plan snapshots.
enum DevelopmentStage: String, Codable, CaseIterable, Sendable {
    case foundations
    case buildingOnBasics = "building_on_basics"
    case adolescence
    case youngAdult = "young_adult"

    static func forAge(weeks: Int) -> DevelopmentStage {
        switch weeks {
        case ..<16: .foundations
        case 16..<26: .buildingOnBasics
        case 26..<52: .adolescence
        default: .youngAdult
        }
    }

    var displayName: String {
        switch self {
        case .foundations: "Foundations"
        case .buildingOnBasics: "Building on basics"
        case .adolescence: "Adolescence"
        case .youngAdult: "Young adult"
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
        stageOverride = try container.decodeIfPresent(DevelopmentStage.self, forKey: .stageOverride)
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
        }
    }

    /// "12 wks" (exact) or "about 9 weeks" (estimated — always qualified,
    /// US-021, doc 09 §9).
    func ageDisplay(on date: Date = Date(), calendar: Calendar = .current) -> String {
        let weeks = ageInWeeks(on: date, calendar: calendar)
        return birthInfo.isEstimated ? "about \(weeks) weeks" : "\(weeks) wks"
    }

    func stage(on date: Date = Date(), calendar: Calendar = .current) -> DevelopmentStage {
        stageOverride ?? .forAge(weeks: ageInWeeks(on: date, calendar: calendar))
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
