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
select test_commands.assert_true(
  'set_routine_preferences materializes the reviewed daily routine schedules',
  (select count(*) = 6
   from public.task_schedules
   where household_id = 'a2000000-0000-0000-0000-000000000001'
     and pet_id = 'a4000000-0000-0000-0000-000000000001'
     and status = 'active'
     and origin_ref->>'routine_managed' = 'true')
);

select public.write_path_set_routine_preferences(
  'a1000000-0000-0000-0000-000000000001', 'commands-pref-2', 'hash-pref-2',
  '{"command":"set_routine_preferences"}',
  '2026-07-26 12:00:30+00', null,
  '{"household_id":"a2000000-0000-0000-0000-000000000001","routine_windows":{"morning":{"start_hour":6,"end_hour":9},"midday":{"start_hour":11,"end_hour":13},"evening":{"start_hour":17,"end_hour":21},"sleep":{"start_hour":22,"end_hour":6},"meals_per_day":2}}'
);
select test_commands.assert_true(
  'routine update normalizes iOS time bands and supersedes managed schedules',
  (select routine_windows #>> '{morning,start}' = '06:00'
      and routine_windows #>> '{sleep,end}' = '06:00'
      and meal_template_ref = '2_meals'
   from public.household_preferences
   where household_id = 'a2000000-0000-0000-0000-000000000001')
  and (select count(*) = 5
       from public.task_schedules
       where pet_id = 'a4000000-0000-0000-0000-000000000001'
         and status = 'active'
         and origin_ref->>'routine_managed' = 'true')
  and (select count(*) = 6
       from public.task_schedules
       where pet_id = 'a4000000-0000-0000-0000-000000000001'
         and status = 'archived'
         and origin_ref->>'routine_managed' = 'true')
);

select public.write_path_set_default_capacity(
  'a1000000-0000-0000-0000-000000000001', 'commands-capacity-1', 'hash-capacity-1',
  '{"command":"set_default_capacity"}',
  '2026-07-26 12:00:45+00', null,
  '{"household_id":"a2000000-0000-0000-0000-000000000001","default_capacity_mode":"busy"}'
);
select test_commands.assert_true(
  'set_default_capacity durably updates household and generation preference',
  (select default_capacity_mode = 'busy' from public.households
   where id = 'a2000000-0000-0000-0000-000000000001')
  and (select default_capacity_mode = 'busy' from public.household_preferences
       where household_id = 'a2000000-0000-0000-0000-000000000001')
  and (select count(*) = 1 from public.audit_events
       where household_id = 'a2000000-0000-0000-0000-000000000001'
         and action = 'capacity.default_changed')
);

