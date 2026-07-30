import Foundation

/// Shared plan/task vocabulary — Daily Plan Engine doc 12 §6, §8, §13 and
/// Data Model doc 10 §9–§10. Raw values match the data-model field values
/// (snake_case) so these types decode straight from the backend later.

/// Primary categories — engine §8.1.
enum PlanItemCategory: String, Codable, CaseIterable, Sendable {
    case health, feeding, routine, training, socialization
    case grooming, event, preparation, life, household

    var displayName: String {
        switch self {
        case .health: "Health"
        case .feeding: "Feeding"
        case .routine: "Routine"
        case .training: "Training"
        case .socialization: "Socialization"
        case .grooming: "Grooming"
        case .event: "Event"
        case .preparation: "Preparation"
        case .life: "Life"
        case .household: "Household"
        }
    }

    /// Quiet category glyph for plan cards (Home density pass).
    var systemImage: String {
        switch self {
        case .health: "heart"
        case .feeding: "fork.knife"
        case .routine: "sun.and.horizon"
        case .training: "figure.walk"
        case .socialization: "person.2"
        case .grooming: "comb"
        case .event: "calendar"
        case .preparation: "checklist"
        case .life: "heart.text.square"
        case .household: "house"
        }
    }
}

/// Obligation classes — engine §8.2. Conveyed to users by section, label,
/// and icon; color is reinforcement only (doc 09 §4.3).
enum ObligationClass: String, Codable, Sendable {
    case required, scheduled, recommended, informational

    var displayName: String {
        switch self {
        case .required: "Required"
        case .scheduled: "Scheduled"
        case .recommended: "Recommended"
        case .informational: "Informational"
        }
    }
}

/// Plan item kind — data model §10.2.
enum PlanItemKind: String, Codable, Sendable {
    case obligation
    case recommendation
    case informational
    case upcomingPreview = "upcoming_preview"
}

/// Plan sections in the fixed display order — engine §6. Empty sections
/// are hidden.
enum PlanSection: String, Codable, CaseIterable, Sendable {
    case needsAttention = "needs_attention"
    case today
    case recommended
    case comingUp = "coming_up"
    case completed

    static let displayOrder: [PlanSection] = [
        .needsAttention, .today, .recommended, .comingUp, .completed,
    ]

    var title: String {
        switch self {
        case .needsAttention: "Needs attention"
        case .today: "Today"
        case .recommended: "Recommended"
        case .comingUp: "Coming up"
        case .completed: "Completed"
        }
    }
}

/// Broad time windows for grouping Today items — engine §6.2.
enum PlanTimeWindow: String, Codable, CaseIterable, Sendable {
    case morning, midday, afternoon, evening, anytime

    var displayName: String {
        switch self {
        case .morning: "Morning"
        case .midday: "Midday"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        case .anytime: "Anytime"
        }
    }
}

/// Effort bands — engine §13.2. Planning estimates, not promises.
enum EffortBand: String, Codable, Sendable {
    case tiny, short, moderate, extended

    var displayText: String {
        switch self {
        case .tiny: "~1–2 min"
        case .short: "~3–5 min"
        case .moderate: "~10 min"
        case .extended: "15+ min"
        }
    }
}

/// Capacity modes — engine §13.1. Custom mode is intentionally absent in
/// MVP (IA §18.2).
enum CapacityMode: String, Codable, Sendable {
    case normal
    case busy
    case essentialsOnly = "essentials_only"

    /// Visible optional-recommendation budget — engine §6.3.
    var recommendationBudget: Int {
        switch self {
        case .normal: 3
        case .busy: 1
        case .essentialsOnly: 0
        }
    }

    var displayName: String {
        switch self {
        case .normal: "Normal day"
        case .busy: "Busy day"
        case .essentialsOnly: "Essentials only"
        }
    }
}

/// Whether a capacity change applies to one day or becomes the household
/// default — HM-04.
enum CapacityScope: Sendable {
    case todayOnly
    case householdDefault
}

/// Origin types — engine §8.3.
enum TaskOrigin: String, Codable, Sendable {
    case userCreated = "user_created"
    case recurringSchedule = "recurring_schedule"
    case healthSchedule = "health_schedule"
    case calendarEvent = "calendar_event"
    case trainingProgram = "training_program"
    case developmentRule = "development_rule"
    case socializationRule = "socialization_rule"
    case systemPreparationRule = "system_preparation_rule"
}

/// Time precision policy — data model §8.6, engine §15.1.
enum TimePolicy: String, Codable, Sendable {
    case exactTime = "exact_time"
    case window
    case anytime
}
