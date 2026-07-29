# Decision Log

**Status:** Active  
**Last updated:** 2026-07-29

Use this log for decisions that materially affect product scope, experience,
architecture, data, privacy, or delivery.

## Decision template

### YYYY-MM-DD — Decision title

- **Status:** Proposed, accepted, superseded, or reversed
- **Context:** What prompted the decision?
- **Decision:** What was chosen?
- **Rationale:** Why was it chosen?
- **Consequences:** What becomes easier, harder, or constrained?
- **Revisit when:** What evidence or event should reopen the decision?

## Accepted decisions

### 2026-07-26 — Use individual accounts within shared households

- **Status:** Accepted
- **Context:** Multiple caregivers need synchronized access without sharing
  credentials.
- **Decision:** Model people as individual users who belong to a shared
  household containing one or more pets.
- **Rationale:** This supports clear ownership, notifications, preferences,
  attribution, permissions, and future caregiver roles.
- **Consequences:** Authentication and authorization must account for household
  membership from the beginning.
- **Revisit when:** Product research reveals a materially simpler model that
  preserves security, attribution, and future flexibility.

### 2026-07-26 — Focus Version 1 on puppies while supporting the full life cycle

- **Status:** Accepted
- **Context:** The immediate use case is raising a new puppy, but the intended
  product relationship can last for the pet's lifetime.
- **Decision:** Keep the initial experience dog- and puppy-focused while avoiding
  puppy-only assumptions in foundational data and architecture.
- **Rationale:** This keeps the MVP coherent without forcing an expensive
  redesign for adolescent, adult, and senior stages.
- **Consequences:** Generalized concepts must not add visible complexity to the
  puppy experience.
- **Revisit when:** Broader species support or conflicting domain requirements
  become a committed roadmap item.

### 2026-07-26 — Use a deterministic Daily Plan Engine for the MVP

- **Status:** Accepted (owner review, 2026-07-26)
- **Context:** The Daily Plan must be trustworthy, testable, and explainable
  before AI-assisted planning is considered.
- **Decision:** Generate the MVP plan from versioned rules, explicit schedules,
  pet context, household preferences, and recent history.
- **Rationale:** A deterministic engine can be scenario-tested, reproduced, and
  reviewed for safety while still providing meaningful personalization.
- **Consequences:** The product needs a governed rule catalogue and clear
  separation between content, eligibility, scheduling, and presentation.
- **Revisit when:** The deterministic MVP has reliable baseline behavior and a
  clearly defined problem that a probabilistic model can improve safely.

### 2026-07-26 — Limit the primary recommendation set

- **Status:** Accepted (owner review, 2026-07-26)
- **Context:** A comprehensive list would undermine the product's promise to
  reduce cognitive load.
- **Decision:** Show up to three primary recommendations on a normal day, one on
  a Busy day, and none in Essentials-only mode. Genuine required and
  household-scheduled items are not subject to this limit.
- **Rationale:** The plan should communicate priorities instead of presenting a
  backlog.
- **Consequences:** The engine needs capacity, variety, and replacement rules,
  and the interface may offer additional ideas outside the primary plan.
- **Revisit when:** Prototype testing shows that a different limit produces
  better comprehension and follow-through.

### 2026-07-26 — Deliver the MVP through end-to-end release slices

- **Status:** Accepted (owner review, 2026-07-26); amended by the pre-arrival
  decision below
- **Context:** Building features as isolated screens would delay validation of
  the shared Daily Plan experience and create integration risk.
- **Decision:** Start with a single-caregiver daily-plan loop, add shared
  household coordination, and then layer in guided content, care schedules, and
  memories as complete vertical slices.
- **Rationale:** Each slice produces a usable outcome and validates the
  relationships between identity, data, rules, interface, and synchronization.
- **Consequences:** Some features will begin with deliberately narrow behavior
  and expand only after the core loop works end to end.
- **Revisit when:** Technical constraints make the proposed slice boundaries
  impractical or product testing changes the core loop.

### 2026-07-26 — Adopt five-destination navigation with contextual Profile access

- **Status:** Accepted (owner review, 2026-07-26)
- **Context:** The candidate model (Home, Pets, Training, Planner, Life,
  Profile) had six destinations, gave low-frequency surfaces (Pets, Profile)
  permanent slots, and left weekly health-and-care recording without a direct
  route.
- **Decision:** Use five tabs — Home, Planner, Training, Care, Life. Care is
  the pet hub (profile, health, medications, weight, grooming, providers).
  Profile and settings open from a persistent avatar entry in the Home header.
  See [Information Architecture](05-information-architecture.md) §5.
- **Rationale:** Matches the five-slot platform convention, gives every tab a
  weekly-or-better usage frequency, and gives health records the direct route
  the PRD questioned, without demoting the Daily Plan.
