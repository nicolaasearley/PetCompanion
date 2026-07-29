-- Events foundation tests (F11, DM §11.5, US-081).
--
-- Covers:
--   * create / edit / cancel / archive with revision checks and idempotency;
--   * household-level vs pet-linked events;
--   * timed vs all-day shape validation;
--   * generation context emits confirmed upcoming events (not cancelled/archived);
--   * RLS isolation + direct-write denial;
--   * SECURITY DEFINER lockdown.
--
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_events;
create table test_events.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create table test_events.state (key text primary key, value text);

grant usage on schema test_events to authenticated;
grant select, insert, update on test_events.results, test_events.state to authenticated;
grant usage, select on all sequences in schema test_events to authenticated;

create or replace function test_events.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_events.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_events.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin perform test_events.record(p_name, coalesce(p_condition, false), p_detail); end;
$$;

create or replace function test_events.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_events.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_events.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

create or replace function test_events.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_events.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_events.val(p_key text)
returns text language sql stable as $$
  select value from test_events.state where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('e4440000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'events-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('e4440000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'events-partner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('e4440000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'events-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.user_profiles(id, display_name) values
  ('e4440000-0000-4000-8000-000000000001', 'Nic'),
  ('e4440000-0000-4000-8000-000000000002', 'Sarah'),
  ('e4440000-0000-4000-8000-000000000003', 'Outsider');

insert into public.households (id, name, time_zone, created_by, updated_by) values
  ('e5550000-0000-4000-8000-000000000001', 'Maple House', 'America/Toronto',
   'e4440000-0000-4000-8000-000000000001', 'e4440000-0000-4000-8000-000000000001'),
  ('e5550000-0000-4000-8000-000000000002', 'Other House', 'America/Toronto',
   'e4440000-0000-4000-8000-000000000003', 'e4440000-0000-4000-8000-000000000003');

insert into public.household_memberships (
  id, household_id, user_id, role, status, created_by, updated_by
) values
  ('e6660000-0000-4000-8000-000000000001', 'e5550000-0000-4000-8000-000000000001',
   'e4440000-0000-4000-8000-000000000001', 'owner', 'active',
   'e4440000-0000-4000-8000-000000000001', 'e4440000-0000-4000-8000-000000000001'),
  ('e6660000-0000-4000-8000-000000000002', 'e5550000-0000-4000-8000-000000000001',
   'e4440000-0000-4000-8000-000000000002', 'caregiver', 'active',
   'e4440000-0000-4000-8000-000000000001', 'e4440000-0000-4000-8000-000000000001'),
  ('e6660000-0000-4000-8000-000000000003', 'e5550000-0000-4000-8000-000000000002',
   'e4440000-0000-4000-8000-000000000003', 'owner', 'active',
   'e4440000-0000-4000-8000-000000000003', 'e4440000-0000-4000-8000-000000000003');

insert into public.household_preferences (household_id, default_capacity_mode, created_by, updated_by)
values
  ('e5550000-0000-4000-8000-000000000001', 'normal',
   'e4440000-0000-4000-8000-000000000001', 'e4440000-0000-4000-8000-000000000001'),
  ('e5550000-0000-4000-8000-000000000002', 'normal',
   'e4440000-0000-4000-8000-000000000003', 'e4440000-0000-4000-8000-000000000003');

insert into public.pets (
  id, household_id, name, species, birth_date_kind, birth_date, created_by, updated_by
) values
  ('e7770000-0000-4000-8000-000000000001', 'e5550000-0000-4000-8000-000000000001',
   'Maple', 'dog', 'exact', current_date - 70,
   'e4440000-0000-4000-8000-000000000001', 'e4440000-0000-4000-8000-000000000001');

insert into public.pet_preferences (pet_id, household_id, created_by, updated_by)
values (
  'e7770000-0000-4000-8000-000000000001',
  'e5550000-0000-4000-8000-000000000001',
  'e4440000-0000-4000-8000-000000000001',
  'e4440000-0000-4000-8000-000000000001'
);

select test_events.put('owner', 'e4440000-0000-4000-8000-000000000001');
select test_events.put('partner', 'e4440000-0000-4000-8000-000000000002');
select test_events.put('outsider', 'e4440000-0000-4000-8000-000000000003');
select test_events.put('household', 'e5550000-0000-4000-8000-000000000001');
select test_events.put('pet', 'e7770000-0000-4000-8000-000000000001');

-- ---------------------------------------------------------------------------
-- Create timed vet appointment
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claim.sub', test_events.val('owner'), true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select test_events.put('create_resp', public.write_path_create_event(
  test_events.val('owner')::uuid,
  'evt-create-1',
  'hash-create-1',
  '{}'::jsonb,
  now(), now(),
  jsonb_build_object(
    'event_id', 'e8880000-0000-4000-8000-000000000001',
    'household_id', test_events.val('household'),
    'pet_id', test_events.val('pet'),
    'kind', 'vet_appointment',
    'title', 'Vet checkup',
    'start_date', (public.household_current_local_date(test_events.val('household')::uuid, now()) + 2)::text,
    'all_day', false,
    'start_time', '14:00',
    'location_text', 'Maple Vet',
    'reminder_config', jsonb_build_object('lead_minutes', jsonb_build_array(60, 1440)),
    'notes', 'Bring records'
  )
)::text);

select test_events.assert_true(
  'create_event returns the event',
  (test_events.val('create_resp')::jsonb->'event'->>'title') = 'Vet checkup'
);

select test_events.assert_true(
  'create_event stores timed fields',
  exists (
    select 1 from public.events
    where id = 'e8880000-0000-4000-8000-000000000001'
      and kind = 'vet_appointment'
      and all_day = false
      and start_time = time '14:00'
      and status = 'confirmed'
      and deleted_at is null
  )
);

-- Idempotent replay
select test_events.assert_true(
  'create_event is idempotent',
  public.write_path_create_event(
    test_events.val('owner')::uuid,
    'evt-create-1',
    'hash-create-1',
    '{}'::jsonb,
    now(), now(),
    jsonb_build_object(
      'event_id', 'e8880000-0000-4000-8000-000000000001',
      'household_id', test_events.val('household'),
      'pet_id', test_events.val('pet'),
      'kind', 'vet_appointment',
      'title', 'Vet checkup',
      'start_date', (public.household_current_local_date(test_events.val('household')::uuid, now()) + 2)::text,
      'all_day', false,
      'start_time', '14:00'
    )
  )->'event'->>'id' = 'e8880000-0000-4000-8000-000000000001'
);

select test_events.expect_sqlstate(
  'create_event rejects idempotency reuse with different payload',
  format($s$select public.write_path_create_event(
    '%s'::uuid, 'evt-create-1', 'other-hash', '{}'::jsonb, now(), now(),
    '{"household_id":"%s","kind":"class","title":"X","start_date":"2026-08-01","all_day":true}'::jsonb
  )$s$, test_events.val('owner'), test_events.val('household')),
  '23505'
);

select test_events.expect_sqlstate(
  'timed event requires start_time',
  format($s$select public.write_path_create_event(
    '%s'::uuid, 'evt-bad-time', 'hash-bad-time', '{}'::jsonb, now(), now(),
    jsonb_build_object(
      'household_id', '%s',
      'kind', 'class',
      'title', 'Puppy class',
      'start_date', current_date::text,
      'all_day', false
    )
  )$s$, test_events.val('owner'), test_events.val('household')),
  '22023'
);

-- Household-level all-day event
select public.write_path_create_event(
  test_events.val('owner')::uuid,
  'evt-create-hh',
  'hash-create-hh',
  '{}'::jsonb,
  now(), now(),
  jsonb_build_object(
    'event_id', 'e8880000-0000-4000-8000-000000000002',
    'household_id', test_events.val('household'),
    'kind', 'other',
    'title', 'Family photo day',
    'start_date', (public.household_current_local_date(test_events.val('household')::uuid, now()) + 5)::text,
    'all_day', true
  )
);

select test_events.assert_true(
  'household-level event has null pet_id',
  exists (
    select 1 from public.events
    where id = 'e8880000-0000-4000-8000-000000000002' and pet_id is null and all_day
  )
);

-- ---------------------------------------------------------------------------
-- Edit + revision conflict
-- ---------------------------------------------------------------------------

select test_events.put('edit_resp', public.write_path_edit_event(
  test_events.val('partner')::uuid,
  'evt-edit-1',
  'hash-edit-1',
  '{}'::jsonb,
  now(), now(),
  jsonb_build_object(
    'event_id', 'e8880000-0000-4000-8000-000000000001',
    'expected_revision', 1,
    'title', 'Vet checkup (rescheduled)',
    'start_date', (public.household_current_local_date(test_events.val('household')::uuid, now()) + 3)::text,
    'all_day', false,
    'start_time', '15:30'
  )
)::text);

select test_events.assert_true(
  'edit_event bumps revision and title',
  (test_events.val('edit_resp')::jsonb->'event'->>'revision')::int = 2
  and (test_events.val('edit_resp')::jsonb->'event'->>'title') = 'Vet checkup (rescheduled)'
  and (test_events.val('edit_resp')::jsonb->'event'->>'start_time') = '15:30'
);

select test_events.expect_sqlstate(
  'edit_event rejects stale revision',
  format($s$select public.write_path_edit_event(
    '%s'::uuid, 'evt-edit-stale', 'hash-edit-stale', '{}'::jsonb, now(), now(),
    jsonb_build_object(
      'event_id', 'e8880000-0000-4000-8000-000000000001',
      'expected_revision', 1,
      'title', 'Stale'
    )
  )$s$, test_events.val('owner')),
  '40001'
);

-- ---------------------------------------------------------------------------
-- Cancel keeps row; archive soft-deletes
-- ---------------------------------------------------------------------------

select public.write_path_cancel_event(
  test_events.val('owner')::uuid,
  'evt-cancel-1',
  'hash-cancel-1',
  '{}'::jsonb,
  now(), now(),
  jsonb_build_object(
    'event_id', 'e8880000-0000-4000-8000-000000000001',
    'expected_revision', 2
  )
);

select test_events.assert_true(
  'cancel_event sets status cancelled and retains row',
  exists (
    select 1 from public.events
    where id = 'e8880000-0000-4000-8000-000000000001'
      and status = 'cancelled'
      and deleted_at is null
      and revision = 3
  )
);

-- Restore via edit (product path after cancel)
select public.write_path_edit_event(
  test_events.val('owner')::uuid,
  'evt-restore-1',
  'hash-restore-1',
  '{}'::jsonb,
  now(), now(),
  jsonb_build_object(
    'event_id', 'e8880000-0000-4000-8000-000000000001',
    'expected_revision', 3,
    'title', 'Vet checkup',
    'start_date', (public.household_current_local_date(test_events.val('household')::uuid, now()) + 2)::text,
    'all_day', false,
    'start_time', '14:00'
  )
);

select test_events.assert_true(
  'edit after cancel restores confirmed status',
  exists (
    select 1 from public.events
    where id = 'e8880000-0000-4000-8000-000000000001'
      and status = 'confirmed'
      and revision = 4
  )
);

select public.write_path_archive_event(
  test_events.val('owner')::uuid,
  'evt-archive-hh',
  'hash-archive-hh',
  '{}'::jsonb,
  now(), now(),
  jsonb_build_object(
    'event_id', 'e8880000-0000-4000-8000-000000000002',
    'expected_revision', 1
  )
);

select test_events.assert_true(
  'archive_event soft-deletes',
  exists (
    select 1 from public.events
    where id = 'e8880000-0000-4000-8000-000000000002'
      and deleted_at is not null
  )
);

-- ---------------------------------------------------------------------------
-- Generation context includes confirmed events
-- ---------------------------------------------------------------------------

select test_events.put('ctx', public.write_path_generation_context(
  test_events.val('owner')::uuid,
  test_events.val('pet')::uuid,
  null,
  now()
)::text);

select test_events.assert_true(
  'generation context includes confirmed vet event',
  exists (
    select 1
    from jsonb_array_elements(test_events.val('ctx')::jsonb->'events') ev
    where ev->>'event_id' = 'e8880000-0000-4000-8000-000000000001'
      and ev->>'kind' = 'vet_appointment'
      and (ev->>'confirmed')::boolean = true
      and ev->>'exact_time' = '14:00'
  )
);

select test_events.assert_true(
  'generation context omits archived event',
  not exists (
    select 1
    from jsonb_array_elements(test_events.val('ctx')::jsonb->'events') ev
    where ev->>'event_id' = 'e8880000-0000-4000-8000-000000000002'
  )
);

select test_events.assert_true(
  'generation context still has training_state key (not reverted)',
  (test_events.val('ctx')::jsonb) ? 'training_state'
  and jsonb_typeof(test_events.val('ctx')::jsonb->'training_state') = 'array'
);

select test_events.assert_true(
  'generation context still has socialization catalogue',
  jsonb_typeof(test_events.val('ctx')::jsonb->'catalogue'->'socialization_catalog') = 'array'
);

-- Cancelled events drop out of context
select public.write_path_cancel_event(
  test_events.val('owner')::uuid,
  'evt-cancel-2',
  'hash-cancel-2',
  '{}'::jsonb,
  now(), now(),
  jsonb_build_object(
    'event_id', 'e8880000-0000-4000-8000-000000000001',
    'expected_revision', 4
  )
);

select test_events.assert_true(
  'cancelled events are absent from generation context',
  not exists (
    select 1
    from jsonb_array_elements(
      public.write_path_generation_context(
        test_events.val('owner')::uuid,
        test_events.val('pet')::uuid,
        null,
        now()
      )->'events'
    ) ev
    where ev->>'event_id' = 'e8880000-0000-4000-8000-000000000001'
  )
);

-- ---------------------------------------------------------------------------
-- RLS + direct writes
-- ---------------------------------------------------------------------------

-- Re-seed a live event for SELECT checks (previous vet event was cancelled).
select public.write_path_create_event(
  test_events.val('owner')::uuid,
  'evt-rls-seed',
  'hash-rls-seed',
  '{}'::jsonb,
  now(), now(),
  jsonb_build_object(
    'event_id', 'e8880000-0000-4000-8000-000000000099',
    'household_id', test_events.val('household'),
    'pet_id', test_events.val('pet'),
    'kind', 'grooming_visit',
    'title', 'Grooming',
    'start_date', (public.household_current_local_date(test_events.val('household')::uuid, now()) + 4)::text,
    'all_day', true
  )
);

set local role authenticated;
select set_config('request.jwt.claim.sub', test_events.val('outsider'), true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select test_events.assert_true(
  'outsider cannot SELECT household events',
  (
    select count(*) from public.events
    where id = 'e8880000-0000-4000-8000-000000000099'
  ) = 0
);

select test_events.expect_sqlstate(
  'authenticated cannot EXECUTE write_path_create_event',
  format($s$select public.write_path_create_event(
    '%s'::uuid, 'x', 'y', '{}'::jsonb, now(), now(), '{}'::jsonb
  )$s$, test_events.val('owner')),
  '42501'
);

reset role;
select set_config('request.jwt.claim.sub', test_events.val('owner'), true);
set local role authenticated;

select test_events.assert_true(
  'member can SELECT own household event',
  (
    select count(*) from public.events
    where id = 'e8880000-0000-4000-8000-000000000099'
  ) = 1
);

select test_events.expect_sqlstate(
  'authenticated cannot INSERT events directly',
  format($s$insert into public.events (
    household_id, kind, title, start_date, all_day, created_by, updated_by
  ) values (
    '%s', 'other', 'sneaky', current_date, true, '%s', '%s'
  )$s$,
    test_events.val('household'), test_events.val('owner'), test_events.val('owner')),
  '42501'
);

select test_events.expect_sqlstate(
  'authenticated cannot UPDATE events directly',
  $s$update public.events set notes = 'bypass'
    where id = 'e8880000-0000-4000-8000-000000000099'$s$,
  '42501'
);

select test_events.expect_sqlstate(
  'authenticated cannot DELETE events directly',
  $s$delete from public.events
    where id = 'e8880000-0000-4000-8000-000000000099'$s$,
  '42501'
);

reset role;

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

do $$
declare
  failed integer;
begin
  select count(*) into failed from test_events.results where not passed;
  raise notice 'EVENTS SUITE: % passed, % failed',
    (select count(*) from test_events.results where passed), failed;
  if failed > 0 then
    raise exception '% events assertions failed', failed;
  end if;
end;
$$;

rollback;
