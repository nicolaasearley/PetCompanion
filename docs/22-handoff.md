# Handoff

**Status:** Active
**Last updated:** 2026-07-29

For anyone — human or AI — picking this project up. It assumes you have read
`README.md` and `docs/README.md`. The specifications in `docs/` are the source
of truth: where this document and a specification disagree, the specification
wins and the discrepancy should be raised rather than silently resolved.

The most valuable part of this file is §6, the traps. Every one of them cost
real time to find, and several were silent — the code looked correct, the tests
passed, and the behaviour was wrong.

## 1. What this is

A native SwiftUI iOS app for new puppy owners in a shared household, backed by
Supabase. The **user-facing product name is Settle** (home screen
`CFBundleDisplayName`, in-app copy, welcome brand mark). The repository,
Xcode target/scheme/module, bundle id (`com.nic.petcompanion`), deep-link
scheme (`petcompanion://`), and many internal identifiers remain
**PetCompanion** deliberately — do not rename those without an explicit
migration plan (password-recovery allow-list and App Store identity).

The centrepiece is a **Daily Plan**: one deterministic, server-generated plan
per pet per household-local day.

The product's character is restraint. Maximum three recommendations a day, no
streaks, no guilt mechanics, no unexplained scores, and a hard veterinary
boundary — it records and reminds, never diagnoses or doses. Health-adjacent
content ships deliberately **empty**; those records are always owner- or
vet-entered. Read `PRODUCT.md` before making product judgements; its
anti-references are load-bearing, not decoration.

**Multi-pet:** households may contain one or more pets in the data model from
Slice A (decision log / IA / PRD). MVP UI is single-active-pet first with
per-pet Daily Plans; a combined multi-pet Home is **out of MVP**. GL-02 pet
switcher chrome when `pets.count > 1` is specified but not fully shipped —
Planner may show pet badges; `AppModel.activePet` is still one selection.

## 2. Where things stand

Working end to end against hosted Supabase: account and onboarding (including
ON-04 password recovery), the Daily Plan, the Planner with full recurrence and
occurrence actions plus the PL-01 forward-scrolling agenda (event rows and
month-grid dots), household invitations with a second caregiver, training goals
and sessions, the socialization passport, Care records, Life milestones, and
Events. A durable offline mutation queue, local reminders (plan + confirmed
events), and an append-only attributed history underpin all of it.

`docs/19-current-build-status.md` is superseded by this section for current
product status; keep `docs/19` only for the local-run checklist if useful.

**Git:** the 2026-07-29 Care/Life/Events/engine/CI landing is on `origin/main`
(11 commits ending `cbf672d`). Settle branding + new app icon may still be
local uncommitted work — check `git status` before assuming they are on
remote.

**Owner testing (2026-07-29) → next revision in flight / landed in working
tree:** Home undo + offline queue honesty, same-day Needs Attention, Home
Upcoming care strip, Home density (collapsed Recommended/Coming up, category
icons), Planner week-nav without scroll thrash + Schedule/Routines filter,
Life blurb + retained First-year ideas, stronger Socialization passport hero.
See §2 “Owner-testing revision” below.

**App Store Connect:** Account Holder contracts were blocking iOS app-record
creation (`STATE_ERROR.APP_CREATE.PLATFORM_NOT_ALLOWED_DUE_TO_CONTRACT_STATE`);
that contract state is **resolved**. Listing name can be Settle while the
bundle id stays `com.nic.petcompanion`.

### Shipped in the 2026-07-29 session batch (on `main`)

- **Home visual refresh** — PlanItemCard / section hierarchy polish (needs-
  attention tint + icon; leading accent bar tried and dropped — see
  `docs/09` §7.1); design-token and Home surface updates in-tree.
- **Socialization stabilization** — inline record-sheet errors, visible remove
  overflow + confirm (no undo), calm `SocializationError` mapping, queued vs
  confirmed vs failure banners; focused unit tests. Still no XCUITest of the
  three passport screens; queued writes still do not appear as optimistic
  passport rows.
- **ON-04 password recovery** — non-enumerating reset request, mock review
  path, `petcompanion://password-reset` deep link, PKCE exchange before
  set-password, hosted Auth `uri_allow_list` updated surgically. Real-email
  recovery smoke in `docs/21` §7 still remains before TestFlight.