- **Consequences:** Pet profile and settings are one tap deeper; the Insights
  pillar has no navigation surface in the MVP; adding any top-level
  destination later is a material decision.
- **Revisit when:** Wireframe or prototype testing shows users failing to find
  profile/settings or Care, or a multi-pet Home overview changes Home's role.

### 2026-07-26 — Model tasks as layered definitions, schedules, occurrences, plan items, and dispositions

- **Status:** Accepted (owner review, 2026-07-26)
- **Context:** The PRD and engine require separating reusable content,
  household intent, dated instances, plan presentation, and recorded outcomes,
  with idempotent generation and trustworthy shared completion state.
- **Decision:** Adopt the layered model in [Data Model](10-data-model.md) §9:
  TaskDefinition → TaskSchedule → TaskOccurrence → PlanItem / Disposition.
  Occurrence identity is a deterministic key — (schedule, original local due
  date) for calendar-based rules, (schedule, ordinal) for
  interval-after-completion — making materialization idempotent and reschedule
  identity-preserving. An occurrence has at most one effective completion;
  concurrent completions converge on the earliest valid effective time with
  duplicates retained for audit. Accepted or pinned recommendations are
  promoted to real occurrences via a `once` schedule so all completions share
  one history model.
- **Rationale:** Deterministic identity eliminates duplicate-generation bugs
  by construction; a single disposition history gives uniform attribution,
  undo, idempotency, and audit across obligations and recommendations.
- **Consequences:** Series edits split schedules rather than mutating them;
  every one-off flows through a schedule; the write path must enforce the
  Data Model §18 invariants.
- **Revisit when:** Implementation shows the promotion-to-occurrence step or
  schedule-splitting creates unacceptable complexity for the MVP.

### 2026-07-26 — Treat the household as the single tenancy and authorization boundary

- **Status:** Accepted (owner review, 2026-07-26)
- **Context:** Follows from the accepted individual-accounts decision; the
  data model needed an explicit enforcement boundary and a home for global
  content.
- **Decision:** Every user-generated record belongs to exactly one household
  and is authorized against active membership at the data layer. Governed
  content (skills, rules, stages, socialization catalogue) is global,
  versioned, and read-only to users. See [Data Model](10-data-model.md) §5.
- **Rationale:** One boundary makes authorization auditable and testable,
  prevents cross-household leakage by construction, and keeps content
  governance separate from user data.
- **Consequences:** Cross-household features (breeder transfer, professional
  access) will need explicit sharing constructs later rather than falling out
  of the model accidentally.
- **Revisit when:** Pet transfer between households or professional roles
  become committed roadmap items.

### 2026-07-26 — Store birth information as exact-or-estimated with a reference date

- **Status:** Accepted (owner review, 2026-07-26)
- **Context:** Owners often know only an approximate age (US-021); a bare
  birth-date field would force false precision that development guidance and
  copy must not imply.
- **Decision:** Pet birth information is a tagged structure: an exact birth
  date, or an estimated age in weeks as of a reference date, so estimates age
  correctly over time. Plans snapshot the derived stage and definition version
  at generation. See [Data Model](10-data-model.md) §8.2.
- **Rationale:** Preserves honest uncertainty end to end — storage, engine
  eligibility, and display language stay consistent, and replacing an
  estimate with an exact date is a controlled, audited recalculation.
- **Consequences:** All age-derived logic consumes one derivation function;
  UI copy must branch on the estimate flag.
- **Revisit when:** Real usage shows estimated ages are rare enough that the
  structure is not worth its complexity, or additional approximate dates need
  the same pattern.

### 2026-07-26 — Promote pre-arrival mode into Release Slice A

- **Status:** Accepted (owner decision, 2026-07-26); amends the release-slice
  decision above
- **Context:** The founding household is in the pre-arrival period today, but
  pre-arrival preparation mode was prioritized P2, meaning the first real
  users would have had no useful product until homecoming.
- **Decision:** The pre-arrival plan variant — future homecoming date on the
  pet profile, preparation obligations and recommendations, countdown framing,
  suppression of post-arrival routines, and the automatic homecoming
  transition (US-022, engine §26.1, IA §14) — is part of Slice A. The P2
  remainder (richer preparation content breadth) stays P2.
- **Rationale:** Slice A's proof is "one person can create a puppy and
  complete a useful plan"; for the actual first household, a useful plan is a
  preparation plan. The data model already carries the homecoming date, so the
  cost is engine gating plus one Home variant, not new modeling.
- **Consequences:** Slice A needs seeded preparation content and the
  homecoming transition tested; the first-plan experience must be validated in
  both pre- and post-arrival forms.
- **Revisit when:** Slice A delivery shows the preparation catalogue or
  transition meaningfully delays the core loop.

