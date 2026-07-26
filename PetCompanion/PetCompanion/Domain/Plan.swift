import Foundation

/// Stage key + definition version used at generation (F07, doc 10 §10.1).
/// The SQL column is a jsonb object (`{"stage_key": ..., "version": ...}`),
/// not a bare string.
struct StageSnapshot: Codable, Equatable, Sendable {
    var stageKey: String
    var version: Int

    enum CodingKeys: String, CodingKey {
        case stageKey = "stage_key"
        case version
    }

    init(stageKey: String, version: Int = 1) {
        self.stageKey = stageKey
        self.version = version
    }
}

/// The single shared plan for one pet on one local day — Data Model doc 10
/// §10.1. Unique per (pet, local date); regeneration mutates, never clones.
struct Plan: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var householdId: UUID
    var petId: UUID
    /// Local date (day granularity) in the household time zone.
    var localDate: Date
    /// Historical plans stay interpretable after a time-zone change.
    var timeZoneSnapshot: String
    /// Stage key + definition version used at generation (F07).
    var stageSnapshot: StageSnapshot
    var capacityModeApplied: CapacityMode
    /// Incremented on each meaningful regeneration (engine §10.2).
    var planVersion: Int
    var status: Status
    var generatedAt: Date

    enum Status: String, Codable, Sendable {
        case open, closed
    }

    enum CodingKeys: String, CodingKey {
        case id, status
        case householdId = "household_id"
        case petId = "pet_id"
        case localDate = "local_date"
        case timeZoneSnapshot = "time_zone_snapshot"
        case stageSnapshot = "stage_snapshot"
        case capacityModeApplied = "capacity_mode_applied"
        case planVersion = "plan_version"
        case generatedAt = "generated_at"
    }

    init(
        id: UUID = UUID(),
        householdId: UUID,
        petId: UUID,
        localDate: Date,
        timeZoneSnapshot: String,
        stageSnapshot: StageSnapshot,
        capacityModeApplied: CapacityMode = .normal,
        planVersion: Int = 1,
        status: Status = .open,
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.householdId = householdId
        self.petId = petId
        self.localDate = localDate
        self.timeZoneSnapshot = timeZoneSnapshot
        self.stageSnapshot = stageSnapshot
        self.capacityModeApplied = capacityModeApplied
        self.planVersion = planVersion
        self.status = status
        self.generatedAt = generatedAt
    }
}

/// Ordering hint, internal only, never displayed as a score — engine §12.1.
/// Raw values match the SQL enum `public.priority_tier` ('P0'..'P5'); lower
/// tiers sort first.
enum PriorityTier: String, Codable, CaseIterable, Sendable {
    case p0 = "P0"
    case p1 = "P1"
    case p2 = "P2"
    case p3 = "P3"
    case p4 = "P4"
    case p5 = "P5"

    private var rank: Int {
        PriorityTier.allCases.firstIndex(of: self) ?? 0
    }
}

extension PriorityTier: Comparable {
    static func < (lhs: PriorityTier, rhs: PriorityTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// One entry in a plan — Data Model doc 10 §10.2.
///
/// `title` is denormalized display text resolved at generation time from
/// the occurrence's definition or the rule's content — the same pattern as
/// `explanation_text`, which is rendered at generation and stored, never
/// re-rendered (doc 10 §10.2).
struct PlanItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var planId: UUID
    /// Stable across regenerations of the same logical item.
    var itemKey: String
    var kind: PlanItemKind
    /// Set for obligations; recommendations gain one only when accepted
    /// (doc 10 §10.3).
    var occurrenceId: UUID?
    /// Rule id + version for recommendations.
    var recommendationRuleRef: String?
    var title: String
    var category: PlanItemCategory
    var obligationClass: ObligationClass
    /// Engine §12.1; internal ordering hint, never displayed as a score.
    var priorityTier: PriorityTier
    var section: PlanSection
    var timeWindow: PlanTimeWindow?
    var effortBand: EffortBand?
    /// Rendered at generation from the rule's template — stored, not
    /// re-rendered. No numeric scores, ever (US-037).
    var explanationText: String?
    var pinned: Bool
    var displayState: DisplayState

    enum DisplayState: String, Codable, Sendable {
        case normal, queued, stale
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, category, section, pinned
        case planId = "plan_id"
        case itemKey = "item_key"
        case occurrenceId = "occurrence_id"
        case recommendationRuleRef = "recommendation_rule_ref"
        case obligationClass = "obligation_class"
        case priorityTier = "priority_tier"
        case timeWindow = "time_window"
        case effortBand = "effort_band"
        case explanationText = "explanation_text"
        case displayState = "display_state"
    }

    init(
        id: UUID = UUID(),
        planId: UUID,
        itemKey: String,
        kind: PlanItemKind,
        occurrenceId: UUID? = nil,
        recommendationRuleRef: String? = nil,
        title: String,
        category: PlanItemCategory,
        obligationClass: ObligationClass,
        priorityTier: PriorityTier = .p3,
        section: PlanSection,
        timeWindow: PlanTimeWindow? = nil,
        effortBand: EffortBand? = nil,
        explanationText: String? = nil,
        pinned: Bool = false,
        displayState: DisplayState = .normal
    ) {
        self.id = id
        self.planId = planId
        self.itemKey = itemKey
        self.kind = kind
        self.occurrenceId = occurrenceId
        self.recommendationRuleRef = recommendationRuleRef
        self.title = title
        self.category = category
        self.obligationClass = obligationClass
        self.priorityTier = priorityTier
        self.section = section
        self.timeWindow = timeWindow
        self.effortBand = effortBand
        self.explanationText = explanationText
        self.pinned = pinned
        self.displayState = displayState
    }
}

/// A plan with everything the UI needs to render and attribute it — the
/// aggregate a backend query returns (plan + items + occurrences +
/// dispositions).
struct PlanSnapshot: Codable, Equatable, Sendable {
    var plan: Plan
    var items: [PlanItem]
    var occurrences: [TaskOccurrence]
    var dispositions: [Disposition]

    enum CodingKeys: String, CodingKey {
        case plan, items, occurrences, dispositions
    }
}

/// One rendered section: engine §6 fixed order, empty sections hidden.
struct PlanSectionGroup: Identifiable, Equatable {
    let section: PlanSection
    var items: [PlanItem]
    var id: PlanSection { section }
}

extension PlanSnapshot {
    /// Sections in the fixed display order with empty sections hidden
    /// (engine §6). Item order within a section preserves the stored
    /// (generation) order.
    var orderedSections: [PlanSectionGroup] {
        PlanSection.displayOrder.compactMap { section in
            let sectionItems = items.filter { $0.section == section }
            return sectionItems.isEmpty ? nil : PlanSectionGroup(section: section, items: sectionItems)
        }
    }

    var isEmpty: Bool { items.isEmpty }

    func occurrence(for item: PlanItem) -> TaskOccurrence? {
        guard let occurrenceId = item.occurrenceId else { return nil }
        return occurrences.first { $0.id == occurrenceId }
    }

    func isCompleted(_ item: PlanItem) -> Bool {
        occurrence(for: item)?.state == .completed
    }

    /// The single effective completion (earliest valid, non-superseded) —
    /// completion convergence rule, doc 10 §9.4.
    func effectiveCompletion(for item: PlanItem) -> Disposition? {
        guard let occurrence = occurrence(for: item), occurrence.state == .completed else {
            return nil
        }
        return dispositions
            .filter { $0.occurrenceId == occurrence.id && $0.action == .complete && !$0.superseded }
            .min { $0.effectiveAt < $1.effectiveAt }
    }
}