- **Training passport hero + honest progress bar** —
  `SocializationPassportHero` on Training overview; `TrainingProgressStateBar`
  shows the household's reported `TrainingProgressState` continuum (not a
  session-count %). Socialization still has no ratio/progress bar (F09).
- **Engine cooldown fixes + `rule.event_prep_vet`** — `CooldownScope`
  (`rule` | `content`) with fixtures for handling rule-wide cooldown, active-
  skill / dismissal content isolation, start-next-skill, homecoming-once;
  `event_prep_vet` enabled in `SUPPORTED_RULES` with catalogue content
  migration and event-scoped once-per-event fixtures. `rule.growth_photo`
  stays **out of MVP** — seeded catalogue only; see §7 (intentionally
  deferred with P2 journal / US-095; no opt-in preference to gate on).
- **Care** — Weight & growth, Providers, Medications (Accepted safety model),
  Vaccinations (US-070 history only), Grooming (US-076 history only), Notes
  (US-077 general_note + document CRUD) with household-private **image + PDF**
  attach via `household-media` (Scenario H; Life stays image-only). Engine medication obligation
  rules on the Daily Plan remain later.
- **Life milestones + photos** — LF-01/LF-03 create/edit/remove with offline-
  queue truthfulness; photo attach same Storage / Scenario H pattern.
- **Planner** — PL-01 multi-day forward agenda; US-080 confirmed Events as
  distinct agenda rows; month-jump dots for tasks and/or events. Full PL-04
  (linked prep tasks / reschedule-from-agenda) still open.
- **Events foundation + US-086 + local event reminders** — `events` table +
  write-path commands; generation context emits confirmed upcoming events;
  `refresh_event_notification_candidates`; on-device `pc.event.*` local
  reminders. Care → Appointments & events is the edit entry; Planner shows
  read-only detail.
- **Realtime plan reconciliation** — publication for `dispositions` /
  `task_occurrences` / `plans`; iOS debounced truthful re-fetch into
  `SharedPlanState`. Linked hosted publication verified; do not re-push
  unrelated pending migrations solely for this.
- **APNs foundation** — device-token register/unregister via write-path;
  `process-notification-candidates` stub skips send when secrets absent.
  **No HTTP/2 APNs sender and no `.p8` secrets configured.**
- **CI** — `.github/workflows/ci.yml`: engine fixtures + typecheck, write-path
  typecheck, SQL via `supabase db start` / `db reset` / `tests/run.sh`.
  iOS unit/UI tests remain local-only.
- **Localization foundation** — `Localizable.xcstrings` + `PCL10n`; only tab
  labels, tab-shell loading, and a small Home empty-state/quick-add set
  migrated. English default; rest of app still inline literals.
- **Hosted redirect** — `petcompanion://password-reset` on hosted Auth
  `uri_allow_list` (see `docs/21` §5).

### Owner-testing revision (post checklist)

Landed against founding-household notes (Home overwhelm, undo, offline,
Needs Attention, meds visibility, Planner thrash, Life prompts, passport hero):

- **Home undo** — visible Undo on completed cards + short-lived undo banner
  (US-033); Completed auto-expands when completion already resections.
- **Offline** — cache-served plans stay actionable (complete/undo queue);
  Home/Planner sync line shows `queued(count:)` from `mutationQueue` ahead of
  stale. Item `.stale` is a sync cue, not a hard disable.
- **Needs Attention** — engine promotes same-day **required** items after
  exact time / window end (`packages/engine` fixtures
  `same-day-required-*-needs-attention`); scheduled routines stay in Today.
  Bundle `engine.mjs` after engine edits. Full medication **engine**
  obligations still deferred.
- **Upcoming care strip** — next medication dues + appointments from Care /
  Events reads (interim until engine meds obligations).
- **Home density** — Recommended / Coming up collapsed by default with counts;
  category SF Symbols; quieter meta; Capacity on Today header.
- **Planner** — week arrows no longer force agenda `scrollTo`; All/Schedule/
  Routines filter; Schedule group above Routines within a day.
- **Life** — always-on purpose blurb; First-year ideas retained (collapsed)
  after first milestone; create editor has suggestion chips.
- **Training** — passport hero taller with soft warm wash (not saturated block).

### Settle branding + app icon (2026-07-29, often still uncommitted)

- **Display name** — `INFOPLIST_KEY_CFBundleDisplayName = Settle` (Debug +
  Release) so the home-screen label is Settle.