### 2026-07-26 — Adopt the MVP implementation stack

- **Status:** Accepted (owner approval, 2026-07-26)
- **Context:** Wireframing and implementation planning need a platform and
  backend; the data model's deferred implementation decisions
  ([Data Model §19](10-data-model.md)) needed resolution.
- **Decision:** React Native + Expo with TypeScript for a single iOS + Android
  client; Supabase (managed Postgres with row-level security, Auth, Storage,
  Realtime, Edge Functions) as the backend; the Daily Plan Engine as a pure
  TypeScript package run server-side in the MVP; all writes through a single
  invariant-enforcing write path; Expo Push for notifications; first-party
  analytics table. Full detail in
  [Technical Architecture](06-technical-architecture.md).
- **Rationale:** One language and toolchain end to end; Postgres RLS maps
  directly onto the accepted household-tenancy boundary; a pure engine package
  keeps generation scenario-testable and portable; managed services minimize
  undifferentiated work for a two-person private MVP while remaining plain
  Postgres underneath if migration is ever needed.
- **Consequences:** Client-side polish ceilings of React Native are accepted
  for the MVP; the backend is coupled to Supabase conventions (mitigated by
  standard Postgres + SQL migrations); server-side generation means no fresh
  plan generation while fully offline (last saved plan remains available, per
  engine §25.3).
- **Revisit when:** The founding household's devices, the wireframe polish
  bar, or Slice A implementation experience contradict the platform choice —
  or before any public-release scaling work.

### 2026-07-26 — Seed content catalogue governance

- **Status:** Accepted (owner approval, 2026-07-26)
- **Context:** The Daily Plan is only as valuable as its rule and content
  catalogue; the engine requires versioned, reviewed content with provenance
  (engine §9, §22.1).
- **Decision:** Maintain the initial governed catalogue in
  [Content Catalogue](15-content-catalogue.md): development stages,
  preparation checklist, routine templates, training skills, socialization
  experiences, and recommendation rules, each carrying content-version
  metadata and a review status. All seed content ships as
  `pending_professional_review` and is used only for the founding household's
  private MVP; health-adjacent domains (vaccination guidance, medication
  content) ship **empty** — those records are always user- or
  professional-entered.
- **Rationale:** Makes the safety boundary structural: the product schedules
  reviewed general-care content but never generates health schedules; private
  use can begin without blocking on external review, while the review gate to
  any external audience is explicit.
- **Consequences:** Before beta or public release, named review of training,
  socialization, and development-stage content is a release gate (PRD §20);
  the catalogue format must round-trip into the ContentVersion model.
- **Revisit when:** A professional reviewer engages, or private use shows the
  seed catalogue is too thin to sustain daily value.

### 2026-07-26 — Revise the client platform to native iOS (SwiftUI)

- **Status:** Accepted (owner decision, 2026-07-26); amends the client portion
  of the implementation-stack decision above
- **Context:** The stack decision chose React Native for mixed-device
  households. The owner has since confirmed the household is iOS-only for the
  foreseeable future and created a native Xcode project — exactly the
  revisit trigger named in that decision.
- **Decision:** The client is a native SwiftUI iOS app (the owner-created
  Xcode project, deployment target iOS 27), with a local SQLite/SwiftData
  cache and operation queue, using the Supabase Swift SDK. Everything
  server-side is unchanged: Supabase backend, Postgres RLS, single write
  path, and the Daily Plan Engine as a pure TypeScript package running in
  edge functions (client language is irrelevant to server-side generation).
- **Rationale:** Native SwiftUI gives the best fit for the premium, calm,
  accessibility-heavy design direction on the only platform in use; dropping
  the cross-platform constraint removes React Native's polish ceiling.
- **Consequences:** No Android client until this is revisited (an Android
  caregiver would need one built); design tokens map to native
  SwiftUI/dynamic-type primitives; distribution is TestFlight only; client
  work in the Slice A plan is re-expressed in Swift terms.
- **Revisit when:** A non-iOS caregiver joins the household, or public
  release planning begins.

### 2026-07-28 — Limit an account to one active household

- **Status:** Accepted (owner decision, 2026-07-28)
- **Context:** Household invitations made it possible for the first time for one
  account to hold active memberships in two households. The data model permits
  that ([Data Model](10-data-model.md) §5.1), but every client surface in this
  release — household resolution, plan generation, and notification routing —
  assumes a single active household and silently takes the oldest membership.
  Accepting a second invitation would therefore render untruthfully rather than
  fail honestly.
- **Decision:** An account may hold at most one active membership across all
  active households. `write_path_accept_invitation` rejects a second with a
  distinct error code so the interface can explain the specific limitation
  instead of showing a generic failure.
