import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { SEED_CATALOGUE } from "../fixtures/seed-catalogue.ts";
import { generatePlan } from "../src/index.ts";
import type {
  CapacityMode,
  Category,
  GenerationContext,
  HistoryEntry,
  ObligationClass,
  Origin,
  PlanResult,
  TaskOccurrenceInput,
  TimePolicy,
  TrainingStateInput,
} from "../src/index.ts";

interface FixtureObligation {
  key: string;
  title: string;
  content_id?: string;
  category: Category;
  obligation_class: Exclude<ObligationClass, "recommended" | "informational">;
  origin?: Origin;
  due_date?: string;
  time_policy?: TimePolicy;
  due_time?: string;
  window_ref?: "morning" | "midday" | "afternoon" | "evening" | "sleep";
  state?: TaskOccurrenceInput["state"];
  completed_by?: string;
}

interface Fixture {
  scenario: string;
  local_date: string;
  now_instant?: string;
  capacity: CapacityMode;
  custom_recommendation_budget?: number;
  pet?: {
    name?: string;
    birth_info?: GenerationContext["pet"]["birth_info"];
    stage_override?: string;
    expected_homecoming_date?: string;
  };
  household?: Partial<GenerationContext["household"]>;
  obligations?: FixtureObligation[];
  events?: GenerationContext["events"];
  training_state?: TrainingStateInput[];
  recent_history?: HistoryEntry[];
  expect: {
    recommendation_budget?: number;
    recommended_count?: number;
    recommended_count_max?: number;
    required_titles?: string[];
    recommended_content_ids?: string[];
    absent_content_ids?: string[];
    sections?: Partial<Record<PlanResult["items"][number]["section"], string[]>>;
    no_duplicates?: boolean;
    explanations?: boolean;
    sufficient_profile?: boolean;
    catalogue_refs?: string[];
    suppressed?: Array<{ candidate_key: string; reason: string }>;
    obligations_before_recommendations?: boolean;
    empty?: boolean;
    deterministic_replay?: boolean;
  };
}

const fixtureDirectory = fileURLToPath(new URL("../fixtures/scenarios", import.meta.url));

function occurrence(localDate: string, input: FixtureObligation): TaskOccurrenceInput {
  const state = input.state ?? "pending";
  return {
    id: `occ-${input.key}`,
    occurrence_key: `schedule-${input.key}:${input.due_date ?? localDate}`,
    schedule_id: `schedule-${input.key}`,
    title: input.title,
    ...(input.content_id ? { content_id: input.content_id, content_version: 1 } : {}),
    category: input.category,
    obligation_class: input.obligation_class,
    origin: input.origin ?? "user_created",
    local_due_date: input.due_date ?? localDate,
    original_local_due_date: input.due_date ?? localDate,
    time_policy: input.time_policy ?? (input.due_time ? "exact_time" : input.window_ref ? "window" : "anytime"),
    ...(input.due_time ? { due_time: input.due_time } : {}),
    ...(input.window_ref ? { window_ref: input.window_ref } : {}),
    effort_band: "short",
    state,
    ...(state === "completed"
      ? {
          completion: {
            completed_at: `${localDate}T11:42:00Z`,
            completed_by_user_id: `user-${input.completed_by ?? "caregiver"}`,
            completed_by_name: input.completed_by ?? "Caregiver",
          },
        }
      : {}),
  };
}

function contextFromFixture(fixture: Fixture): GenerationContext {
  return {
    local_date: fixture.local_date,
    now_instant: fixture.now_instant ?? `${fixture.local_date}T12:00:00Z`,
    plan_version: 1,
    pet: {
      pet_id: "pet-maple",
      household_id: "household-1",
      name: fixture.pet?.name ?? "Maple",
      species: "dog",
      birth_info:
        fixture.pet?.birth_info ??
        ({ kind: "estimated", estimated_age_weeks: 10, estimated_as_of_date: fixture.local_date } as const),
      ...(fixture.pet?.stage_override ? { stage_override: fixture.pet.stage_override } : {}),
      ...(fixture.pet?.expected_homecoming_date
        ? { expected_homecoming_date: fixture.pet.expected_homecoming_date }
        : {}),
    },
    household: {
      time_zone: "America/Toronto",
      capacity_mode: fixture.capacity,
      routine_windows: [
        { window_ref: "morning", start_time: "07:00", end_time: "10:00" },
        { window_ref: "evening", start_time: "17:00", end_time: "21:00" },
      ],
      ...(fixture.custom_recommendation_budget === undefined
        ? {}
        : { custom_recommendation_budget: fixture.custom_recommendation_budget }),
      ...fixture.household,
    },
    active_occurrences: (fixture.obligations ?? []).map((item) => occurrence(fixture.local_date, item)),
    events: fixture.events ?? [],
    catalogue: SEED_CATALOGUE,
    training_state: fixture.training_state ?? [],
    recent_history: fixture.recent_history ?? [],
  };
}

