# Implementation Plan — Slice A

**Status:** Draft  
**Version:** 0.1  
**Last updated:** 2026-07-26  
**Related documents:** [Core Features §20](03-core-features.md),
[Technical Architecture](06-technical-architecture.md),
[Data Model](10-data-model.md), [Daily Plan Engine](12-daily-plan-engine.md),
[Wireframes — Onboarding and Home](14-wireframes-onboarding-home.md),
[Content Catalogue](15-content-catalogue.md)

## 1. Purpose

The implementation plan for Release Slice A, written as the handoff package
for the implementing coding agent (Codex). It sequences the work, fixes the
definition of done, and points to the specifications that own each behavior.
This document adds **no new product behavior**; where it and a specification
disagree, the specification wins and the discrepancy must be raised, not
resolved silently.

## 2. Slice A scope

From [Core Features §20](03-core-features.md) (as amended by the pre-arrival
decision):

> **Proof:** One person can create a puppy — before or after homecoming — and
> complete a useful plan.

In scope: F01 basic account, F02 household creation (no invitations yet),
F03 minimal pet profile incl. future homecoming date, F04 saved Daily Plan
incl. pre-arrival variant and homecoming transition, F05 one-time tasks +
completion/undo/history, F14 baseline diagnostics.

**Not in Slice A** (do not build early): invitations and second-caregiver
sync (Slice B — but idempotency, attribution, and the operation queue ARE
Slice A, because retrofitting them is the expensive path), recommendations
beyond the seed rules needed for a useful plan, recurring schedules UI
(model supports them; UI ships Slice D), notifications (in-app states only),
Training/Care/Life tab content beyond stubs, media upload.

## 3. Reading order for the implementing agent

1. [Technical Architecture](06-technical-architecture.md) — stack, write
   path, engine placement (all Accepted).
2. [Data Model](10-data-model.md) — §4 conventions, §5 tenancy, §8 time and
   recurrence, §9 task layer, §10 plan layer, §18 invariants.
3. [Daily Plan Engine](12-daily-plan-engine.md) — §6 structure, §10–§13
   generation, §26 example plans, §30 acceptance, §31 fixtures.
4. [Wireframes doc 14](14-wireframes-onboarding-home.md) +
   [UI Design System](09-ui-design-system.md) — screens and tokens.
5. [User Stories](04-user-stories.md) — acceptance criteria for US-001,
   US-010, US-020–US-023, US-030–US-036, US-040, US-041, US-050, US-100,
   US-106–US-108.
6. [Content Catalogue](15-content-catalogue.md) — seed data to load.

## 4. Work packages

Ordered; each ends green (tests + running app). WP-1→WP-4 form the **walking
skeleton** and are the first demo milestone.

### WP-0 — Repository and environments

*(Revised 2026-07-26 for the native-iOS platform decision.)*
Repository root `/…/PetCompanion` containing: `docs/`, `PetCompanion/` (the
owner-created Xcode project — SwiftUI, iOS 27, file-system-synchronized
groups), `supabase/` (migrations, edge functions, seeds), and
`packages/engine` (pure TypeScript engine + fixtures). Local Supabase +
simulator running; CI: Swift build/tests, TypeScript typecheck + engine
fixtures, RLS tests. `prod` Supabase project provisioned but deployed only
from tagged builds.

### WP-1 — Schema, RLS, write path core

- Migrations for the Slice A entity subset: user profile, household,
  membership, pet, preferences, task definition/schedule/occurrence,
  disposition, plan, plan item, content tables, audit event,
  analytics event. Include Slice B+ columns already specified in the Data
  Model (status enums, invitation table) — schema is cheap now, migration
  churn later is not; **build no behavior for them**.
- Every expressible DM §18 invariant as a constraint; RLS policies per
  TA §7; client write access denied on invariant-bearing tables.
- Write-path edge function skeleton: command envelope
  (`client_idempotency_key`, `recorded_at`, `effective_at`), idempotent
  replay, audit-event hook, per-command authorization.
- **Exit tests:** RLS isolation (non-member reads/writes fail on every
  table); idempotent command replay; invariant violations rejected.

### WP-2 — Auth and onboarding flow

- Supabase Auth via the Supabase Swift SDK: email+password with
  verification; Sign in with Apple enabled (natural on iOS-only).
- SwiftUI screens ON-01, ON-02, ON-03, ON-06, ON-07, ON-08 per doc 14
  (ON-04/05/09 are later slices), with the design-system tokens/components
  from doc 09 implemented as a `DesignSystem` module.
- Commands: `create_household` (idempotent, US-010), `create_pet`
  (exact/estimated birth structure, homecoming date, validations per DM
  §7.5), `set_routine_preferences`.
- **Exit tests:** US-001/US-010/US-020/US-021 acceptance criteria; retry of
  household creation produces no duplicate membership.

### WP-3 — Engine package with fixtures

- `packages/engine`: pure `generatePlan(context) → PlanResult` implementing
  pipeline steps 1–9 (engine §11) for Slice A inputs: obligations from
  one-time tasks, routine-template scheduled items, preparation items, and
  seed recommendation rules (`rule.prep_window`, `rule.homecoming_routine`,
  `rule.start_next_skill`, `rule.socialization_breadth`,
  `rule.handling_cadence`, `rule.brushing` — enough for useful pre- and
  post-arrival days); capacity budgets; dedup; explanation rendering from
  templates; deterministic ordering.