- **Rationale:** Truthfulness over capability. A product whose central promise
  is unambiguous shared care must not present a household view that quietly
  omits the caregiver's other household. Enforcing the limit at the write path
  keeps it a product rule rather than a schema constraint, so lifting it later
  needs no destructive migration.
- **Consequences:** A caregiver who genuinely belongs to two households — a
  sitter, or someone in a separated family — cannot be served until a household
  switcher exists. The limit lives in one RPC and one error code, so removing it
  is a small change rather than a redesign.
- **Revisit when:** A household switcher is planned, or a real caregiver needs
  membership in a second household — whichever comes first. Professional and
  sitter roles ([Data Model](10-data-model.md) §5.2 reserved roles) would each
  force this open.

### 2026-07-29 — Medication-occurrence safety model

- **Status:** Accepted — orchestrator decision on owner request, 2026-07-29
- **Context:** Care (Release Slice D) is gated on a medication-occurrence safety
  model ([Handoff](22-handoff.md) §5). Specs already require dose text stored
  exactly as entered, mandatory field-level change history, no missed-dose
  advice, and confirmation behavior proportionate to duplicate-dose risk
  ([Daily Plan Engine](12-daily-plan-engine.md) §22.3; [Core Features F10](03-core-features.md);
  [Data Model](10-data-model.md) §11.2; US-071–US-073). The owner's Care mock
  shows "Flea & Tick Prevention · Due in 5 days" — the same occurrence surface.
  Medication scheduling UI remains deferred until after Care Weight/Providers
  land; this decision unlocks a later Care slice, not immediate implementation.
- **Decision:** Adopt the following safety contract for medication and
  owner-entered preventive schedules before any Care medication scheduling UI,
  migrations, or engine medication obligation rules ship.

  **Dose & history (what records store)**

  - A **MedicationSchedule** (authoritative; [Data Model](10-data-model.md)
    §11.2) holds: `medication_name` and optional `dose_text` / instructions
    **exactly as entered** by the owner or professional — never computed,
    converted, or normalized into a “canonical” dose; optional
    `instructions_text`; `provenance`
    (`owner_entered | professional_instruction`) and optional `provider_id`;
    a supported `recurrence` shape and `times`; `status`
    (`active | archived | superseded`).
  - **Mandatory field-level change history** for material schedule/dose edits
    (AuditEvent with before/after values on every such edit).
  - Each schedule owns exactly one required TaskSchedule; occurrences are
    materialized from it with deterministic `occurrence_key` identity.
  - **Last completion + caregiver** come from disposition/history only:
    effective completion time and completing caregiver — never inferred from
    schedule math alone.
  - **Preventive products** (e.g. flea/tick, worming) use the same
    MedicationSchedule path when the owner creates an explicit schedule or
    next-due date; a preventive-care HealthRecord may reference or coexist but
    does not substitute for the schedule when dated reminders are wanted.

  **Occurrence generation — may**

  - Generate dated occurrences **only** from an explicit owner- or
    professional-entered schedule using supported recurrence types
    ([Engine](12-daily-plan-engine.md) §17.1; [Data Model](10-data-model.md)
    §8.6): `once`, `daily`, `weekdays`, `every_n_days`, `weekly`,
    `monthly_safe`, `interval_after_completion`, and bounded finite series.
  - Use **idempotent occurrence identity** (deterministic `occurrence_key`),
    reschedule-without-duplicate identity, and bounded forward materialization
    per the accepted layered task model.
  - Surface **Today / Coming up / Needs attention** with the **original due
    time** and clear pet + medication context (medication name as entered,
    dose text when provided, last completion, source line such as
    "Scheduled from Maple's medication record"); after the due window passes
    without completion, promote to Needs attention with original due time and
    source-appropriate neutral copy (engine §17.2, §26.5).
  - For `interval_after_completion`, maintain exactly one open occurrence;
    materialize the next only after an effective completion.

  **Occurrence generation — must not**

  - Compute, convert, normalize, or suggest a dose — ever.
  - Invent schedules or approximate unsupported clinical recurrence; reject
    with a manual-entry or simpler explicit-schedule fallback (US-071).
  - Auto-complete, auto-skip, or back-fill synthetic missed occurrences.
  - Emit missed-dose advice: no doubling, skipping, changing, discontinuing,
    or "what to do now" clinical guidance (US-073; engine §17.2).
  - Alter professionally sourced content; edits are owner-initiated and
    audited.
  - Expose numeric priority scores or caregiver comparison on medication
    surfaces.

  **Preventive products (flea/tick, worming, etc.)**

  - **Allowed** on the same MedicationSchedule path when the owner creates an
    explicit schedule or next-due date. Neutral copy that restates owner
    configuration — e.g. "Due in 5 days" / "Next due Sat" — is allowed; it is
    record-keeping, not clinical advice.
  - **Forbidden:** inferring due dates from packaging, breed, weight, age, or
    catalogue content; urgency language that implies medical risk; implying
    veterinary endorsement.

  **Confirmation UX**

  - Completing a medication occurrence **always** shows: pet (photo/name),
    medication name, due time, dose text as entered, and latest completion +
    caregiver when available (US-072; IA §17.4).
  - If another caregiver completed recently: show a **prominent
    recent-completion notice** and require an **extra explicit confirm** to
    reduce duplicate-dose risk; completion is not blocked (engine §18.3,
    §22.3).
  - Never suggest doubling, skipping, or changing a dose.
  - Simultaneous completions converge on the earliest valid effective time;
    duplicates remain in audit; no error shown when final state is correct
    (engine §18.3).
  - Lock-screen and banner notification copy stays discreet unless the user
    opts into detail (engine §22.4).
  - The confirmation interaction requires **dedicated usability validation**
    before public release (US-072; engine §32 open question on exact
    interaction pattern).

  **Explicit bans**

  - Diagnosis, prescription, treatment recommendation, or clinical assessment
    language on medication or preventive surfaces ([Engine](12-daily-plan-engine.md)
    §22.2; [PRODUCT.md](../PRODUCT.md) veterinary boundary).
  - Dose calculation, unit conversion, or dose suggestion.
  - Missed-dose clinical advice (double, skip, delay, change, discontinue).
  - Guilt mechanics, streaks, unexplained scores, or caregiver competition on
    medication completion.
  - Health details in analytics or cross-household leakage.

