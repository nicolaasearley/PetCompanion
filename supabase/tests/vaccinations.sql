-- Care vaccinations tests (F10, DM §11.1 vaccination, US-070).
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
-- occurrence generation.
--
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_vaccinations;
create table test_vaccinations.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create table test_vaccinations.state (key text primary key, value text);

grant usage on schema test_vaccinations to authenticated;
grant select, insert, update on test_vaccinations.results, test_vaccinations.state to authenticated;
grant usage, select on all sequences in schema test_vaccinations to authenticated;

create or replace function test_vaccinations.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_vaccinations.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_vaccinations.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  perform test_vaccinations.record(p_name, coalesce(p_condition, false), p_detail);
end;
$$;

create or replace function test_vaccinations.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_vaccinations.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_vaccinations.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

create or replace function test_vaccinations.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_vaccinations.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_vaccinations.val(p_key text)
returns text language sql stable as $$
  select value from test_vaccinations.state where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('b4440000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'vax-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('b4440000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'vax-partner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('b4440000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'vax-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.user_profiles(id, display_name) values
  ('b4440000-0000-4000-8000-000000000001', 'Nic'),
  ('b4440000-0000-4000-8000-000000000002', 'Sarah'),
  ('b4440000-0000-4000-8000-000000000003', 'Outsider');

insert into public.households (id, name, time_zone, created_by, updated_by) values
  ('b5550000-0000-4000-8000-000000000001', 'Maple House', 'America/Toronto',
   'b4440000-0000-4000-8000-000000000001', 'b4440000-0000-4000-8000-000000000001'),
  ('b5550000-0000-4000-8000-000000000002', 'Elsewhere House', 'Europe/Stockholm',
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
   'b4440000-0000-4000-8000-000000000001', 'b4440000-0000-4000-8000-000000000001'),
  ('b6660000-0000-4000-8000-000000000003', 'b5550000-0000-4000-8000-000000000002',
   'Birch', 'exact', current_date - 90, 'active',
   'b4440000-0000-4000-8000-000000000003', 'b4440000-0000-4000-8000-000000000003');

insert into public.household_preferences (household_id, created_by, updated_by) values
  ('b5550000-0000-4000-8000-000000000001', 'b4440000-0000-4000-8000-000000000001',
   'b4440000-0000-4000-8000-000000000001'),
  ('b5550000-0000-4000-8000-000000000002', 'b4440000-0000-4000-8000-000000000003',
   'b4440000-0000-4000-8000-000000000003');

insert into public.providers (
  id, household_id, name, kind, created_by, updated_by
) values (
  'b7770000-0000-4000-8000-000000000001', 'b5550000-0000-4000-8000-000000000001',
  'Riverside Vet', 'veterinarian',
  'b4440000-0000-4000-8000-000000000001', 'b4440000-0000-4000-8000-000000000001'
);

-- ---------------------------------------------------------------------------
-- 1. Record vaccination
-- ---------------------------------------------------------------------------

select test_vaccinations.put(
  'vax_1',
  public.write_path_record_vaccination(
    'b4440000-0000-4000-8000-000000000001', 'vax-1', 'hash-vax-1',
    '{"command":"record_vaccination"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'b6660000-0000-4000-8000-000000000001',
      'vaccination_id', 'b8880000-0000-4000-8000-000000000001',
      'vaccine_name', 'DHPP',
      'effective_date', (current_date - 14)::text,
      'next_due_date', (current_date + 350)::text,
      'provenance', 'professional_instruction',
      'provider_id', 'b7770000-0000-4000-8000-000000000001',
      'note', 'From clinic card'
    )
  )::text
);

select test_vaccinations.assert_true(
  'record_vaccination stores name and next_due as entered',
  exists (
    select 1 from public.vaccination_records
    where id = 'b8880000-0000-4000-8000-000000000001'
      and vaccine_name = 'DHPP'
      and next_due_date = current_date + 350
      and provenance = 'professional_instruction'
      and provider_id = 'b7770000-0000-4000-8000-000000000001'
      and note = 'From clinic card'
      and deleted_at is null
  )
);

select test_vaccinations.assert_true(
  'record_vaccination returns created_by_name attribution',
  (test_vaccinations.val('vax_1')::jsonb->'vaccination'->>'created_by_name') = 'Nic'
);

select test_vaccinations.assert_true(
  'record_vaccination is idempotent',
  public.write_path_record_vaccination(
    'b4440000-0000-4000-8000-000000000001', 'vax-1', 'hash-vax-1',
    '{"command":"record_vaccination"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'b6660000-0000-4000-8000-000000000001',
      'vaccination_id', 'b8880000-0000-4000-8000-000000000001',
      'vaccine_name', 'DHPP',
      'effective_date', (current_date - 14)::text,
      'next_due_date', (current_date + 350)::text,
      'provenance', 'professional_instruction',
      'provider_id', 'b7770000-0000-4000-8000-000000000001',
      'note', 'From clinic card'
    )
  )::text = test_vaccinations.val('vax_1')
);

select test_vaccinations.expect_sqlstate(
  'record_vaccination rejects idempotency reuse with different payload',
  $stmt$
    select public.write_path_record_vaccination(
      'b4440000-0000-4000-8000-000000000001', 'vax-1', 'hash-vax-1-diff',
      '{"command":"record_vaccination"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'b6660000-0000-4000-8000-000000000001',
        'vaccine_name', 'Rabies',
        'effective_date', (current_date - 14)::text
      )
    );
  $stmt$,
  '23505'
);

