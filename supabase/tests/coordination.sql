-- Slice B daily-coordination tests. Entire suite rolls back.
\set ON_ERROR_STOP on
begin;

create schema test_coordination;
create table test_coordination.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create or replace function test_coordination.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_coordination.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;
create or replace function test_coordination.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin perform test_coordination.record(p_name, coalesce(p_condition, false), p_detail); end;
$$;
create or replace function test_coordination.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_coordination.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_coordination.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('c1000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'coord-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('c1000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'coord-partner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);
insert into public.user_profiles(id, display_name) values
  ('c1000000-0000-4000-8000-000000000001', 'Owner'),
  ('c1000000-0000-4000-8000-000000000002', 'Partner');
insert into public.households (
  id, name, time_zone, created_by, updated_by
) values (
  'c2000000-0000-4000-8000-000000000001', 'Coordination House',
  'America/Toronto', 'c1000000-0000-4000-8000-000000000001',
  'c1000000-0000-4000-8000-000000000001'
);
insert into public.household_memberships (
  household_id, user_id, role, status, joined_at, created_by, updated_by
) values
  ('c2000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001',
   'owner', 'active', now(), 'c1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001'),
  ('c2000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000002',
   'caregiver', 'active', now(), 'c1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001');
insert into public.household_preferences(household_id, created_by, updated_by)
values (
  'c2000000-0000-4000-8000-000000000001',
  'c1000000-0000-4000-8000-000000000001',
  'c1000000-0000-4000-8000-000000000001'
);
insert into public.pets (
  id, household_id, name, species, birth_date_kind, birth_date,
  created_by, updated_by
) values (
  'c3000000-0000-4000-8000-000000000001',
  'c2000000-0000-4000-8000-000000000001', 'Maple', 'dog',
  'exact', '2026-08-01',
  'c1000000-0000-4000-8000-000000000001',
  'c1000000-0000-4000-8000-000000000001'
);

-- Fixed DST policy: nonexistent wall time moves to the first valid minute;
-- repeated wall time selects the first occurrence.
select test_coordination.assert_true(
  'DST spring gap resolves to the first valid instant after the missing wall time',
  public.resolve_household_wall_time('2026-03-08', '02:30', 'America/Toronto')
    = '2026-03-08 07:00:00+00'
);
select test_coordination.assert_true(
  'DST fall overlap resolves to the first occurrence',
  public.resolve_household_wall_time('2026-11-01', '01:30', 'America/Toronto')
    = '2026-11-01 05:30:00+00'
);
select test_coordination.assert_true(
  'recurrence validation rejects unsupported weekdays and accepts finite safe rules',
  not public.recurrence_rule_is_valid(
    '{"type":"weekdays","anchor_date":"2026-11-01","weekdays":["funday"],"time_policy":"anytime"}'
  )
  and public.recurrence_rule_is_valid(
    '{"type":"monthly_safe","anchor_date":"2026-01-31","day_of_month":31,"count":3,"time_policy":"exact_time","exact_time":"08:00"}'
  )
);

-- Daily exact-time routine: 14 deterministic occurrences and two candidates
-- per occurrence (one per active caregiver).
select public.write_path_create_recurring_task(
  'c1000000-0000-4000-8000-000000000001', 'coord-create-daily', 'hash-create-daily',
  '{"command":"create_recurring_task"}', '2026-11-01 13:00:00+00', null,
  '{
    "pet_id":"c3000000-0000-4000-8000-000000000001",
    "title":"Morning check-in",
    "recurrence":{"type":"daily","anchor_date":"2026-11-01","time_policy":"exact_time","exact_time":"09:00"},
    "assignment":"anyone",
    "reminder_config":{"lead_minutes":[0]},
    "task_definition_id":"c4000000-0000-4000-8000-000000000001",
    "schedule_id":"c5000000-0000-4000-8000-000000000001"
  }'
);
select test_coordination.assert_true(
  'create_recurring_task returns one occurrence per due day with stable keys',
  (select count(*) = 14 from public.task_occurrences
   where schedule_id = 'c5000000-0000-4000-8000-000000000001')
  and (select count(*) = 14 from (
    select distinct occurrence_key from public.task_occurrences
    where schedule_id = 'c5000000-0000-4000-8000-000000000001'
  ) keys)
  and (select count(*) = 28 from public.notification_candidates nc
       join public.task_occurrences o on o.id = nc.occurrence_id
       where o.schedule_id = 'c5000000-0000-4000-8000-000000000001'
         and nc.state = 'scheduled')
);
select public.write_path_create_recurring_task(
  'c1000000-0000-4000-8000-000000000001', 'coord-create-daily', 'hash-create-daily',
  '{"command":"create_recurring_task"}', '2026-11-01 13:00:00+00', null,
  '{
    "pet_id":"c3000000-0000-4000-8000-000000000001",
    "title":"Morning check-in",
    "recurrence":{"type":"daily","anchor_date":"2026-11-01","time_policy":"exact_time","exact_time":"09:00"},
    "assignment":"anyone",
    "reminder_config":{"lead_minutes":[0]},
    "task_definition_id":"c4000000-0000-4000-8000-000000000001",
    "schedule_id":"c5000000-0000-4000-8000-000000000001"
  }'
);
select test_coordination.assert_true(
  'recurring creation replay is idempotent across definitions schedules occurrences and candidates',
  (select count(*) = 1 from public.task_definitions where id = 'c4000000-0000-4000-8000-000000000001')
  and (select count(*) = 1 from public.task_schedules where id = 'c5000000-0000-4000-8000-000000000001')
  and (select count(*) = 14 from public.task_occurrences where schedule_id = 'c5000000-0000-4000-8000-000000000001')
  and (select count(*) = 1 from public.command_log where client_idempotency_key = 'coord-create-daily')
);

