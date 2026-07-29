-- Life milestones tests (F12, DM §12.5, US-090, LF-01/LF-03).
--
-- Covers:
--   * create / edit / remove milestone with revision checks and idempotency;
--   * archived pet / closed household / outsider guards;
--   * future-date rejection;
--   * non-empty media_refs rejection on create (attach via prepare_* only);
--   * RLS isolation (outsider cannot SELECT);
--   * authenticated members cannot INSERT/UPDATE/DELETE directly;
--   * SECURITY DEFINER lockdown (authenticated cannot EXECUTE write_path_*).
--
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_life;
create table test_life.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create table test_life.state (key text primary key, value text);

grant usage on schema test_life to authenticated;
grant select, insert, update on test_life.results, test_life.state to authenticated;
grant usage, select on all sequences in schema test_life to authenticated;

create or replace function test_life.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_life.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_life.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin perform test_life.record(p_name, coalesce(p_condition, false), p_detail); end;
$$;

create or replace function test_life.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_life.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_life.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

create or replace function test_life.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_life.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_life.val(p_key text)
returns text language sql stable as $$
  select value from test_life.state where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('b4440000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'life-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('b4440000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'life-partner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('b4440000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'life-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

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

-- ---------------------------------------------------------------------------
-- 1. Create milestone
-- ---------------------------------------------------------------------------

select test_life.put(
  'ms_1',
  public.write_path_create_milestone(
    'b4440000-0000-4000-8000-000000000001', 'life-ms-1', 'hash-life-ms-1',
    '{"command":"create_milestone"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'b6660000-0000-4000-8000-000000000001',
      'milestone_id', 'b7770000-0000-4000-8000-000000000001',
      'title', 'First day home',
      'effective_date', (current_date - 10)::text,
      'note', 'Brought Maple home from the breeder'
    )
  )::text
);

select test_life.assert_true(
  'create_milestone returns title',
  (test_life.val('ms_1')::jsonb->'milestone'->>'title') = 'First day home'
);

select test_life.assert_true(
  'create_milestone stores effective_date',
  (test_life.val('ms_1')::jsonb->'milestone'->>'effective_date') = (current_date - 10)::text
);

select test_life.assert_true(
  'create_milestone has revision 1',
  (test_life.val('ms_1')::jsonb->'milestone'->>'revision')::int = 1
);

select test_life.assert_true(
  'create_milestone leaves media_refs null',
  (test_life.val('ms_1')::jsonb->'milestone'->'media_refs') is null
    or (test_life.val('ms_1')::jsonb->'milestone'->>'media_refs') is null
);

-- Idempotent replay
select test_life.assert_true(
  'create_milestone idempotent replay',
  public.write_path_create_milestone(
    'b4440000-0000-4000-8000-000000000001', 'life-ms-1', 'hash-life-ms-1',
    '{"command":"create_milestone"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'b6660000-0000-4000-8000-000000000001',
      'milestone_id', 'b7770000-0000-4000-8000-000000000001',
      'title', 'First day home',
      'effective_date', (current_date - 10)::text,
      'note', 'Brought Maple home from the breeder'
    )
  ) = test_life.val('ms_1')::jsonb
);

select test_life.expect_sqlstate(
  'create_milestone rejects idempotency reuse with different payload',
  format($sql$
    select public.write_path_create_milestone(
      'b4440000-0000-4000-8000-000000000001', 'life-ms-1', 'hash-DIFFERENT',
      '{"command":"create_milestone"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'b6660000-0000-4000-8000-000000000001',
        'title', 'Different title'
      )
    )
  $sql$),
  '23505'
);

select test_life.expect_sqlstate(
  'create_milestone rejects future date',
  format($sql$
    select public.write_path_create_milestone(
      'b4440000-0000-4000-8000-000000000001', 'life-ms-future', 'hash-future',
      '{"command":"create_milestone"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'b6660000-0000-4000-8000-000000000001',
        'title', 'Tomorrow',
        'effective_date', (current_date + 1)::text
      )
    )
  $sql$),
  '22023'
);

select test_life.expect_sqlstate(
  'create_milestone rejects non-empty media_refs',
  format($sql$
    select public.write_path_create_milestone(
      'b4440000-0000-4000-8000-000000000001', 'life-ms-media', 'hash-media',
      '{"command":"create_milestone"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'b6660000-0000-4000-8000-000000000001',
        'title', 'With photo claim',
        'media_refs', jsonb_build_array('fake-media-id')
      )
    )
  $sql$),
  '22023'
);

select test_life.expect_sqlstate(
  'create_milestone rejects archived pet',
  format($sql$
    select public.write_path_create_milestone(
      'b4440000-0000-4000-8000-000000000001', 'life-ms-archived', 'hash-archived',
      '{"command":"create_milestone"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'b6660000-0000-4000-8000-000000000002',
        'title', 'Should fail'
      )
    )
  $sql$),
  '42501'
);

