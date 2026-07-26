-- Slice A command tests. Entire suite rolls back.
\set ON_ERROR_STOP on
begin;

create schema test_commands;
create table test_commands.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);

create or replace function test_commands.record(p_name text, p_passed boolean, p_detail text default null)
returns void
language plpgsql
as $$
begin
  insert into test_commands.results(name, passed, detail) values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %', case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_commands.assert_true(p_name text, p_condition boolean, p_detail text default null)
returns void
language plpgsql
as $$
begin
  perform test_commands.record(p_name, coalesce(p_condition, false), p_detail);
end;
$$;

create or replace function test_commands.expect_sqlstate(p_name text, p_statement text, p_sqlstate text)
returns void
language plpgsql
as $$
begin
  begin
    execute p_statement;
    perform test_commands.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_commands.record(
      p_name,
      sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
)
values
  ('a1000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'commands-member@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('a1000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'commands-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.households (
  id, name, time_zone, status, default_capacity_mode, created_by, updated_by
)
values (
  'a2000000-0000-0000-0000-000000000001', 'Commands Household', 'America/Toronto',
  'active', 'normal', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001'
);

insert into public.household_memberships (
  id, household_id, user_id, role, status, joined_at, created_by, updated_by
)
values (
  'a3000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001', 'owner', 'active', now(),
  'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001'
);

insert into public.household_preferences (
  household_id, created_by, updated_by
)
values (
  'a2000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001'
);

insert into public.pets (
  id, household_id, name, species, birth_date_kind, birth_date, status, created_by, updated_by
)
values
  ('a4000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001',
   'Active Pup', 'dog', 'exact', '2026-01-01', 'active',
   'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001'),
  ('a4000000-0000-0000-0000-000000000002', 'a2000000-0000-0000-0000-000000000001',
   'Archived Pup', 'dog', 'exact', '2026-01-01', 'archived',
   'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001');

-- 1. Routine preferences: happy path and replay.
select public.write_path_set_routine_preferences(
  'a1000000-0000-0000-0000-000000000001', 'commands-pref-1', 'hash-pref-1',
  '{"command":"set_routine_preferences"}',
  '2026-07-26 12:00:00+00', null,
  '{"household_id":"a2000000-0000-0000-0000-000000000001","routine_windows":{"morning":{"start":"07:00","end":"09:00"}},"meal_template_ref":"three_meals"}'
);
select test_commands.assert_true(
  'set_routine_preferences updates routine windows and meal template',
  (select routine_windows #>> '{morning,start}' = '07:00' and meal_template_ref = 'three_meals'
   from public.household_preferences where household_id = 'a2000000-0000-0000-0000-000000000001')
);
select public.write_path_set_routine_preferences(
  'a1000000-0000-0000-0000-000000000001', 'commands-pref-1', 'hash-pref-1',
  '{"command":"set_routine_preferences"}',
  '2026-07-26 12:00:00+00', null,
  '{"household_id":"a2000000-0000-0000-0000-000000000001","routine_windows":{"morning":{"start":"07:00","end":"09:00"}},"meal_template_ref":"three_meals"}'
);
select test_commands.assert_true(
  'set_routine_preferences replay creates one command_log row',
  (select count(*) = 1 from public.command_log where actor_user_id = 'a1000000-0000-0000-0000-000000000001' and client_idempotency_key = 'commands-pref-1')
);

-- 2. One-time task: all three layers, deterministic key, and replay.
select public.write_path_create_task(
  'a1000000-0000-0000-0000-000000000001', 'commands-task-1', 'hash-task-1',
  '{"command":"create_task"}',
  '2026-07-26 12:01:00+00', null,
  '{"pet_id":"a4000000-0000-0000-0000-000000000001","title":"Pack puppy bag","local_due_date":"2026-07-27","time_policy":"window","window_ref":"morning","assignment":"anyone","task_definition_id":"a5000000-0000-0000-0000-000000000001","schedule_id":"a6000000-0000-0000-0000-000000000001","occurrence_id":"a7000000-0000-0000-0000-000000000001"}'
);
select test_commands.assert_true(
  'create_task creates a user definition, once schedule, and one pending occurrence',
  (select count(*) = 1 from public.task_definitions where id = 'a5000000-0000-0000-0000-000000000001' and provenance = 'user')
  and (select count(*) = 1 from public.task_schedules where id = 'a6000000-0000-0000-0000-000000000001' and recurrence->>'type' = 'once' and recurrence->>'anchor_date' = '2026-07-27')
  and (select count(*) = 1 from public.task_occurrences where id = 'a7000000-0000-0000-0000-000000000001' and state = 'pending')
);
select test_commands.assert_true(
  'create_task occurrence_key is schedule_id plus original_local_due_date',
  (select occurrence_key = 'a6000000-0000-0000-0000-000000000001:2026-07-27'
   from public.task_occurrences where id = 'a7000000-0000-0000-0000-000000000001')
);
select public.write_path_create_task(
  'a1000000-0000-0000-0000-000000000001', 'commands-task-1', 'hash-task-1',
  '{"command":"create_task"}',
  '2026-07-26 12:01:00+00', null,
  '{"pet_id":"a4000000-0000-0000-0000-000000000001","title":"Pack puppy bag","local_due_date":"2026-07-27","time_policy":"window","window_ref":"morning","assignment":"anyone","task_definition_id":"a5000000-0000-0000-0000-000000000001","schedule_id":"a6000000-0000-0000-0000-000000000001","occurrence_id":"a7000000-0000-0000-0000-000000000001"}'
);
select test_commands.assert_true(
  'create_task replay does not duplicate any task-layer row',
  (select count(*) = 1 from public.task_definitions where id = 'a5000000-0000-0000-0000-000000000001')
  and (select count(*) = 1 from public.task_schedules where id = 'a6000000-0000-0000-0000-000000000001')
  and (select count(*) = 1 from public.task_occurrences where schedule_id = 'a6000000-0000-0000-0000-000000000001')
);

select test_commands.expect_sqlstate(
  'create_task rejects a non-member actor',
  $sql$select public.write_path_create_task(
    'a1000000-0000-0000-0000-000000000002', 'commands-task-outsider', 'hash-outsider',
    '{"command":"create_task"}', '2026-07-26 12:02:00+00', null,
    '{"pet_id":"a4000000-0000-0000-0000-000000000001","title":"Forbidden","local_due_date":"2026-07-27","time_policy":"anytime","assignment":"anyone"}'
  )$sql$,
  '42501'
);
select test_commands.expect_sqlstate(
  'create_task rejects an archived pet',
  $sql$select public.write_path_create_task(
    'a1000000-0000-0000-0000-000000000001', 'commands-task-archived', 'hash-archived',
    '{"command":"create_task"}', '2026-07-26 12:02:00+00', null,
    '{"pet_id":"a4000000-0000-0000-0000-000000000002","title":"Archived","local_due_date":"2026-07-27","time_policy":"anytime","assignment":"anyone"}'
  )$sql$,
  '22023'
);

-- 3. Completion convergence: a later-arriving earlier effective time wins.
select public.write_path_complete_occurrence(
  'a1000000-0000-0000-0000-000000000001', 'commands-complete-1', 'hash-complete-1',
  '{"command":"complete_occurrence"}',
  '2026-07-26 12:10:00+00', '2026-07-26 12:05:00+00',
  '{"occurrence_id":"a7000000-0000-0000-0000-000000000001","note":"first arrival"}'
);
select public.write_path_complete_occurrence(
  'a1000000-0000-0000-0000-000000000001', 'commands-complete-2', 'hash-complete-2',
  '{"command":"complete_occurrence"}',
  '2026-07-26 12:11:00+00', '2026-07-26 12:04:00+00',
  '{"occurrence_id":"a7000000-0000-0000-0000-000000000001","note":"earlier completion"}'
);
select test_commands.assert_true(
  'complete-twice convergence retains both and makes earliest effective_at effective',
  (select count(*) = 2 from public.dispositions where occurrence_id = 'a7000000-0000-0000-0000-000000000001' and action = 'complete')
  and (select count(*) = 1 from public.dispositions where occurrence_id = 'a7000000-0000-0000-0000-000000000001' and action = 'complete' and not superseded)
  and (select effective_at = '2026-07-26 12:04:00+00' from public.dispositions where occurrence_id = 'a7000000-0000-0000-0000-000000000001' and action = 'complete' and not superseded)
  and (select state = 'completed' from public.task_occurrences where id = 'a7000000-0000-0000-0000-000000000001')
);
select public.write_path_complete_occurrence(
  'a1000000-0000-0000-0000-000000000001', 'commands-complete-2', 'hash-complete-2',
  '{"command":"complete_occurrence"}',
  '2026-07-26 12:11:00+00', '2026-07-26 12:04:00+00',
  '{"occurrence_id":"a7000000-0000-0000-0000-000000000001","note":"earlier completion"}'
);
select test_commands.assert_true(
  'complete_occurrence replay creates no duplicate disposition',
  (select count(*) = 1 from public.dispositions where actor_user_id = 'a1000000-0000-0000-0000-000000000001' and client_idempotency_key = 'commands-complete-2')
);

-- 4. Undo supersedes the effective completion, audits, then re-completion
-- starts a new convergence epoch even if an older historical completion exists.
select public.write_path_undo_completion(
  'a1000000-0000-0000-0000-000000000001', 'commands-undo-1', 'hash-undo-1',
  '{"command":"undo_completion"}',
  '2026-07-26 12:12:00+00', null,
  '{"occurrence_id":"a7000000-0000-0000-0000-000000000001","note":"logged against wrong task"}'
);
select test_commands.assert_true(
  'undo_completion appends undo, clears effective completion, and returns pending',
  (select count(*) = 1 from public.dispositions where occurrence_id = 'a7000000-0000-0000-0000-000000000001' and action = 'undo_complete')
  and (select count(*) = 0 from public.dispositions where occurrence_id = 'a7000000-0000-0000-0000-000000000001' and action = 'complete' and not superseded)
  and (select state = 'pending' from public.task_occurrences where id = 'a7000000-0000-0000-0000-000000000001')
);
select test_commands.assert_true(
  'undo_completion writes the mandatory completion-correction audit event',
  (select count(*) = 1 from public.audit_events where action = 'completion.undone' and entity_ref->>'id' = 'a7000000-0000-0000-0000-000000000001')
);
select public.write_path_complete_occurrence(
  'a1000000-0000-0000-0000-000000000001', 'commands-complete-3', 'hash-complete-3',
  '{"command":"complete_occurrence"}',
  '2026-07-26 12:13:00+00', '2026-07-26 12:06:00+00',
  '{"occurrence_id":"a7000000-0000-0000-0000-000000000001"}'
);
select test_commands.assert_true(
  're-complete after undo creates exactly one new effective completion',
  (select count(*) = 1 from public.dispositions where occurrence_id = 'a7000000-0000-0000-0000-000000000001' and action = 'complete' and not superseded)
  and (select client_idempotency_key = 'commands-complete-3' from public.dispositions where occurrence_id = 'a7000000-0000-0000-0000-000000000001' and action = 'complete' and not superseded)
  and (select state = 'completed' from public.task_occurrences where id = 'a7000000-0000-0000-0000-000000000001')
);

-- 5. Skip: non-required is frictionless; required needs typed confirmation.
insert into public.task_occurrences (
  id, occurrence_key, household_id, pet_id, schedule_id, local_due_date,
  original_local_due_date, time_policy, assignment_kind, state,
  obligation_class, origin, created_by, updated_by
)
values
  ('a7000000-0000-0000-0000-000000000002', 'a6000000-0000-0000-0000-000000000001:2026-07-28',
   'a2000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000001',
   'a6000000-0000-0000-0000-000000000001', '2026-07-28', '2026-07-28', 'anytime',
   'anyone', 'pending', 'scheduled', 'user_created',
   'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001'),
  ('a7000000-0000-0000-0000-000000000003', 'a6000000-0000-0000-0000-000000000001:2026-07-29',
   'a2000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000001',
   'a6000000-0000-0000-0000-000000000001', '2026-07-29', '2026-07-29', 'anytime',
   'anyone', 'pending', 'required', 'user_created',
   'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001');

select public.write_path_skip_item(
  'a1000000-0000-0000-0000-000000000001', 'commands-skip-normal', 'hash-skip-normal',
  '{"command":"skip_item"}',
  '2026-07-26 12:14:00+00', null,
  '{"occurrence_id":"a7000000-0000-0000-0000-000000000002","skip_reason":"too_busy"}'
);
select test_commands.assert_true(
  'skip_item is frictionless for non-required occurrences',
  (select state = 'skipped' from public.task_occurrences where id = 'a7000000-0000-0000-0000-000000000002')
  and (select count(*) = 1 from public.dispositions where occurrence_id = 'a7000000-0000-0000-0000-000000000002' and action = 'skip' and skip_reason = 'too_busy')
);
select test_commands.expect_sqlstate(
  'skip_item returns typed REQUIRED_CONFIRMATION for required occurrence without confirmation',
  $sql$select public.write_path_skip_item(
    'a1000000-0000-0000-0000-000000000001', 'commands-skip-required-no', 'hash-skip-required-no',
    '{"command":"skip_item"}', '2026-07-26 12:15:00+00', null,
    '{"occurrence_id":"a7000000-0000-0000-0000-000000000003","skip_reason":"not_relevant_today"}'
  )$sql$,
  'PC001'
);
select public.write_path_skip_item(
  'a1000000-0000-0000-0000-000000000001', 'commands-skip-required-yes', 'hash-skip-required-yes',
  '{"command":"skip_item"}',
  '2026-07-26 12:16:00+00', null,
  '{"occurrence_id":"a7000000-0000-0000-0000-000000000003","skip_reason":"not_relevant_today","confirm_required":true}'
);
select test_commands.assert_true(
  'skip_item accepts an explicitly confirmed required occurrence',
  (select state = 'skipped' from public.task_occurrences where id = 'a7000000-0000-0000-0000-000000000003')
  and (select count(*) = 1 from public.dispositions where occurrence_id = 'a7000000-0000-0000-0000-000000000003' and action = 'skip')
);

do $$
declare
  failed_count integer;
begin
  select count(*) into failed_count from test_commands.results where not passed;
  if failed_count > 0 then
    raise exception '% command assertion(s) failed', failed_count;
  end if;
end;
$$;

rollback;