-- Give the first occurrence a plan item so action-derived presentation and
-- recommendation freezing are exercised.
insert into public.plans (
  id, household_id, pet_id, local_date, time_zone_snapshot, stage_snapshot,
  capacity_mode_applied, catalogue_version_set, input_digest, created_by, updated_by
) values (
  'c6000000-0000-4000-8000-000000000001',
  'c2000000-0000-4000-8000-000000000001',
  'c3000000-0000-4000-8000-000000000001', '2026-11-01',
  'America/Toronto', '{"stage_key":"foundations"}', 'normal', '[]', 'coord-plan',
  'c1000000-0000-4000-8000-000000000001',
  'c1000000-0000-4000-8000-000000000001'
);
insert into public.plan_items (
  id, plan_id, item_key, kind, occurrence_id, title, category,
  obligation_class, priority_tier, section, due_time, display_state, origin
) select
  'c7000000-0000-4000-8000-000000000001',
  'c6000000-0000-4000-8000-000000000001',
  'occ:' || occurrence_key, 'obligation', id, 'Morning check-in', 'routine',
  'scheduled', 'P2', 'today', due_time, 'planned', 'user_created'
from public.task_occurrences
where schedule_id = 'c5000000-0000-4000-8000-000000000001'
  and local_due_date = '2026-11-01';

select public.write_path_snooze_occurrence(
  'c1000000-0000-4000-8000-000000000001', 'coord-snooze', 'hash-snooze',
  '{"command":"snooze_occurrence"}', '2026-11-01 14:00:00+00', null,
  jsonb_build_object(
    'occurrence_id', (
      select id from public.task_occurrences
      where schedule_id = 'c5000000-0000-4000-8000-000000000001'
        and local_due_date = '2026-11-01'
    ),
    'snooze_until', '2026-11-01T16:00:00Z'
  )
);
select test_coordination.assert_true(
  'same-day snooze keeps occurrence pending, freezes plan, and replaces candidates',
  (select state = 'pending' from public.task_occurrences
   where schedule_id = 'c5000000-0000-4000-8000-000000000001'
     and local_due_date = '2026-11-01')
  and (select display_state = 'snoozed' from public.plan_items
       where id = 'c7000000-0000-4000-8000-000000000001')
  and (select recommendations_frozen_at is not null from public.plans
       where id = 'c6000000-0000-4000-8000-000000000001')
  and (select count(*) = 2 from public.notification_candidates nc
       join public.task_occurrences o on o.id = nc.occurrence_id
       where o.schedule_id = 'c5000000-0000-4000-8000-000000000001'
         and o.local_due_date = '2026-11-01'
         and nc.class = 'task_snooze' and nc.state = 'scheduled')
  and (select count(*) = 2 from public.notification_candidates nc
       join public.task_occurrences o on o.id = nc.occurrence_id
       where o.schedule_id = 'c5000000-0000-4000-8000-000000000001'
         and o.local_due_date = '2026-11-01'
         and nc.class = 'task_due' and nc.state = 'cancelled')
);
select test_coordination.expect_sqlstate(
  'snooze rejects a next-day instant',
  $sql$select public.write_path_snooze_occurrence(
    'c1000000-0000-4000-8000-000000000001', 'coord-snooze-bad', 'hash',
    '{"command":"snooze_occurrence"}', '2026-11-01 14:00:00+00', null,
    jsonb_build_object(
      'occurrence_id', (
        select id from public.task_occurrences
        where schedule_id = 'c5000000-0000-4000-8000-000000000001'
          and local_due_date = '2026-11-01'
      ),
      'snooze_until', '2026-11-02T16:00:00Z'
    )
  )$sql$, '22023'
);

