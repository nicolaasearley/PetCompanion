-- Care weight + providers tests (F10, DM §11.3–§11.4, US-075, CA-08/CA-09).
--
-- Covers:
--   * record / edit / remove weight with revision checks and idempotency;
--   * create / edit / remove providers;
--   * archived pet / closed household guards;
--   * RLS isolation (outsider cannot SELECT);
--   * authenticated members cannot INSERT/UPDATE/DELETE weight or providers
--     directly (mutations go through write-path only);
--   * SECURITY DEFINER lockdown (authenticated cannot EXECUTE write_path_*).
--
-- Medication scheduling is deliberately out of scope — no dose, recurrence,
-- or "due" assertions belong here.
--
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_care;
create table test_care.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create table test_care.state (key text primary key, value text);

grant usage on schema test_care to authenticated;
grant select, insert, update on test_care.results, test_care.state to authenticated;
grant usage, select on all sequences in schema test_care to authenticated;

create or replace function test_care.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_care.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_care.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin perform test_care.record(p_name, coalesce(p_condition, false), p_detail); end;
$$;

create or replace function test_care.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_care.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_care.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

create or replace function test_care.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_care.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_care.val(p_key text)
returns text language sql stable as $$
  select value from test_care.state where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('a4440000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'care-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('a4440000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'care-partner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('a4440000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'care-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.user_profiles(id, display_name) values
  ('a4440000-0000-4000-8000-000000000001', 'Nic'),
  ('a4440000-0000-4000-8000-000000000002', 'Sarah'),
  ('a4440000-0000-4000-8000-000000000003', 'Outsider');

insert into public.households (id, name, time_zone, created_by, updated_by) values
  ('a5550000-0000-4000-8000-000000000001', 'Maple House', 'America/Toronto',
   'a4440000-0000-4000-8000-000000000001', 'a4440000-0000-4000-8000-000000000001'),
  ('a5550000-0000-4000-8000-000000000002', 'Elsewhere House', 'Europe/Stockholm',
   'a4440000-0000-4000-8000-000000000003', 'a4440000-0000-4000-8000-000000000003');

insert into public.household_memberships (
  household_id, user_id, role, status, joined_at, created_by, updated_by
) values
  ('a5550000-0000-4000-8000-000000000001', 'a4440000-0000-4000-8000-000000000001',
   'owner', 'active', now(), 'a4440000-0000-4000-8000-000000000001', 'a4440000-0000-4000-8000-000000000001'),
  ('a5550000-0000-4000-8000-000000000001', 'a4440000-0000-4000-8000-000000000002',
   'caregiver', 'active', now(), 'a4440000-0000-4000-8000-000000000001', 'a4440000-0000-4000-8000-000000000001'),
  ('a5550000-0000-4000-8000-000000000002', 'a4440000-0000-4000-8000-000000000003',
   'owner', 'active', now(), 'a4440000-0000-4000-8000-000000000003', 'a4440000-0000-4000-8000-000000000003');

insert into public.pets (
  id, household_id, name, birth_date_kind, birth_date, status, created_by, updated_by
) values
  ('a6660000-0000-4000-8000-000000000001', 'a5550000-0000-4000-8000-000000000001',
   'Maple', 'exact', current_date - 80, 'active',
   'a4440000-0000-4000-8000-000000000001', 'a4440000-0000-4000-8000-000000000001'),
  ('a6660000-0000-4000-8000-000000000002', 'a5550000-0000-4000-8000-000000000001',
   'Willow', 'exact', current_date - 200, 'archived',
   'a4440000-0000-4000-8000-000000000001', 'a4440000-0000-4000-8000-000000000001'),
  ('a6660000-0000-4000-8000-000000000003', 'a5550000-0000-4000-8000-000000000002',
   'Birch', 'exact', current_date - 90, 'active',
   'a4440000-0000-4000-8000-000000000003', 'a4440000-0000-4000-8000-000000000003');

insert into public.household_preferences (household_id, created_by, updated_by) values
  ('a5550000-0000-4000-8000-000000000001', 'a4440000-0000-4000-8000-000000000001',
   'a4440000-0000-4000-8000-000000000001'),
  ('a5550000-0000-4000-8000-000000000002', 'a4440000-0000-4000-8000-000000000003',
   'a4440000-0000-4000-8000-000000000003');

-- ---------------------------------------------------------------------------
-- 1. Record weight
-- ---------------------------------------------------------------------------

select test_care.put(
  'weight_1',
  public.write_path_record_weight(
    'a4440000-0000-4000-8000-000000000001', 'care-weight-1', 'hash-weight-1',
    '{"command":"record_weight"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'a6660000-0000-4000-8000-000000000001',
      'measurement_id', 'a7770000-0000-4000-8000-000000000001',
      'value', '6.4',
      'unit', 'kg',
      'effective_date', (current_date - 1)::text,
      'note', 'At the clinic'
    )
  )::text
);

select test_care.assert_true(
  'record_weight stores original value and unit',
  exists (
    select 1 from public.weight_measurements
    where id = 'a7770000-0000-4000-8000-000000000001'
      and value = 6.4 and unit = 'kg' and note = 'At the clinic'
      and deleted_at is null and revision = 1
  )
);

select test_care.assert_true(
  'record_weight is idempotent on the same key+payload',
  public.write_path_record_weight(
    'a4440000-0000-4000-8000-000000000001', 'care-weight-1', 'hash-weight-1',
    '{"command":"record_weight"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'a6660000-0000-4000-8000-000000000001',
      'measurement_id', 'a7770000-0000-4000-8000-000000000001',
      'value', '6.4',
      'unit', 'kg',
      'effective_date', (current_date - 1)::text,
      'note', 'At the clinic'
    )
  )::text = test_care.val('weight_1')
  and (select count(*) from public.weight_measurements
       where id = 'a7770000-0000-4000-8000-000000000001') = 1
);

select test_care.expect_sqlstate(
  'record_weight rejects archived pet',
  $stmt$
    select public.write_path_record_weight(
      'a4440000-0000-4000-8000-000000000001', 'care-weight-archived', 'hash-a',
      '{}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'a6660000-0000-4000-8000-000000000002',
        'value', '5', 'unit', 'kg'
      )
    );
  $stmt$,
  '42501'
);

