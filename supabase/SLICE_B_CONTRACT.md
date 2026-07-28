# Slice B backend contract

This is the client handoff for migrations
`202607270001_slice_b_coordination_foundation.sql`,
`202607270002_slice_b_coordination_commands.sql` (daily coordination), and
`20260728000200_household_invitations.sql` (shared care).

## Transport envelope

Send authenticated `POST` requests to the `write-path` Edge Function:

```json
{
  "command": "command_name",
  "payload": {},
  "client_idempotency_key": "stable-client-generated-key",
  "recorded_at": "2026-11-01T14:00:00Z",
  "effective_at": "2026-11-01T14:00:00Z"
}
```

Success:

```json
{
  "ok": true,
  "command": "command_name",
  "idempotent_replay": false,
  "result": {}
}
```

Failure:

```json
{
  "ok": false,
  "command": "command_name",
  "code": "VALIDATION_ERROR",
  "message": "human-readable summary",
  "idempotent_replay": false
}
```

`REVISION_CONFLICT` is HTTP 409. Reusing one idempotency key with a different
command or payload is also HTTP 409. The server returns the stored result for
an exact replay and sets `idempotent_replay` to `true`.

## Commands

| Command | Required payload | Optional payload | Authoritative `result` |
| --- | --- | --- | --- |
| `create_recurring_task` | `pet_id`, `title`, `recurrence`, `assignment` | `category`, `obligation_class`, `reminder_config`, `task_definition_id`, `schedule_id` | `task_definition`, `task_schedule`, `occurrences[]` |
| `edit_occurrence` | `occurrence_id`, `expected_revision` | `title`, time fields, `assignment`, `note` | `occurrence`, `task_definition` |
| `cancel_occurrence` | `occurrence_id`, `expected_revision`, `confirm_required: true` | `note` | `occurrence`, `disposition` |
| `snooze_occurrence` | `occurrence_id`, `snooze_until` | `note` | `occurrence`, `disposition`, `notification_candidates_scheduled` |
| `reschedule_occurrence` | `occurrence_id`, `expected_revision`, `local_due_date` | time fields, `note` | `occurrence`, `disposition` |
| `undo_skip` | `occurrence_id` | `note` | `occurrence`, `disposition`, `cleared_skip_ids[]` |
| `edit_schedule_future` | `schedule_id`, `expected_revision`, `split_date`, `recurrence` | `title`, `assignment`, `reminder_config`, successor IDs, `note` | `superseded_schedule`, `successor_schedule`, `task_definition`, `future_occurrences_cancelled`, `cancelled_occurrences[]`, `occurrences[]` |
| `archive_schedule` | `schedule_id`, `expected_revision`, `confirm_required: true` | `note` | `task_schedule`, `occurrences_cancelled`, `occurrences[]` |
| `create_invitation` | `household_id` | `invitation_id`, `expires_in_hours` (1–336, default 168), `role_granted` (`caregiver`) | `invitation`, `token` (once), `token_returned_once` |
| `revoke_invitation` | `invitation_id` | — | `invitation` |
| `accept_invitation` | `token` | — | `household`, `membership`, `invitation` |
| `decline_invitation` | `token` | — | `invitation` |

Every returned schedule, definition, and occurrence includes its authoritative
revision. Both create operations and this-and-future edits return materialized
occurrence IDs. Clients must replace optimistic objects with these results.

`assignment` is `unassigned`, `anyone`, or `member:<user UUID>`.

Time fields are:

- `time_policy: "anytime"` with no `window_ref` or `exact_time`
- `time_policy: "window"` plus `window_ref`
- `time_policy: "exact_time"` plus local-wall `exact_time`

Supported recurrence objects have `type`, `anchor_date`, and time fields.
Types are `once`, `daily`, `weekdays`, `every_n_days`, `weekly`,
`monthly_safe`, and `interval_after_completion`. Rules may be bounded by
`count` or `until`. `weekdays` uses ISO values 1 through 7. `every_n_days`
and `interval_after_completion` require a positive `interval`; `weekly`
repeats every seven days from its anchor and does not accept `interval`.
`monthly_safe` requires `day_of_month` from 1 through 31 and clamps safely to
the last day of short months.

## Read models and columns

Authenticated clients retain RLS-scoped `SELECT` access to the following
tables. Writes remain service-role-only through the Edge Function.

`task_definitions`:

```text
id, provenance, household_id, content_id, content_version, title, category,
default_obligation_class, instructions_content_ref, default_effort,
default_time_policy, metadata, revision, created_at, created_by, updated_at,
updated_by, deleted_at, deleted_by
```

`task_schedules`:

```text
id, household_id, pet_id, task_definition_id, recurrence, assignment_kind,
assignment_user_id, origin, obligation_class, reminder_config,
active_range_start_date, active_range_until, status, supersedes_schedule_id,
origin_ref, revision, created_at, created_by, updated_at, updated_by,
deleted_at, deleted_by
```