- Fixture harness reading YAML scenarios (engine §31). Seed fixtures: the
  four §26 example plans, empty day, insufficient-profile day, capacity
  variants, duplicate-generation replay.
- **Exit tests:** all fixtures green; same context twice → identical plan
  (determinism); no database imports anywhere in the package.

### WP-4 — Generation, materialization, and day lifecycle

- Load the content catalogue seed (doc 15 §4–§9) into content tables with
  version metadata.
- Occurrence materialization per DM §8.6 (calendar types + `once`;
  `interval_after_completion` deferred to Slice D with medication UI).
- Generation triggers: on first open of local day + on meaningful change
  (task created/edited, capacity change, profile change); advisory lock per
  (pet, local_date); plan persisted with snapshots per DM §10.1.
- Day-close job: close plans, expire recommendations, needs-attention
  derivation. Homecoming transition: `preparing` → post-arrival on the
  homecoming local date.
- **Exit tests:** regeneration idempotence (US-041); US-023 recalculation
  (birth-date edit changes future, not history); homecoming flip fixture;
  DST + time-zone-change cases from engine §27 relevant to Slice A.

**⛳ Walking-skeleton demo:** sign in → create household + pet (pre-arrival
and post-arrival variants) → server-generated plan renders from a device.

### WP-5 — Home experience

- HM-01 with all Slice A variants (normal, pre-arrival, empty,
  insufficient-profile, offline/stale), HM-02 detail, HM-04 capacity sheet,
  HM-05 history, GL-01 quick add → one-time task creation (PL-02 minimal
  form), GL-03 no-access.
- Local SwiftData/SQLite cache + operation queue per TA §6; optimistic
  complete/undo/skip; dispositions through the write path; realtime
  subscription updating the cache (single-user for now, but the pipe is the
  Slice B foundation).
- Completion, undo, skip flows per US-030–US-036; plan-freezing behavior
  per DM §10.1.
- **Exit tests:** US-032 (complete twice → one completion), US-033 (undo),
  US-034 (skip expires, no carryover), US-036 (capacity), US-106/107/108
  states exercised in component tests; offline queue replay test.

### WP-6 — Diagnostics baseline and acceptance pass

- Analytics allowlist events (plan_generated/viewed, item dispositions,
  onboarding steps) with schema validation (TA §12); Sentry wired;
  guardrail queries (duplicate plan items, generation failures).
- Full Slice A acceptance sweep: §5 checklist below on the household's two
  iPhones, pre-arrival household and post-arrival household.

## 5. Definition of done (Slice A)

1. The Slice A proof demonstrated end to end on device, both pre- and
   post-arrival, by a non-developer (Sarah test).
2. Engine acceptance criteria 1–7, 10, 11, 14, 16, 17 (engine §30) pass;
   the remainder (multi-caregiver, notifications) are explicitly Slice B/D.
3. Story acceptance criteria pass for the §3.5 story list.
4. RLS isolation suite green; no client write path to invariant tables.
5. All engine fixtures green in CI; determinism test green.
6. No raw hex values / one-off styles (design-system validation §12.5).
7. Accessibility smoke pass on ON + HM screens: screen-reader labels, focus
   order, dynamic type XL, reduced motion.
8. Decision log updated with any implementation-forced deviations.

## 6. Risks and watch items

| Risk | Mitigation |
| --- | --- |
| Engine scope creep (building all rules now) | Only the six seed rules listed in WP-3; the catalogue loader is generic, the rule set is not |
| Local-day bugs (TZ/DST) | Fixtures first (WP-3) before any UI; use a fixed fake clock in all tests |
| Operation queue over-engineering | Slice A needs: FIFO, idempotency key, retry, auth-recheck. Nothing else |
| Optimistic UI divergence | Cache is only ever written from server echoes + queued-op overlay; never a third path |
| SDK version drift (supabase-swift, supabase CLI) | Pin versions in WP-0; upgrade as an explicit task |

## 6a. Known follow-ups from walking-skeleton verification (2026-07-26)

1. **Recommendation churn across regenerations.** Every app open regenerates
   the day's plan, and the selected recommendation set can change between
   regenerations (observed: three catalogue items on one generation, three
   different ones after later regenerations). Item keys stay stable and no
   duplicates are created, but this contradicts engine §4.3 ("stable unless
   something meaningful changes"). Plan freezing (§10.3) only engages after the
   first meaningful interaction, so this is legal but undesirable. Fix in WP-5:
   persist the selected recommendation set and reuse it for the local day
   unless inputs materially change or the user explicitly refreshes.
2. **Recommendation acceptance is not exposed.** Recommendations arrive with
   no occurrence, and no command promotes them (Data Model §10.3). The client
   surfaces a typed not-yet-actionable error. Needs a `accept_recommendation`
   write-path command before Home's complete action is meaningful for
   recommendations.
3. **Day-close scheduling.** `close_plans_for_date` exists but nothing invokes
   it automatically; pg_cron wiring is deferred.

## 7. Open questions

1. ~~Confirm caregiver device platforms.~~ **Resolved 2026-07-26:** iOS
   only (Decision Log).
2. Sarah-test scheduling — WP-6 wants a real non-developer run before Slice
   A is called done.
3. Whether HM-05 history ships in Slice A or first Slice C (it is listed in
   Slice A here because US-040's read-only view is cheap once plans persist;
   cut it first if WP-5 runs long).

## 8. Validation criteria

This plan is validated when the implementing agent can execute WP-0 through
WP-6 without asking a product-behavior question that the referenced
documents do not answer — any such question is a specification bug to file
against the owning document.
