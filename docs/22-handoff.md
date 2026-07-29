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
Supabase. The centrepiece is a **Daily Plan**: one deterministic,
server-generated plan per pet per household-local day.

The product's character is restraint. Maximum three recommendations a day, no
streaks, no guilt mechanics, no unexplained scores, and a hard veterinary
boundary — it records and reminds, never diagnoses or doses. Health-adjacent
content ships deliberately **empty**; those records are always owner- or
vet-entered. Read `PRODUCT.md` before making product judgements; its
anti-references are load-bearing, not decoration.

## 2. Where things stand

Working end to end against hosted Supabase: account and onboarding, the Daily
Plan, the Planner with full recurrence and occurrence actions, household
invitations with a second caregiver, training goals and sessions, and the
socialization passport. A durable offline mutation queue, local reminders, and
an append-only attributed history underpin all of it.

**Not built:** Care records (in progress at time of writing), Life timeline and
media, events and calendar, medication scheduling (deliberately — see §5),
remote APNs delivery, CI, and localization.

**Stubs that are honest about being stubs:** `Life/`. `Care/` is being replaced
as this is written.

Counts at handoff: 13 migrations, 8 SQL suites, 22 engine fixtures, 83 Swift
files, 72 unit tests, plus an XCUITest review harness.

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
bash supabase/tests/run.sh               # all 8 SQL suites
cd packages/engine && npm test && npm run typecheck
cd packages/write-path && npm run typecheck
```

iOS unit tests (72):

```sh
cd PetCompanion && xcodebuild test -project PetCompanion.xcodeproj \
  -scheme PetCompanion -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0'
```

Driving the real UI and capturing screenshots: see
`PetCompanion/PetCompanionUITests/README.md`. Read it before using the harness —
its two documented traps are covered in §6.

Deploying to hosted: `docs/21-hosted-supabase-deployment.md`.

## 5. Decisions the owner still needs to make

1. **The medication-occurrence safety model.** This gates the rest of Care.
   `docs/12 §22` requires dose text stored exactly as entered and never
   computed, mandatory field-level change history, and no missed-dose advice of
   any kind. Until that is designed, medication scheduling must not be built.
   Note the owner's Care mock shows "Flea & Tick Prevention · Due in 5 days",
   which is precisely this surface.
2. **Training progress bars.** A design mock shows "Module Completion 60%".
   `PRODUCT.md` bans unexplained scores and F08 specifies seven *owner-reported*
   states, not a percentage — and the socialization passport was deliberately
   built with no ratio anywhere. An honest middle path is a bar rendering the
   owner's own reported state rather than a computed percentage.
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

## 7. Known defects, unfixed

- **`onCooldown` scope** was fixed for socialization only. Verify before
  assuming it is right for other rules.
- **The engine's §26.2 example plan is not reproducible from the full seed** —
  the fixture catalogue is a curated subset. Pre-existing.
- **`notification_candidates`** rows accumulate with nothing consuming them.
  Correct for now: remote APNs is a later slice. They are groundwork, not a leak.
- **Socialization shipped three screens with no iOS tests.** Its SQL coverage is
  strong; its client is unverified.
- **Behavioural findings from the UX critique, unfixed:** a socialization save
  that fails completely silently (the error renders on the screen *behind* the
  sheet); "Remove from the passport" is destructive, long-press-only, with no
  confirmation and no undo, while the *reversible* action beside it gets a full
  dialog; server validation strings are shown to users verbatim; there is no
  password recovery (ON-04 does not exist and was never marked deferred).
- **The Planner is a day view, not the forward-scrolling agenda** `docs/16 PL-01`
  specifies.

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