`task_occurrences`:

```text
id, occurrence_key, household_id, pet_id, schedule_id, local_due_date,
original_local_due_date, time_policy, due_time, window_ref, assignment_kind,
assignment_user_id, state, obligation_class, origin, origin_ref,
title_override, revision, created_at, created_by, updated_at, updated_by,
deleted_at, deleted_by
```

`dispositions`:

```text
id, household_id, occurrence_id, action, actor_user_id, recorded_at,
effective_at, note, skip_reason, snooze_until, reschedule_to, media_refs,
client_idempotency_key, superseded, device_metadata, sync_metadata, created_at
```

`notification_candidates` (recipient-only RLS):

```text
id, recipient_user_id, household_id, occurrence_id, class, source_ref,
scheduled_for, dedupe_key, state, resolved_at, resolution_reason,
created_at, updated_at
```

## Invitations (E02)

`create_invitation` is owner-only. The share token is generated server-side
and stored only as a SHA-256 hash, so the plaintext `token` appears **once**,
in the live create response — it is not written to `command_log`, and an
idempotent replay returns the same invitation with `token` absent and
`token_returned_once: true`. Clients must redact the token from any log and
must not queue invitation commands offline. `accept_invitation` and
`decline_invitation` carry the token in the payload; the edge function
redacts it before the command is logged.

Acceptance is single-use and atomic: it creates exactly one active membership
or changes nothing. Re-submitting a completed acceptance by the same user
returns the original result (DM 10 §7.4). Every outcome has its own code so
ON-05 can explain itself:

| Code | HTTP | Meaning |
| --- | --- | --- |
| `INVITATION_NOT_FOUND` | 404 | The token matches no invitation |
| `INVITATION_EXPIRED` | 410 | Past `expires_at` |
| `INVITATION_ALREADY_RESOLVED` | 409 | Already accepted, declined, or revoked |
| `ALREADY_A_MEMBER` | 409 | The caller is already active in that household |
| `HOUSEHOLD_CLOSED` | 409 | The household is closed |
| `SINGLE_HOUSEHOLD_LIMIT` | 409 | The caller is already active in another household |

Pre-acceptance disclosure uses the read-only RPC
`invitation_preview(token_input)`, callable by any authenticated user. It
returns `status` plus **only** `household_name`, `inviter_display_name`,
`expires_at`, and `role_granted` (DM 10 §7.4), and returns
`{"status":"not_found"}` alone for an unknown token. Statuses are `valid`,
`expired`, `revoked`, `declined`, `already_used`, `accepted_by_you`,
`already_member`, `household_closed`, `other_household`, `not_found`.

Additional read models:

`household_invitations` — `token_hash` is **not** granted to clients; select
the explicit column list `id, household_id, created_by, role_granted,
expires_at, status, accepted_by, resolved_at, created_at, updated_at,
updated_by`. A row can still read `pending` after its expiry (there is no
sweeper job), so treat `status = 'pending' and expires_at <= now()` as
expired, exactly as the server does.

`household_member_profiles` (view) — `membership_id, household_id, user_id,
role, status, joined_at, ended_at, display_name, user_status`. This is the
only way to resolve another member's display name; `user_profiles` RLS stays
self-only.

## Behavioral invariants

- A rescheduled occurrence retains its `id`, `occurrence_key`, and
  `original_local_due_date`; only its active due placement changes.
- Snooze is an annotation for a later instant on the same household-local
  date. It does not change the due date, occurrence revision, or frozen plan
  identity.
- A this-and-future edit supersedes the old schedule at `split_date - 1`,
  cancels its future occurrences, creates a linked successor, and materializes
  successor occurrences without rewriting earlier history.
- Complete, cancel, reschedule, archive, and undo actions reconcile scheduled
  notification candidates. Exact-time candidates obey household time zones.
- Nonexistent DST wall times resolve to the first valid instant after the gap;
  repeated wall times resolve to the first occurrence.
- Interval-after-completion schedules keep one next ordinal based on the
  earliest effective completion. Concurrent/replayed completions do not
  duplicate it; undo cancels the derived next ordinal.
- Optimistic writes use `expected_revision`; stale values fail with
  `REVISION_CONFLICT`.
- An active household always keeps at least one active owner: removing or
  demoting the last one is rejected by a database trigger, not only by the
  write path.

## Local migration and verification

From the repository root:

```sh
supabase start
supabase db reset
bash supabase/tests/run.sh
```

The runner derives `project_id` from `supabase/config.toml` and targets only
`supabase_db_petcompanion`. It runs the RLS, invariant, core-command,
generation-lifecycle, daily-coordination, and household-invitation suites.
Each suite rolls back its fixtures.
