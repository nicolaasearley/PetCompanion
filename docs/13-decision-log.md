# Decision Log

**Status:** Active  
**Last updated:** 2026-07-26

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

## Proposed decisions

*(none currently open)*