- **In-app copy** — user-visible PetCompanion strings moved to Settle via
  `PCL10n.Brand.displayName` / `Localizable.xcstrings` (`brand.display_name`)
  and direct copy updates (settings, auth errors, invitations, disclaimers).
- **App icon** — source `images/Icon-iOS-Default-1024@1x.png` installed as
  `Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`; welcome screen uses
  `BrandMark.imageset` (derived) instead of the pawprint placeholder.
- **Docs** — `README.md`, `PRODUCT.md`, `docs/README.md` note Settle as the
  working user-facing name; internals stay PetCompanion.
- **Do not change** without an explicit plan: bundle id, `petcompanion://`,
  Xcode target/module names, on-disk cache path prefixes, launch arg
  `-PetCompanionBackend`.

### Not built / still honest gaps

- Life **journal** (P2 / US-094+).
- **`rule.growth_photo`** — **do not enable in MVP.** Seeded only; keep out of
  `SUPPORTED_RULES` until P2 journal / US-095 ships with a real opt-in
  preference (none exists today — see §7).
- Full **APNs HTTP/2 send** (needs Auth Key `.p8` / env secrets per `docs/21`
  §4.1, plus the sender implementation — stub only today).
- Events **calendar import/export** and broader calendar UI polish.
- Planner **PL-04** linked preparation tasks / reschedule from agenda.
- Engine **medication obligation** rules on the Daily Plan.
- **GL-02 pet switcher** UI when multiple pets exist (data model already
  multi-pet; no combined multi-pet Home in MVP).
- **Professional content review** — all seeded content remains
  `pending_professional_review` (release gate, `PRD §20`).
- Broader **localization** migration beyond the foundation set.
- Diagnostics/telemetry; complete accessibility device matrix beyond current
  XCUITest harness coverage.
- **Owner device testing** — founding-household checklist returned 2026-07-29;
  functional Care/Auth/Training/Life CRUD largely pass. Revision above addresses
  Home/Planner/Life/hero notes; retest: undo banner, offline queue line, Needs
  Attention after a missed required exact time, Upcoming care meds, Home
  collapsed sections, Planner week scrub + Schedule filter, Life ideas after
  first milestone, passport hero.
- **ON-04 real-email recovery smoke** and first **TestFlight** upload after
  App Store Connect app record exists.

### Counts at this landing

The 2026-07-29 batch is **committed and pushed** to `origin/main`. Migrations
in that batch include Care weight/providers, medications, vaccinations,
grooming, notes (+ note media), Life milestones (+ media), Events foundation
(+ hosted apply / client write lockdown), device tokens / notification
dispatch, US-086 event candidates, event_prep_vet content, and plan Realtime
publication. `supabase/tests/run.sh` runs **20** SQL suites (including
`care`, `medications`, `vaccinations`, `grooming`, `notes`, `notes_media`,
`events`, `event_notifications`, `life`, `life_media`, `device_push`,
`plan_realtime`). Engine fixture scenarios expanded for cooldown isolation
and event_prep_vet. Swift unit tests cover the new Care / Life / Events /
localization / password-recovery / Realtime / push registration surfaces;
iOS UI scenario tests updated for Planner and Training.

## 3. Architecture in one page

- **Client:** native SwiftUI, iOS 27. Services are protocol-typed with `Mock*`
  and `Real*` implementations chosen at launch by `BackendSelection.resolve`.
- **Backend:** Supabase. Row-level security is the household tenancy boundary
  and is enforced at the data layer, not in application code.
- **The write path is the only way in.** Every invariant-bearing mutation goes
  through the `write-path` Edge Function, which calls a `write_path_*` RPC.
  Clients have `SELECT` only; they cannot write those tables at all. Every such
  function is `SECURITY DEFINER`, sets `search_path`, and is revoked from
  `public`/`anon`/`authenticated` and granted only to `service_role`. If you add
  a command, copy that shape exactly — `20260728001100_socialization_records.sql`
  is the cleanest current example.
- **The engine is pure.** `packages/engine` is a dependency-free TypeScript
  function `(context) → plan`, bundled into `supabase/functions/_shared/engine.mjs`
  and run server-side so there is one authoritative plan and no per-device drift.
- **Occurrence identity is deterministic**, so regeneration cannot duplicate and
  rescheduling preserves identity. See `docs/10 §9`.