-- One occurrence moves without changing its identity or the rest of the series.
select public.write_path_reschedule_occurrence(
  'c1000000-0000-4000-8000-000000000001', 'coord-reschedule', 'hash-reschedule',
  '{"command":"reschedule_occurrence"}', '2026-11-01 14:10:00+00', null,
  jsonb_build_object(
    'occurrence_id', (
      select id from public.task_occurrences
      where schedule_id = 'c5000000-0000-4000-8000-000000000001'
        and original_local_due_date = '2026-11-01'
    ),
    'expected_revision', 1,
    'local_due_date', '2026-11-03',
    'time_policy', 'exact_time',
    'exact_time', '10:00'
  )
);
select test_coordination.assert_true(
  'occurrence-only reschedule preserves key/original date and refreshes notifications',
  (select local_due_date = '2026-11-03'
      and original_local_due_date = '2026-11-01'
      and occurrence_key = 'c5000000-0000-4000-8000-000000000001:2026-11-01'
      and revision = 2
   from public.task_occurrences
   where schedule_id = 'c5000000-0000-4000-8000-000000000001'
     and original_local_due_date = '2026-11-01')
  and (select count(*) = 2 from public.notification_candidates nc
       join public.task_occurrences o on o.id = nc.occurrence_id
       where o.schedule_id = 'c5000000-0000-4000-8000-000000000001'
         and o.original_local_due_date = '2026-11-01'
         and nc.class = 'task_due' and nc.state = 'scheduled'
         and nc.scheduled_for = '2026-11-03 15:00:00+00')
  and (select display_state = 'rescheduled' from public.plan_items
       where id = 'c7000000-0000-4000-8000-000000000001')
);
select test_coordination.expect_sqlstate(
  'stale occurrence revision is rejected without partial mutation',
  $sql$select public.write_path_reschedule_occurrence(
    'c1000000-0000-4000-8000-000000000001', 'coord-reschedule-stale', 'hash',
    '{"command":"reschedule_occurrence"}', '2026-11-01 14:11:00+00', null,
    jsonb_build_object(
      'occurrence_id', (
        select id from public.task_occurrences
        where schedule_id = 'c5000000-0000-4000-8000-000000000001'
          and original_local_due_date = '2026-11-01'
      ),
      'expected_revision', 1, 'local_due_date', '2026-11-04'
    )
  )$sql$, '40001'
);

-- Skip/undo-skip remains append-only, idempotent, and returns the same
-- occurrence to active state.
select public.write_path_skip_item(
  'c1000000-0000-4000-8000-000000000001', 'coord-skip', 'hash-skip',
  '{"command":"skip_item"}', '2026-11-01 14:20:00+00', null,
  jsonb_build_object(
    'occurrence_id', (
      select id from public.task_occurrences
      where schedule_id = 'c5000000-0000-4000-8000-000000000001'
        and original_local_due_date = '2026-11-01'
    ),
    'skip_reason', 'too_busy'
  )
);
select public.write_path_undo_skip(
  'c1000000-0000-4000-8000-000000000001', 'coord-undo-skip', 'hash-undo-skip',
  '{"command":"undo_skip"}', '2026-11-01 14:21:00+00', null,
  jsonb_build_object(
    'occurrence_id', (
      select id from public.task_occurrences
      where schedule_id = 'c5000000-0000-4000-8000-000000000001'
        and original_local_due_date = '2026-11-01'
    )
  )
);
select public.write_path_undo_skip(
  'c1000000-0000-4000-8000-000000000001', 'coord-undo-skip', 'hash-undo-skip',
  '{"command":"undo_skip"}', '2026-11-01 14:21:00+00', null,
  jsonb_build_object(
    'occurrence_id', (
      select id from public.task_occurrences
      where schedule_id = 'c5000000-0000-4000-8000-000000000001'
        and original_local_due_date = '2026-11-01'
    )
  )
);
select test_coordination.assert_true(
  'undo_skip restores pending state once and preserves skip plus correction history',
  (select state = 'pending' from public.task_occurrences
   where schedule_id = 'c5000000-0000-4000-8000-000000000001'
     and original_local_due_date = '2026-11-01')
  and (select count(*) = 1 from public.dispositions d
       join public.task_occurrences o on o.id = d.occurrence_id
       where o.schedule_id = 'c5000000-0000-4000-8000-000000000001'
         and o.original_local_due_date = '2026-11-01'
         and d.action = 'skip' and d.superseded)
  and (select count(*) = 1 from public.dispositions d
       join public.task_occurrences o on o.id = d.occurrence_id
       where o.schedule_id = 'c5000000-0000-4000-8000-000000000001'
         and o.original_local_due_date = '2026-11-01'
         and d.action = 'undo_skip')
);

