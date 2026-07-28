import Foundation

/// Socialization passport domain types — F09, DM 10 §12.4, catalogue §7–§8.
///
/// Two product rules are load-bearing here and are expressed in the types
/// rather than left to the views:
///
///   * A **response is owner-reported and never diagnostic.** The vocabulary
///     is a closed enum matching catalogue §8, and `guidance` returns the
///     catalogue's own next-time wording — "more distance, a softer version"
///     — for `hesitant` and `fearful`. Nothing in this file, or anywhere the
///     passport renders, converts a response into an assessment of the puppy.
///   * There is **no score.** Breadth is reported per category as recency and
///     a plain count of recorded experiences, never a number out of anything,
///     never a percentage, and never a progress bar (F09 exclusion,
///     wireframes TR-06).

/// The eight F09 categories (core features §14). Raw values match the
/// catalogue's `category` column exactly, because the engine's breadth
/// rotation and the server's exclusion rows key on that string.
enum SocializationCategory: String, CaseIterable, Identifiable, Codable, Hashable {
    case people = "People"
    case animals = "Animals"
    case sounds = "Sounds"
    case surfaces = "Surfaces"
    case environments = "Environments"
    case handling = "Handling"
    case transportation = "Transportation"
    case householdObjects = "Household objects"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// Calm, non-clinical iconography (doc 09 §6).
    var systemImage: String {
        switch self {
        case .people: "person.2"
        case .animals: "pawprint"
        case .sounds: "speaker.wave.2"
        case .surfaces: "square.stack.3d.down.right"
        case .environments: "tree"
        case .handling: "hand.raised"
        case .transportation: "car"
        case .householdObjects: "shippingbox"
        }
    }
}

/// Catalogue §8, verbatim and closed. Owner-reported; never a behavioural
/// finding, and never rendered as one.
enum SocializationResponse: String, CaseIterable, Identifiable, Codable, Hashable {
    case relaxed
    case curious
    case neutral
    case hesitant
    case fearful

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .relaxed: "Relaxed"
        case .curious: "Curious"
        case .neutral: "Neutral"
        case .hesitant: "Hesitant"
        case .fearful: "Fearful"
        }
    }

    /// The standing catalogue §8 note. It is deliberately about what to do
    /// next time, not about what the response means — the product does not
    /// interpret behaviour.
    var guidance: String? {
        switch self {
        case .relaxed, .curious, .neutral:
            nil
        case .hesitant, .fearful:
            "Next time, try more distance and a softer version — not more repetitions."
        }
    }
}

/// DM §12.4. Every reason is reversible.
enum SocializationExclusionReason: String, CaseIterable, Identifiable, Codable, Hashable {
    case unavailable
    case unsuitable
    case paused

    var id: String { rawValue }

    /// TR-07's overflow wording. `{name}` is filled with the pet's name.
    func displayName(petName: String) -> String {
        switch self {
        case .unavailable: "Not available"
        case .unsuitable: "Not right for \(petName)"
        case .paused: "Paused"
        }
    }

    var shortLabel: String {
        switch self {
        case .unavailable: "Not available"
        case .unsuitable: "Not right for now"
        case .paused: "Paused"
        }
    }
}

/// A catalogue experience (`socialization_catalog`).
struct SocializationExperience: Identifiable, Hashable {
    let contentId: String
    let category: SocializationCategory
    let label: String

    var id: String { contentId }
}

/// One recorded experience (`socialization_records`).
struct SocializationRecord: Identifiable, Hashable {
    let id: UUID
    let experienceContentId: String?
    /// The catalogue label, or the caregiver's own wording for a custom one.
    let label: String
    let category: SocializationCategory
    let effectiveDate: Date
    let context: String?
    let response: SocializationResponse
    let note: String?
    let revision: Int
    let recordedByName: String?
}

/// One live or cleared exclusion (`socialization_exclusions`).
struct SocializationExclusion: Identifiable, Hashable {
    let id: UUID
    /// Exactly one of these two is set.
    let category: SocializationCategory?
    let experienceContentId: String?
    let reason: SocializationExclusionReason
    let isActive: Bool
}

/// What TR-06 renders for one category card.
///
/// Deliberately carries no score, ratio, or completion fraction: `count` is
/// how many experiences the household recorded in the window and `lastDate`
/// is when — the two facts a caregiver asked for. Neither is compared against
/// a target, because F09 excludes a universal numeric socialization score.
struct SocializationCategoryBreadth: Identifiable, Hashable {
    let category: SocializationCategory
    let recentCount: Int
    let lastDate: Date?
    let isExcluded: Bool
    let exclusionReason: SocializationExclusionReason?

    var id: String { category.rawValue }
}

/// Seed content mirroring `supabase/seed.sql` and catalogue §8.
///
/// The app carries the seed so the passport is browsable before any records
/// exist and while offline; the server remains the authority for what is
/// recordable, and rejects anything not published.
enum SocializationCatalogue {
    /// Catalogue §8's standing caution. It renders on **every** category and
    /// on the overview — not once, not behind a disclosure, and not only
    /// pre-vaccination. `{name}` is substituted with the pet's name.
    static let standingCaution =
        "Ask your vet where {name} can go before their vaccinations are complete. "
        + "Watching from a distance and being carried both count."