- **Rationale:** Care's highest-risk surface is shared household medication
  memory. Storing instructions verbatim, generating only from explicit
  owner-entered rules, and refusing missed-dose advice keeps PetCompanion on
  the record-keeping side of the veterinary boundary while still delivering
  the dated-reminder value shown in product mocks. Field-level audit and
  duplicate-aware confirmation address the failure modes that matter most in
  multi-caregiver use.
- **Consequences:** Medication scheduling UI, Slice D medication migrations, and
  engine medication obligation rules may be built only in a later Care slice
  after Weight/Providers land, and must honor this contract. Unsupported
  recurrence patterns require a manual path, not approximation. Preventive
  "due in N days" surfaces share MedicationSchedule invariants. The exact
  confirmation interaction remains a design/usability deliverable, bounded by
  the non-negotiable bans above. Travel-time-zone behavior for medications
  stays deferred ([Engine](12-daily-plan-engine.md) §15.2 note).
- **Revisit when:** Usability testing of the confirm flow; sitter/travel roles
  (or other professional/cross-time-zone requirements that change attribution
  or due-window rules); regulatory/App Store health guidance changes; or
  evidence that preventive-due copy is misread as clinical advice.

### 2026-07-29 — Training progress bars use owner-reported state, not computed %

- **Status:** Accepted
- **Context:** A design mock showed “Module Completion 60%” on Training.
  `PRODUCT.md` bans unexplained scores; F08 specifies seven owner-reported
  labels (six continuum states + Paused as lifecycle); the socialization
  passport (F09) deliberately has no ratio. Docs/22 §5 item 2 left an honest
  middle path open: a bar of the owner's own reported state rather than a
  percentage.
- **Decision:** Training goal surfaces (TR-01 active cards, TR-03 lesson,
  TR-05 progress history) show a segmented state bar driven only by
  `TrainingProgressState`. Labels always name the state; caption marks it
  owner-reported. Reject computed completion percentages and session-count
  ratios presented as scores. Paused remains `TrainingGoal.status` and
  prefixes the label without moving the continuum step (US-064).
- **Rationale:** Caregivers get a calm sense of “where we said we are” without
  inventing mastery from logging frequency. Matches F08 and PRODUCT.md.
- **Consequences:** Catalogue chips name the reported state (not “Active
  goal”). Socialization stays bar-free. No engine or write-path change.
- **Revisit when:** Professional content review changes progress vocabulary,
  or usability evidence that discrete steps are still misread as a score.

### 2026-07-29 — Vaccinations are history only (no computed schedule)

- **Status:** Accepted — Care vaccinations slice
- **Context:** US-070 and DM §11.1 require vaccination records with optional
  `next_due_date` only when explicitly known. Product and content docs ban
  vaccination scheduling guidance in catalogue content.
- **Decision:** Ship vaccinations as owner/vet-entered history: vaccine name,
  date given, optional next-due as an entered fact for display, provenance,
  optional provider, notes. Soft duplicate review prompt only — never
  auto-merge. No engine-generated due dates, no dose advice, no occurrence
  engine. Client uses a dedicated `VaccinationService` (parallel to
  socialization) rather than extending `CareService`, to keep medications WIP
  isolated.