select test_vaccinations.expect_sqlstate(
  'record_vaccination rejects future effective_date',
  $stmt$
    select public.write_path_record_vaccination(
      'b4440000-0000-4000-8000-000000000001', 'vax-future', 'hash-vax-future',
      '{"command":"record_vaccination"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'b6660000-0000-4000-8000-000000000001',
        'vaccine_name', 'Rabies',
        'effective_date', (current_date + 1)::text
      )
    );
  $stmt$,
  '22023'
);

select test_vaccinations.expect_sqlstate(
  'record_vaccination rejects next_due before given date',
  $stmt$
    select public.write_path_record_vaccination(
      'b4440000-0000-4000-8000-000000000001', 'vax-due-before', 'hash-vax-due-before',
      '{"command":"record_vaccination"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'b6660000-0000-4000-8000-000000000001',
        'vaccine_name', 'Rabies',
        'effective_date', (current_date - 1)::text,
        'next_due_date', (current_date - 30)::text
      )
    );
  $stmt$,
  '22023'
);

select test_vaccinations.expect_sqlstate(
  'record_vaccination rejects archived pet',
  $stmt$
    select public.write_path_record_vaccination(
      'b4440000-0000-4000-8000-000000000001', 'vax-archived', 'hash-vax-archived',
      '{"command":"record_vaccination"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'b6660000-0000-4000-8000-000000000002',
        'vaccine_name', 'Rabies',
        'effective_date', (current_date - 1)::text
      )
    );
  $stmt$,
  '42501'
);

-- ---------------------------------------------------------------------------
-- 2. Edit vaccination
-- ---------------------------------------------------------------------------

select test_vaccinations.put(
  'vax_1_edit',
  public.write_path_edit_vaccination(
    'b4440000-0000-4000-8000-000000000002', 'vax-1-edit', 'hash-vax-1-edit',
    '{"command":"edit_vaccination"}'::jsonb, now(), null,
    jsonb_build_object(
      'vaccination_id', 'b8880000-0000-4000-8000-000000000001',
      'expected_revision', 1,
      'vaccine_name', 'DHPP booster',
      'note', 'Updated from card'
    )
  )::text
);

select test_vaccinations.assert_true(
  'edit_vaccination bumps revision and updates fields',
  exists (
    select 1 from public.vaccination_records
    where id = 'b8880000-0000-4000-8000-000000000001'
      and vaccine_name = 'DHPP booster'
      and note = 'Updated from card'
      and revision = 2
      and updated_by = 'b4440000-0000-4000-8000-000000000002'
  )
);