## 4. Running it

```sh
supabase start && supabase db reset      # local; db reset is LOCAL only
bash supabase/tests/run.sh               # all 20 SQL suites
cd packages/engine && npm test && npm run typecheck
cd packages/write-path && npm run typecheck
```

The same engine, write-path, and SQL checks run in CI on push/PR to `main`
when backend or TypeScript paths change (see `.github/workflows/ci.yml`).
CI uses `supabase db start` (Postgres only) rather than the full local stack.

iOS unit tests:

```sh
cd PetCompanion && xcodebuild test -project PetCompanion.xcodeproj \
  -scheme PetCompanion -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0'
```

Driving the real UI and capturing screenshots: see
`PetCompanion/PetCompanionUITests/README.md`. Read it before using the harness —
its two documented traps are covered in §6.

Deploying to hosted: `docs/21-hosted-supabase-deployment.md`.

## 5. Decisions the owner still needs to make

1. **The medication-occurrence safety model.** **Accepted** (orchestrator
   decision on owner request, 2026-07-29) in `docs/13-decision-log.md`.
   Care Medications (CA-06/CA-07) now ships against that contract: dose text
   verbatim, field-level change history, occurrences only from explicit
   schedules, neutral “Due in N days”, and recent-partner extra confirmation
   with no missed-dose advice. Remaining follow-ups: usability validation of
   the confirm interaction before public release; Daily Plan engine medication
   obligation rules; travel time-zone behavior.
2. **Training progress bars.** **Accepted** (orchestrator decision on owner
   request, 2026-07-29) in `docs/13-decision-log.md`. Training goal UI now
   shows a calm segmented bar for the household's own reported
   `TrainingProgressState` (discrete continuum steps + named label), not a
   computed “Module Completion 60%” or session-count ratio. F08's seventh
   label (“Paused”) remains a goal lifecycle status so pausing stays
   non-destructive. Socialization passport still has no ratio or progress bar
   (F09).
3. **`rule.alone_time`'s prerequisite gate.** It is spec-correct and cannot fire
   until a `skill.crate_comfort` goal exists. Dropping the gate would make it
   live immediately at the cost of engine §12.3. Recommending alone-time work
   before crate comfort is established is poor advice for a puppy; the gate was
   kept deliberately.
4. **Professional content review.** All seeded content is
   `pending_professional_review`. This is a release gate before any external
   audience (`PRD §20`).

## 6. Traps — read this section

Each of these was found the hard way. Most were silent.

**Dates decode at midnight GMT.** `local_date` and `local_due_date` are SQL
`date` columns; `SupabaseCoding.restDecoder` lands them on midnight GMT. Setting
a wall-clock hour "of" such a value with a household calendar lands on the
*previous day* for any household west of GMT — and for today's plan that puts the
result in the past, where filters silently drop it. This disabled local
reminders entirely in America/Toronto. Use `Plan.localDayStart(in:)` /
`TaskOccurrence.localDayStart(in:)` before combining with a wall time. Test
fixtures must be built in the GMT-midnight shape or they prove nothing.

**`INFOPLIST_KEY_*` silently discards custom keys.** Xcode only maps that prefix
onto its own allowlist. `PC_BACKEND_MODE` and friends never reached the bundle,
so backend selection always fell through to its compiled-in default — meaning
Release would have failed at launch. They now come from a base `Info.plist`
named by `INFOPLIST_FILE`. There is a test asserting the keys actually arrive,
expanded; keep it.

**Two migrations must never both re-issue the same function.** Training and
socialization each did `create or replace write_path_generation_context`. Git
merged them cleanly — different files — and every suite passed in isolation. The
later one silently reverted the earlier's work, re-starving three engine rules.
Only ever have one migration own a function, and re-run `supabase db reset` plus
the full suite after any merge involving migrations.

**Hosted requires an `apikey` header on every route.** The local gateway does
not. A hand-rolled health probe worked locally and reported a healthy hosted
project as unreachable. Everything else goes through the Supabase SDK, which
sets it automatically.

**Do not cache 5xx failures against an idempotency key.** The write path used
to; the client classifies 5xx as retryable and replays the same key, gets the
stored failure back, and retries forever — and because a retryable failure blocks
the FIFO head, every later mutation was stuck behind it. Only deterministic
(4xx) failures are cached now.