function assertFixture(fixture: Fixture, result: PlanResult): void {
  const recommendations = result.items.filter((item) => item.section === "recommended");
  const expectation = fixture.expect;
  if (expectation.recommendation_budget !== undefined) {
    assert.equal(result.plan.recommendation_budget, expectation.recommendation_budget);
  }
  if (expectation.recommended_count !== undefined) {
    assert.equal(recommendations.length, expectation.recommended_count);
  }
  if (expectation.recommended_count_max !== undefined) {
    assert.ok(recommendations.length <= expectation.recommended_count_max);
  }
  for (const title of expectation.required_titles ?? []) {
    assert.ok(
      result.items.some(
        (item) =>
          item.title === title &&
          (item.obligation_class === "required" || item.obligation_class === "scheduled"),
      ),
      `missing required/scheduled title "${title}"`,
    );
  }
  for (const contentId of expectation.recommended_content_ids ?? []) {
    assert.ok(
      recommendations.some((item) => item.content_ref?.content_id === contentId),
      `missing recommendation content "${contentId}"`,
    );
  }
  for (const contentId of expectation.absent_content_ids ?? []) {
    assert.ok(
      !result.items.some((item) => item.content_ref?.content_id === contentId),
      `unexpected content "${contentId}"`,
    );
  }
  for (const [section, titles] of Object.entries(expectation.sections ?? {})) {
    for (const title of titles ?? []) {
      assert.ok(
        result.items.some((item) => item.section === section && item.title === title),
        `missing "${title}" in ${section}`,
      );
    }
  }
  if (expectation.no_duplicates) {
    assert.equal(new Set(result.items.map((item) => item.item_key)).size, result.items.length);
    const logical = result.items.map((item) => item.content_ref?.content_id ?? item.title.toLowerCase());
    assert.equal(new Set(logical).size, logical.length);
  }
  if (expectation.explanations) {
    assert.ok(recommendations.every((item) => item.explanation_text && !item.explanation_text.includes("{")));
  }
  if (expectation.sufficient_profile !== undefined) {
    assert.equal(result.plan.stage_snapshot.sufficient_profile, expectation.sufficient_profile);
  }
  for (const ref of expectation.catalogue_refs ?? []) {
    assert.ok(
      result.plan.catalogue_version_set.some(({ content_id, version }) => `${content_id}@${version}` === ref),
      `missing catalogue version ref "${ref}"`,
    );
  }
  for (const suppression of expectation.suppressed ?? []) {
    assert.ok(
      result.diagnostics.suppressed.some(
        (entry) =>
          entry.candidate_key === suppression.candidate_key && entry.reason === suppression.reason,
      ),
      `missing suppression ${suppression.candidate_key}: ${suppression.reason}`,
    );
  }
  if (expectation.obligations_before_recommendations) {
    const firstRecommendation = result.items.findIndex((item) => item.kind === "recommendation");
    const lastCurrentObligation = result.items.reduce(
      (last, item, index) =>
        item.kind === "obligation" && item.section !== "completed" ? Math.max(last, index) : last,
      -1,
    );
    assert.ok(firstRecommendation === -1 || lastCurrentObligation < firstRecommendation);
  }
  if (expectation.empty) assert.deepEqual(result.items, []);
}

for (const filename of readdirSync(fixtureDirectory).filter((name) => name.endsWith(".yaml")).sort()) {
  const fixture = JSON.parse(readFileSync(join(fixtureDirectory, filename), "utf8")) as Fixture;
  test(`${filename}: ${fixture.scenario}`, () => {
    const context = contextFromFixture(fixture);
    const result = generatePlan(context);
    assertFixture(fixture, result);
    if (fixture.expect.deterministic_replay) {
      assert.deepEqual(generatePlan(context), result);
      assert.equal(JSON.stringify(generatePlan(context)), JSON.stringify(result));
    }
  });
}

