# API and Integrations

**Status:** Draft (APNs + Realtime plan reconciliation foundations)
**Last updated:** 2026-07-29

Potential areas include notifications, calendars, media storage, poster text
recognition, training media, weather, maps, and veterinary records.

No integration should be selected until its product value, reliability, privacy
impact, operating cost, and fallback behavior are understood.

## 1. Apple Push Notification service (APNs)

**Status:** Foundation landed 2026-07-29. Device-token registration and a
candidate-consumer stub are in place. Full HTTP/2 delivery is gated on hosted
secrets and a later sender slice.

### What exists

| Layer | Location | Role |
| --- | --- | --- |
| Local reminders | `LocalNotifications.swift` | On-device scheduling for plan items **and** confirmed Events; source of convenience delivery today |
| Device tokens | `device_push_tokens` + `register_device_token` / `unregister_device_token` | User-owned APNs tokens via write-path only |
| Candidate verify | `verify_due_notification_candidates` (pg_cron every 5 min) | Cancels stale due rows (occurrence + event); leaves valid `scheduled` rows |
| Claim helper | `claim_due_notification_candidates` | Eligible due candidates + active tokens for a sender |
| Edge stub | `process-notification-candidates` | Claims/verifies; skips send when APNs secrets absent |
| Event refresh | `refresh_event_notification_candidates` (US-086) | Create/edit/cancel/archive Events cancel stale `event_reminder` rows and recreate for confirmed events with `reminder_config.lead_minutes` |
| iOS capture | `RemotePushRegistration.swift` + app delegate | Registers for remote notifications after permission; uploads hex token |

Local reminders remain the caregiver-visible delivery path until APNs send is
enabled. Simulator registration failures are non-fatal. Plan item reminders use
namespace `pc.local.{accountId}.`; Event reminders use `pc.event.{accountId}.`
so reconciling one never clears the other. Event schedules mirror server lead
minutes + quiet hours, with discreet banner copy (no titles/notes/health
detail). `EventStore` reloads replace pending Event locals; foreground also
reconciles from a fresh Events read.

### Secrets (never commit)

Apple Auth Key `.p8` files are gitignored (`*.p8`, `AuthKey_*.p8`). Configure
them only as Supabase Edge Function secrets — see
[Hosted deployment §4.1](21-hosted-supabase-deployment.md).

Required secret names:

- `APNS_KEY_ID` — Key ID from Apple Developer → Keys
- `APNS_TEAM_ID` — Apple Team ID
- `APNS_TOPIC` — iOS bundle id (APNs topic)
- `APNS_PRIVATE_KEY` **or** `APNS_PRIVATE_KEY_BASE64` — Auth Key `.p8` PEM
  contents (or base64 of that PEM)
- Optional: `NOTIFICATION_DISPATCH_SECRET` — shared header for cron/ops
  invocation (`x-notification-dispatch-secret`)

### Explicit non-goals of this foundation

- No HTTP/2 APNs sender implementation yet (even when secrets are present).
- No Expo Push, FCM, or third-party relay.
- No Care / Planner / Life UI changes for remote push.

## 2. Supabase Realtime (plan reconciliation)

**Status:** Foundation landed 2026-07-29. Household-scoped postgres_changes on
plan tables drive a truthful client re-fetch — not a client-side merge.

| Layer | Location | Role |
| --- | --- | --- |
| Publication | `*_plan_household_realtime_publication.sql` | Adds `dispositions`, `task_occurrences`, `plans` to `supabase_realtime` with `REPLICA IDENTITY FULL` |
| Bridge | `PlanRealtimeReconciliation.swift` | `SupabasePlanRealtimeBridge` filters by `household_id`; mock is `NoOpPlanRealtimeBridge` |
| Reconciler | same | Debounces change signals → `AppModel.reconcilePlanFromRemote()` |
| Shared state | `SharedPlanState.reconciliationEpoch` | Home/Planner refresh hooks only |

Auth lifecycle: subscribe in main with a household; unsubscribe on sign-out /
rollback. Foreground safety refresh via `scenePhase`. SQL assertion suite:
`supabase/tests/plan_realtime.sql`.

## 3. Deferred integrations

Calendars, poster OCR, weather, maps, and veterinary-record imports remain TBD
until each has a product + privacy review. Household-private Life milestone
photos use Supabase Storage (`household-media` + RLS); Care note / document
attachments (images + PDF) reuse the same bucket and `media` metadata via
`prepare_care_note_media` / complete / fail / remove. Life milestones stay
image-only.