select test_care.expect_sqlstate(
  'record_weight rejects outsider pet',
  $stmt$
    select public.write_path_record_weight(
      'a4440000-0000-4000-8000-000000000001', 'care-weight-outsider', 'hash-o',
      '{}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'a6660000-0000-4000-8000-000000000003',
        'value', '5', 'unit', 'kg'
      )
    );
  $stmt$,
  '42501'
);

select test_care.expect_sqlstate(
  'record_weight rejects future date',
  $stmt$
    select public.write_path_record_weight(
      'a4440000-0000-4000-8000-000000000001', 'care-weight-future', 'hash-f',
      '{}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'a6660000-0000-4000-8000-000000000001',
        'value', '5', 'unit', 'kg',
        'effective_date', (current_date + 2)::text
      )
    );
  $stmt$,
  '22023'
);

-- ---------------------------------------------------------------------------
-- 2. Edit + remove weight
-- ---------------------------------------------------------------------------

select public.write_path_edit_weight(
  'a4440000-0000-4000-8000-000000000002', 'care-weight-edit-1', 'hash-edit-1',
  '{}'::jsonb, now(), null,
  jsonb_build_object(
    'measurement_id', 'a7770000-0000-4000-8000-000000000001',
    'expected_revision', 1,
    'value', '6.6',
    'note', 'Rechecked at home'
  )
);

select test_care.assert_true(
  'edit_weight updates value and bumps revision',
  exists (
    select 1 from public.weight_measurements
    where id = 'a7770000-0000-4000-8000-000000000001'
      and value = 6.6 and revision = 2 and note = 'Rechecked at home'
      and updated_by = 'a4440000-0000-4000-8000-000000000002'
  )
);

