-- Care medications tests (F10, DM §11.2, docs/12 §22.3, docs/13 Accepted).
--
-- Covers:
--   * create / edit (field-level audit) / archive medication schedules;
--   * dose text stored verbatim;
--   * occurrence from explicit schedule only (interval_after_completion);
--   * complete with recent-partner confirmation (PC001);
--   * RLS isolation; authenticated cannot mutate tables or EXECUTE write_path_*;
--   * unsupported recurrence rejected.
--
-- Does NOT replace write_path_generation_context.
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_meds;
create table test_meds.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create table test_meds.state (key text primary key, value text);

grant usage on schema test_meds to authenticated;
grant select, insert, update on test_meds.results, test_meds.state to authenticated;
grant usage, select on all sequences in schema test_meds to authenticated;

create or replace function test_meds.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_meds.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_meds.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin perform test_meds.record(p_name, coalesce(p_condition, false), p_detail); end;
$$;

create or replace function test_meds.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_meds.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_meds.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

create or replace function test_meds.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_meds.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_meds.val(p_key text)
returns text language sql stable as $$
  select value from test_meds.state where key = p_key;
$$;

-- Fixtures
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('b4440000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'med-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('b4440000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'med-partner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('b4440000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'med-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.user_profiles(id, display_name) values
  ('b4440000-0000-4000-8000-000000000001', 'Nic'),
  ('b4440000-0000-4000-8000-000000000002', 'Sarah'),
  ('b4440000-0000-4000-8000-000000000003', 'Outsider');

insert into public.households (id, name, time_zone, created_by, updated_by) values
  ('b5550000-0000-4000-8000-000000000001', 'Maple House', 'America/Toronto',
   'b4440000-0000-4000-8000-000000000001', 'b4440000-0000-4000-8000-000000000001'),
  ('b5550000-0000-4000-8000-000000000002', 'Elsewhere', 'Europe/Stockholm',
   'b4440000-0000-4000-8000-000000000003', 'b4440000-0000-4000-8000-000000000003');

insert into public.household_memberships (
  household_id, user_id, role, status, joined_at, created_by, updated_by
) values
  ('b5550000-0000-4000-8000-000000000001', 'b4440000-0000-4000-8000-000000000001',
   'owner', 'active', now(), 'b4440000-0000-4000-8000-000000000001', 'b4440000-0000-4000-8000-000000000001'),
  ('b5550000-0000-4000-8000-000000000001', 'b4440000-0000-4000-8000-000000000002',
   'caregiver', 'active', now(), 'b4440000-0000-4000-8000-000000000001', 'b4440000-0000-4000-8000-000000000001'),
  ('b5550000-0000-4000-8000-000000000002', 'b4440000-0000-4000-8000-000000000003',
   'owner', 'active', now(), 'b4440000-0000-4000-8000-000000000003', 'b4440000-0000-4000-8000-000000000003');

insert into public.pets (
  id, household_id, name, birth_date_kind, birth_date, status, created_by, updated_by
) values
  ('b6660000-0000-4000-8000-000000000001', 'b5550000-0000-4000-8000-000000000001',
   'Maple', 'exact', current_date - 80, 'active',
   'b4440000-0000-4000-8000-000000000001', 'b4440000-0000-4000-8000-000000000001'),
  ('b6660000-0000-4000-8000-000000000002', 'b5550000-0000-4000-8000-000000000001',
   'Willow', 'exact', current_date - 200, 'archived',
   'b4440000-0000-4000-8000-000000000001', 'b4440000-0000-4000-8000-000000000001');

insert into public.household_preferences (household_id, created_by, updated_by) values
  ('b5550000-0000-4000-8000-000000000001', 'b4440000-0000-4000-8000-000000000001',
   'b4440000-0000-4000-8000-000000000001'),
  ('b5550000-0000-4000-8000-000000000002', 'b4440000-0000-4000-8000-000000000003',
   'b4440000-0000-4000-8000-000000000003');

-- 1. Create medication (verbatim dose + occurrence)
select test_meds.put(
  'create_1',
  public.write_path_create_medication_schedule(
    'b4440000-0000-4000-8000-000000000001', 'med-create-1', 'hash-med-1',
    '{"command":"create_medication_schedule"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'b6660000-0000-4000-8000-000000000001',
      'medication_schedule_id', 'b7770000-0000-4000-8000-000000000001',
      'medication_name', 'Flea & Tick Prevention',
      'dose_text', '1 pipette as written',
      'provenance', 'owner_entered',
      'recurrence', jsonb_build_object(
        'type', 'interval_after_completion',
        'anchor_date', current_date::text,
        'interval', 30,
        'time_policy', 'anytime'
      )
    )
  )::text
);

select test_meds.assert_true(
  'create stores dose verbatim',
  (select dose_text = '1 pipette as written' and medication_name = 'Flea & Tick Prevention'
   from public.medication_schedules
   where id = 'b7770000-0000-4000-8000-000000000001')
);

select test_meds.assert_true(
  'create owns health_schedule task schedule',
  (select s.origin = 'health_schedule' and s.obligation_class = 'required'
   from public.medication_schedules m
   join public.task_schedules s on s.id = m.task_schedule_id
   where m.id = 'b7770000-0000-4000-8000-000000000001')
);

select test_meds.assert_true(
  'create materializes one pending occurrence',
  (select count(*) = 1
   from public.medication_schedules m
   join public.task_occurrences o on o.schedule_id = m.task_schedule_id
   where m.id = 'b7770000-0000-4000-8000-000000000001'
     and o.state = 'pending')
);

select test_meds.assert_true(
  'create audit event exists',
  (select count(*) = 1 from public.audit_events
   where entity_ref->>'id' = 'b7770000-0000-4000-8000-000000000001'
     and action = 'care.medication_schedule_created')
);

select test_meds.assert_true(
  'create is idempotent',
  public.write_path_create_medication_schedule(
    'b4440000-0000-4000-8000-000000000001', 'med-create-1', 'hash-med-1',
    '{"command":"create_medication_schedule"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'b6660000-0000-4000-8000-000000000001',
      'medication_schedule_id', 'b7770000-0000-4000-8000-000000000001',
      'medication_name', 'Flea & Tick Prevention',
      'dose_text', '1 pipette as written',
      'provenance', 'owner_entered',
      'recurrence', jsonb_build_object(
        'type', 'interval_after_completion',
        'anchor_date', current_date::text,
        'interval', 30,
        'time_policy', 'anytime'
      )
    )
  )->>'medication_schedule' is not null
  and (select count(*) = 1 from public.medication_schedules
       where id = 'b7770000-0000-4000-8000-000000000001')
);

-- 2. Unsupported recurrence rejected
select test_meds.expect_sqlstate(
  'unsupported recurrence rejected',
  $s$select public.write_path_create_medication_schedule(
    'b4440000-0000-4000-8000-000000000001', 'med-bad-rec', 'hash-bad-rec',
    '{"command":"create_medication_schedule"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'b6660000-0000-4000-8000-000000000001',
      'medication_name', 'Mystery',
      'recurrence', jsonb_build_object(
        'type', 'every_full_moon',
        'anchor_date', current_date::text,
        'time_policy', 'anytime'
      )
    )
  )$s$,
  '22023'
);