-- A this-and-future edit is a schedule split: old history remains, stale future
-- occurrences are cancelled, and successor occurrences use a new schedule id.
select public.write_path_edit_schedule_future(
  'c1000000-0000-4000-8000-000000000001', 'coord-split', 'hash-split',
  '{"command":"edit_schedule_future"}', '2026-11-01 14:30:00+00', null,
  '{
    "schedule_id":"c5000000-0000-4000-8000-000000000001",
    "expected_revision":1,
    "split_date":"2026-11-05",
    "recurrence":{"type":"every_n_days","anchor_date":"2026-11-05","interval":2,"time_policy":"window","window_ref":"evening"},
    "title":"Evening check-in",
    "assignment":"member:c1000000-0000-4000-8000-000000000002",
    "successor_schedule_id":"c5000000-0000-4000-8000-000000000002",
    "successor_task_definition_id":"c4000000-0000-4000-8000-000000000002"
  }'
);
select test_coordination.assert_true(
  'this-and-future edit splits schedules and preserves pre-split occurrences',
  (select status = 'superseded' and active_range_until = '2026-11-04' and revision = 2
   from public.task_schedules where id = 'c5000000-0000-4000-8000-000000000001')
  and (select status = 'active'
      and supersedes_schedule_id = 'c5000000-0000-4000-8000-000000000001'
      and recurrence->>'type' = 'every_n_days'
      and assignment_user_id = 'c1000000-0000-4000-8000-000000000002'
   from public.task_schedules where id = 'c5000000-0000-4000-8000-000000000002')
  and (select count(*) = 4 from public.task_occurrences
       where schedule_id = 'c5000000-0000-4000-8000-000000000001'
         and original_local_due_date < '2026-11-05' and state <> 'cancelled')
  and (select count(*) = 10 from public.task_occurrences
       where schedule_id = 'c5000000-0000-4000-8000-000000000001'
         and original_local_due_date >= '2026-11-05' and state = 'cancelled')
  and (select count(*) = 7 from public.task_occurrences
       where schedule_id = 'c5000000-0000-4000-8000-000000000002'
         and state = 'pending')
);
select test_coordination.expect_sqlstate(
  'stale schedule revision is rejected after split',
  $sql$select public.write_path_edit_schedule_future(
    'c1000000-0000-4000-8000-000000000001', 'coord-split-stale', 'hash',
    '{"command":"edit_schedule_future"}', '2026-11-01 14:31:00+00', null,
    '{
      "schedule_id":"c5000000-0000-4000-8000-000000000001",
      "expected_revision":1,
      "split_date":"2026-11-06",
      "recurrence":{"type":"daily","anchor_date":"2026-11-06","time_policy":"anytime"}
    }'
  )$sql$, '40001'
);

select public.write_path_archive_schedule(
  'c1000000-0000-4000-8000-000000000001', 'coord-archive', 'hash-archive',
  '{"command":"archive_schedule"}', '2026-11-01 14:40:00+00', null,
  '{"schedule_id":"c5000000-0000-4000-8000-000000000002","expected_revision":1}'
);
select test_coordination.assert_true(
  'archive_schedule retains history while cancelling active occurrences and notifications',
  (select status = 'archived' and revision = 2 from public.task_schedules
   where id = 'c5000000-0000-4000-8000-000000000002')
  and (select count(*) = 0 from public.task_occurrences
       where schedule_id = 'c5000000-0000-4000-8000-000000000002'
         and state = 'pending')
  and (select count(*) = 0 from public.notification_candidates nc
       join public.task_occurrences o on o.id = nc.occurrence_id
       where o.schedule_id = 'c5000000-0000-4000-8000-000000000002'
         and nc.state = 'scheduled')
);

