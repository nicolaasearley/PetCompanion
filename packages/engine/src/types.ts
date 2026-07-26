export type LocalDate = string;
export type Instant = string;
export type Species = "dog";
export type CapacityMode = "normal" | "busy" | "essentials_only" | "custom";
export type Category =
  | "health"
  | "feeding"
  | "routine"
  | "training"
  | "socialization"
  | "grooming"
  | "event"
  | "preparation"
  | "life"
  | "household";
export type ObligationClass = "required" | "scheduled" | "recommended" | "informational";
export type PriorityTier = "P0" | "P1" | "P2" | "P3" | "P4" | "P5";
export type PlanSection = "needs_attention" | "today" | "recommended" | "coming_up" | "completed";
export type EffortBand = "tiny" | "short" | "moderate" | "extended";
export type TimePolicy = "exact_time" | "window" | "anytime";
export type TimeWindow = "morning" | "midday" | "afternoon" | "evening" | "sleep" | "anytime";
export type OccurrenceState = "pending" | "completed" | "skipped" | "rescheduled" | "cancelled" | "expired";
export type Origin =
  | "user_created"
  | "recurring_schedule"
  | "health_schedule"
  | "calendar_event"
  | "training_program"
  | "development_rule"
  | "socialization_rule"
  | "system_preparation_rule";

export interface ExactBirthInfo {
  kind: "exact";
  birth_date: LocalDate;
}

export interface EstimatedBirthInfo {
  kind: "estimated";
  estimated_age_weeks: number;
  estimated_as_of_date: LocalDate;
}

export interface UnknownBirthInfo {
  kind: "unknown";
}

export type BirthInfo = ExactBirthInfo | EstimatedBirthInfo | UnknownBirthInfo;

export interface PetInput {
  pet_id: string;
  household_id: string;
  name: string;
  species: Species;
  birth_info: BirthInfo;
  expected_homecoming_date?: LocalDate;
  stage_override?: string;
}

export interface RoutineWindow {
  window_ref: Exclude<TimeWindow, "anytime">;
  start_time: string;
  end_time: string;
}

export interface HouseholdInput {
  time_zone: string;
  capacity_mode: CapacityMode;
  custom_recommendation_budget?: number;
  routine_windows: RoutineWindow[];
  excluded_socialization_categories?: string[];
  excluded_content_ids?: string[];
  paused_content_ids?: string[];
  brushing_cooldown_days?: number;
}

export interface CompletionSnapshot {
  completed_at: Instant;
  completed_by_user_id: string;
  completed_by_name?: string;
}

export interface TaskOccurrenceInput {
  id: string;
  occurrence_key: string;
  schedule_id: string;
  title: string;
  content_id?: string;
  content_version?: number;
  category: Category;
  obligation_class: "required" | "scheduled";
  origin: Origin;
  origin_ref?: Record<string, unknown>;
  local_due_date: LocalDate;
  original_local_due_date: LocalDate;
  time_policy: TimePolicy;
  due_time?: string;
  window_ref?: Exclude<TimeWindow, "anytime">;
  effort_band?: EffortBand;
  state: OccurrenceState;
  completion?: CompletionSnapshot;
}

export interface EventInput {
  event_id: string;
  title: string;
  kind: string;
  local_date: LocalDate;
  exact_time?: string;
  confirmed: boolean;
  content_id?: string;
}

export interface ContentVersionRef {
  content_id: string;
  version: number;
}

export interface DevelopmentStageRow extends ContentVersionRef {
  stage_key: string;
  name: string;
  position: number;
  entry_guidance: Record<string, unknown>;
  effective_from: LocalDate;
  retired_at?: Instant | null;
}

export interface TaskDefinitionRow extends ContentVersionRef {
  title: string;
  category: Category;
  default_obligation_class: ObligationClass;
  default_effort: EffortBand;
  default_time_policy: TimePolicy;
  metadata: Record<string, unknown>;
}

export interface RecommendationRuleRow extends ContentVersionRef {
  name: string;
  description: string;
  category: Category;
  eligibility: Record<string, unknown>;
  cooldown_days: number;
  frequency_cap?: Record<string, unknown> | null;
  effort_band: EffortBand;
  default_time_window: TimeWindow | null;
  default_priority: PriorityTier;
  explanation_template: string;
  effective_from: LocalDate;
  retired_at?: Instant | null;
}