- **Rationale:** Keeps Care on the record-keeping side of the veterinary
  boundary while making CA-01 Vaccinations navigable.
- **Consequences:** `vaccination_records` table + `record_vaccination` /
  `edit_vaccination` / `remove_vaccination` write-path commands. Hosted
  `db push` + write-path deploy required for real backends.
- **Revisit when:** Attachments / media refs for clinic cards; shared
  HealthRecord polymorphic table if grooming/notes need the same envelope.

### 2026-07-29 — Care notes are text-first (documents deferred)

- **Status:** Superseded 2026-07-29 — document kind + Storage attach shipped
  (`*_care_note_media.sql`); PDF allowed for Care only
  (`*_care_note_media_pdf.sql`). Life milestones remain image-only.
- **Context:** F10 / DM §11.1 `general_note` needs household-private
  observations with provenance. Storage is not set up; Life milestones already
  treat `media_refs` as reserved. Sibling Vaccinations/Grooming agents own
  Care/** in parallel.
- **Decision:** Ship `care_notes` as general_note CRUD only via dedicated
  `CareNoteService` (separate files/migration from vaccinations/grooming).
  Reject `kind = document` and non-empty `media_refs` in write-path until
  Storage RLS lands. UI uses honest “later” copy — never a fake upload control.
- **Rationale:** Prefer solid text notes over half-wired document Storage.
- **Consequences:** Migration `*_care_notes.sql`, write-path
  `create/edit/remove_care_note`, Care hub Notes destination. Hosted needs
  `db push` + write-path deploy.
- **Revisit when:** Household-private Storage bucket + media metadata for
  clinic PDFs / photos.

### 2026-07-29 — Care document attachments allow PDF (Life image-only)

- **Status:** Accepted — Care note PDF attach (US-077)
- **Context:** Care note media landed image-only on shared `household-media`.
  Owners need clinic paperwork PDFs on document notes without opening Life
  milestones to non-image MIME.
- **Decision:** Expand shared `media.mime_type` + bucket allow-list with
  `application/pdf`. Care `prepare_care_note_media` accepts images + PDF
  (10 MB). Life `prepare_milestone_media` stays image-only. iOS document notes
  get PhotosPicker + PDF file importer with honest size copy and Quick Look.
- **Rationale:** Paperwork is Care’s job; Life photos stay a narrow image path.
- **Consequences:** Migration `*_care_note_media_pdf.sql`, write-path validator
  update, SQL + unit tests. Hosted `db push` + `write-path` redeploy.
- **Revisit when:** Larger PDF limits, multi-attachment UX, or OCR import.

### 2026-07-29 — Events foundation (appointments before Planner event rows)

- **Status:** Accepted — Events foundation slice
- **Context:** F11 / DM §11.5 / US-081 need Event rows so plans can surface
  upcoming appointments. Planner agenda (PL-01) was in flight without Event
  CRUD; Care hub was owned by Medications/Vaccinations agents.
- **Decision:** Ship Event table + write-path create/edit/cancel/archive with
  SELECT-only RLS. Surface Care → “Appointments & events” (plus a Settings
  household link) without rewriting Planner agenda. Extend
  `write_path_generation_context` in a dedicated migration that preserves
  training_state and socialization fields and only replaces the hard-coded
  `events: []` with confirmed upcoming rows (engine `EventInput` shape).
  Notification candidate cancel/recreate on reschedule remains a follow-up.
- **Rationale:** Unblocks calendar_event plan items and `event_prep_vet`
  eligibility data without fighting parallel Planner agenda UI work.
- **Consequences:** Hosted `db push` + write-path deploy required. Planner can
  later consume the same `events` table for agenda dots/rows.
- **Revisit when:** PL-04 detail with linked prep tasks; provider picker on
  vet kind; notification candidate lifecycle (US-086).

### 2026-07-29 — Enable `rule.event_prep_vet` in the daily plan engine

- **Status:** Accepted — engine + catalogue content
- **Context:** Events foundation already feeds confirmed upcoming events into
  `write_path_generation_context` as `EventInput`. `rule.event_prep_vet` was
  seeded but omitted from `SUPPORTED_RULES`, so prep never competed.
- **Decision:** Implement `eventPrepVetCandidates` (confirmed `vet_appointment`
  within `within_days`, default 3; once per `event_id`; origin
  `system_preparation_rule`). Add `prep.gather_records_questions` to seed +
  engine catalogue (engine keeps a fallback row). Optional
  `HistoryEntry.event_id` scopes the frequency cap; unscoped history still
  blocks daily re-show. Bundle via `npm run bundle:edge`. No Care/Planner UI
  changes. No generation_context rewrite (event fields already match).
- **Rationale:** Unblocks catalogue §9 prep once Events exist, without
  touching agenda UI.
- **Consequences:** Hosted needs content migration
  `20260729184527_event_prep_vet_content` + `generate-plan` redeploy for the
  bundled engine (`write-path` does not embed it); not a generation_context
  hotfix. Applied surgically 2026-07-29.
- **Revisit when:** Emit `event_id` from plan item keys into
  `recent_history` for perfect multi-event once-caps; class/grooming prep
  rules if catalogue adds them.

### 2026-07-29 — Event notification candidates refresh on reschedule (US-086)

- **Status:** Accepted — candidate lifecycle slice
- **Context:** Events foundation shipped create/edit/cancel/archive without
  touching `notification_candidates`. Occurrence refresh already cancelled
  and recreated `task_due` / `task_snooze` rows; Events needed the same for
  obsolete appointment reminders (US-086).
- **Decision:** Extend `notification_candidates` with nullable `event_id`
  (XOR with `occurrence_id`), add class `event_reminder`, and
  `refresh_event_notification_candidates`. Call it from write-path
  create/edit/cancel/archive. Reschedule cancels scheduled rows and inserts
  for the new start + `reminder_config.lead_minutes`; cancel/archive leave
  zero scheduled. Update verify/claim to validate event-linked rows. Do not
  invent local APNs sends or on-device Event reminder scheduling.
- **Rationale:** Server-authoritative hygiene mirrors occurrence patterns and
  keeps Care/Planner UI unchanged.
- **Consequences:** Hosted needs `20260729184100_event_notification_candidates_us086`
  + `write-path` redeploy. Prep-task retention on reschedule (Scenario G) is
  still a separate follow-up when prep schedules exist.
- **Revisit when:** Linked preparation tasks under events; APNs HTTP/2 sender
  delivering `event_reminder`.

### 2026-07-29 — On-device Event local notifications (US-086 parity)

- **Status:** Accepted — local delivery parity slice
- **Context:** Server `event_reminder` candidates refresh on create/edit/
  cancel/archive, but APNs send remains stubbed. Planner tasks already had
  on-device local reminders; Events did not, so caregivers never saw
  appointment banners on the live path.
- **Decision:** Extend `LocalNotifications` with
  `EventLocalNotificationCandidateBuilder` and a separate
  `pc.event.{accountId}.` namespace. Schedule confirmed events with
  `reminder_config.lead_minutes`, apply the same quiet-hour / 7-day fire
  horizon patterns as plan items, and use discreet copy
  (“An appointment is coming up.”). Reconcile from `EventStore` loads and
  foreground Event re-fetch. Do not invent APNs HTTP/2 sends.
- **Rationale:** Keeps server candidate hygiene authoritative for remote
  push later while making Events useful on today’s local path without
  breaking planner reminder namespaces.
- **Consequences:** Deep-link destination `event` resolves against a fresh
  Events list and opens Planner when still confirmed. Preference toggles
  re-reconcile both plan and event caches.
- **Revisit when:** APNs sender delivering `event_reminder`; PL-04 event
  detail deep-link; lock-screen detailed preference (US-109).

### 2026-07-29 — Planner agenda shows Event rows (US-080)

- **Status:** Accepted — agenda attachment slice
- **Context:** Events foundation shipped Care CRUD + generation-context feed;
  PL-01 forward agenda already scrolled task occurrences. Caregivers still
  lacked one mixed calendar of tasks and appointments (US-080).
- **Decision:** Keep Event CRUD in Care. Have `PlannerStore` load the visible
  window’s tasks as before, then attach confirmed Events from `EventService`
  through pure `PlannerAgendaGrouping` helpers. Render event rows with a kind
  glyph and open affordance (no fake complete checkbox). Read-only detail
  sheet in Planner; edit/cancel stay on Care → Appointments.
- **Rationale:** Satisfies US-080 distinguishability without rewriting the
  Care editor or coupling `RealPlannerService` to the events table.
- **Consequences:** Pull-to-refresh / plan reconciliation epoch also reattach
  events. Full PL-04 (prep tasks, reschedule) remains a follow-up.
- **Revisit when:** Linked preparation tasks under events; deep-link from
  agenda into the Care editor.

### 2026-07-29 — Planner month-jump grid dots

- **Status:** Accepted — PL-01 jump affordance follow-up
- **Context:** Week-rail dots already reflected tasks/events in the loaded
  window; the month jump sheet was still a plain graphical `DatePicker`
  with no activity markers (docs/16 open question).
- **Decision:** Replace the jump sheet picker with a custom month grid.
  Mark days that have tasks and/or confirmed events using a filled dot plus
  VoiceOver value (“Has tasks or events”). Seed markers from the loaded
  agenda window and best-effort fetch the visible month via existing
  `PlannerService.agenda` + `EventService.loadEvents` without changing the
  agenda architecture or Care Events CRUD.
- **Rationale:** Matches the week-rail affordance for longer-range jumps
  while keeping PL-01 agenda-first and avoiding a Care/Planner rewrite.
- **Consequences:** Pure helpers live on `PlannerAgendaGrouping`
  (`datesWithContent`, `eventContentDates`, `monthGridDays`). Full PL-04
  remains separate.
- **Revisit when:** Distinct task vs event markers; multi-month prefetch.

### 2026-07-29 — Remote APNs foundation without committing Auth Keys

- **Status:** Accepted — remote push foundation slice
- **Context:** Engine-produced `notification_candidates` accumulated with no
  consumer. Slice B deliberately deferred APNs; local reminders already cover
  on-device delivery. Docs/06 names APNs as the push path for Slice D.
- **Decision:** Ship device-token registration (`device_push_tokens`, owner
  SELECT RLS, write-path register/unregister), candidate verify/claim RPCs,
  a `process-notification-candidates` Edge stub that skips send when APNs
  secrets are absent, and iOS token capture additive to
  `LocalNotificationService`. Keep Auth Key `.p8` material out of git; document
  hosted secret names in `docs/11` / `docs/21` §4.1. Do not implement HTTP/2
  APNs delivery in this slice.
- **Rationale:** Makes candidate hygiene and token storage real without
  requiring Apple keys in the repo or blocking Care/Planner/Life parallel
  work. Local reminders remain the visible path until secrets + sender land.
- **Consequences:** Hosted needs the device-token migration, `write-path`
  redeploy, and `process-notification-candidates` deploy. Full remote push
  still needs Apple Auth Key secrets and a sender implementation.
- **Revisit when:** Enabling TestFlight remote delivery; wiring HTTP/2 APNs
  send + `notification_delivery` outcomes; multi-device token lifecycle UX.

### 2026-07-29 — Multi-device plan reconciliation is refresh, not merge

- **Status:** Accepted
- **Context:** Two caregivers on different devices must converge on the same
  Daily Plan after completes/skips/regenerates without inventing conflict
  resolution in the client. Planner agenda structure must stay intact.
- **Decision:** Publish `dispositions` / `task_occurrences` / `plans` to
  `supabase_realtime` with `REPLICA IDENTITY FULL`. iOS
  `PlanRealtimeReconciler` debounces household-scoped postgres_changes into a
  truthful `PlanService` re-fetch published on `SharedPlanState`. Cache-served
  answers never overwrite a live snapshot (epoch still bumps so Planner can
  re-read). Mock installs a no-op bridge. Subscribe when `phase == .main` with
  a household; tear down on sign-out / auth rollback / recovery dismiss.
  Foreground `scenePhase.active` requests a safety refresh. Home/Planner only
  observe `reconciliationEpoch` — no agenda rewrite.
- **Rationale:** Server state is the authority; client merge logic would drift
  from write-path invariants. Debounce absorbs bursty disposition writes.
- **Consequences:** Linked hosted already has the publication migration
  (`20260729180800`). Missed events while suspended rely on foreground refresh
  + Realtime reconnect. Does not cover Care/Life/Training realtime yet.
- **Revisit when:** Adding Care/Life multi-device surfaces; measuring missed
  Realtime payloads in production; considering presence/typing indicators.

### 2026-07-29 — `rule.growth_photo` stays out of MVP

- **Status:** Accepted — defer with P2 journal
- **Context:** Catalogue §9 seeds `rule.growth_photo` (opt-in, P2, P4, 7-day
  cooldown). US-095 is Priority P2. Open question in catalogue §11.4 asked
  whether to enable in MVP Daily Plan or wait for journal work. Engine
  enablement requires a real opt-in gate; `pet_preferences` /
  `household_preferences` have no growth-photo flag, and generation context
  cannot honestly gate eligibility.
- **Decision:** Keep `rule.growth_photo` **out of** `SUPPORTED_RULES`, engine
  fixtures, and hosted `engine.mjs` for MVP. Ship later with P2 Life journal
  / US-095 once an explicit opt-in preference exists. Leave the seeded
  catalogue row for forward compatibility.
- **Rationale:** Enabling without opt-in would violate catalogue eligibility
  and US-095 (“optional and configurable”). Pairing with journal avoids a
  Daily Plan prompt with no Life surface to complete it.
- **Consequences:** No generate-plan / fixture / deploy work for this rule in
  the current batch. Documented in `docs/22` §7 and catalogue §11.4 resolved.
- **Revisit when:** Adding growth-photo opt-in on pet/household preferences,
  US-095 UI, and journal capture path.

## Proposed decisions

_None at this time._