-- Interval-after-completion keeps exactly one open ordinal and recomputes it
-- when a later-arriving earlier effective completion wins convergence.
select public.write_path_create_recurring_task(
  'c1000000-0000-4000-8000-000000000001', 'coord-create-interval', 'hash-create-interval',
  '{"command":"create_recurring_task"}', '2026-11-01 15:00:00+00', null,
  '{
    "pet_id":"c3000000-0000-4000-8000-000000000001",
    "title":"Wash bedding",
    "recurrence":{"type":"interval_after_completion","anchor_date":"2026-11-01","interval":3,"count":3,"time_policy":"anytime"},
    "assignment":"anyone",
    "task_definition_id":"c4000000-0000-4000-8000-000000000003",
    "schedule_id":"c5000000-0000-4000-8000-000000000003"
  }'
);
select public.write_path_complete_occurrence(
  'c1000000-0000-4000-8000-000000000001', 'coord-interval-complete-1', 'hash-i1',
  '{"command":"complete_occurrence"}',
  '2026-11-01 16:00:00+00', '2026-11-01 15:00:00+00',
  jsonb_build_object(
    'occurrence_id', (select id from public.task_occurrences
      where schedule_id = 'c5000000-0000-4000-8000-000000000003'
        and occurrence_key like '%:ordinal:1')
  )
);
select test_coordination.assert_true(
  'interval completion creates exactly one next ordinal from effective local date',
  (select count(*) = 1 from public.task_occurrences
   where schedule_id = 'c5000000-0000-4000-8000-000000000003'
     and state = 'pending')
  and (select local_due_date = '2026-11-04' and origin_ref->>'interval_ordinal' = '2'
       from public.task_occurrences
       where schedule_id = 'c5000000-0000-4000-8000-000000000003'
         and occurrence_key like '%:ordinal:2')
);
select public.write_path_complete_occurrence(
  'c1000000-0000-4000-8000-000000000002', 'coord-interval-complete-2', 'hash-i2',
  '{"command":"complete_occurrence"}',
  '2026-11-01 16:01:00+00', '2026-10-31 15:00:00+00',
  jsonb_build_object(
    'occurrence_id', (select id from public.task_occurrences
      where schedule_id = 'c5000000-0000-4000-8000-000000000003'
        and occurrence_key like '%:ordinal:1')
  )
);
select test_coordination.assert_true(
  'simultaneous earlier completion wins and moves rather than duplicates interval next',
  (select count(*) = 2 from public.dispositions d
   join public.task_occurrences o on o.id = d.occurrence_id
   where o.schedule_id = 'c5000000-0000-4000-8000-000000000003'
     and o.occurrence_key like '%:ordinal:1' and d.action = 'complete')
  and (select count(*) = 1 from public.dispositions d
       join public.task_occurrences o on o.id = d.occurrence_id
       where o.schedule_id = 'c5000000-0000-4000-8000-000000000003'
         and o.occurrence_key like '%:ordinal:1'
         and d.action = 'complete' and not d.superseded)
  and (select count(*) = 1 from public.task_occurrences
       where schedule_id = 'c5000000-0000-4000-8000-000000000003'
         and occurrence_key like '%:ordinal:2')
  and (select local_due_date = '2026-11-03'
       from public.task_occurrences
       where schedule_id = 'c5000000-0000-4000-8000-000000000003'
         and occurrence_key like '%:ordinal:2')
);
select public.write_path_undo_completion(
  'c1000000-0000-4000-8000-000000000001', 'coord-interval-undo', 'hash-iu',
  '{"command":"undo_completion"}', '2026-11-01 16:02:00+00', null,
  jsonb_build_object(
    'occurrence_id', (select id from public.task_occurrences
      where schedule_id = 'c5000000-0000-4000-8000-000000000003'
        and occurrence_key like '%:ordinal:1')
  )
);
select test_coordination.assert_true(
  'undo interval completion restores current and cancels materialized next ordinal',
  (select state = 'pending' from public.task_occurrences
   where schedule_id = 'c5000000-0000-4000-8000-000000000003'
     and occurrence_key like '%:ordinal:1')
  and (select state = 'cancelled' from public.task_occurrences
       where schedule_id = 'c5000000-0000-4000-8000-000000000003'
         and occurrence_key like '%:ordinal:2')
);

do $$
declare failed_count integer;
begin
  select count(*) into failed_count from test_coordination.results where not passed;
  if failed_count > 0 then
    raise exception '% coordination assertion(s) failed', failed_count;
  end if;
end;
$$;
rollback;
