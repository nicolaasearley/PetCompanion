# Slice B daily-coordination backend contract

This is the client handoff for migrations
`202607270001_slice_b_coordination_foundation.sql` and
`202607270002_slice_b_coordination_commands.sql`.

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

## Local migration and verification

From the repository root:

```sh
supabase start
supabase db reset
bash supabase/tests/run.sh
```

The runner derives `project_id` from `supabase/config.toml` and targets only
`supabase_db_petcompanion`. It runs the RLS, invariant, core-command,
generation-lifecycle, and daily-coordination suites. Each suite rolls back its
fixtures.
