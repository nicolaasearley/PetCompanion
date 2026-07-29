-- Device push token RLS + write-path registration tests (remote APNs foundation).
--
-- Covers:
--   * register / unregister via write_path_*;
--   * owner SELECT, outsider isolation;
--   * authenticated cannot INSERT/UPDATE/DELETE tokens directly;
--   * SECURITY DEFINER lockdown;
--   * verify_due_notification_candidates cancels stale rows and leaves valid
--     scheduled candidates untouched.
--
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_push;
create table test_push.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create table test_push.state (key text primary key, value text);

grant usage on schema test_push to authenticated;
grant select, insert, update on test_push.results, test_push.state to authenticated;
grant usage, select on all sequences in schema test_push to authenticated;

create or replace function test_push.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_push.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_push.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin perform test_push.record(p_name, coalesce(p_condition, false), p_detail); end;
$$;

create or replace function test_push.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_push.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_push.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

create or replace function test_push.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_push.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_push.val(p_key text)
returns text language sql stable as $$
  select value from test_push.state where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('b1110000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'push-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('b1110000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'push-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.user_profiles(id, display_name) values
  ('b1110000-0000-4000-8000-000000000001', 'Push Owner'),
  ('b1110000-0000-4000-8000-000000000002', 'Push Outsider');

insert into public.households (id, name, time_zone, created_by, updated_by) values
  ('b2220000-0000-4000-8000-000000000001', 'Push House', 'America/Toronto',
   'b1110000-0000-4000-8000-000000000001', 'b1110000-0000-4000-8000-000000000001');

insert into public.household_memberships (
  household_id, user_id, role, status, joined_at, created_by, updated_by
) values (
  'b2220000-0000-4000-8000-000000000001',
  'b1110000-0000-4000-8000-000000000001',
  'owner', 'active', now(),
  'b1110000-0000-4000-8000-000000000001',
  'b1110000-0000-4000-8000-000000000001'
);

insert into public.pets (
  id, household_id, name, species, birth_date_kind, birth_date,
  created_by, updated_by
) values (
  'b3330000-0000-4000-8000-000000000001',
  'b2220000-0000-4000-8000-000000000001',
  'Maple', 'dog', 'exact', current_date - 90,
  'b1110000-0000-4000-8000-000000000001',
  'b1110000-0000-4000-8000-000000000001'
);

-- Minimal schedule + pending occurrence for candidate verify coverage.
insert into public.task_definitions (
  id, provenance, household_id, title, category, default_obligation_class,
  default_effort, default_time_policy, created_by, updated_by
) values (
  'b4440000-0000-4000-8000-000000000001',
  'user',
  'b2220000-0000-4000-8000-000000000001',
  'Walk', 'routine', 'scheduled', 'short', 'anytime',
  'b1110000-0000-4000-8000-000000000001',
  'b1110000-0000-4000-8000-000000000001'
);

insert into public.task_schedules (
  id, household_id, pet_id, task_definition_id, recurrence, origin,
  obligation_class, active_range_start_date, created_by, updated_by
) values (
  'b5550000-0000-4000-8000-000000000001',
  'b2220000-0000-4000-8000-000000000001',
  'b3330000-0000-4000-8000-000000000001',
  'b4440000-0000-4000-8000-000000000001',
  '{"type":"once","anchor_date":"2026-07-29","time_policy":"anytime"}'::jsonb,
  'user_created', 'scheduled', current_date,
  'b1110000-0000-4000-8000-000000000001',
  'b1110000-0000-4000-8000-000000000001'
);

insert into public.task_occurrences (
  id, occurrence_key, household_id, pet_id, schedule_id, local_due_date,
  original_local_due_date, time_policy, state, obligation_class,
  origin, created_by, updated_by
) values (
  'b6660000-0000-4000-8000-000000000001',
  'PUSH-TEST-OCC-PENDING',
  'b2220000-0000-4000-8000-000000000001',
  'b3330000-0000-4000-8000-000000000001',
  'b5550000-0000-4000-8000-000000000001',
  current_date, current_date,
  'anytime', 'pending', 'scheduled', 'user_created',
  'b1110000-0000-4000-8000-000000000001',
  'b1110000-0000-4000-8000-000000000001'
),
(
  'b6660000-0000-4000-8000-000000000002',
  'PUSH-TEST-OCC-COMPLETED',
  'b2220000-0000-4000-8000-000000000001',
  'b3330000-0000-4000-8000-000000000001',
  'b5550000-0000-4000-8000-000000000001',
  current_date, current_date,
  'anytime', 'completed', 'scheduled', 'user_created',
  'b1110000-0000-4000-8000-000000000001',
  'b1110000-0000-4000-8000-000000000001'
);

-- ---------------------------------------------------------------------------
-- Register device token
-- ---------------------------------------------------------------------------

select public.write_path_register_device_token(
  'b1110000-0000-4000-8000-000000000001',
  'push-reg-1',
  'hash-push-reg-1',
  '{"command":"register_device_token"}'::jsonb,
  now(), null,
  jsonb_build_object(
    'token', 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899',
    'environment', 'sandbox',
    'platform', 'ios',
    'app_build', '1'
  )
);

select test_push.assert_true(
  'register: owner has one active token',
  (select count(*) = 1 from public.device_push_tokens
   where user_id = 'b1110000-0000-4000-8000-000000000001' and revoked_at is null)
);

select test_push.put(
  'token_id',
  (select id::text from public.device_push_tokens
   where user_id = 'b1110000-0000-4000-8000-000000000001' and revoked_at is null limit 1)
);

-- Idempotent replay
select test_push.assert_true(
  'register: idempotent replay returns same token',
  (
    select (public.write_path_register_device_token(
      'b1110000-0000-4000-8000-000000000001',
      'push-reg-1',
      'hash-push-reg-1',
      '{"command":"register_device_token"}'::jsonb,
      now(), null,
      jsonb_build_object(
        'token', 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899',
        'environment', 'sandbox',
        'platform', 'ios',
        'app_build', '1'
      )
    )->'device_token'->>'id') = test_push.val('token_id')
  )
);

-- ---------------------------------------------------------------------------
-- RLS isolation
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', 'b1110000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select test_push.assert_true(
  'rls: owner can select own token',
  (select count(*) = 1 from public.device_push_tokens
   where id = test_push.val('token_id')::uuid)
);

select test_push.expect_sqlstate(
  'rls: owner cannot insert token directly',
  $s$insert into public.device_push_tokens (
       user_id, token, environment
     ) values (
       'b1110000-0000-4000-8000-000000000001',
       '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff',
       'sandbox'
     )$s$,
  '42501'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'b1110000-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select test_push.assert_true(
  'rls: outsider sees 0 tokens',
  (select count(*) = 0 from public.device_push_tokens)
);

reset role;

select test_push.expect_sqlstate(
  'security: authenticated cannot execute register RPC',
  $s$set local role authenticated;
    select set_config('request.jwt.claim.sub', 'b1110000-0000-4000-8000-000000000001', true);
    select public.write_path_register_device_token(
      'b1110000-0000-4000-8000-000000000001', 'x', 'y', '{}'::jsonb, now(), null, '{}'::jsonb
    )$s$,
  '42501'
);

reset role;

-- ---------------------------------------------------------------------------
-- Unregister
-- ---------------------------------------------------------------------------

select public.write_path_unregister_device_token(
  'b1110000-0000-4000-8000-000000000001',
  'push-unreg-1',
  'hash-push-unreg-1',
  '{"command":"unregister_device_token"}'::jsonb,
  now(), null,
  jsonb_build_object(
    'token', 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899'
  )
);

select test_push.assert_true(
  'unregister: token revoked',
  (select revoked_at is not null from public.device_push_tokens
   where id = test_push.val('token_id')::uuid)
);

-- ---------------------------------------------------------------------------
-- verify_due_notification_candidates
-- ---------------------------------------------------------------------------

insert into public.notification_candidates (
  id, recipient_user_id, household_id, occurrence_id, class, source_ref,
  scheduled_for, dedupe_key, state
) values
(
  'b7770000-0000-4000-8000-000000000001',
  'b1110000-0000-4000-8000-000000000001',
  'b2220000-0000-4000-8000-000000000001',
  'b6660000-0000-4000-8000-000000000001',
  'task_due', '{}'::jsonb, now() - interval '1 minute',
  'push-test-eligible', 'scheduled'
),
(
  'b7770000-0000-4000-8000-000000000002',
  'b1110000-0000-4000-8000-000000000001',
  'b2220000-0000-4000-8000-000000000001',
  'b6660000-0000-4000-8000-000000000002',
  'task_due', '{}'::jsonb, now() - interval '1 minute',
  'push-test-stale-completed', 'scheduled'
);

select test_push.put(
  'verify',
  public.verify_due_notification_candidates(now(), 50)::text
);

select test_push.assert_true(
  'verify: cancels completed-occurrence candidate',
  (select state = 'cancelled' and resolution_reason = 'occurrence_completed'
   from public.notification_candidates
   where id = 'b7770000-0000-4000-8000-000000000002')
);

select test_push.assert_true(
  'verify: leaves eligible candidate scheduled',
  (select state = 'scheduled'
   from public.notification_candidates
   where id = 'b7770000-0000-4000-8000-000000000001')
);

select test_push.assert_true(
  'verify: writes dispatch run',
  (select count(*) >= 1 from public.notification_dispatch_runs where mode = 'verify_only')
);

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

do $$
declare
  failed integer;
begin
  select count(*) into failed from test_push.results where not passed;
  raise notice 'device_push suite failures: %', failed;
  if failed > 0 then
    raise exception '% assertion(s) failed in device_push suite', failed;
  end if;
end;
$$;

rollback;