-- 3. Archived pet rejected
select test_meds.expect_sqlstate(
  'archived pet cannot get medication',
  $s$select public.write_path_create_medication_schedule(
    'b4440000-0000-4000-8000-000000000001', 'med-arch-pet', 'hash-arch-pet',
    '{"command":"create_medication_schedule"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'b6660000-0000-4000-8000-000000000002',
      'medication_name', 'No',
      'recurrence', jsonb_build_object(
        'type', 'once',
        'anchor_date', current_date::text,
        'time_policy', 'anytime'
      )
    )
  )$s$,
  '42501'
);

-- 4. Edit with field-level audit
select public.write_path_edit_medication_schedule(
  'b4440000-0000-4000-8000-000000000001', 'med-edit-1', 'hash-med-edit-1',
  '{"command":"edit_medication_schedule"}'::jsonb, now(), null,
  jsonb_build_object(
    'medication_schedule_id', 'b7770000-0000-4000-8000-000000000001',
    'expected_revision', 1,
    'dose_text', '1 pipette — vet note unchanged wording'
  )
);

select test_meds.assert_true(
  'edit stores new dose verbatim',
  (select dose_text = '1 pipette — vet note unchanged wording' and revision = 2
   from public.medication_schedules
   where id = 'b7770000-0000-4000-8000-000000000001')
);

select test_meds.assert_true(
  'edit audit has field-level before/after',
  (select summary->'changes'->'dose_text'->>'before' = '1 pipette as written'
      and summary->'changes'->'dose_text'->>'after' = '1 pipette — vet note unchanged wording'
   from public.audit_events
   where entity_ref->>'id' = 'b7770000-0000-4000-8000-000000000001'
     and action = 'care.medication_schedule_edited'
   order by occurred_at desc limit 1)
);

select test_meds.expect_sqlstate(
  'edit revision conflict',
  $s$select public.write_path_edit_medication_schedule(
    'b4440000-0000-4000-8000-000000000001', 'med-edit-stale', 'hash-med-edit-stale',
    '{"command":"edit_medication_schedule"}'::jsonb, now(), null,
    jsonb_build_object(
      'medication_schedule_id', 'b7770000-0000-4000-8000-000000000001',
      'expected_revision', 1,
      'medication_name', 'Stale'
    )
  )$s$,
  '40001'
);