**`supabase config push` sends the whole file.** Anything unspecified is pushed
as a CLI default. It silently disabled TOTP enrolment, relaxed the e-mail send
throttle to 1s and shortened OTP length on the hosted project. Keep
`config.toml` an accurate description of hosted; a push reporting every service
`up_to_date` is the signal that it is.

**The MCP `apply_migration` tool assigns its own version.** That drifts from
your filenames. `supabase db push` keeps them aligned; if you must use the MCP
tool, rename the local file to match afterwards.

**Care Weight, Providers, Medications, and Vaccinations need a hosted push +
write-path redeploy.** Debug builds currently set `PC_BACKEND_MODE=hosted`.
Shipping `*_care_weight_and_providers.sql` / `*_care_medications.sql` /
`*_care_vaccinations.sql` only in the working tree leaves hosted PostgREST
returning schema-cache misses for `weight_measurements` / `providers` /
`medication_schedules` / `vaccination_records`. Apply with
`supabase db push --linked`, then `supabase functions deploy write-path` so
Care commands are live. Local `supabase db reset` / `migration up` does not
update the hosted project the app is talking to.

**Remote APNs foundation (2026-07-29):** device-token migration
`20260729180325` is on hosted (applied surgically so later Care
grooming/notes/realtime migrations stayed local-only for their owners).
`write-path` and `process-notification-candidates` are deployed. APNs `.p8`
secrets are **not** set — configure per `docs/21` §4.1 when enabling delivery.

**Xcode 27 removed `Simulator.app`** and moved `SimulatorKit` to
`Contents/SharedFrameworks`, so FBSimulatorControl-based tooling (including the
Claude Code simulator panel) cannot load. macOS App Management blocks patching
the bundle. **XCUITest is the answer** — it drives the app through accessibility
via `testmanagerd` and needs none of that. `xcrun simctl` can install, launch and
screenshot but cannot inject touches.

**`TEST_RUNNER_*` environment values never reach the runner** under `xcodebuild
test`. A run could request accessibility text size and silently render default —
producing confident, wrong conclusions on the exact axis the app was failing.
Variants must be test *methods*.

**`-UIUserInterfaceStyle` is inert on iOS 27.** Appearance is a device setting:
`xcrun simctl ui booted appearance dark`. The harness measures screen luminance
and warns when the render contradicts the folder name — trust that warning.

**The simulator may already be at an enlarged text size.** An inherited
"standard" baseline made the app look far more large-text tolerant than it was.
State the size explicitly in both variants.

**A test failing at 0.000s with the runner moving to a new simulator clone is a
crash, not an assertion failure.** Read `~/Library/Logs/DiagnosticReports/`
rather than re-running: a crashing run costs ~11 minutes on a 600s diagnostics
timeout. Never kill `xcodebuild` mid-run — it corrupts simulator state and
produces a second, misleading failure mode.

**A detached `UIWindow` cannot measure accessibility.** `UIWindow(frame:)` is
deprecated on iOS 26+ and a window with no `windowScene` never builds the
snapshot SwiftUI answers traversal from. Sizing via `UIHostingController` works
fine without a scene; accessibility traversal does not. Assert VoiceOver
structure in XCUITest instead.

**Mock mode ignores passwords.** `MockBackend.signIn(email:)` derives a name
from any email and returns that user. Automation needs no real credentials — and
should use an obviously synthetic address. Also reset the simulator keychain
before screenshotting: AutoFill and the keyboard's QuickType bar will otherwise
render a real address into images.

## 7. Known defects and open gaps

Open items only. Shipped work from the 2026-07-29 batch is summarized in §2;
do not re-read older “not built” bullets for Planner agenda, Events, Care
records, Life milestones, ON-04, Training progress bar, Realtime foundation,
or APNs *registration*.

### Still open / incomplete

- **APNs HTTP/2 delivery is not implemented.** Device-token registration,
  candidate refresh (including US-086 `event_reminder`), cron
  `verify_due_notification_candidates`, and `process-notification-candidates`
  (skips send when secrets absent) are live. Eligible rows stay `scheduled`
  until Auth Key `.p8` / env secrets (`docs/21` §4.1) **and** the HTTP/2
  sender land. Never commit `.p8` keys.
