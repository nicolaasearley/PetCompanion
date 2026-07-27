# Current Build Status

**Status:** Working checkpoint
**Checkpoint:** 2026-07-27
**Build:** Local private MVP, Slice B complete

## Outcome

PetCompanion is a compiling, test-backed native iOS application connected to a
fully local Supabase backend. A new owner can create an account and household,
add a puppy with exact, estimated, or unknown age information, choose routine
basics, and reach a server-generated Daily Plan. Caregivers can now coordinate
dated and recurring work through a real Planner, use local reminders, and
continue issuing visibly queued actions during a temporary connection loss.
The app never silently switches to disposable mock data when its configured
service is unavailable.

## Working product paths

### Account and onboarding

- Explicit local, hosted, or mock environment selection.
- Email/password signup and sign-in.
- Hosted email-confirmation pause state.
- Session restoration.
- Expired or locally invalidated sessions return safely to sign-in instead of
  masquerading as a backend outage.
- Interrupted setup resumes at household or puppy creation as appropriate.
- Household time zone is authoritative for calendar-day behavior.
- Exact, estimated, and unknown puppy age.
- Future, today, and past homecoming semantics.
- Routine choices persist and create real meal, potty, and wind-down schedules.

### Daily Plan

- Server-generated, persisted plan for the household-local day.
- Stable same-day recommendations; passive refresh does not churn the plan.
- Required, scheduled, recommended, upcoming, and completed presentation.
- Complete and undo with caregiver attribution.
- Explicit recommendation acceptance into a pending scheduled occurrence.
- One-time task quick add.
- Today-only and durable household-default capacity changes.
- Visible loading, empty, error, stale, and offline-cache states.
- Last-known-good plan cache is read-only and visibly stale.
- Home and Planner share one in-memory plan state.
- Timezone-aware day closing and recommendation expiry.

### Planner and coordination

- Agenda-first day navigation in the household time zone.
- One-time, daily, weekly, selected-weekday, every-N-days, and safe-monthly
  schedules with anytime, broad-window, or exact-time timing.
- Task detail, editing, and append-only attributed action history.
- Complete/undo, skip/undo, same-day snooze, occurrence reschedule, occurrence
  cancellation, future-series split, and schedule archive.
- Rescheduling preserves occurrence identity; future-series edits preserve
  historical schedule ownership.
- Household-local civil dates and deterministic DST behavior.
- Durable, account-scoped FIFO write queue with stable idempotency keys,
  process-relaunch recovery, serialized replay, and visible failure/rejection
  states.
- Permission-aware local reminders, lead-time and quiet-hour preferences,
  discreet copy, cancellation, and current-state resolution.
- Settings surfaces notification controls, sync state, retry, and sign-out.

### Other destinations

- Training provides a searchable, stage-aware local seed catalogue and
  accessible lesson pages. Content remains marked pending professional review.
- Care shows verified puppy profile context and clearly labels future record
  capabilities as planned.
- Life establishes the first-year memory structure without pretending media
  persistence exists.

### Product foundation

- Premium semantic light/dark design tokens and accessible components.
- WCAG-oriented VoiceOver, Dynamic Type, Reduce Motion, and minimum-target
  behavior in the implemented flows.
- Final opaque 1024×1024 app icon and asset catalogue.
- iOS-only project settings, real bundle identifier, privacy manifest, and
  native XCTest target.
- Durable retry identity and persisted FIFO replay for write commands.
- RLS-isolated household data and a single audited server write path.

## Verified

- Debug simulator build: pass.
- Release simulator build: pass.
- iOS XCTest: 25/25 pass.
- Plan engine fixtures: 13/13 pass.
- Engine TypeScript: pass.
- Write-path TypeScript: pass.
- Database RLS isolation: 86/86 pass.
- Database invariants: 32/32 pass.
- Command suite: pass.
- Generation lifecycle: pass.
- Slice B coordination/recurrence suite: pass.
- Fresh local database reset: pass.
- Authenticated local smoke:
  account → household → unknown-age future puppy → routines → plan →
  recommendation promotion/completion.
- Signed iOS local-backend smoke:
  sign-in → household restore → plan fetch → complete → undo → session restore.
- Signed clean-account Planner smoke:
  account → household → pet → recurring task → skip/undo → complete/undo →
  snooze → identity-preserving reschedule → action history → cancel →
  edit this and future.

## Deliberately remaining

These are the next product slices, not hidden claims in the current build:

1. Provision hosted Supabase, deploy schema/functions, and inject the
   production client configuration using the ready runbook.
2. Add realtime multi-device reconciliation.
3. Build invitations, household membership, and companion-account UI.
4. Add event capture and calendar import/export.
5. Add training goals, session logging, progress history, and socialization
   records backed by server data.
6. Add health, medication, weight, grooming, provider, and document records
   after resolving the medication-occurrence safety model.
7. Add Life milestones, media upload, and timeline.
8. Add remote APNs delivery, diagnostics/telemetry, CI, localization, and
   complete accessibility device testing.
9. Obtain professional review for health-adjacent and training seed content
   before any public distribution.

## Local run

1. Start Docker.
2. From the repository root, run `supabase start`.
3. On first setup or when intentionally rebuilding local data, run
   `supabase db reset`.
4. In a second terminal, run `supabase functions serve`.
5. Open `PetCompanion/PetCompanion.xcodeproj`.
6. Run the `PetCompanion` scheme on an iOS 27 simulator.

Debug builds select the local backend by default. Mock mode is opt-in via the
`-PetCompanionBackend mock` launch argument. Release builds require hosted
Supabase URL and anonymous-key configuration and fail visibly when it is
missing.