-- 5. Complete + recent partner confirmation
select test_meds.put(
  'occ_1',
  (select o.id::text
   from public.medication_schedules m
   join public.task_occurrences o on o.schedule_id = m.task_schedule_id
   where m.id = 'b7770000-0000-4000-8000-000000000001' and o.state = 'pending'
   limit 1)
);

select public.write_path_complete_medication_occurrence(
  'b4440000-0000-4000-8000-000000000002', 'med-complete-partner', 'hash-med-complete-partner',
  '{"command":"complete_medication_occurrence"}'::jsonb, now(), now(),
  jsonb_build_object('occurrence_id', test_meds.val('occ_1')::uuid)
);

select test_meds.expect_sqlstate(
  'recent partner completion requires acknowledgement',
  format(
    $s$select public.write_path_complete_medication_occurrence(
      'b4440000-0000-4000-8000-000000000001', 'med-complete-dup', 'hash-med-complete-dup',
      '{"command":"complete_medication_occurrence"}'::jsonb, now(), now(),
      jsonb_build_object('occurrence_id', %L::uuid)
    )$s$,
    test_meds.val('occ_1')
  ),
  'PC001'
);

-- After interval completion, a new pending occurrence should exist.
select test_meds.put(
  'occ_2',
  (select o.id::text
   from public.medication_schedules m
   join public.task_occurrences o on o.schedule_id = m.task_schedule_id
   where m.id = 'b7770000-0000-4000-8000-000000000001' and o.state = 'pending'
   order by o.created_at desc limit 1)
);

select test_meds.assert_true(
  'interval_after_completion seeded next occurrence',
  test_meds.val('occ_2') is not null
  and test_meds.val('occ_2') is distinct from test_meds.val('occ_1')
);

select public.write_path_complete_medication_occurrence(
  'b4440000-0000-4000-8000-000000000001', 'med-complete-ack', 'hash-med-complete-ack',
  '{"command":"complete_medication_occurrence"}'::jsonb, now(), now(),
  jsonb_build_object(
    'occurrence_id', test_meds.val('occ_2')::uuid,
    'acknowledged_recent_completion', true
  )
);

select test_meds.assert_true(
  'acknowledged complete succeeds',
  (select count(*) >= 1 from public.dispositions d
   where d.occurrence_id = test_meds.val('occ_2')::uuid
     and d.action = 'complete' and not d.superseded)
);

-- 6. Archive
select public.write_path_archive_medication_schedule(
  'b4440000-0000-4000-8000-000000000001', 'med-archive-1', 'hash-med-archive-1',
  '{"command":"archive_medication_schedule"}'::jsonb, now(), null,
  jsonb_build_object(
    'medication_schedule_id', 'b7770000-0000-4000-8000-000000000001',
    'expected_revision', 2
  )
);

select test_meds.assert_true(
  'archive sets status archived and cancels pending',
  (select m.status = 'archived'
   from public.medication_schedules m
   where m.id = 'b7770000-0000-4000-8000-000000000001')
  and (select count(*) = 0
       from public.medication_schedules m
       join public.task_occurrences o on o.schedule_id = m.task_schedule_id
       where m.id = 'b7770000-0000-4000-8000-000000000001' and o.state = 'pending')
);

-- 7. RLS + lockdown
set local role authenticated;
select set_config('request.jwt.claim.sub', 'b4440000-0000-4000-8000-000000000003', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select test_meds.assert_true(
  'outsider cannot select medication schedules',
  (select count(*) = 0 from public.medication_schedules
   where household_id = 'b5550000-0000-4000-8000-000000000001')
);

select test_meds.expect_sqlstate(
  'authenticated cannot insert medication_schedules',
  $s$insert into public.medication_schedules (
    household_id, pet_id, medication_name, recurrence, task_schedule_id, created_by, updated_by
  ) values (
    'b5550000-0000-4000-8000-000000000001', 'b6660000-0000-4000-8000-000000000001',
    'Nope', '{"type":"once","anchor_date":"2026-07-29","time_policy":"anytime"}'::jsonb,
    'b7770000-0000-4000-8000-000000000099',
    'b4440000-0000-4000-8000-000000000003', 'b4440000-0000-4000-8000-000000000003'
  )$s$,
  '42501'
);

select test_meds.expect_sqlstate(
  'authenticated cannot execute write_path_create_medication_schedule',
  $s$select public.write_path_create_medication_schedule(
    'b4440000-0000-4000-8000-000000000003', 'x', 'y', '{}'::jsonb, now(), null, '{}'::jsonb
  )$s$,
  '42501'
);

reset role;

-- Summary
do $$
declare
  failed integer;
begin
  select count(*) into failed from test_meds.results where not passed;
  if failed > 0 then
    raise exception '% medication assertion(s) failed', failed;
  end if;
  raise notice 'Care medications suite: all assertions passed';
end;
$$;

rollback;