export interface TrainingSkillRow extends ContentVersionRef {
  skill_group: string;
  title: string;
  prerequisite_skill_refs: string[];
  stage_guidance: string;
  effort_band: EffortBand;
  recommended_frequency: string;
  effective_from: LocalDate;
  retired_at?: Instant | null;
}

export interface SocializationRow extends ContentVersionRef {
  category: string;
  experience_key: string;
  label: string;
  caution_text: string;
  response_vocabulary: string[];
  effective_from: LocalDate;
  retired_at?: Instant | null;
}

export interface CatalogueInput {
  development_stages: DevelopmentStageRow[];
  task_definitions: TaskDefinitionRow[];
  recommendation_rules: RecommendationRuleRow[];
  training_skills: TrainingSkillRow[];
  socialization_catalog: SocializationRow[];
}

export type TrainingStatus = "not_started" | "active" | "paused" | "completed";

export interface TrainingStateInput {
  skill_content_id: string;
  status: TrainingStatus;
  user_selected_goal?: boolean;
  started_on?: LocalDate;
}

export interface HistoryEntry {
  local_date: LocalDate;
  content_id?: string;
  rule_content_id?: string;
  category: Category;
  socialization_category?: string;
  outcome: "completed" | "skipped" | "dismissed" | "expired" | "shown";
}

export interface ScoreWeights {
  base_priority_p3: number;
  base_priority_p4: number;
  stage_relevance: number;
  due_frequency_max: number;
  user_selected_goal: number;
  continuity_value: number;
  preparation_urgency_max: number;
  variety_bonus: number;
  recent_repetition: number;
  burden_tiny: number;
  burden_short: number;
  burden_moderate: number;
  burden_extended: number;
  dismissal_penalty: number;
  conflict_penalty: number;
}

export interface GenerationContext {
  local_date: LocalDate;
  now_instant: Instant;
  plan_version: number;
  pet: PetInput;
  household: HouseholdInput;
  active_occurrences: TaskOccurrenceInput[];
  events: EventInput[];
  catalogue: CatalogueInput;
  training_state: TrainingStateInput[];
  recent_history: HistoryEntry[];
  score_weights?: ScoreWeights;
}

export interface StageSnapshot {
  stage_key: string | null;
  content_id: string | null;
  version: number | null;
  age_weeks: number | null;
  age_is_estimated: boolean;
  sufficient_profile: boolean;
}

export interface ScoreComponents {
  base_priority: number;
  stage_relevance: number;
  due_frequency: number;
  user_selected_goal: number;
  continuity_value: number;
  preparation_urgency: number;
  variety_bonus: number;
  recent_repetition: number;
  estimated_burden: number;
  dismissal_penalty: number;
  conflict_penalty: number;
  total: number;
}

export interface RecommendationRuleRef {
  content_id: string;
  version: number;
}

export interface PlanItem {
  item_key: string;
  kind: "obligation" | "recommendation" | "informational" | "upcoming_preview";
  occurrence_id: string | null;
  recommendation_rule_ref: RecommendationRuleRef | null;
  content_ref: ContentVersionRef | null;
  title: string;
  category: Category;
  obligation_class: ObligationClass;
  priority_tier: PriorityTier;
  section: PlanSection;
  time_window: TimeWindow | null;
  due_time: string | null;
  effort_band: EffortBand | null;
  explanation_text: string | null;
  score_components: ScoreComponents | null;
  pinned: false;
  display_state: "planned" | "completed" | "skipped" | "rescheduled" | "cancelled" | "expired";
  origin: Origin | null;
  completion: CompletionSnapshot | null;
}

export interface PlanHeader {
  plan_key: string;
  household_id: string;
  pet_id: string;
  local_date: LocalDate;
  time_zone_snapshot: string;
  stage_snapshot: StageSnapshot;
  capacity_mode_applied: CapacityMode;
  recommendation_budget: number;
  plan_version: number;
  catalogue_version_set: ContentVersionRef[];
  input_digest: string;
  status: "open";
  generated_at: Instant;
}

export interface PlanResult {
  plan: PlanHeader;
  items: PlanItem[];
  diagnostics: {
    eligible_recommendation_count: number;
    selected_recommendation_count: number;
    suppressed: Array<{ candidate_key: string; reason: string }>;
  };
}