test("homecoming keeps a puppy in settling-in for the first fourteen local days", () => {
  const context = contextFromFixture({
    scenario: "homecoming transition",
    local_date: "2026-08-10",
    capacity: "normal",
    pet: {
      birth_info: { kind: "exact", birth_date: "2026-05-01" },
      expected_homecoming_date: "2026-08-01",
    },
    expect: {},
  });

  assert.equal(generatePlan(context).plan.stage_snapshot.stage_key, "settling_in");
});

test("input digest ignores generation timestamp and proposed persistence version", () => {
  const fixture: Fixture = {
    scenario: "meaningful digest",
    local_date: "2026-08-10",
    capacity: "normal",
    expect: {},
  };
  const first = contextFromFixture(fixture);
  const second = {
    ...first,
    now_instant: "2026-08-10T18:30:00Z",
    plan_version: 42,
  };

  assert.equal(generatePlan(first).plan.input_digest, generatePlan(second).plan.input_digest);
});

test("coming up previews at most three future items, nearest first", () => {
  // Mirrors a real household: onboarding creates six daily routine schedules,
  // each materialized across the next fortnight. Every future occurrence used
  // to be previewed, which produced forty-two Coming up rows.
  const context = contextFromFixture({
    scenario: "recurring routines fill the preview window",
    local_date: "2026-08-10",
    capacity: "normal",
    expect: {},
  });
  const routines: Array<{ key: string; title: string; window: "morning" | "evening" }> = [
    { key: "breakfast", title: "Breakfast", window: "morning" },
    { key: "potty-am", title: "Morning potty routine", window: "morning" },
    { key: "dinner", title: "Evening meal", window: "evening" },
    { key: "potty-pm", title: "Evening potty routine", window: "evening" },
    { key: "wind-down", title: "Wind-down routine", window: "evening" },
    { key: "midday-potty", title: "Midday potty routine", window: "morning" },
  ];
  context.active_occurrences = Array.from({ length: 7 }, (_, dayOffset) =>
    routines.map((routine) => {
      const dueDate = `2026-08-${String(10 + dayOffset).padStart(2, "0")}`;
      return {
        ...occurrence(dueDate, {
          key: routine.key,
          title: routine.title,
          category: "routine",
          obligation_class: "scheduled",
          window_ref: routine.window,
          due_date: dueDate,
        }),
        id: `occ-${routine.key}-${dueDate}`,
        occurrence_key: `schedule-${routine.key}:${dueDate}`,
      };
    }),
  ).flat();

  const result = generatePlan(context);
  const comingUp = result.items.filter((item) => item.section === "coming_up");

  assert.equal(comingUp.length, 3, "Coming up must show at most three future items");
  // Today's six obligations are not capped — only the preview is.
  assert.equal(result.items.filter((item) => item.section === "today").length, routines.length);
  // Nearest first: all three previews come from the earliest future day.
  for (const item of comingUp) {
    assert.ok(
      item.item_key.endsWith(":2026-08-11"),
      `expected the nearest future day, got ${item.item_key}`,
    );
    assert.equal(item.kind, "upcoming_preview");
  }
  assert.equal(new Set(result.items.map((item) => item.item_key)).size, result.items.length);
});

test("an occurrence-only reschedule preserves plan identity while moving placement", () => {
  const context = contextFromFixture({
    scenario: "rescheduled occurrence identity",
    local_date: "2026-11-01",
    capacity: "essentials_only",
    expect: {},
  });
  context.active_occurrences = [
    {
      ...occurrence("2026-11-01", {
        key: "walk",
        title: "Evening walk",
        category: "routine",
        obligation_class: "scheduled",
      }),
      occurrence_key: "schedule-walk:2026-11-01",
      local_due_date: "2026-11-03",
      original_local_due_date: "2026-11-01",
    },
  ];

  const moved = generatePlan(context).items.find((item) => item.occurrence_id === "occ-walk");
  assert.ok(moved);
  assert.equal(moved.item_key, "occurrence:schedule-walk:2026-11-01");
  assert.equal(moved.section, "coming_up");
  assert.equal(moved.kind, "upcoming_preview");
});