select public.write_path_create_pet(
  'a1000000-0000-0000-0000-000000000001', 'commands-pet-unknown', 'hash-pet-unknown',
  '{"command":"create_pet"}',
  '2026-07-26 12:00:50+00', null,
  '{"id":"a4000000-0000-0000-0000-000000000003","household_id":"a2000000-0000-0000-0000-000000000001","name":"Future Pup","species":"dog","birth_date_kind":"unknown","homecoming_date":"2026-08-15"}'
);
select test_commands.assert_true(
  'create_pet preserves an explicitly unknown birth date without false precision',
  (select birth_date_kind::text = 'unknown'
      and birth_date is null
      and estimated_age_weeks is null
      and estimated_as_of_date is null
   from public.pets where id = 'a4000000-0000-0000-0000-000000000003')
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

-- 6. A recommendation completion is promoted to the uniform task model.
insert into public.plans (
  id, household_id, pet_id, local_date, time_zone_snapshot, stage_snapshot,
  capacity_mode_applied, catalogue_version_set, input_digest, status,
  created_by, updated_by
) values (
  'a8000000-0000-0000-0000-000000000001',
  'a2000000-0000-0000-0000-000000000001',
  'a4000000-0000-0000-0000-000000000001',
  '2026-07-26', 'America/Toronto', '{"stage_key":"foundations"}',
  'busy', '[]', 'commands-rec-plan', 'open',
  'a1000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001'
);
insert into public.plan_items (
  id, plan_id, item_key, kind, recommendation_rule_ref, content_ref, title,
  category, obligation_class, priority_tier, section, time_window, effort_band,
  explanation_text, display_state, origin
) values (
  'a9000000-0000-0000-0000-000000000001',
  'a8000000-0000-0000-0000-000000000001',
  'recommendation:commands-test', 'recommendation',
  '{"content_id":"rule.brushing","version":1}',
  '{"content_id":"care.brushing","version":1}',
  'Try a calm brushing session', 'grooming', 'recommended', 'P3',
  'recommended', 'evening', 'tiny', 'A calm minute is enough.',
  'planned', 'development_rule'
);

select public.write_path_accept_recommendation(
  'a1000000-0000-0000-0000-000000000001',
  'commands-accept-rec-1', 'hash-accept-rec-1',
  '{"command":"accept_recommendation"}',
  '2026-07-26 12:20:00+00', null,
  '{"plan_item_id":"a9000000-0000-0000-0000-000000000001","complete":true,"pinned":false}'
);
select test_commands.assert_true(
  'accept_recommendation promotes and completes through task/disposition history',
  (select kind = 'obligation'
      and occurrence_id is not null
      and recommendation_rule_ref is null
      and display_state = 'completed'
      and section = 'completed'
   from public.plan_items where id = 'a9000000-0000-0000-0000-000000000001')
  and (select count(*) = 1
       from public.task_occurrences o
       join public.plan_items pi on pi.occurrence_id = o.id
       where pi.id = 'a9000000-0000-0000-0000-000000000001'
         and o.state = 'completed')
  and (select count(*) = 1
       from public.dispositions d
       join public.plan_items pi on pi.occurrence_id = d.occurrence_id
       where pi.id = 'a9000000-0000-0000-0000-000000000001'
         and d.action = 'complete'
         and not d.superseded)
  and (select recommendations_frozen_at is not null
       from public.plans where id = 'a8000000-0000-0000-0000-000000000001')
);
select public.write_path_accept_recommendation(
  'a1000000-0000-0000-0000-000000000001',
  'commands-accept-rec-1', 'hash-accept-rec-1',
  '{"command":"accept_recommendation"}',
  '2026-07-26 12:20:00+00', null,
  '{"plan_item_id":"a9000000-0000-0000-0000-000000000001","complete":true,"pinned":false}'
);
select test_commands.assert_true(
  'accept_recommendation replay does not duplicate promoted task rows',
  (select count(*) = 1 from public.task_occurrences o
   join public.plan_items pi on pi.occurrence_id = o.id
   where pi.id = 'a9000000-0000-0000-0000-000000000001')
  and (select count(*) = 1 from public.command_log
       where actor_user_id = 'a1000000-0000-0000-0000-000000000001'
         and client_idempotency_key = 'commands-accept-rec-1')
);

-- Undoing a completion must return the item to Today. The derivative trigger
-- used to move an item into the Completed section on completion and then fall
-- through to the existing section for every other state, so the section was
-- sticky: an undone item stayed collapsed under Completed, and skipping it
-- afterwards left a skipped item sitting in Completed.
select test_commands.assert_true(
  'a completed promotion sits in the completed section',
  (select section = 'completed' and display_state = 'completed' and completion is not null
   from public.plan_items where id = 'a9000000-0000-0000-0000-000000000001')
);
do $$
declare
  promoted_occurrence uuid;
begin
  select occurrence_id into promoted_occurrence
  from public.plan_items where id = 'a9000000-0000-0000-0000-000000000001';

  perform public.write_path_undo_completion(
    'a1000000-0000-0000-0000-000000000001',
    'commands-undo-promoted', 'hash-undo-promoted',
    '{"command":"undo_completion"}'::jsonb,
    '2026-07-26 12:25:00+00'::timestamptz, null,
    jsonb_build_object('occurrence_id', promoted_occurrence)
  );
end;
$$;
select test_commands.assert_true(
  'undo_completion returns the plan item to today rather than stranding it in completed',
  (select section = 'today' and display_state = 'planned' and completion is null
   from public.plan_items where id = 'a9000000-0000-0000-0000-000000000001')
  and (select state = 'pending' from public.task_occurrences o
       join public.plan_items pi on pi.occurrence_id = o.id
       where pi.id = 'a9000000-0000-0000-0000-000000000001')
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
