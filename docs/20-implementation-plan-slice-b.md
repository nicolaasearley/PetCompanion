# Implementation Plan — Slice B Daily Coordination

**Status:** Complete
**Version:** 1.0
**Started:** 2026-07-27
**Completed:** 2026-07-27

## 1. Outcome

Slice B turns the Slice A Daily Plan into a dependable household operating
loop. A caregiver can create dated or recurring tasks, act on an occurrence,
see the attributed history, receive restrained device reminders, and keep
working through a temporary network interruption without mistaking queued
work for confirmed server state.

This is a local-backend implementation. Hosted Supabase provisioning and
multi-device household invitations follow in a separate deployment step after
Slice B passes locally.

## 2. In scope

- Agenda-first Planner with household-local day navigation.
- Create and edit one-time and recurring task schedules.
- Explicit supported recurrence:
  - once;
  - daily;
  - selected weekdays;
  - weekly;
  - every N days;
  - safe monthly.
- Anytime, broad-window, and exact-time scheduling.
- Human-readable recurrence summaries before save.
- Occurrence detail and append-only action history.
- Complete and undo completion.
- Skip and undo skip.
- Same-day snooze without changing the due date.
- Reschedule one occurrence without changing its series.
- Change this and future occurrences through a schedule split.
- Pause/archive or cancel future household-authored work without deleting
  history.
- Durable FIFO mutation queue with stable idempotency keys, original
  timestamps, serialized replay, and visible queued/failed/rejected states.
- Local notification permission, preferences, scheduling, cancellation, and
  discreet lock-screen copy.
- Household attribution for confirmed actions.
- Database, engine, write-path, domain, service, and iOS tests.

## 3. Deliberately out of scope

- Hosted Supabase provisioning or production secrets.
- APNs server delivery, device-token registration, or production push.
- Household invitations and remote multi-device realtime reconciliation.
- Arbitrary RRULE input or unsupported recurrence approximation.
- Health/medication scheduling, whose safety model remains a separate slice.
- Events, providers, maps, media, or calendar export.

## 4. Behavioral contracts

1. The server remains authoritative. Optimistic local state is explicitly
   marked queued until the write path confirms it.
2. Every mutation is persisted locally before transmission and retains one
   idempotency key across retries and relaunches.
3. Replay is FIFO per signed-in user. Signing out cannot replay one account's
   operations under another account.
4. Authorization and revisions are rechecked by the server. Rejected work is
   visible and never silently discarded.
5. Dispositions are append-only. Undo records a new action; it does not erase
   history.
6. Snooze changes reminder emphasis only. It never changes the occurrence's
   due date.
7. Rescheduling one occurrence preserves its identity and does not alter later
   occurrences.
8. Editing this and future splits the schedule. Historical occurrences retain
   their original schedule.
9. Recurrence uses household-local dates. DST gaps resolve to the first valid
   local instant; repeated wall times use the first occurrence.
10. Local notifications are convenience delivery, not the source of truth.
    Before presenting an action, the app resolves the current occurrence.

## 5. Experience contract

- Planner opens to the useful agenda rather than a month grid.
- Date controls are familiar and compact; the current day remains obvious.
- Editing uses standard iOS forms and sheets with one primary save action.
- Unsupported recurrence cannot be constructed.
- Recurring edits require an explicit “this occurrence” or “this and future”
  choice.
- Destructive actions explain their scope before confirmation.
- Queued, stale, failed, empty, loading, and permission-denied states use text
  and symbols in addition to color.
- All controls support VoiceOver, Dynamic Type, Reduce Motion, and 44-point
  targets.

## 6. Completion gate

Slice B is complete when:

1. A signed-in caregiver can create each supported schedule type and see
   deterministic occurrences in Planner and the Daily Plan.
2. Complete, undo, skip, undo skip, snooze, one-occurrence reschedule, and
   future-series changes pass authenticated local-backend smoke tests.
3. A queued offline action survives relaunch and replays exactly once after
   connectivity returns.
4. Notifications are permission-aware, deduplicated, cancelled after terminal
   actions, and do not expose sensitive detail by default.
5. Debug and Release builds pass.
6. All prior Slice A tests and new Slice B tests pass.
7. The final UI is visually inspected in light mode, dark mode, and a large
   Dynamic Type size.
8. The hosted Supabase runbook is complete and contains no committed secrets.

## 7. Completion evidence

- The authenticated production-adapter smoke passes on a signed iOS simulator
  with a clean local account and household:
  create recurring task → skip/undo → complete/undo → snooze → reschedule
  while preserving occurrence identity → inspect history → cancel → edit this
  and future.
- The durable, account-scoped FIFO queue survives process recreation, preserves
  command identity and original timestamps, and exposes pending, failed, and
  rejected work through Settings.
- Local reminder permission, preferences, quiet hours, scheduling,
  deduplication, cancellation, and deep-link resolution are covered by tests.
- Debug and Release simulator builds pass.
- iOS XCTest passes 25/25 tests across domain, infrastructure, Planner, queue,
  and notification suites.
- Planner was visually inspected in light mode, dark mode, and Accessibility
  Extra Large; compact week controls remain legible while agenda content
  continues scaling through the accessibility range.
- The deterministic plan engine passes 13/13 fixtures and TypeScript checking.
- Write-path TypeScript checking passes.
- A fresh local database reset and all five SQL suites pass, including RLS,
  invariants, command behavior, generation lifecycle, recurrence, DST,
  revision conflicts, and coordination actions.
- Planner uses household-local civil-date decoding, including the authenticated
  Toronto smoke that caught and verified the UTC-boundary correction.
- The hosted deployment runbook is ready and contains no production secret.