    static func caution(petName: String) -> String {
        standingCaution.replacingOccurrences(of: "{name}", with: petName)
    }

    /// The quality-over-quantity framing that heads TR-06 (F09 objective).
    static let framing = "Gentle, positive, varied — quality beats quantity."

    static let experiences: [SocializationExperience] = [
        .init(contentId: "soc.people.calm_adult_visitor", category: .people, label: "Calm adult visitor"),
        .init(contentId: "soc.people.hat_hood", category: .people, label: "Person with a hat/hood"),
        .init(contentId: "soc.people.stick_umbrella", category: .people, label: "Person with a stick or umbrella"),
        .init(contentId: "soc.people.child_distance", category: .people, label: "Child at a distance"),
        .init(contentId: "soc.people.delivery_worker_window", category: .people, label: "Delivery worker observed from window"),

        .init(contentId: "soc.animals.known_vaccinated_dog", category: .animals, label: "Calm vaccinated adult dog (known)"),
        .init(contentId: "soc.animals.dog_distance", category: .animals, label: "Dog seen at a distance"),
        .init(contentId: "soc.animals.cat_distance", category: .animals, label: "Cat at a distance"),
        .init(contentId: "soc.animals.birds_garden", category: .animals, label: "Birds in the garden"),

        .init(contentId: "soc.sounds.vacuum_low", category: .sounds, label: "Vacuum at low volume/distance"),
        .init(contentId: "soc.sounds.doorbell", category: .sounds, label: "Doorbell"),
        .init(contentId: "soc.sounds.hairdryer", category: .sounds, label: "Hairdryer"),
        .init(contentId: "soc.sounds.traffic_distance", category: .sounds, label: "Traffic from a distance"),
        .init(contentId: "soc.sounds.thunder_low", category: .sounds, label: "Recorded thunder at low volume"),
        .init(contentId: "soc.sounds.kitchen_clatter", category: .sounds, label: "Kitchen clatter"),

        .init(contentId: "soc.surfaces.grass", category: .surfaces, label: "Grass"),
        .init(contentId: "soc.surfaces.gravel", category: .surfaces, label: "Gravel"),
        .init(contentId: "soc.surfaces.wet_ground", category: .surfaces, label: "Wet ground"),
        .init(contentId: "soc.surfaces.smooth_floor", category: .surfaces, label: "Smooth floor"),
        .init(contentId: "soc.surfaces.wobbly_cushion", category: .surfaces, label: "Wobbly cushion"),
        .init(contentId: "soc.surfaces.low_step", category: .surfaces, label: "Low step"),

        .init(contentId: "soc.environments.front_garden", category: .environments, label: "Front garden"),
        .init(contentId: "soc.environments.quiet_street_carried", category: .environments, label: "Quiet street (carried if pre-vaccination per vet guidance)"),
        .init(contentId: "soc.environments.car_park_distance", category: .environments, label: "Car park at a distance"),
        .init(contentId: "soc.environments.friends_home", category: .environments, label: "Friend's home"),
        .init(contentId: "soc.environments.outdoor_cafe_distance", category: .environments, label: "Outdoor cafe from a distance"),

        .init(contentId: "soc.handling.towel_wipe", category: .handling, label: "Towel wipe-down"),
        .init(contentId: "soc.handling.brush_touch", category: .handling, label: "Brush touch"),
        .init(contentId: "soc.handling.nail_clipper_shown", category: .handling, label: "Nail-clipper shown and touched"),
        .init(contentId: "soc.handling.gently_held", category: .handling, label: "Being gently held"),
        .init(contentId: "soc.handling.harness_on_off", category: .handling, label: "Harness on/off"),

        .init(contentId: "soc.transportation.stationary_car", category: .transportation, label: "Stationary car with treats"),
        .init(contentId: "soc.transportation.short_car_ride", category: .transportation, label: "Short car ride"),
        .init(contentId: "soc.transportation.crate_in_car", category: .transportation, label: "Crate in the car"),

        .init(contentId: "soc.household_objects.umbrella_opening", category: .householdObjects, label: "Umbrella opening"),
        .init(contentId: "soc.household_objects.bin_bag_rustle", category: .householdObjects, label: "Bin bag rustle"),
        .init(contentId: "soc.household_objects.broom", category: .householdObjects, label: "Broom"),
        .init(contentId: "soc.household_objects.suitcase_wheels", category: .householdObjects, label: "Suitcase with wheels"),
        .init(contentId: "soc.household_objects.mirror", category: .householdObjects, label: "Mirror"),
    ]

    static func experiences(in category: SocializationCategory) -> [SocializationExperience] {
        experiences.filter { $0.category == category }
    }

    static func experience(contentId: String) -> SocializationExperience? {
        experiences.first { $0.contentId == contentId }
    }
}