- **`rule.growth_photo` — intentionally deferred; stay out of MVP.** Catalogue
  §9 + seed mark it `opt-in` / `p2` (tier P4, 7-day cooldown). US-095 is
  Priority P2 (“prompt is optional and configurable”). Product decision:
  ship with **P2 Life journal** work, not MVP Daily Plan. **Blocker for
  engine enablement:** there is no household/pet preference flag for growth-
  photo opt-in (`pet_preferences` only has category pauses +
  `suggestion_frequency_adjustments`; generation context has nothing to gate
  on). Enabling without a real opt-in would violate catalogue eligibility.
  Leave seeded content in place; do **not** add to `SUPPORTED_RULES`,
  fixtures, or hosted `engine.mjs` until opt-in storage + US-095 UI land.
  Catalogue open question §11.4 is closed in this direction.
- **Life journal (P2)** — not started; prerequisite companion surface for
  growth-photo prompts (US-094+ / US-095).
- **PL-04** linked prep tasks / reschedule-from-agenda — still open after
  PL-01 + US-080.
- **Events calendar import/export** and broader calendar UI polish — not
  built; Care → Appointments is the capture surface.
- **Engine medication obligation rules** on the Daily Plan — Care
  Medications UI/schedules ship; plan engine rules do not.
- **Professional content review** — all seed content remains
  `pending_professional_review`.
- **ON-04 real-email recovery smoke** (`docs/21` §7) still required before
  TestFlight.
- **GL-02 pet switcher** — multi-pet data model yes; polished switcher chrome
  and combined multi-pet Home no (Home is out of MVP by IA).
- **Settle branding commit** — if `git status` still shows display-name /
  AppIcon / BrandMark / copy changes, they are not on remote yet; commit
  before relying on TestFlight builds to show Settle.
- **Socialization follow-ups:** no XCUITest of the three passport screens;
  no restore/undo command after remove; queued writes do not show as
  optimistic passport rows (appears after offline replay + reload).
- **The engine's §26.2 example plan is not reproducible from the full seed** —
  the fixture catalogue is a curated subset. Pre-existing.
- **Hosted Care / Events / notification migrations** may still need a
  deliberate `supabase db push --linked` + `write-path` redeploy for slices
  not yet applied on the linked project. Debug builds use
  `PC_BACKEND_MODE=hosted` — local `db reset` does not update hosted.
  Realtime publication and device-token / password-reset allow-list pieces
  were applied surgically; do not assume every 2026-07-29 migration is on
  hosted without checking.

### Resolved this batch (do not re-open as defects)

- Engine `onCooldown` / `CooldownScope` isolation (handling rule-wide;
  active-skill and dismissal content-scoped) + `rule.event_prep_vet`.
- Socialization UX critique items (inline errors, visible remove, calm
  error mapping, queued banner tone).
- ON-04 password recovery client + hosted redirect allow-list.
- Training honest progress bar + passport hero.
- Planner PL-01 forward agenda + US-080 event rows + month dots.
- Events foundation, US-086 candidates, on-device `pc.event.*` reminders.
- Care weight/providers/medications/vaccinations/grooming/notes (+ image
  attach; document notes also accept PDF ≤10 MB) and Life milestones
  (+ image attach; Life stays image-only).
- Realtime plan reconciliation foundation; CI; localization foundation.
- 2026-07-29 landing **pushed to `origin/main`** (no longer an uncommitted
  tree).
- App Store Connect **provider contract state** unblocked for iOS app-record
  creation (was `PLATFORM_NOT_ALLOWED_DUE_TO_CONTRACT_STATE`).
- **Settle** user-facing name + new AppIcon / welcome BrandMark (internals
  and `petcompanion://` unchanged) — confirm committed before release builds.
- Owner-testing Home/Planner/Life/hero revision: inline undo + offline queue
  sync line; same-day required Needs Attention; Upcoming care strip; Home
  density; Planner week scrub + Schedule/Routines; Life ideas retained;
  passport hero presence.

## 8. Working conventions

- Specifications in `docs/` win. Material product decisions go in
  `docs/13-decision-log.md` with a "revisit when".
- Never weaken RLS or grant clients direct writes to make something easier.
- Never present a failed or unconfirmed write as success. Loading, empty,
  offline, stale, queued and error states must each say something true and
  specific.
- State is never carried by colour alone.
- Verify claims rather than trusting reports — including your own. Several
  confidently-written tests in this repo's history could not measure what they
  asserted. If a test passes, check that it fails when the fix is removed.
