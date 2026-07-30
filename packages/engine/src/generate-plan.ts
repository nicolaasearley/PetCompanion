import type {
  CatalogueInput,
  Category,
  ContentVersionRef,
  DevelopmentStageRow,
  EffortBand,
  GenerationContext,
  HistoryEntry,
  LocalDate,
  PlanItem,
  PlanResult,
  PriorityTier,
  RecommendationRuleRow,
  ScoreComponents,
  ScoreWeights,
  SocializationRow,
  StageSnapshot,
  TaskDefinitionRow,
  TaskOccurrenceInput,
  TimeWindow,
  TrainingSkillRow,
} from "./types.ts";

const DAY_MS = 86_400_000;
const SUPPORTED_RULES = [
  "rule.active_skill_practice",
  "rule.alone_time",
  "rule.brushing",
  "rule.event_prep_vet",
  "rule.handling_cadence",
  "rule.homecoming_routine",
  "rule.prep_window",
  "rule.socialization_breadth",
  "rule.start_next_skill",
] as const;

/** Catalogue §9 / seed: content selected by `rule.event_prep_vet`. */
const EVENT_PREP_VET_CONTENT_ID = "prep.gather_records_questions";
const EVENT_PREP_VET_TITLE = "Gather records and questions";
const EVENT_PREP_VET_FALLBACK: TaskDefinitionRow = {
  content_id: EVENT_PREP_VET_CONTENT_ID,
  version: 1,
  title: EVENT_PREP_VET_TITLE,
  category: "preparation",
  default_obligation_class: "recommended",
  default_effort: "short",
  default_time_policy: "anytime",
  metadata: { event_prep_kind: "vet_appointment" },
};

const SECTION_ORDER = {
  needs_attention: 0,
  today: 1,
  recommended: 2,
  coming_up: 3,
  completed: 4,
} as const;
/** Engine §13.3 / IA §5: "Coming up — up to three future items". */
const MAX_UPCOMING_ITEMS = 3;
const PRIORITY_ORDER: Record<PriorityTier, number> = { P0: 0, P1: 1, P2: 2, P3: 3, P4: 4, P5: 5 };
const WINDOW_ORDER: Record<TimeWindow, number> = {
  morning: 0,
  midday: 1,
  afternoon: 2,
  evening: 3,
  sleep: 4,
  anytime: 5,
};

/**
 * Named, exported weights make the initial policy inspectable and replaceable.
 * A caller may provide the same-shaped score_weights object in GenerationContext.
 */
export const DEFAULT_SCORE_WEIGHTS: ScoreWeights = Object.freeze({
  base_priority_p3: 30,
  base_priority_p4: 20,
  stage_relevance: 5,
  due_frequency_max: 5,
  user_selected_goal: 4,
  continuity_value: 3,
  preparation_urgency_max: 5,
  variety_bonus: 3,
  recent_repetition: 3,
  burden_tiny: 0,
  burden_short: 1,
  burden_moderate: 3,
  burden_extended: 5,
  dismissal_penalty: 2,
  conflict_penalty: 4,
});

interface Candidate {
  candidate_key: string;
  activity_key: string;
  rule: RecommendationRuleRow;
  content_ref: ContentVersionRef;
  title: string;
  category: Category;
  effort_band: EffortBand;
  explanation_values: Record<string, string | number>;
  score: ScoreComponents;
}

function dateMs(value: LocalDate): number {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) throw new Error(`Invalid local date: ${value}`);
  return Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
}

function daysBetween(from: LocalDate, to: LocalDate): number {
  return Math.round((dateMs(to) - dateMs(from)) / DAY_MS);
}