select test_care.expect_sqlstate(
  'edit_weight rejects stale revision',
  $stmt$
    select public.write_path_edit_weight(
      'a4440000-0000-4000-8000-000000000001', 'care-weight-stale', 'hash-stale',
      '{}'::jsonb, now(), null,
      jsonb_build_object(
        'measurement_id', 'a7770000-0000-4000-8000-000000000001',
        'expected_revision', 1,
        'value', '7'
      )
    );
  $stmt$,
  '40001'
);

select public.write_path_remove_weight(
  'a4440000-0000-4000-8000-000000000001', 'care-weight-remove-1', 'hash-rm-1',
  '{}'::jsonb, now(), null,
  jsonb_build_object('measurement_id', 'a7770000-0000-4000-8000-000000000001')
);

select test_care.assert_true(
  'remove_weight soft-deletes the row',
  exists (
    select 1 from public.weight_measurements
    where id = 'a7770000-0000-4000-8000-000000000001'
      and deleted_at is not null
      and deleted_by = 'a4440000-0000-4000-8000-000000000001'
  )
);

-- ---------------------------------------------------------------------------
-- 3. Providers
-- ---------------------------------------------------------------------------

select test_care.put(
  'provider_1',
  public.write_path_create_provider(
    'a4440000-0000-4000-8000-000000000001', 'care-provider-1', 'hash-provider-1',
    '{}'::jsonb, now(), null,
    jsonb_build_object(
      'household_id', 'a5550000-0000-4000-8000-000000000001',
      'provider_id', 'a8880000-0000-4000-8000-000000000001',
      'name', 'Riverside Vet',
      'kind', 'veterinarian',
      'phone', '+1-555-0100',
      'address', '12 River Rd'
    )
  )::text
);

select test_care.assert_true(
  'create_provider stores contact fields',
  exists (
    select 1 from public.providers
    where id = 'a8880000-0000-4000-8000-000000000001'
      and name = 'Riverside Vet' and kind = 'veterinarian'
      and phone = '+1-555-0100' and deleted_at is null
  )
);

select public.write_path_edit_provider(
  'a4440000-0000-4000-8000-000000000002', 'care-provider-edit-1', 'hash-pe-1',
  '{}'::jsonb, now(), null,
  jsonb_build_object(
    'provider_id', 'a8880000-0000-4000-8000-000000000001',
    'expected_revision', 1,
    'notes', 'Ask for Dr. Patel'
  )
);

select test_care.assert_true(
  'edit_provider updates notes and revision',
  exists (
    select 1 from public.providers
    where id = 'a8880000-0000-4000-8000-000000000001'
      and notes = 'Ask for Dr. Patel' and revision = 2
  )
);

select public.write_path_remove_provider(
  'a4440000-0000-4000-8000-000000000001', 'care-provider-rm-1', 'hash-prm-1',
  '{}'::jsonb, now(), null,
  jsonb_build_object('provider_id', 'a8880000-0000-4000-8000-000000000001')
);

select test_care.assert_true(
  'remove_provider soft-deletes the contact',
  exists (
    select 1 from public.providers
    where id = 'a8880000-0000-4000-8000-000000000001' and deleted_at is not null
  )
);

select test_care.expect_sqlstate(
  'create_provider rejects outsider household',
  $stmt$
    select public.write_path_create_provider(
      'a4440000-0000-4000-8000-000000000001', 'care-provider-out', 'hash-po',
      '{}'::jsonb, now(), null,
      jsonb_build_object(
        'household_id', 'a5550000-0000-4000-8000-000000000002',
        'name', 'Elsewhere Clinic',
        'kind', 'veterinarian'
      )
    );
  $stmt$,
  '42501'
);

-- ---------------------------------------------------------------------------
-- 4. RLS isolation + execute lockdown
-- ---------------------------------------------------------------------------

-- Re-seed a live weight and provider for SELECT checks.
select public.write_path_record_weight(
  'a4440000-0000-4000-8000-000000000001', 'care-weight-rls', 'hash-rls-w',
  '{}'::jsonb, now(), null,
  jsonb_build_object(
    'pet_id', 'a6660000-0000-4000-8000-000000000001',
    'measurement_id', 'a7770000-0000-4000-8000-000000000099',
    'value', '7.1', 'unit', 'kg'
  )
);