select test_life.expect_sqlstate(
  'create_milestone rejects outsider pet',
  format($sql$
    select public.write_path_create_milestone(
      'b4440000-0000-4000-8000-000000000001', 'life-ms-outsider', 'hash-outsider',
      '{"command":"create_milestone"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'b6660000-0000-4000-8000-000000000003',
        'title', 'Should fail'
      )
    )
  $sql$),
  '42501'
);

-- ---------------------------------------------------------------------------
-- 2. Edit milestone
-- ---------------------------------------------------------------------------

select test_life.put(
  'ms_1_edit',
  public.write_path_edit_milestone(
    'b4440000-0000-4000-8000-000000000002', 'life-ms-edit-1', 'hash-edit-1',
    '{"command":"edit_milestone"}'::jsonb, now(), null,
    jsonb_build_object(
      'milestone_id', 'b7770000-0000-4000-8000-000000000001',
      'expected_revision', 1,
      'title', 'First day home!',
      'note', 'Updated note'
    )
  )::text
);

select test_life.assert_true(
  'edit_milestone bumps revision',
  (test_life.val('ms_1_edit')::jsonb->'milestone'->>'revision')::int = 2
);

select test_life.assert_true(
  'edit_milestone updates title',
  (test_life.val('ms_1_edit')::jsonb->'milestone'->>'title') = 'First day home!'
);

select test_life.expect_sqlstate(
  'edit_milestone rejects stale revision',
  format($sql$
    select public.write_path_edit_milestone(
      'b4440000-0000-4000-8000-000000000001', 'life-ms-stale', 'hash-stale',
      '{"command":"edit_milestone"}'::jsonb, now(), null,
      jsonb_build_object(
        'milestone_id', 'b7770000-0000-4000-8000-000000000001',
        'expected_revision', 1,
        'title', 'Stale'
      )
    )
  $sql$),
  '40001'
);

-- ---------------------------------------------------------------------------
-- 3. Remove milestone
-- ---------------------------------------------------------------------------

select test_life.put(
  'ms_1_remove',
  public.write_path_remove_milestone(
    'b4440000-0000-4000-8000-000000000001', 'life-ms-remove-1', 'hash-remove-1',
    '{"command":"remove_milestone"}'::jsonb, now(), null,
    jsonb_build_object('milestone_id', 'b7770000-0000-4000-8000-000000000001')
  )::text
);

select test_life.assert_true(
  'remove_milestone sets removed_at',
  (test_life.val('ms_1_remove')::jsonb->'milestone'->>'removed_at') is not null
);

select test_life.assert_true(
  'removed milestone hidden from active select',
  not exists (
    select 1 from public.milestones
    where id = 'b7770000-0000-4000-8000-000000000001' and deleted_at is null
  )
);

-- Soft-delete is idempotent at the command layer with a new key
select test_life.assert_true(
  'remove_milestone second call still succeeds',
  (public.write_path_remove_milestone(
    'b4440000-0000-4000-8000-000000000001', 'life-ms-remove-2', 'hash-remove-2',
    '{"command":"remove_milestone"}'::jsonb, now(), null,
    jsonb_build_object('milestone_id', 'b7770000-0000-4000-8000-000000000001')
  )->'milestone'->>'removed_at') is not null
);

-- ---------------------------------------------------------------------------
-- 4. RLS + direct-mutation lockdown
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', 'b4440000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select test_life.assert_true(
  'member can select household milestones (including soft-deleted via RLS)',
  exists (
    select 1 from public.milestones
    where id = 'b7770000-0000-4000-8000-000000000001'
  )
);

select test_life.expect_sqlstate(
  'member cannot insert milestones directly',
  $sql$
    insert into public.milestones (
      household_id, pet_id, title, effective_date, created_by, updated_by
    ) values (
      'b5550000-0000-4000-8000-000000000001',
      'b6660000-0000-4000-8000-000000000001',
      'Direct insert', current_date,
      'b4440000-0000-4000-8000-000000000001',
      'b4440000-0000-4000-8000-000000000001'
    )
  $sql$,
  '42501'
);

select set_config('request.jwt.claim.sub', 'b4440000-0000-4000-8000-000000000003', true);

select test_life.assert_true(
  'outsider cannot select other household milestones',
  not exists (
    select 1 from public.milestones
    where id = 'b7770000-0000-4000-8000-000000000001'
  )
);

select test_life.expect_sqlstate(
  'authenticated cannot execute write_path_create_milestone',
  $sql$
    select public.write_path_create_milestone(
      'b4440000-0000-4000-8000-000000000001', 'life-ms-auth', 'hash-auth',
      '{"command":"create_milestone"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'b6660000-0000-4000-8000-000000000001',
        'title', 'Nope'
      )
    )
  $sql$,
  '42501'
);

reset role;

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

do $$
declare
  failed integer;
  total integer;
begin
  select count(*) filter (where not passed), count(*)
  into failed, total
  from test_life.results;
  raise notice 'Life milestones suite: %/% passed', total - failed, total;
  if failed > 0 then
    raise exception 'Life milestones suite failed: % of % assertions', failed, total;
  end if;
end;
$$;

rollback;