function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  const object = value as Record<string, unknown>;
  return `{${Object.keys(object)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${stableStringify(object[key])}`)
    .join(",")}}`;
}

function digest(value: unknown): string {
  const text = stableStringify(value);
  let hash = 0x811c9dc5;
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return `fnv1a32:${(hash >>> 0).toString(16).padStart(8, "0")}`;
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function latestRows<T extends ContentVersionRef>(rows: readonly T[], localDate: LocalDate, nowInstant: string): T[] {
  const eligible = rows.filter((row) => {
    const dated = row as T & { effective_from?: LocalDate; retired_at?: string | null };
    return (!dated.effective_from || dated.effective_from <= localDate) && (!dated.retired_at || dated.retired_at > nowInstant);
  });
  const byId = new Map<string, T>();
  for (const row of eligible.sort((a, b) => a.version - b.version || compareText(a.content_id, b.content_id))) {
    byId.set(row.content_id, row);
  }
  return [...byId.values()].sort((a, b) => compareText(a.content_id, b.content_id));
}

function activeCatalogue(context: GenerationContext): CatalogueInput {
  return {
    development_stages: latestRows(context.catalogue.development_stages, context.local_date, context.now_instant),
    task_definitions: latestRows(context.catalogue.task_definitions, context.local_date, context.now_instant),
    recommendation_rules: latestRows(context.catalogue.recommendation_rules, context.local_date, context.now_instant),
    training_skills: latestRows(context.catalogue.training_skills, context.local_date, context.now_instant),
    socialization_catalog: latestRows(context.catalogue.socialization_catalog, context.local_date, context.now_instant),
  };
}

function deriveAgeWeeks(context: GenerationContext): { age_weeks: number | null; estimated: boolean } {
  const birth = context.pet.birth_info;
  if (birth.kind === "exact") {
    return { age_weeks: Math.max(0, daysBetween(birth.birth_date, context.local_date) / 7), estimated: false };
  }
  if (birth.kind === "estimated") {
    // The database can intentionally carry an unknown birth date. Older
    // generation-context payloads encode that as an estimated shape with null
    // values, so keep the engine fail-safe instead of inventing an age.
    if (
      typeof birth.estimated_age_weeks !== "number" ||
      !Number.isFinite(birth.estimated_age_weeks) ||
      typeof birth.estimated_as_of_date !== "string"
    ) {
      return { age_weeks: null, estimated: false };
    }
    return {
      age_weeks: Math.max(0, birth.estimated_age_weeks + daysBetween(birth.estimated_as_of_date, context.local_date) / 7),
      estimated: true,
    };
  }
  return { age_weeks: null, estimated: false };
}

function guidanceMinimumWeeks(stage: DevelopmentStageRow): number | null {
  const guidance = stage.entry_guidance;
  const weeks = guidance["age_min_weeks"];
  if (typeof weeks === "number") return weeks;
  const months = guidance["age_min_months"];
  if (typeof months === "number") return months * 4.345;
  return null;
}

function resolveStage(context: GenerationContext, stages: DevelopmentStageRow[]): StageSnapshot {
  const age = deriveAgeWeeks(context);
  let stageKey: string | null = null;
  if (context.pet.expected_homecoming_date && context.pet.expected_homecoming_date > context.local_date) {
    stageKey = "preparing";
  } else if (context.pet.stage_override) {
    stageKey = context.pet.stage_override;
  } else if (
    context.pet.expected_homecoming_date &&
    daysBetween(context.pet.expected_homecoming_date, context.local_date) >= 0 &&
    daysBetween(context.pet.expected_homecoming_date, context.local_date) < 14
  ) {
    // The first two weeks in the household are a distinct developmental
    // context regardless of chronological age.
    stageKey = "settling_in";
  } else if (age.age_weeks !== null) {
    const numericStages = stages
      .map((stage) => ({ stage, minimum: guidanceMinimumWeeks(stage) }))
      .filter((entry): entry is { stage: DevelopmentStageRow; minimum: number } => entry.minimum !== null)
      .filter((entry) => entry.minimum <= age.age_weeks!)
      .sort((a, b) => b.minimum - a.minimum || b.stage.position - a.stage.position);
    stageKey = numericStages[0]?.stage.stage_key ?? "settling_in";
  }
  const row = stages.find((stage) => stage.stage_key === stageKey);
  return {
    stage_key: row?.stage_key ?? stageKey,
    content_id: row?.content_id ?? null,
    version: row?.version ?? null,
    age_weeks: age.age_weeks === null ? null : Number(age.age_weeks.toFixed(3)),
    age_is_estimated: age.estimated,
    sufficient_profile: stageKey !== null,
  };
}

function stagePosition(stageKey: string | null, stages: DevelopmentStageRow[]): number {
  return stages.find((stage) => stage.stage_key === stageKey)?.position ?? -1;
}

function budget(context: GenerationContext): number {
  switch (context.household.capacity_mode) {
    case "normal":
      return 3;
    case "busy":
      return 1;
    case "essentials_only":
      return 0;
    case "custom":
      return Math.max(0, Math.floor(context.household.custom_recommendation_budget ?? 0));
  }
}

function historyFor(context: GenerationContext, predicate: (entry: HistoryEntry) => boolean): HistoryEntry[] {
  return context.recent_history.filter(predicate).sort((a, b) => compareText(b.local_date, a.local_date));
}

function latestHistoryDate(context: GenerationContext, predicate: (entry: HistoryEntry) => boolean): LocalDate | null {
  return historyFor(context, predicate)[0]?.local_date ?? null;
}

/**
 * How far a rule's cooldown reaches.
 *
 * `rule` (the default, and what every rule but one wants) treats the whole
 * rule as one cadence: `rule.start_next_skill` is "3 days after last start"
 * whichever skill was started, and `rule.handling_cadence` is "2 days" of
 * handling regardless of which body part.
 *
 * `content` narrows the match to the candidate's own content id. It is used
 * where the catalogue gives each selected content item its own cadence (active
 * skill practice), and where a broader selector applies its own scope first.
 * Catalogue §9 specifies `rule.socialization_breadth` as "≥ 2 days PER
 * CATEGORY", and
 * `socializationCandidates` already applies that per-category recency filter
 * before proposing anything. Matching `rule_content_id` as well meant a single
 * shown socialization recommendation put the entire rule on cooldown, so the
 * chosen next category was suppressed as "cooldown" and breadth could never
 * rotate.
 */
type CooldownScope = "rule" | "content";

function onCooldown(
  context: GenerationContext,
  rule: RecommendationRuleRow,
  contentId: string,
  scope: CooldownScope = "rule",
): boolean {
  const latest = latestHistoryDate(
    context,
    (entry) =>
      (entry.content_id === contentId || (scope === "rule" && entry.rule_content_id === rule.content_id)) &&
      entry.outcome !== "expired",
  );
  return latest !== null && daysBetween(latest, context.local_date) < rule.cooldown_days;
}

function wasDismissedInCooldown(context: GenerationContext, rule: RecommendationRuleRow, contentId: string): boolean {
  const latest = latestHistoryDate(
    context,
    (entry) => entry.outcome === "dismissed" && entry.content_id === contentId,
  );
  return latest !== null && daysBetween(latest, context.local_date) <= Math.max(1, rule.cooldown_days);
}

function normalizeTitle(title: string): string {
  return title.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function occurrenceActivityKey(occurrence: TaskOccurrenceInput): string {
  return occurrence.content_id ?? `title:${normalizeTitle(occurrence.title)}`;
}

function emptyScore(priority: PriorityTier, effort: EffortBand, weights: ScoreWeights): ScoreComponents {
  const burdenKey = `burden_${effort}` as const;
  const score: ScoreComponents = {
    base_priority: priority === "P4" ? weights.base_priority_p4 : weights.base_priority_p3,
    stage_relevance: weights.stage_relevance,
    due_frequency: 0,
    user_selected_goal: 0,
    continuity_value: 0,
    preparation_urgency: 0,
    variety_bonus: 0,
    recent_repetition: 0,
    estimated_burden: weights[burdenKey],
    dismissal_penalty: 0,
    conflict_penalty: 0,
    total: 0,
  };
  return withTotal(score);
}

function withTotal(score: ScoreComponents): ScoreComponents {
  return {
    ...score,
    total:
      score.base_priority +
      score.stage_relevance +
      score.due_frequency +
      score.user_selected_goal +
      score.continuity_value +
      score.preparation_urgency +
      score.variety_bonus -
      score.recent_repetition -
      score.estimated_burden -
      score.dismissal_penalty -
      score.conflict_penalty,
  };
}

function scoreCandidate(
  context: GenerationContext,
  rule: RecommendationRuleRow,
  contentId: string,
  effort: EffortBand,
  category: Category,
  weights: ScoreWeights,
  cooldownScope: CooldownScope,
): ScoreComponents {
  const score = emptyScore(rule.default_priority, effort, weights);
  const latest = latestHistoryDate(
    context,
    (entry) =>
      entry.content_id === contentId ||
      (cooldownScope === "rule" && entry.rule_content_id === rule.content_id),
  );
  if (latest) {
    const elapsed = daysBetween(latest, context.local_date);
    score.due_frequency = Math.min(weights.due_frequency_max, Math.max(0, elapsed - rule.cooldown_days + 1));
    if (elapsed <= rule.cooldown_days + 2) score.recent_repetition = weights.recent_repetition;
  } else {
    score.due_frequency = weights.due_frequency_max;
  }
  if (context.active_occurrences.some((item) => item.local_due_date === context.local_date && item.category === category)) {
    score.conflict_penalty = weights.conflict_penalty;
  }
  if (
    historyFor(context, (entry) => entry.outcome === "dismissed" && entry.content_id === contentId).length > 0
  ) {
    score.dismissal_penalty = weights.dismissal_penalty;
  }
  return withTotal(score);
}

function ruleMap(catalogue: CatalogueInput): Map<string, RecommendationRuleRow> {
  return new Map(
    catalogue.recommendation_rules
      .filter((rule) => (SUPPORTED_RULES as readonly string[]).includes(rule.content_id))
      .map((rule) => [rule.content_id, rule]),
  );
}

function addCandidate(
  candidates: Candidate[],
  suppressed: PlanResult["diagnostics"]["suppressed"],
  context: GenerationContext,
  rule: RecommendationRuleRow,
  content: ContentVersionRef,
  title: string,
  category: Category,
  effort: EffortBand,
  values: Record<string, string | number>,
  weights: ScoreWeights,
  scorePatch: Partial<ScoreComponents> = {},
  cooldownScope: CooldownScope = "rule",
  /**
   * Optional scope (e.g. event_id) appended to the candidate and activity keys
   * so the same catalogue content can appear once per underlying entity.
   */
  scopeKey?: string,
): void {
  const candidateKey = scopeKey
    ? `${rule.content_id}:${content.content_id}:${scopeKey}`
    : `${rule.content_id}:${content.content_id}`;
  const activityKey = scopeKey ? `${content.content_id}:${scopeKey}` : content.content_id;
  if (context.household.excluded_content_ids?.includes(content.content_id)) {
    suppressed.push({ candidate_key: candidateKey, reason: "content_excluded" });
    return;
  }
  if (context.household.paused_content_ids?.includes(content.content_id)) {
    suppressed.push({ candidate_key: candidateKey, reason: "content_paused" });
    return;
  }
  if (onCooldown(context, rule, content.content_id, cooldownScope)) {
    suppressed.push({ candidate_key: candidateKey, reason: "cooldown" });
    return;
  }
  if (wasDismissedInCooldown(context, rule, content.content_id)) {
    suppressed.push({ candidate_key: candidateKey, reason: "dismissal_cooldown" });
    return;
  }
  candidates.push({
    candidate_key: candidateKey,
    activity_key: activityKey,
    rule,
    content_ref: content,
    title,
    category,
    effort_band: effort,
    explanation_values: values,
    score: withTotal({
      ...scoreCandidate(context, rule, content.content_id, effort, category, weights, cooldownScope),
      ...scorePatch,
    }),
  });
}

function formatAppointmentWhen(localDate: LocalDate, eventDate: LocalDate): string {
  const days = daysBetween(localDate, eventDate);
  if (days <= 0) return "today";
  if (days === 1) return "tomorrow";
  return `in ${days} days`;
}

/**
 * Catalogue §9 `rule.event_prep_vet`: recommend gathering records/questions when
 * a confirmed vet appointment falls within the eligibility lead window
 * (`within_days`, default 3). Frequency cap is once per event.
 */
function eventPrepVetCandidates(
  context: GenerationContext,
  catalogue: CatalogueInput,
  rule: RecommendationRuleRow,
  candidates: Candidate[],
  suppressed: PlanResult["diagnostics"]["suppressed"],
  weights: ScoreWeights,
): void {
  const eventKind =
    typeof rule.eligibility["event_kind"] === "string" ? rule.eligibility["event_kind"] : "vet_appointment";
  const withinDays =
    typeof rule.eligibility["within_days"] === "number" ? rule.eligibility["within_days"] : 3;
  const content =
    catalogue.task_definitions.find((row) => row.content_id === EVENT_PREP_VET_CONTENT_ID) ?? EVENT_PREP_VET_FALLBACK;

  for (const event of context.events) {
    if (!event.confirmed || event.kind !== eventKind) continue;
    if (event.local_date < context.local_date) continue;
    const days = daysBetween(context.local_date, event.local_date);
    if (days > withinDays) continue;

    const candidateKey = `${rule.content_id}:${content.content_id}:${event.event_id}`;
    // `each_event: once`. History may omit event_id (older generation_context);
    // unscoped rows still count so the prep does not reappear every day.
    const onceDone = context.recent_history.some(
      (entry) =>
        entry.outcome !== "expired" &&
        (entry.content_id === content.content_id || entry.rule_content_id === rule.content_id) &&
        (entry.event_id === undefined || entry.event_id === event.event_id),
    );
    if (onceDone) {
      suppressed.push({ candidate_key: candidateKey, reason: "frequency_cap_once" });
      continue;
    }

    addCandidate(
      candidates,
      suppressed,
      context,
      rule,
      content,
      content.title,
      "preparation",
      content.default_effort,
      {
        Puppy: context.pet.name,
        name: context.pet.name,
        when: formatAppointmentWhen(context.local_date, event.local_date),
      },
      weights,
      { preparation_urgency: Math.max(0, weights.preparation_urgency_max - days) },
      "content",
      event.event_id,
    );
  }
}

function prepCandidates(
  context: GenerationContext,
  catalogue: CatalogueInput,
  stage: StageSnapshot,
  rule: RecommendationRuleRow,
  candidates: Candidate[],
  suppressed: PlanResult["diagnostics"]["suppressed"],
  weights: ScoreWeights,
): void {
  if (stage.stage_key !== "preparing" || !context.pet.expected_homecoming_date) return;
  const days = daysBetween(context.local_date, context.pet.expected_homecoming_date);
  for (const item of catalogue.task_definitions.filter((row) => row.content_id.startsWith("prep."))) {
    const timing = item.metadata["timing_window_days_before_homecoming"];
    const inWindow =
      timing === "any_time" ||
      (Array.isArray(timing) &&
        typeof timing[0] === "number" &&
        typeof timing[1] === "number" &&
        days <= timing[0] &&
        days >= timing[1]);
    if (!inWindow) continue;
    const onceDone = context.recent_history.some(
      (entry) => entry.content_id === item.content_id && (entry.outcome === "completed" || entry.outcome === "shown"),
    );
    if (onceDone) {
      suppressed.push({ candidate_key: `${rule.content_id}:${item.content_id}`, reason: "frequency_cap_once" });
      continue;
    }
    addCandidate(
      candidates,
      suppressed,
      context,
      rule,
      item,
      item.title,
      "preparation",
      item.default_effort,
      { Puppy: context.pet.name, name: context.pet.name, n: days },
      weights,
      { preparation_urgency: Math.max(0, weights.preparation_urgency_max - Math.floor(days / 3)) },
    );
  }
}

function homecomingCandidate(
  context: GenerationContext,
  catalogue: CatalogueInput,
  rule: RecommendationRuleRow,
  candidates: Candidate[],
  suppressed: PlanResult["diagnostics"]["suppressed"],
  weights: ScoreWeights,
): void {
  if (!context.pet.expected_homecoming_date) return;
  const days = daysBetween(context.local_date, context.pet.expected_homecoming_date);
  if (days < 0 || days > 1) return;
  const content = catalogue.task_definitions.find((row) => row.content_id === "prep.routine_agreement");
  if (!content) return;
  if (context.recent_history.some((entry) => entry.content_id === content.content_id && entry.outcome !== "expired")) {
    suppressed.push({ candidate_key: `${rule.content_id}:${content.content_id}`, reason: "frequency_cap_once" });
    return;
  }
  addCandidate(
    candidates,
    suppressed,
    context,
    rule,
    content,
    content.title,
    "routine",
    content.default_effort,
    { Puppy: context.pet.name, name: context.pet.name, n: days },
    weights,
    { preparation_urgency: weights.preparation_urgency_max },
  );
}

function startSkillCandidates(
  context: GenerationContext,
  catalogue: CatalogueInput,
  stage: StageSnapshot,
  rule: RecommendationRuleRow,
  candidates: Candidate[],
  suppressed: PlanResult["diagnostics"]["suppressed"],
  weights: ScoreWeights,
): void {
  if (!stage.sufficient_profile || !stage.stage_key) return;
  const activeCount = context.training_state.filter((state) => state.status === "active").length;
  if (activeCount >= 2) return;
  const lastStartedOn = context.training_state
    .map((state) => state.started_on)
    .filter((value): value is LocalDate => Boolean(value))
    .sort(compareText)
    .pop();
  if (lastStartedOn && daysBetween(lastStartedOn, context.local_date) < rule.cooldown_days) return;
  const stateBySkill = new Map(context.training_state.map((state) => [state.skill_content_id, state]));
  const currentPosition = stagePosition(stage.stage_key, catalogue.development_stages);
  for (const skill of catalogue.training_skills) {
    const state = stateBySkill.get(skill.content_id);
    if (state && state.status !== "not_started") continue;
    if (stagePosition(skill.stage_guidance, catalogue.development_stages) > currentPosition) continue;
    const prereqsMet = skill.prerequisite_skill_refs.every((id) => {
      const prereq = stateBySkill.get(id);
      return prereq && (prereq.status === "active" || prereq.status === "completed");
    });
    if (!prereqsMet) continue;
    addCandidate(
      candidates,
      suppressed,
      context,
      rule,
      skill,
      `Start ${skill.title}`,
      "training",
      skill.effort_band,
      { Puppy: context.pet.name, name: context.pet.name, stage: stage.stage_key, skill: skill.title },
      weights,
      { user_selected_goal: state?.user_selected_goal ? weights.user_selected_goal : 0 },
      "content",
    );
  }
}

function socializationCandidates(
  context: GenerationContext,
  catalogue: CatalogueInput,
  stage: StageSnapshot,
  rule: RecommendationRuleRow,
  candidates: Candidate[],
  suppressed: PlanResult["diagnostics"]["suppressed"],
  weights: ScoreWeights,
): void {
  const allowed = new Set(["settling_in", "foundations", "exploration", "teething", "early_adolescence"]);
  if (!stage.stage_key || !allowed.has(stage.stage_key)) return;
  const excludedCategories = new Set(context.household.excluded_socialization_categories ?? []);
  const categoryRows = new Map<string, SocializationRow[]>();
  for (const row of catalogue.socialization_catalog) {
    if (excludedCategories.has(row.category)) continue;
    const rows = categoryRows.get(row.category) ?? [];
    rows.push(row);
    categoryRows.set(row.category, rows);
  }
  const categories = [...categoryRows.keys()]
    .map((category) => {
      const latest = latestHistoryDate(context, (entry) => entry.socialization_category === category);
      return { category, latest };
    })
    .filter(({ latest }) => latest === null || daysBetween(latest, context.local_date) >= rule.cooldown_days)
    .sort((a, b) => {
      if (a.latest === null && b.latest !== null) return -1;
      if (a.latest !== null && b.latest === null) return 1;
      return compareText(a.latest ?? "", b.latest ?? "") || compareText(a.category, b.category);
    });
  const leastRecentCategory = categories[0]?.category;
  if (!leastRecentCategory) return;
  for (const row of (categoryRows.get(leastRecentCategory) ?? []).sort((a, b) => compareText(a.content_id, b.content_id))) {
    addCandidate(
      candidates,
      suppressed,
      context,
      rule,
      row,
      row.label,
      "socialization",
      rule.effort_band,
      { Puppy: context.pet.name, name: context.pet.name, category: row.category.toLowerCase() },
      weights,
      {},
      // Catalogue §9: the socialization cooldown is per category, and the
      // category filter above has already applied it.
      "content",
    );
  }
}

function handlingCandidate(
  context: GenerationContext,
  catalogue: CatalogueInput,
  stage: StageSnapshot,
  rule: RecommendationRuleRow,
  candidates: Candidate[],
  suppressed: PlanResult["diagnostics"]["suppressed"],
  weights: ScoreWeights,
): void {
  if (!stage.stage_key || stagePosition(stage.stage_key, catalogue.development_stages) < stagePosition("settling_in", catalogue.development_stages)) return;
  const stateBySkill = new Map(context.training_state.map((state) => [state.skill_content_id, state.status]));
  const options = catalogue.training_skills
    .filter((skill) => skill.content_id === "skill.paw_handling" || skill.content_id === "skill.body_handling")
    .filter((skill) => stateBySkill.get(skill.content_id) !== "paused")
    .filter((skill) => stagePosition(skill.stage_guidance, catalogue.development_stages) <= stagePosition(stage.stage_key, catalogue.development_stages))
    .filter((skill) =>
      skill.prerequisite_skill_refs.every((id) => {
        const status = stateBySkill.get(id);
        return status === "active" || status === "completed";
      }),
    )
    .sort((a, b) => {
      const aLatest = latestHistoryDate(context, (entry) => entry.content_id === a.content_id);
      const bLatest = latestHistoryDate(context, (entry) => entry.content_id === b.content_id);
      if (aLatest === null && bLatest !== null) return -1;
      if (aLatest !== null && bLatest === null) return 1;
      return compareText(aLatest ?? "", bLatest ?? "") || compareText(a.content_id, b.content_id);
    });
  const option = options.find((skill) => !onCooldown(context, rule, skill.content_id));
  if (!option) {
    for (const skill of options) {
      suppressed.push({ candidate_key: `${rule.content_id}:${skill.content_id}`, reason: "cooldown" });
    }
    return;
  }
  addCandidate(
    candidates,
    suppressed,
    context,
    rule,
    option,
    `Practice ${option.title.toLowerCase()}`,
    "training",
    option.effort_band,
    { Puppy: context.pet.name, name: context.pet.name, skill: option.title },
    weights,
  );
}

/**
 * Catalogue §9 `rule.alone_time`: "goal active or stage ≤ foundations".
 *
 * The stage branch still honours the engine's hard constraints (§12.3): the
 * catalogue gives `skill.alone_time` a crate-comfort prerequisite, so an
 * unstarted prerequisite makes the activity ineligible. An explicitly started
 * goal is user intent (§4.5) and carries past the stage band.
 */
function aloneTimeCandidate(
  context: GenerationContext,
  catalogue: CatalogueInput,
  stage: StageSnapshot,
  rule: RecommendationRuleRow,
  candidates: Candidate[],
  suppressed: PlanResult["diagnostics"]["suppressed"],
  weights: ScoreWeights,
): void {
  const skill = catalogue.training_skills.find((row) => row.content_id === "skill.alone_time");
  if (!skill) return;
  const state = context.training_state.find((entry) => entry.skill_content_id === skill.content_id);
  if (state?.status === "paused" || state?.status === "completed" || state?.status === "retired") return;
  if (state?.status !== "active") {
    if (!stage.stage_key) return;
    const position = stagePosition(stage.stage_key, catalogue.development_stages);
    if (position < stagePosition(skill.stage_guidance, catalogue.development_stages)) return;
    if (position > stagePosition("foundations", catalogue.development_stages)) return;
    const stateBySkill = new Map(context.training_state.map((entry) => [entry.skill_content_id, entry.status]));
    const prerequisitesMet = skill.prerequisite_skill_refs.every((id) => {
      const status = stateBySkill.get(id);
      return status === "active" || status === "completed";
    });
    if (!prerequisitesMet) return;
  }
  addCandidate(
    candidates,
    suppressed,
    context,
    rule,
    skill,
    `Practice ${skill.title.toLowerCase()}`,
    "training",
    skill.effort_band,
    { Puppy: context.pet.name, name: context.pet.name, skill: skill.title },
    weights,
    { user_selected_goal: state?.user_selected_goal ? weights.user_selected_goal : 0 },
  );
}

function brushingCandidate(
  context: GenerationContext,
  catalogue: CatalogueInput,
  stage: StageSnapshot,
  rule: RecommendationRuleRow,
  candidates: Candidate[],
  suppressed: PlanResult["diagnostics"]["suppressed"],
  weights: ScoreWeights,
): void {
  if (!stage.stage_key || stagePosition(stage.stage_key, catalogue.development_stages) < stagePosition("settling_in", catalogue.development_stages)) return;
  const content = catalogue.task_definitions.find((row) => row.content_id === "care.brushing");
  if (!content) return;
  const adjustedRule =
    context.household.brushing_cooldown_days === undefined
      ? rule
      : { ...rule, cooldown_days: Math.max(0, context.household.brushing_cooldown_days) };
  addCandidate(
    candidates,
    suppressed,
    context,
    adjustedRule,
    content,
    content.title,
    "grooming",
    content.default_effort,
    { Puppy: context.pet.name, name: context.pet.name },
    weights,
  );
}

/**
 * Catalogue §9 `rule.active_skill_practice` cadence: "per skill's freq/wk,
 * min 1 day gap".
 *
 * The seeded frequencies are human phrases ("3-5/week", "daily at first"), so
 * the upper bound is read as the most often the content is willing to be
 * practised and turned into the smallest honest gap between suggestions. A
 * phrase with no readable number falls back to the rule's own cooldown.
 */
function practiceGapDays(recommendedFrequency: string): number {
  const text = recommendedFrequency.toLowerCase();
  if (text.includes("daily")) return 1;
  const perWeek = [...text.matchAll(/\d+/g)]
    .map((match) => Number(match[0]))
    .filter((value) => value > 0);
  if (perWeek.length === 0) return 1;
  return Math.max(1, Math.floor(7 / Math.max(...perWeek)));
}

/**
 * Catalogue §9 `rule.active_skill_practice`: selects a session for an active
 * TrainingGoal. "Active goals are eligible, not forced, into every plan"
 * (engine §26.2), so this competes on score like any other candidate.
 *
 * Hard constraints still apply (§12.3): a skill whose prerequisite is not
 * started is not practisable just because someone selected it, and the
 * catalogue cadence sets a per-skill floor under the rule's own cooldown.
 */
function activeSkillPracticeCandidates(
  context: GenerationContext,
  catalogue: CatalogueInput,
  rule: RecommendationRuleRow,
  candidates: Candidate[],
  suppressed: PlanResult["diagnostics"]["suppressed"],
  weights: ScoreWeights,
): void {
  const skillById = new Map(catalogue.training_skills.map((skill) => [skill.content_id, skill]));
  const statusBySkill = new Map(context.training_state.map((state) => [state.skill_content_id, state.status]));

  const active = context.training_state
    .filter((state) => state.status === "active")
    .sort((a, b) => compareText(a.skill_content_id, b.skill_content_id));

  for (const state of active) {
    const skill = skillById.get(state.skill_content_id);
    // A goal whose skill has been retired from the catalogue keeps its history
    // but has no current guidance to practise from.
    if (!skill) continue;

    const candidateKey = `${rule.content_id}:${skill.content_id}`;
    const prerequisitesMet = skill.prerequisite_skill_refs.every((id) => {
      const status = statusBySkill.get(id);
      return status === "active" || status === "completed";
    });
    if (!prerequisitesMet) {
      suppressed.push({ candidate_key: candidateKey, reason: "prerequisite_unmet" });
      continue;
    }

    const cadenceRule: RecommendationRuleRow = {
      ...rule,
      cooldown_days: Math.max(rule.cooldown_days, practiceGapDays(skill.recommended_frequency)),
    };

    // Sessions logged in the Training tab and completions of a promoted
    // recommendation are both practice; the context supplies the first as
    // `last_practiced_on` and the second through history.
    const latestHistory = latestHistoryDate(
      context,
      (entry) => entry.content_id === skill.content_id && entry.outcome === "completed",
    );
    const lastPractised = [state.last_practiced_on, latestHistory]
      .filter((value): value is LocalDate => Boolean(value))
      .sort(compareText)
      .pop();

    // The seeded template says "last practiced {n} days ago", which presumes a
    // previous practice, and the catalogue cadence is a GAP between practices.
    // A goal with no practice yet has neither, so the count is measured from
    // the day it was started — never-practised understates diligence rather
    // than inventing it — and a goal started today is left alone entirely
    // instead of claiming it was practised "0 days ago".
    const reference = lastPractised ?? state.started_on;
    const elapsed = reference === undefined ? null : daysBetween(reference, context.local_date);
    if (elapsed === null || (lastPractised === undefined && elapsed < 1)) {
      suppressed.push({ candidate_key: candidateKey, reason: "no_practice_interval_yet" });
      continue;
    }

    // `addCandidate` applies the cooldown from plan history alone. A session
    // logged straight into the Training tab never becomes a plan item, so the
    // cadence is enforced against the practice date itself as well — otherwise
    // logging a session would suggest practising the same skill again today.
    if (lastPractised !== undefined && elapsed < cadenceRule.cooldown_days) {
      suppressed.push({ candidate_key: candidateKey, reason: "cooldown" });
      continue;
    }

    addCandidate(
      candidates,
      suppressed,
      context,
      cadenceRule,
      skill,
      `Practice ${skill.title.toLowerCase()}`,
      "training",
      skill.effort_band,
      {
        Puppy: context.pet.name,
        name: context.pet.name,
        Skill: skill.title,
        skill: skill.title,
        n: Math.max(0, elapsed),
      },
      weights,
      {
        // §19.2 "Continue a skill that the owner actively selected" — the only
        // two adaptations the MVP allows for training, and both apply here.
        user_selected_goal: state.user_selected_goal === false ? 0 : weights.user_selected_goal,
        continuity_value: weights.continuity_value,
      },
      "content",
    );
  }
}

function renderTemplate(template: string, values: Record<string, string | number>): string {
  return template.replace(/\{([^}]+)\}/g, (whole, key: string) =>
    Object.prototype.hasOwnProperty.call(values, key) ? String(values[key]) : whole,
  );
}

/** Default window end HH:mm when household has no matching routine_windows row. */
const DEFAULT_WINDOW_ENDS: Record<Exclude<TimeWindow, "anytime">, string> = {
  morning: "11:59",
  midday: "14:59",
  afternoon: "17:59",
  evening: "20:59",
  sleep: "05:59",
};

/** Local wall-clock `HH:mm` for `now_instant` in the household time zone. */
function localClockHHMM(nowInstant: string, timeZone: string): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(new Date(nowInstant));
  const hour = parts.find((part) => part.type === "hour")?.value ?? "00";
  const minute = parts.find((part) => part.type === "minute")?.value ?? "00";
  // en-GB can still emit "24" for midnight in some engines — normalize.
  const normalizedHour = hour === "24" ? "00" : hour.padStart(2, "0");
  return `${normalizedHour}:${minute.padStart(2, "0")}`;
}

function compareHHMM(left: string, right: string): number {
  return compareText(left, right);
}

function windowEndHHMM(
  windowRef: Exclude<TimeWindow, "anytime">,
  routineWindows: GenerationContext["household"]["routine_windows"],
): string {
  const match = routineWindows.find((window) => window.window_ref === windowRef);
  return match?.end_time ?? DEFAULT_WINDOW_ENDS[windowRef];
}

/**
 * Required + pending items become Needs attention after their due window
 * (engine §17.2 / US-035). Prior calendar days always qualify; same-day
 * exact_time / window items qualify once local clock is past due/end.
 * Anytime required items wait until the next local day. Scheduled (non-
 * required) items never enter Needs attention (§6.1 uncommon).
 */
function isRequiredOverdue(
  occurrence: TaskOccurrenceInput,
  context: GenerationContext,
): boolean {
  if (occurrence.obligation_class !== "required" || occurrence.state !== "pending") {
    return false;
  }
  if (occurrence.local_due_date < context.local_date) {
    return true;
  }
  if (occurrence.local_due_date > context.local_date) {
    return false;
  }
  const localNow = localClockHHMM(context.now_instant, context.household.time_zone);
  if (occurrence.time_policy === "exact_time" && occurrence.due_time) {
    return compareHHMM(localNow, occurrence.due_time) > 0;
  }
  if (occurrence.time_policy === "window" && occurrence.window_ref) {
    const end = windowEndHHMM(occurrence.window_ref, context.household.routine_windows);
    // sleep windows can wrap past midnight; treat end before start as next-day
    // boundary already encoded by local_due_date advancement upstream — here
    // we only compare same-day end times.
    return compareHHMM(localNow, end) > 0;
  }
  return false;
}

function obligationItem(occurrence: TaskOccurrenceInput, context: GenerationContext): PlanItem {
  const localDate = context.local_date;
  const completed = occurrence.state === "completed";
  const overdue = isRequiredOverdue(occurrence, context);
  const future = occurrence.local_due_date > localDate;
  const section = completed ? "completed" : overdue ? "needs_attention" : future ? "coming_up" : "today";
  const priority: PriorityTier = overdue ? "P0" : future ? "P5" : occurrence.obligation_class === "required" ? "P1" : "P2";
  const timeWindow: TimeWindow | null =
    occurrence.time_policy === "window"
      ? occurrence.window_ref ?? null
      : occurrence.time_policy === "anytime"
        ? "anytime"
        : null;
  return {
    item_key: `occurrence:${occurrence.occurrence_key}`,
    kind: future ? "upcoming_preview" : "obligation",
    occurrence_id: occurrence.id,
    recommendation_rule_ref: null,
    content_ref:
      occurrence.content_id && occurrence.content_version
        ? { content_id: occurrence.content_id, version: occurrence.content_version }
        : null,
    title: occurrence.title,
    category: occurrence.category,
    obligation_class: occurrence.obligation_class,
    priority_tier: priority,
    section,
    time_window: timeWindow,
    due_time: occurrence.due_time ?? null,
    effort_band: occurrence.effort_band ?? null,
    explanation_text: null,
    score_components: null,
    pinned: false,
    display_state: occurrence.state === "pending" ? "planned" : occurrence.state,
    origin: occurrence.origin,
    completion: occurrence.completion ?? null,
  };
}

function eventItem(context: GenerationContext, event: GenerationContext["events"][number]): PlanItem {
  const today = event.local_date === context.local_date;
  return {
    item_key: `event:${event.event_id}:${event.local_date}`,
    kind: today ? "obligation" : "upcoming_preview",
    occurrence_id: null,
    recommendation_rule_ref: null,
    content_ref: event.content_id ? { content_id: event.content_id, version: 1 } : null,
    title: event.title,
    category: "event",
    obligation_class: today ? "scheduled" : "informational",
    priority_tier: today ? "P2" : "P5",
    section: today ? "today" : "coming_up",
    time_window: event.exact_time ? null : "anytime",
    due_time: event.exact_time ?? null,
    effort_band: null,
    explanation_text: null,
    score_components: null,
    pinned: false,
    display_state: "planned",
    origin: "calendar_event",
    completion: null,
  };
}

function recommendationItem(candidate: Candidate): PlanItem {
  return {
    item_key: `recommendation:${candidate.candidate_key}`,
    kind: "recommendation",
    occurrence_id: null,
    recommendation_rule_ref: { content_id: candidate.rule.content_id, version: candidate.rule.version },
    content_ref: candidate.content_ref,
    title: candidate.title,
    category: candidate.category,
    obligation_class: "recommended",
    priority_tier: candidate.rule.default_priority,
    section: "recommended",
    time_window: candidate.rule.default_time_window ?? "anytime",
    due_time: null,
    effort_band: candidate.effort_band,
    explanation_text: renderTemplate(candidate.rule.explanation_template, candidate.explanation_values),
    score_components: candidate.score,
    pinned: false,
    display_state: "planned",
    origin:
      candidate.category === "socialization"
        ? "socialization_rule"
        : candidate.category === "preparation" || candidate.category === "routine"
          ? "system_preparation_rule"
          : candidate.category === "training"
            ? "training_program"
            : "development_rule",
    completion: null,
  };
}

function comparePlanItems(left: PlanItem, right: PlanItem): number {
  return (
    SECTION_ORDER[left.section] - SECTION_ORDER[right.section] ||
    PRIORITY_ORDER[left.priority_tier] - PRIORITY_ORDER[right.priority_tier] ||
    (left.due_time === null ? 1 : 0) - (right.due_time === null ? 1 : 0) ||
    compareText(left.due_time ?? "", right.due_time ?? "") ||
    WINDOW_ORDER[left.time_window ?? "anytime"] - WINDOW_ORDER[right.time_window ?? "anytime"] ||
    compareText(left.title, right.title) ||
    compareText(left.item_key, right.item_key)
  );
}

function catalogueVersionSet(catalogue: CatalogueInput): ContentVersionRef[] {
  const refs = [
    ...catalogue.development_stages,
    ...catalogue.task_definitions,
    ...catalogue.recommendation_rules,
    ...catalogue.training_skills,
    ...catalogue.socialization_catalog,
  ].map(({ content_id, version }) => ({ content_id, version }));
  const unique = new Map(refs.map((ref) => [`${ref.content_id}@${ref.version}`, ref]));
  return [...unique.values()].sort((a, b) => compareText(a.content_id, b.content_id) || a.version - b.version);
}

/**
 * Pipeline steps 1–9 are expressed as a pure transformation. Step 9 returns
 * persistence-ready rows and snapshots; the server owns the actual write.
 *
 * Final ordering tie-breakers are section, priority tier, exact time,
 * broad time window, title, then stable item_key. Recommendation selection
 * ties are total score, category, title, candidate_key.
 */
export function generatePlan(context: GenerationContext): PlanResult {
  const catalogue = activeCatalogue(context);
  const stage = resolveStage(context, catalogue.development_stages);
  const recommendationBudget = budget(context);
  const weights = context.score_weights ?? DEFAULT_SCORE_WEIGHTS;
  const suppressed: PlanResult["diagnostics"]["suppressed"] = [];

  const eligibleOccurrences = context.active_occurrences.filter(
    (occurrence) =>
      occurrence.state !== "cancelled" &&
      occurrence.state !== "expired" &&
      (occurrence.local_due_date <= context.local_date ||
        daysBetween(context.local_date, occurrence.local_due_date) <= 7),
  );

  // Engine §13.3 and IA §5: Coming up shows at most three future items, nearest
  // first. There is no limit on today's obligations. Without this cap a
  // household with a few daily routines fills the section with a week of
  // repeats — six routines became forty-two previewed items — which is exactly
  // the backlog the plan is meant not to be.
  const upcomingOccurrences = eligibleOccurrences
    .filter((occurrence) => occurrence.local_due_date > context.local_date)
    .sort(
      (left, right) =>
        compareText(left.local_due_date, right.local_due_date) ||
        (left.due_time === undefined ? 1 : 0) - (right.due_time === undefined ? 1 : 0) ||
        compareText(left.due_time ?? "", right.due_time ?? "") ||
        WINDOW_ORDER[left.window_ref ?? "anytime"] - WINDOW_ORDER[right.window_ref ?? "anytime"] ||
        compareText(left.title, right.title) ||
        compareText(left.occurrence_key, right.occurrence_key),
    )
    .slice(0, MAX_UPCOMING_ITEMS);
  const upcomingKeys = new Set(upcomingOccurrences.map((occurrence) => occurrence.occurrence_key));

  const obligations = eligibleOccurrences
    .filter(
      (occurrence) =>
        occurrence.local_due_date <= context.local_date || upcomingKeys.has(occurrence.occurrence_key),
    )
    .map((occurrence) => obligationItem(occurrence, context));

  const representedActivityKeys = new Set(
    context.active_occurrences
      .filter((occurrence) => occurrence.state !== "cancelled" && occurrence.state !== "expired")
      .map(occurrenceActivityKey),
  );
  // Derived from every eligible occurrence rather than the rendered items, so
  // capping Coming up cannot let a recommendation duplicate work that is
  // already scheduled but no longer previewed.
  const representedTitles = new Set(eligibleOccurrences.map((occurrence) => normalizeTitle(occurrence.title)));

  const eventItems = context.events
    .filter(
      (event) =>
        event.confirmed &&
        event.local_date >= context.local_date &&
        daysBetween(context.local_date, event.local_date) <= (stage.stage_key === "preparing" ? 14 : 7) &&
        !obligations.some((item) => item.origin === "calendar_event" && normalizeTitle(item.title) === normalizeTitle(event.title)),
    )
    .map((event) => eventItem(context, event));

  const rules = ruleMap(catalogue);
  const candidates: Candidate[] = [];
  const prepRule = rules.get("rule.prep_window");
  if (prepRule) prepCandidates(context, catalogue, stage, prepRule, candidates, suppressed, weights);
  const homecomingRule = rules.get("rule.homecoming_routine");
  if (homecomingRule) homecomingCandidate(context, catalogue, homecomingRule, candidates, suppressed, weights);
  const eventPrepVetRule = rules.get("rule.event_prep_vet");
  if (eventPrepVetRule) eventPrepVetCandidates(context, catalogue, eventPrepVetRule, candidates, suppressed, weights);
  const startRule = rules.get("rule.start_next_skill");
  if (startRule) startSkillCandidates(context, catalogue, stage, startRule, candidates, suppressed, weights);
  const practiceRule = rules.get("rule.active_skill_practice");
  if (practiceRule) activeSkillPracticeCandidates(context, catalogue, practiceRule, candidates, suppressed, weights);
  const socialRule = rules.get("rule.socialization_breadth");
  if (socialRule) socializationCandidates(context, catalogue, stage, socialRule, candidates, suppressed, weights);
  const handlingRule = rules.get("rule.handling_cadence");
  if (handlingRule) handlingCandidate(context, catalogue, stage, handlingRule, candidates, suppressed, weights);
  const aloneTimeRule = rules.get("rule.alone_time");
  if (aloneTimeRule) aloneTimeCandidate(context, catalogue, stage, aloneTimeRule, candidates, suppressed, weights);
  const brushingRule = rules.get("rule.brushing");
  if (brushingRule) brushingCandidate(context, catalogue, stage, brushingRule, candidates, suppressed, weights);

  const deduplicated: Candidate[] = [];
  const candidateActivities = new Set<string>();
  for (const candidate of candidates.sort((a, b) => compareText(a.candidate_key, b.candidate_key))) {
    if (
      representedActivityKeys.has(candidate.activity_key) ||
      representedTitles.has(normalizeTitle(candidate.title)) ||
      candidateActivities.has(candidate.activity_key)
    ) {
      suppressed.push({ candidate_key: candidate.candidate_key, reason: "equivalent_obligation_or_candidate" });
      continue;
    }
    candidateActivities.add(candidate.activity_key);
    deduplicated.push(candidate);
  }

  const selected: Candidate[] = [];
  const usedCategories = new Set(
    obligations.filter((item) => item.section === "today").map((item) => item.category),
  );
  const pool = [...deduplicated];
  while (selected.length < recommendationBudget && pool.length > 0) {
    const ranked = pool
      .map((candidate) => {
        const variety = usedCategories.has(candidate.category) ? 0 : weights.variety_bonus;
        return { candidate, score: withTotal({ ...candidate.score, variety_bonus: variety }) };
      })
      .sort(
        (a, b) =>
          b.score.total - a.score.total ||
          compareText(a.candidate.category, b.candidate.category) ||
          compareText(a.candidate.title, b.candidate.title) ||
          compareText(a.candidate.candidate_key, b.candidate.candidate_key),
      );
    const winner = ranked[0];
    if (!winner) break;
    winner.candidate.score = winner.score;
    selected.push(winner.candidate);
    usedCategories.add(winner.candidate.category);
    pool.splice(pool.indexOf(winner.candidate), 1);
  }

  for (const unselected of pool) {
    suppressed.push({ candidate_key: unselected.candidate_key, reason: "capacity_or_rank" });
  }

  const items = [...obligations, ...eventItems, ...selected.map(recommendationItem)].sort(comparePlanItems);
  const versions = catalogueVersionSet(catalogue);
  suppressed.sort((a, b) => compareText(a.candidate_key, b.candidate_key) || compareText(a.reason, b.reason));

  return {
    plan: {
      plan_key: `${context.pet.pet_id}:${context.local_date}`,
      household_id: context.pet.household_id,
      pet_id: context.pet.pet_id,
      local_date: context.local_date,
      time_zone_snapshot: context.household.time_zone,
      stage_snapshot: stage,
      capacity_mode_applied: context.household.capacity_mode,
      recommendation_budget: recommendationBudget,
      plan_version: context.plan_version,
      catalogue_version_set: versions,
      // Runtime timestamps and the proposed next persistence version are
      // output metadata, not generation inputs. Excluding them makes the
      // digest useful for detecting a genuinely unchanged same-day plan.
      input_digest: digest((({ now_instant: _now, plan_version: _version, ...inputs }) => inputs)(context)),
      status: "open",
      generated_at: context.now_instant,
    },
    items,
    diagnostics: {
      eligible_recommendation_count: deduplicated.length,
      selected_recommendation_count: selected.length,
      suppressed,
    },
  };
}
