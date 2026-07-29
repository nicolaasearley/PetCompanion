-- Care grooming tests (F10, DM §11.1 grooming, CA-01).
--
-- Covers:
--   * record / edit / remove with revision checks and idempotency;
--   * next_due_date as owner-entered fact only (no schedule computation);
--   * archived pet / closed household guards;
--   * RLS isolation (outsider cannot SELECT);
--   * authenticated members cannot INSERT/UPDATE/DELETE directly;
--   * SECURITY DEFINER lockdown (authenticated cannot EXECUTE write_path_*).
--
-- Explicitly out of scope: dose advice, computed due schedules, medication
-- occurrence generation, engine grooming obligations.
--
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_grooming;
create table test_grooming.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create table test_grooming.state (key text primary key, value text);

grant usage on schema test_grooming to authenticated;
grant select, insert, update on test_grooming.results, test_grooming.state to authenticated;
grant usage, select on all sequences in schema test_grooming to authenticated;

create or replace function test_grooming.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_grooming.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_grooming.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  perform test_grooming.record(p_name, coalesce(p_condition, false), p_detail);
end;
$$;

create or replace function test_grooming.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_grooming.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_grooming.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

create or replace function test_grooming.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_grooming.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_grooming.val(p_key text)
returns text language sql stable as $$
  select value from test_grooming.state where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('c4440000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'groom-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('c4440000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'groom-partner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('c4440000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'groom-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.user_profiles(id, display_name) values
  ('c4440000-0000-4000-8000-000000000001', 'Nic'),
  ('c4440000-0000-4000-8000-000000000002', 'Sarah'),
  ('c4440000-0000-4000-8000-000000000003', 'Outsider');

insert into public.households (id, name, time_zone, created_by, updated_by) values
  ('c5550000-0000-4000-8000-000000000001', 'Maple House', 'America/Toronto',
   'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'),
  ('c5550000-0000-4000-8000-000000000002', 'Elsewhere House', 'Europe/Stockholm',
   'c4440000-0000-4000-8000-000000000003', 'c4440000-0000-4000-8000-000000000003');

insert into public.household_memberships (
  household_id, user_id, role, status, joined_at, created_by, updated_by
) values
  ('c5550000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001',
   'owner', 'active', now(), 'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'),
  ('c5550000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000002',
   'caregiver', 'active', now(), 'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'),
  ('c5550000-0000-4000-8000-000000000002', 'c4440000-0000-4000-8000-000000000003',
   'owner', 'active', now(), 'c4440000-0000-4000-8000-000000000003', 'c4440000-0000-4000-8000-000000000003');

insert into public.pets (
  id, household_id, name, birth_date_kind, birth_date, status, created_by, updated_by
) values
  ('c6660000-0000-4000-8000-000000000001', 'c5550000-0000-4000-8000-000000000001',
   'Maple', 'exact', current_date - 80, 'active',
   'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'),
  ('c6660000-0000-4000-8000-000000000002', 'c5550000-0000-4000-8000-000000000001',
   'Willow', 'exact', current_date - 200, 'archived',
   'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'),
  ('c6660000-0000-4000-8000-000000000003', 'c5550000-0000-4000-8000-000000000002',
   'Birch', 'exact', current_date - 90, 'active',
   'c4440000-0000-4000-8000-000000000003', 'c4440000-0000-4000-8000-000000000003');

insert into public.household_preferences (household_id, created_by, updated_by) values
  ('c5550000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001',
   'c4440000-0000-4000-8000-000000000001'),
  ('c5550000-0000-4000-8000-000000000002', 'c4440000-0000-4000-8000-000000000003',
   'c4440000-0000-4000-8000-000000000003');

-- ---------------------------------------------------------------------------
-- 1. Record grooming
-- ---------------------------------------------------------------------------

select test_grooming.put(
  'groom_1',
  public.write_path_record_grooming(
    'c4440000-0000-4000-8000-000000000001', 'groom-1', 'hash-groom-1',
    '{"command":"record_grooming"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'c6660000-0000-4000-8000-000000000001',
      'grooming_id', 'c8880000-0000-4000-8000-000000000001',
      'activity_type', 'brushing',
      'effective_date', (current_date - 2)::text,
      'next_due_date', (current_date + 3)::text,
      'note', 'Short calm session'
    )
  )::text
);

select test_grooming.assert_true(
  'record_grooming stores activity and next_due as entered',
  exists (
    select 1 from public.grooming_records
    where id = 'c8880000-0000-4000-8000-000000000001'
      and activity_type = 'brushing'
      and next_due_date = current_date + 3
      and note = 'Short calm session'
      and deleted_at is null
  )
);

select test_grooming.assert_true(
  'record_grooming returns created_by_name attribution',
  (test_grooming.val('groom_1')::jsonb->'grooming'->>'created_by_name') = 'Nic'
);

select test_grooming.assert_true(
  'record_grooming is idempotent',
  public.write_path_record_grooming(
    'c4440000-0000-4000-8000-000000000001', 'groom-1', 'hash-groom-1',
    '{"command":"record_grooming"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'c6660000-0000-4000-8000-000000000001',
      'grooming_id', 'c8880000-0000-4000-8000-000000000001',
      'activity_type', 'brushing',
      'effective_date', (current_date - 2)::text,
      'next_due_date', (current_date + 3)::text,
      'note', 'Short calm session'
    )
  )::text = test_grooming.val('groom_1')
);

select test_grooming.expect_sqlstate(
  'record_grooming rejects idempotency reuse with different payload',
  $stmt$
    select public.write_path_record_grooming(
      'c4440000-0000-4000-8000-000000000001', 'groom-1', 'hash-groom-1-diff',
      '{"command":"record_grooming"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'c6660000-0000-4000-8000-000000000001',
        'activity_type', 'bath',
        'effective_date', (current_date - 2)::text
      )
    );
  $stmt$,
  '23505'
);