select public.write_path_create_provider(
  'a4440000-0000-4000-8000-000000000001', 'care-provider-rls', 'hash-rls-p',
  '{}'::jsonb, now(), null,
  jsonb_build_object(
    'household_id', 'a5550000-0000-4000-8000-000000000001',
    'provider_id', 'a8880000-0000-4000-8000-000000000099',
    'name', 'Park Groomer',
    'kind', 'groomer'
  )
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'a4440000-0000-4000-8000-000000000003', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select test_care.assert_true(
  'outsider cannot select weight from another household',
  (select count(*) from public.weight_measurements
   where id = 'a7770000-0000-4000-8000-000000000099') = 0
);

select test_care.assert_true(
  'outsider cannot select provider from another household',
  (select count(*) from public.providers
   where id = 'a8880000-0000-4000-8000-000000000099') = 0
);

select test_care.expect_sqlstate(
  'authenticated cannot execute write_path_record_weight',
  $stmt$
    select public.write_path_record_weight(
      'a4440000-0000-4000-8000-000000000003', 'x', 'y',
      '{}'::jsonb, now(), null, '{}'::jsonb
    );
  $stmt$,
  '42501'
);

reset role;

select set_config('request.jwt.claim.sub', 'a4440000-0000-4000-8000-000000000001', true);
set local role authenticated;

select test_care.assert_true(
  'member can select own household weight',
  (select count(*) from public.weight_measurements
   where id = 'a7770000-0000-4000-8000-000000000099') = 1
);

select test_care.assert_true(
  'member can select own household provider',
  (select count(*) from public.providers
   where id = 'a8880000-0000-4000-8000-000000000099') = 1
);

-- Direct table writes are privilege-denied: only SELECT is granted to
-- authenticated; mutations must go through write-path (same contract as
-- socialization.sql).
select test_care.expect_sqlstate(
  'authenticated member cannot INSERT weight_measurements directly',
  $stmt$
    insert into public.weight_measurements (
      household_id, pet_id, value, unit, effective_date, created_by, updated_by
    ) values (
      'a5550000-0000-4000-8000-000000000001',
      'a6660000-0000-4000-8000-000000000001',
      5.0, 'kg', current_date,
      'a4440000-0000-4000-8000-000000000001',
      'a4440000-0000-4000-8000-000000000001'
    );
  $stmt$,
  '42501'
);

select test_care.expect_sqlstate(
  'authenticated member cannot UPDATE weight_measurements directly',
  $stmt$
    update public.weight_measurements
    set note = 'bypass'
    where id = 'a7770000-0000-4000-8000-000000000099';
  $stmt$,
  '42501'
);

select test_care.expect_sqlstate(
  'authenticated member cannot DELETE weight_measurements directly',
  $stmt$
    delete from public.weight_measurements
    where id = 'a7770000-0000-4000-8000-000000000099';
  $stmt$,
  '42501'
);

select test_care.expect_sqlstate(
  'authenticated member cannot INSERT providers directly',
  $stmt$
    insert into public.providers (
      household_id, name, kind, created_by, updated_by
    ) values (
      'a5550000-0000-4000-8000-000000000001',
      'Direct Clinic', 'veterinarian',
      'a4440000-0000-4000-8000-000000000001',
      'a4440000-0000-4000-8000-000000000001'
    );
  $stmt$,
  '42501'
);

select test_care.expect_sqlstate(
  'authenticated member cannot UPDATE providers directly',
  $stmt$
    update public.providers
    set notes = 'bypass'
    where id = 'a8880000-0000-4000-8000-000000000099';
  $stmt$,
  '42501'
);

select test_care.expect_sqlstate(
  'authenticated member cannot DELETE providers directly',
  $stmt$
    delete from public.providers
    where id = 'a8880000-0000-4000-8000-000000000099';
  $stmt$,
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
  select count(*) into failed from test_care.results where not passed;
  if failed > 0 then
    raise exception '% care assertions failed', failed;
  end if;
  raise notice 'Care suite: all % assertions passed', (select count(*) from test_care.results);
end;
$$;

rollback;