select test_vaccinations.expect_sqlstate(
  'edit_vaccination rejects stale revision',
  $stmt$
    select public.write_path_edit_vaccination(
      'b4440000-0000-4000-8000-000000000001', 'vax-stale', 'hash-vax-stale',
      '{"command":"edit_vaccination"}'::jsonb, now(), null,
      jsonb_build_object(
        'vaccination_id', 'b8880000-0000-4000-8000-000000000001',
        'expected_revision', 1,
        'vaccine_name', 'Stale'
      )
    );
  $stmt$,
  '40001'
);

-- ---------------------------------------------------------------------------
-- 3. Remove vaccination
-- ---------------------------------------------------------------------------

select public.write_path_remove_vaccination(
  'b4440000-0000-4000-8000-000000000001', 'vax-1-remove', 'hash-vax-1-remove',
  '{"command":"remove_vaccination"}'::jsonb, now(), null,
  jsonb_build_object('vaccination_id', 'b8880000-0000-4000-8000-000000000001')
);

select test_vaccinations.assert_true(
  'remove_vaccination soft-deletes',
  exists (
    select 1 from public.vaccination_records
    where id = 'b8880000-0000-4000-8000-000000000001'
      and deleted_at is not null
      and deleted_by = 'b4440000-0000-4000-8000-000000000001'
  )
);

select test_vaccinations.assert_true(
  'remove_vaccination is idempotent',
  (public.write_path_remove_vaccination(
    'b4440000-0000-4000-8000-000000000001', 'vax-1-remove', 'hash-vax-1-remove',
    '{"command":"remove_vaccination"}'::jsonb, now(), null,
    jsonb_build_object('vaccination_id', 'b8880000-0000-4000-8000-000000000001')
  )->'vaccination'->>'id') = 'b8880000-0000-4000-8000-000000000001'
);

-- ---------------------------------------------------------------------------
-- 4. RLS + direct write denial
-- ---------------------------------------------------------------------------

select test_vaccinations.put(
  'vax_2',
  public.write_path_record_vaccination(
    'b4440000-0000-4000-8000-000000000001', 'vax-2', 'hash-vax-2',
    '{"command":"record_vaccination"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'b6660000-0000-4000-8000-000000000001',
      'vaccination_id', 'b8880000-0000-4000-8000-000000000002',
      'vaccine_name', 'Rabies',
      'effective_date', (current_date - 7)::text,
      'provenance', 'owner_entered'
    )
  )::text
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'b4440000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select test_vaccinations.assert_true(
  'member can SELECT own household vaccination',
  exists (
    select 1 from public.vaccination_records
    where id = 'b8880000-0000-4000-8000-000000000002'
  )
);

select test_vaccinations.expect_sqlstate(
  'member cannot INSERT vaccination directly',
  $stmt$
    insert into public.vaccination_records (
      household_id, pet_id, vaccine_name, effective_date, created_by, updated_by
    ) values (
      'b5550000-0000-4000-8000-000000000001',
      'b6660000-0000-4000-8000-000000000001',
      'Bordetella', current_date - 1,
      'b4440000-0000-4000-8000-000000000001',
      'b4440000-0000-4000-8000-000000000001'
    );
  $stmt$,
  '42501'
);

select test_vaccinations.expect_sqlstate(
  'authenticated cannot EXECUTE write_path_record_vaccination',
  $stmt$
    select public.write_path_record_vaccination(
      'b4440000-0000-4000-8000-000000000001', 'vax-lock', 'hash-vax-lock',
      '{}'::jsonb, now(), null, '{}'::jsonb
    );
  $stmt$,
  '42501'
);

select set_config('request.jwt.claim.sub', 'b4440000-0000-4000-8000-000000000003', true);

select test_vaccinations.assert_true(
  'outsider cannot SELECT other household vaccination',
  not exists (
    select 1 from public.vaccination_records
    where id = 'b8880000-0000-4000-8000-000000000002'
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
  select count(*) into failed from test_vaccinations.results where not passed;
  raise notice 'vaccinations suite: % failed of %',
    failed, (select count(*) from test_vaccinations.results);
  if failed > 0 then
    raise exception '% vaccination assertion(s) failed', failed;
  end if;
end;
$$;

rollback;