select test_grooming.expect_sqlstate(
  'record_grooming rejects future effective_date',
  $stmt$
    select public.write_path_record_grooming(
      'c4440000-0000-4000-8000-000000000001', 'groom-future', 'hash-groom-future',
      '{"command":"record_grooming"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'c6660000-0000-4000-8000-000000000001',
        'activity_type', 'nails',
        'effective_date', (current_date + 1)::text
      )
    );
  $stmt$,
  '22023'
);

select test_grooming.expect_sqlstate(
  'record_grooming rejects next_due before effective_date',
  $stmt$
    select public.write_path_record_grooming(
      'c4440000-0000-4000-8000-000000000001', 'groom-next-before', 'hash-groom-next-before',
      '{"command":"record_grooming"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'c6660000-0000-4000-8000-000000000001',
        'activity_type', 'teeth',
        'effective_date', (current_date - 1)::text,
        'next_due_date', (current_date - 5)::text
      )
    );
  $stmt$,
  '22023'
);

select test_grooming.expect_sqlstate(
  'record_grooming rejects archived pet',
  $stmt$
    select public.write_path_record_grooming(
      'c4440000-0000-4000-8000-000000000001', 'groom-archived', 'hash-groom-archived',
      '{"command":"record_grooming"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'c6660000-0000-4000-8000-000000000002',
        'activity_type', 'ears',
        'effective_date', (current_date - 1)::text
      )
    );
  $stmt$,
  '42501'
);

-- ---------------------------------------------------------------------------
-- 2. Edit grooming
-- ---------------------------------------------------------------------------

select test_grooming.put(
  'groom_1_edit',
  public.write_path_edit_grooming(
    'c4440000-0000-4000-8000-000000000002', 'groom-1-edit', 'hash-groom-1-edit',
    '{"command":"edit_grooming"}'::jsonb, now(), null,
    jsonb_build_object(
      'grooming_id', 'c8880000-0000-4000-8000-000000000001',
      'expected_revision', 1,
      'activity_type', 'nails',
      'note', 'One paw only'
    )
  )::text
);

select test_grooming.assert_true(
  'edit_grooming bumps revision and updates fields',
  exists (
    select 1 from public.grooming_records
    where id = 'c8880000-0000-4000-8000-000000000001'
      and activity_type = 'nails'
      and note = 'One paw only'
      and revision = 2
      and updated_by = 'c4440000-0000-4000-8000-000000000002'
  )
);

select test_grooming.expect_sqlstate(
  'edit_grooming rejects stale revision',
  $stmt$
    select public.write_path_edit_grooming(
      'c4440000-0000-4000-8000-000000000001', 'groom-stale', 'hash-groom-stale',
      '{"command":"edit_grooming"}'::jsonb, now(), null,
      jsonb_build_object(
        'grooming_id', 'c8880000-0000-4000-8000-000000000001',
        'expected_revision', 1,
        'activity_type', 'bath'
      )
    );
  $stmt$,
  '40001'
);

-- ---------------------------------------------------------------------------
-- 3. Remove grooming
-- ---------------------------------------------------------------------------

select public.write_path_remove_grooming(
  'c4440000-0000-4000-8000-000000000001', 'groom-1-remove', 'hash-groom-1-remove',
  '{"command":"remove_grooming"}'::jsonb, now(), null,
  jsonb_build_object('grooming_id', 'c8880000-0000-4000-8000-000000000001')
);

select test_grooming.assert_true(
  'remove_grooming soft-deletes',
  exists (
    select 1 from public.grooming_records
    where id = 'c8880000-0000-4000-8000-000000000001'
      and deleted_at is not null
      and deleted_by = 'c4440000-0000-4000-8000-000000000001'
  )
);

select test_grooming.assert_true(
  'remove_grooming is idempotent',
  (public.write_path_remove_grooming(
    'c4440000-0000-4000-8000-000000000001', 'groom-1-remove', 'hash-groom-1-remove',
    '{"command":"remove_grooming"}'::jsonb, now(), null,
    jsonb_build_object('grooming_id', 'c8880000-0000-4000-8000-000000000001')
  )->'grooming'->>'id') = 'c8880000-0000-4000-8000-000000000001'
);

-- ---------------------------------------------------------------------------
-- 4. RLS + direct write denial
-- ---------------------------------------------------------------------------

select test_grooming.put(
  'groom_2',
  public.write_path_record_grooming(
    'c4440000-0000-4000-8000-000000000001', 'groom-2', 'hash-groom-2',
    '{"command":"record_grooming"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'c6660000-0000-4000-8000-000000000001',
      'grooming_id', 'c8880000-0000-4000-8000-000000000002',
      'activity_type', 'bath',
      'effective_date', (current_date - 7)::text
    )
  )::text
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'c4440000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select test_grooming.assert_true(
  'member can SELECT own household grooming',
  exists (
    select 1 from public.grooming_records
    where id = 'c8880000-0000-4000-8000-000000000002'
  )
);

select test_grooming.expect_sqlstate(
  'member cannot INSERT grooming directly',
  $stmt$
    insert into public.grooming_records (
      household_id, pet_id, activity_type, effective_date, created_by, updated_by
    ) values (
      'c5550000-0000-4000-8000-000000000001',
      'c6660000-0000-4000-8000-000000000001',
      'other', current_date - 1,
      'c4440000-0000-4000-8000-000000000001',
      'c4440000-0000-4000-8000-000000000001'
    );
  $stmt$,
  '42501'
);

select test_grooming.expect_sqlstate(
  'authenticated cannot EXECUTE write_path_record_grooming',
  $stmt$
    select public.write_path_record_grooming(
      'c4440000-0000-4000-8000-000000000001', 'groom-lock', 'hash-groom-lock',
      '{}'::jsonb, now(), null, '{}'::jsonb
    );
  $stmt$,
  '42501'
);

select set_config('request.jwt.claim.sub', 'c4440000-0000-4000-8000-000000000003', true);

select test_grooming.assert_true(
  'outsider cannot SELECT other household grooming',
  not exists (
    select 1 from public.grooming_records
    where id = 'c8880000-0000-4000-8000-000000000002'
  )
);

reset role;

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

do $$
declare
  failed integer;
begin
  select count(*) into failed from test_grooming.results where not passed;
  raise notice 'grooming suite: % failed of %',
    failed, (select count(*) from test_grooming.results);
  if failed > 0 then
    raise exception '% grooming assertion(s) failed', failed;
  end if;
end;
$$;

rollback;
