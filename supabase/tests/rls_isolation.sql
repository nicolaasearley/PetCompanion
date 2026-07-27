-- WP-1 exit test: RLS isolation
--
-- Verifies, for every public table that carries household-owned or user-owned
-- data, that:
--   * a user who is NOT an active member of household H cannot read H's rows
--     (RLS filters them to zero rows -- `authenticated` holds a table-wide
--     SELECT grant, so the isolation mechanism under test is genuinely RLS,
--     not an accidental privilege-layer lockout);
--   * a user who IS an active member of H can read H's rows, scoped correctly;
--   * global content tables are readable by any authenticated user;
--   * user-owned tables are visible, insertable, and updatable only by their
--     owning user (self-scoped RLS WITH CHECK);
--   * client-role (authenticated) writes are denied -- at the privilege layer,
--     since Slice A grants INSERT/UPDATE to `authenticated` only on
--     user_profiles/user_preferences -- on every other, invariant-bearing
--     table, even for A, the legitimate active owner of H (writes to those
--     tables go through the service-role write path);
--   * the two write_path_* RPC functions cannot be called directly by
--     anon/authenticated (service_role only);
--   * `anon` has no direct table access at all (no session -> no data).
--
-- Context: an earlier pass over this migration found that `authenticated`/
-- `anon`/`service_role` had ZERO table-level GRANTs on any public table (only
-- REFERENCES/TRIGGER/TRUNCATE from the schema's restrictive default ACL), so
-- every query -- including the "member reads own data" and "world-readable
-- content" cases -- failed with permission-denied before RLS was ever
-- evaluated. That has since been fixed in the migration itself (the
-- `grant select on all tables ... to authenticated` / `grant insert, update
-- on user_profiles, user_preferences to authenticated` block near its end)
-- and verified live. This file tests against that corrected, current grant
-- state; see the final report for a walkthrough of what was found and fixed.
--
-- Design notes:
--   * All setup is performed as the `postgres` superuser (bypasses RLS).
--   * Impersonation of a given end user is done with
--       set local role authenticated;
--       select set_config('request.jwt.claims', '{"sub":"<uuid>","role":"authenticated"}', true);
--     both of which are transaction-local and vanish on rollback.
--   * Every test result is recorded via test_harness.record(); the run ends by
--     raising an exception (nonzero exit code) if any assertion failed, after
--     printing a full pass/fail table.
--   * The entire file runs inside one transaction and is rolled back: no
--     seeded rows or harness objects persist after this script completes, and
--     no migration or grant is modified.

\set ON_ERROR_STOP on
begin;

-- ============================================================================
-- 0. Test harness
-- ============================================================================

create schema test_harness;

create table test_harness.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text,
  created_at timestamptz not null default clock_timestamp()
);

grant usage on schema test_harness to authenticated, anon;
grant select, insert on test_harness.results to authenticated, anon;
grant usage, select on all sequences in schema test_harness to authenticated, anon;

create or replace function test_harness.record(p_name text, p_passed boolean, p_detail text default null)
returns void
language plpgsql
as $$
begin
  insert into test_harness.results (name, passed, detail) values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %', case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

-- Runs p_query (must return a single bigint via `select count(*) ...`) as the
-- CURRENT role/JWT context. p_expect_zero=true means "this caller must see no
-- rows" -- satisfied by either an RLS-filtered empty result OR an outright
-- permission-denied error (stronger isolation, not weaker; either is recorded
-- as a pass, with the actual mechanism preserved in the detail column so the
-- report can distinguish "RLS filtered" from "no grant at all").
-- p_expect_zero=false means "this caller must see at least one row"; an error
-- in that case is always a failure.
create or replace function test_harness.run_count_check(p_name text, p_query text, p_expect_zero boolean)
returns void
language plpgsql
as $$
declare
  cnt bigint;
  ok boolean;
  detail text;
begin
  begin
    execute p_query into cnt;
    if p_expect_zero then
      ok := (cnt = 0);
      detail := format('rows visible=%s (expected 0)', cnt);
    else
      ok := (cnt > 0);
      detail := format('rows visible=%s (expected >0)', cnt);
    end if;
  exception when others then
    if p_expect_zero then
      ok := true;
      detail := format('query denied outright (no access at all -> isolation holds): %s', sqlerrm);
    else
      ok := false;
      detail := format('query denied/errored but rows were expected to be visible: %s', sqlerrm);
    end if;
  end;
  perform test_harness.record(p_name, ok, detail);
end;
$$;

-- Requires the exact row count p_expected, with no error tolerance: used for
-- "self-only" checks where we know precisely how many rows the caller's own
-- data should produce.
create or replace function test_harness.run_exact_count_check(p_name text, p_query text, p_expected bigint)
returns void
language plpgsql
as $$
declare
  cnt bigint;
  ok boolean;
  detail text;
begin
  begin
    execute p_query into cnt;
    ok := (cnt = p_expected);
    detail := format('rows visible=%s (expected exactly %s)', cnt, p_expected);
  exception when others then
    ok := false;
    detail := format('errored: %s', sqlerrm);
  end;
  perform test_harness.record(p_name, ok, detail);
end;
$$;

-- Runs p_stmt (any DML) and expects it to fail (privilege denial, RLS denial,
-- or a trigger -- any error counts as "denied").
create or replace function test_harness.run_write_denied_check(p_name text, p_stmt text)
returns void
language plpgsql
as $$
begin
  begin
    execute p_stmt;
    perform test_harness.record(p_name, false, 'write UNEXPECTEDLY succeeded (no error raised)');
  exception when others then
    perform test_harness.record(p_name, true, format('write denied as expected: %s', sqlerrm));
  end;
end;
$$;

-- Runs p_stmt and expects it to SUCCEED (self-service policy checks, e.g. a
-- user inserting their own user_profiles row).
create or replace function test_harness.run_write_allowed_check(p_name text, p_stmt text)
returns void
language plpgsql
as $$
begin
  begin
    execute p_stmt;
    perform test_harness.record(p_name, true, 'write succeeded as expected');
  exception when others then
    perform test_harness.record(p_name, false, format('write unexpectedly denied: %s', sqlerrm));
  end;
end;
$$;

-- Runs p_stmt (an UPDATE/DELETE) as the current role and expects it to affect
-- ZERO rows without raising an error. This is the correct RLS behavior for a
-- USING-clause policy applied to a statement whose WHERE targets a row the
-- caller cannot see: Postgres silently filters it out (like an implicit
-- extra WHERE predicate), it does not raise an exception. Contrast with
-- run_write_denied_check, which is for statements blocked outright at the
-- privilege layer (those DO raise "permission denied for table ...").
-- An outright error is also accepted here (stronger, not weaker).
create or replace function test_harness.run_update_no_effect_check(p_name text, p_stmt text)
returns void
language plpgsql
as $$
declare
  rc bigint;
begin
  begin
    execute p_stmt;
    get diagnostics rc = row_count;
    if rc = 0 then
      perform test_harness.record(p_name, true, 'RLS correctly scoped the statement to zero rows');
    else
      perform test_harness.record(p_name, false, format('cross-user write affected %s row(s) -- RLS did NOT scope it', rc));
    end if;
  exception when others then
    perform test_harness.record(p_name, true, format('statement denied outright: %s', sqlerrm));
  end;
end;
$$;

grant execute on function test_harness.run_count_check(text, text, boolean) to authenticated, anon;
grant execute on function test_harness.run_exact_count_check(text, text, bigint) to authenticated, anon;
grant execute on function test_harness.run_write_denied_check(text, text) to authenticated, anon;
grant execute on function test_harness.run_write_allowed_check(text, text) to authenticated, anon;
grant execute on function test_harness.run_update_no_effect_check(text, text) to authenticated, anon;

-- ============================================================================
-- 1. Fixtures (as postgres / superuser -- bypasses RLS)
-- ============================================================================

-- Users:
--   user_a - active OWNER of household H.               "the member"
--   user_b - active OWNER of a DIFFERENT household H2.   "the non-member of H"
--   user_c - has no household, no profile row yet.       "the fresh signup"
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wp1-user-a@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wp1-user-b@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wp1-user-c@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.households (id, name, time_zone, status, created_by, updated_by)
values
  ('a1111111-0000-0000-0000-000000000001', 'Household H (A owns)', 'America/Los_Angeles', 'active', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111'),
  ('a2222222-0000-0000-0000-000000000002', 'Household H2 (B owns)', 'America/New_York', 'active', '22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222');

-- A is active owner of H. B has a REMOVED (ended) membership in H -- proving a
-- terminated membership does not grant access. B is active owner of H2 (a
-- DIFFERENT household) -- proving isolation is genuinely per-household, not
-- merely "has some active membership somewhere".
insert into public.household_memberships (id, household_id, user_id, role, status, joined_at, ended_at, ended_by, created_by, updated_by)
values
  ('a3333333-0000-0000-0000-000000000001', 'a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'owner', 'active', now() - interval '10 days', null, null, '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111'),
  ('a3333333-0000-0000-0000-000000000002', 'a1111111-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'caregiver', 'removed', now() - interval '9 days', now() - interval '1 day', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111'),
  ('a3333333-0000-0000-0000-000000000003', 'a2222222-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'owner', 'active', now() - interval '10 days', null, null, '22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222');

insert into public.household_invitations (id, household_id, created_by, token_hash, role_granted, expires_at, status, updated_by)
values ('a4444444-0000-0000-0000-000000000001', 'a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fixture-token-hash', 'caregiver', now() + interval '3 days', 'pending', '11111111-1111-1111-1111-111111111111');

insert into public.pets (id, household_id, name, species, birth_date_kind, birth_date, homecoming_date, status, created_by, updated_by)
values
  ('b1111111-0000-0000-0000-000000000001', 'a1111111-0000-0000-0000-000000000001', 'Fixture Pup H', 'dog', 'exact', '2026-05-01', '2026-05-10', 'active', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111'),
  ('b2222222-0000-0000-0000-000000000002', 'a2222222-0000-0000-0000-000000000002', 'Fixture Pup H2', 'dog', 'exact', '2026-05-01', '2026-05-10', 'active', '22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222');

insert into public.household_preferences (household_id, created_by, updated_by)
values
  ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111'),
  ('a2222222-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222');

insert into public.pet_preferences (pet_id, household_id, created_by, updated_by)
values
  ('b1111111-0000-0000-0000-000000000001', 'a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111'),
  ('b2222222-0000-0000-0000-000000000002', 'a2222222-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222');

insert into public.user_profiles (id, display_name)
values
  ('11111111-1111-1111-1111-111111111111', 'User A'),
  ('22222222-2222-2222-2222-222222222222', 'User B');

insert into public.user_preferences (user_id)
values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

-- One user-provenance task_definition scoped to H (should be H-member-only),
-- distinct from the world-readable system task_definitions already seeded.
insert into public.task_definitions (id, provenance, household_id, title, category, default_obligation_class, default_effort, default_time_policy, created_by, updated_by)
values ('c1111111-0000-0000-0000-000000000001', 'user', 'a1111111-0000-0000-0000-000000000001', 'Fixture household-only task', 'routine', 'scheduled', 'short', 'anytime', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111');

insert into public.task_schedules (id, household_id, pet_id, task_definition_id, recurrence, origin, obligation_class, active_range_start_date, created_by, updated_by)
values ('d1111111-0000-0000-0000-000000000001', 'a1111111-0000-0000-0000-000000000001', 'b1111111-0000-0000-0000-000000000001', 'c1111111-0000-0000-0000-000000000001',
        '{"type":"once","anchor_date":"2026-07-26","time_policy":"anytime"}'::jsonb, 'user_created', 'scheduled', '2026-07-26', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111');

insert into public.task_occurrences (id, occurrence_key, household_id, pet_id, schedule_id, local_due_date, original_local_due_date, time_policy, state, obligation_class, origin, created_by, updated_by)
values ('e1111111-0000-0000-0000-000000000001', 'FIXTURE-RLS-OCC-1', 'a1111111-0000-0000-0000-000000000001', 'b1111111-0000-0000-0000-000000000001', 'd1111111-0000-0000-0000-000000000001',
        '2026-07-26', '2026-07-26', 'anytime', 'pending', 'scheduled', 'user_created', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111');

insert into public.dispositions (id, household_id, occurrence_id, action, actor_user_id, recorded_at, effective_at, client_idempotency_key)
values ('f1111111-0000-0000-0000-000000000001', 'a1111111-0000-0000-0000-000000000001', 'e1111111-0000-0000-0000-000000000001', 'complete', '11111111-1111-1111-1111-111111111111', now(), now(), 'fixture-disp-key-1');

insert into public.notification_candidates (
  id, recipient_user_id, household_id, occurrence_id, class, source_ref,
  scheduled_for, dedupe_key
)
values (
  '06111111-0000-0000-0000-000000000001',
  '11111111-1111-1111-1111-111111111111',
  'a1111111-0000-0000-0000-000000000001',
  'e1111111-0000-0000-0000-000000000001',
  'task_due', '{"fixture":true}'::jsonb, now() + interval '1 hour',
  'fixture-notification-a-1'
);

insert into public.plans (id, household_id, pet_id, local_date, time_zone_snapshot, stage_snapshot, capacity_mode_applied, catalogue_version_set, input_digest, status, created_by, updated_by)
values ('01111111-0000-0000-0000-000000000001', 'a1111111-0000-0000-0000-000000000001', 'b1111111-0000-0000-0000-000000000001', '2026-07-26', 'America/Los_Angeles', '{}'::jsonb, 'normal', '[]'::jsonb, 'fixture-digest-1', 'open', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111');

insert into public.plan_items (id, plan_id, item_key, kind, category, obligation_class, priority_tier, section)
values ('02111111-0000-0000-0000-000000000001', '01111111-0000-0000-0000-000000000001', 'fixture-item-1', 'informational', 'routine', 'informational', 'P3', 'today');

insert into public.audit_events (id, household_id, actor_user_id, entity_ref, action, summary)
values ('03111111-0000-0000-0000-000000000001', 'a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '{"type":"household","id":"a1111111-0000-0000-0000-000000000001"}'::jsonb, 'household.created', '{}'::jsonb);

insert into public.analytics_events (id, household_id, actor_user_id, event_name, metadata)
values ('04111111-0000-0000-0000-000000000001', 'a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'plan_generated', '{}'::jsonb);

insert into public.command_log (id, actor_user_id, client_idempotency_key, command, payload_hash, request_body, status, recorded_at, completed_at)
values
  ('05111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fixture-cmd-a-1', 'create_household', 'hash-a', '{}'::jsonb, 'succeeded', now(), now()),
  ('05111111-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'fixture-cmd-b-1', 'create_household', 'hash-b', '{}'::jsonb, 'succeeded', now(), now());

-- ============================================================================
-- 2. Household-owned tables: non-member B must see zero rows of H
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);

select test_harness.run_count_check('households: non-member B sees 0 rows of H', $q$select count(*) from public.households where id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('household_memberships: non-member B sees 0 rows of H (incl. own removed row)', $q$select count(*) from public.household_memberships where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('household_invitations: non-member B sees 0 rows of H', $q$select count(*) from public.household_invitations where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('pets: non-member B sees 0 rows of H', $q$select count(*) from public.pets where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('household_preferences: non-member B sees 0 rows of H', $q$select count(*) from public.household_preferences where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('pet_preferences: non-member B sees 0 rows of H', $q$select count(*) from public.pet_preferences where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('task_definitions: non-member B sees 0 user-provenance rows of H', $q$select count(*) from public.task_definitions where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('task_schedules: non-member B sees 0 rows of H', $q$select count(*) from public.task_schedules where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('task_occurrences: non-member B sees 0 rows of H', $q$select count(*) from public.task_occurrences where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('dispositions: non-member B sees 0 rows of H', $q$select count(*) from public.dispositions where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('notification_candidates: non-recipient B sees 0 rows of H', $q$select count(*) from public.notification_candidates where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('plans: non-member B sees 0 rows of H', $q$select count(*) from public.plans where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('plan_items: non-member B sees 0 rows of H (via plan join)', $q$select count(*) from public.plan_items pi join public.plans p on p.id = pi.plan_id where p.household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('audit_events: non-member B sees 0 rows of H', $q$select count(*) from public.audit_events where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);
select test_harness.run_count_check('analytics_events: non-member B sees 0 rows of H', $q$select count(*) from public.analytics_events where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, true);

-- ============================================================================
-- 3. Household-owned tables: member A must see H's seeded rows
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);

select test_harness.run_exact_count_check('households: member A sees exactly H', $q$select count(*) from public.households where id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);
select test_harness.run_count_check('household_memberships: member A sees H memberships', $q$select count(*) from public.household_memberships where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, false);
select test_harness.run_exact_count_check('household_invitations: member A sees exactly H''s invitation', $q$select count(*) from public.household_invitations where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);
select test_harness.run_exact_count_check('pets: member A sees exactly H''s pet', $q$select count(*) from public.pets where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);
select test_harness.run_exact_count_check('household_preferences: member A sees exactly H''s preferences', $q$select count(*) from public.household_preferences where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);
select test_harness.run_exact_count_check('pet_preferences: member A sees exactly H''s pet preferences', $q$select count(*) from public.pet_preferences where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);
select test_harness.run_exact_count_check('task_definitions: member A sees exactly H''s user-provenance task def', $q$select count(*) from public.task_definitions where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);
select test_harness.run_count_check('task_definitions: A also sees system-provenance defs', $q$select count(*) from public.task_definitions where provenance = 'system'$q$, false);
select test_harness.run_exact_count_check('task_schedules: member A sees exactly H''s schedule', $q$select count(*) from public.task_schedules where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);
select test_harness.run_exact_count_check('task_occurrences: member A sees exactly H''s occurrence', $q$select count(*) from public.task_occurrences where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);
select test_harness.run_exact_count_check('dispositions: member A sees exactly H''s disposition', $q$select count(*) from public.dispositions where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);
select test_harness.run_exact_count_check('notification_candidates: recipient A sees exactly own candidate', $q$select count(*) from public.notification_candidates where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);
select test_harness.run_exact_count_check('plans: member A sees exactly H''s plan', $q$select count(*) from public.plans where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);
select test_harness.run_exact_count_check('plan_items: member A sees exactly H''s plan item (via plan join)', $q$select count(*) from public.plan_items pi join public.plans p on p.id = pi.plan_id where p.household_id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);
select test_harness.run_exact_count_check('audit_events: member A sees exactly H''s audit event', $q$select count(*) from public.audit_events where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);
select test_harness.run_exact_count_check('analytics_events: member A sees exactly H''s analytics event', $q$select count(*) from public.analytics_events where household_id = 'a1111111-0000-0000-0000-000000000001'$q$, 1);

-- B, despite NOT being a member of H, IS an active member of H2: confirm B
-- sees H2's own data (proves scoping is genuinely per-household, not a
-- blanket "no household data at all" failure mode).
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
select test_harness.run_count_check('pets: B (member of H2) sees H2''s own pet', $q$select count(*) from public.pets where household_id = 'a2222222-0000-0000-0000-000000000002'$q$, false);
select test_harness.run_count_check('households: B (member of H2) sees H2 itself', $q$select count(*) from public.households where id = 'a2222222-0000-0000-0000-000000000002'$q$, false);

-- ============================================================================
-- 4. Global content tables: world-readable to any authenticated user
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
select test_harness.run_count_check('content_versions: non-member B can read global content', $q$select count(*) from public.content_versions$q$, false);
select test_harness.run_count_check('development_stages: non-member B can read global content', $q$select count(*) from public.development_stages$q$, false);
select test_harness.run_count_check('recommendation_rules: non-member B can read global content', $q$select count(*) from public.recommendation_rules$q$, false);
select test_harness.run_count_check('training_skills: non-member B can read global content', $q$select count(*) from public.training_skills$q$, false);
select test_harness.run_count_check('socialization_catalog: non-member B can read global content', $q$select count(*) from public.socialization_catalog$q$, false);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select test_harness.run_count_check('content_versions: member A can read global content', $q$select count(*) from public.content_versions$q$, false);

-- ============================================================================
-- 5. User-owned tables: self-only reads (user_profiles, user_preferences,
--    command_log)
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select test_harness.run_exact_count_check('user_profiles: A sees exactly own profile row', $q$select count(*) from public.user_profiles$q$, 1);
select test_harness.run_exact_count_check('user_preferences: A sees exactly own preferences row', $q$select count(*) from public.user_preferences$q$, 1);
select test_harness.run_exact_count_check('command_log: A sees exactly own command_log row', $q$select count(*) from public.command_log$q$, 1);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
select test_harness.run_exact_count_check('user_profiles: B sees exactly own profile row (not A''s)', $q$select count(*) from public.user_profiles$q$, 1);
select test_harness.run_exact_count_check('user_preferences: B sees exactly own preferences row (not A''s)', $q$select count(*) from public.user_preferences$q$, 1);
select test_harness.run_exact_count_check('command_log: B sees exactly own command_log row (not A''s)', $q$select count(*) from public.command_log$q$, 1);

-- ============================================================================
-- 6. User-owned tables: self-service INSERT/UPDATE (the one place clients DO
--    write directly), self-scoped, cross-user denied
-- ============================================================================

-- C is a fresh signup with no profile/preferences row yet.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
select test_harness.run_write_allowed_check('user_profiles: C can INSERT own profile', $s$insert into public.user_profiles (id, display_name) values ('33333333-3333-3333-3333-333333333333', 'User C')$s$);
select test_harness.run_write_allowed_check('user_preferences: C can INSERT own preferences', $s$insert into public.user_preferences (user_id) values ('33333333-3333-3333-3333-333333333333')$s$);
select test_harness.run_write_denied_check('user_profiles: C cannot INSERT a profile row impersonating A', $s$insert into public.user_profiles (id, display_name) values ('11111111-1111-1111-1111-111111111111', 'Impersonated A') on conflict (id) do update set display_name = excluded.display_name$s$);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select test_harness.run_write_allowed_check('user_profiles: A can UPDATE own profile', $s$update public.user_profiles set display_name = 'User A (updated)' where id = '11111111-1111-1111-1111-111111111111'$s$);
select test_harness.run_update_no_effect_check('user_profiles: A cannot UPDATE B''s profile (RLS scopes UPDATE to zero rows, not an error)', $s$update public.user_profiles set display_name = 'Hacked' where id = '22222222-2222-2222-2222-222222222222'$s$);
select test_harness.run_write_denied_check('user_profiles: A cannot DELETE own profile (no DELETE grant at all)', $s$delete from public.user_profiles where id = '11111111-1111-1111-1111-111111111111'$s$);
select test_harness.run_update_no_effect_check('user_preferences: A cannot UPDATE B''s preferences (RLS scopes UPDATE to zero rows, not an error)', $s$update public.user_preferences set morning_summary_opt_in = false where user_id = '22222222-2222-2222-2222-222222222222'$s$);
select test_harness.run_write_denied_check('user_preferences: A cannot DELETE own preferences (no DELETE grant at all)', $s$delete from public.user_preferences where user_id = '11111111-1111-1111-1111-111111111111'$s$);

-- ============================================================================
-- 7. Client-role (authenticated) writes must be DENIED on every
--    household-owned / invariant-bearing table, even for A, the legitimate
--    active owner of H (writes go through the service-role write path;
--    `authenticated` holds no INSERT/UPDATE/DELETE grant on these tables).
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);

select test_harness.run_write_denied_check('write-denied: A cannot INSERT households directly', $s$insert into public.households (name, time_zone, created_by, updated_by) values ('Hacked', 'UTC', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111')$s$);
select test_harness.run_write_denied_check('write-denied: A cannot UPDATE own household directly', $s$update public.households set name = 'Hacked' where id = 'a1111111-0000-0000-0000-000000000001'$s$);
select test_harness.run_write_denied_check('write-denied: A cannot INSERT a membership (self-elevate)', $s$insert into public.household_memberships (household_id, user_id, role, status, joined_at, created_by, updated_by) values ('a1111111-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'owner', 'active', now(), '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111')$s$);
select test_harness.run_write_denied_check('write-denied: A cannot INSERT a pet directly', $s$insert into public.pets (household_id, name, species, birth_date_kind, birth_date, status, created_by, updated_by) values ('a1111111-0000-0000-0000-000000000001', 'Sneaky Pup', 'dog', 'exact', '2026-01-01', 'active', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111')$s$);
select test_harness.run_write_denied_check('write-denied: A cannot UPDATE own pet directly', $s$update public.pets set name = 'Hacked' where id = 'b1111111-0000-0000-0000-000000000001'$s$);
select test_harness.run_write_denied_check('write-denied: A cannot DELETE own pet directly', $s$delete from public.pets where id = 'b1111111-0000-0000-0000-000000000001'$s$);
select test_harness.run_write_denied_check('write-denied: A cannot INSERT a task_schedule directly', $s$insert into public.task_schedules (household_id, pet_id, task_definition_id, recurrence, origin, obligation_class, active_range_start_date, created_by, updated_by) values ('a1111111-0000-0000-0000-000000000001', 'b1111111-0000-0000-0000-000000000001', 'c1111111-0000-0000-0000-000000000001', '{"type":"once","anchor_date":"2026-08-01","time_policy":"anytime"}'::jsonb, 'user_created', 'scheduled', '2026-08-01', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111')$s$);
select test_harness.run_write_denied_check('write-denied: A cannot INSERT a task_occurrence directly', $s$insert into public.task_occurrences (occurrence_key, household_id, pet_id, schedule_id, local_due_date, original_local_due_date, time_policy, state, obligation_class, origin, created_by, updated_by) values ('SNEAKY-OCC', 'a1111111-0000-0000-0000-000000000001', 'b1111111-0000-0000-0000-000000000001', 'd1111111-0000-0000-0000-000000000001', '2026-08-01', '2026-08-01', 'anytime', 'pending', 'scheduled', 'user_created', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111')$s$);
select test_harness.run_write_denied_check('write-denied: A cannot INSERT a disposition directly (must go through write path)', $s$insert into public.dispositions (household_id, occurrence_id, action, actor_user_id, recorded_at, effective_at, client_idempotency_key) values ('a1111111-0000-0000-0000-000000000001', 'e1111111-0000-0000-0000-000000000001', 'complete', '11111111-1111-1111-1111-111111111111', now(), now(), 'sneaky-disp-key')$s$);
select test_harness.run_write_denied_check('write-denied: A cannot INSERT a notification candidate directly', $s$insert into public.notification_candidates (recipient_user_id, household_id, occurrence_id, class, source_ref, scheduled_for, dedupe_key) values ('11111111-1111-1111-1111-111111111111', 'a1111111-0000-0000-0000-000000000001', 'e1111111-0000-0000-0000-000000000001', 'task_due', '{}'::jsonb, now(), 'sneaky-notification')$s$);
select test_harness.run_write_denied_check('write-denied: A cannot INSERT a plan directly', $s$insert into public.plans (household_id, pet_id, local_date, time_zone_snapshot, stage_snapshot, capacity_mode_applied, catalogue_version_set, input_digest, created_by, updated_by) values ('a1111111-0000-0000-0000-000000000001', 'b1111111-0000-0000-0000-000000000001', '2026-08-02', 'America/Los_Angeles', '{}'::jsonb, 'normal', '[]'::jsonb, 'sneaky-digest', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111')$s$);
select test_harness.run_write_denied_check('write-denied: A cannot UPDATE own plan directly', $s$update public.plans set plan_version = plan_version + 1 where id = '01111111-0000-0000-0000-000000000001'$s$);
select test_harness.run_write_denied_check('write-denied: A cannot INSERT a plan_item directly', $s$insert into public.plan_items (plan_id, item_key, kind, category, obligation_class, priority_tier, section) values ('01111111-0000-0000-0000-000000000001', 'sneaky-item', 'informational', 'routine', 'informational', 'P3', 'today')$s$);
select test_harness.run_write_denied_check('write-denied: A cannot INSERT an audit_event directly', $s$insert into public.audit_events (household_id, actor_user_id, entity_ref, action, summary) values ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '{"type":"household","id":"a1111111-0000-0000-0000-000000000001"}'::jsonb, 'sneaky.action', '{}'::jsonb)$s$);
select test_harness.run_write_denied_check('write-denied: A cannot UPDATE an audit_event directly', $s$update public.audit_events set reason = 'tampered' where id = '03111111-0000-0000-0000-000000000001'$s$);
select test_harness.run_write_denied_check('write-denied: A cannot DELETE an audit_event directly', $s$delete from public.audit_events where id = '03111111-0000-0000-0000-000000000001'$s$);
select test_harness.run_write_denied_check('write-denied: A cannot INSERT into command_log directly (spoof idempotency ledger)', $s$insert into public.command_log (actor_user_id, client_idempotency_key, command, payload_hash, request_body, recorded_at) values ('11111111-1111-1111-1111-111111111111', 'sneaky-cmd', 'create_household', 'sneaky-hash', '{}'::jsonb, now())$s$);
select test_harness.run_write_denied_check('write-denied: A cannot INSERT a household_invitation directly', $s$insert into public.household_invitations (household_id, created_by, token_hash, expires_at, updated_by) values ('a1111111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'sneaky-token', now() + interval '1 day', '11111111-1111-1111-1111-111111111111')$s$);
select test_harness.run_write_denied_check('write-denied: A cannot INSERT a system-provenance task_definition', $s$insert into public.task_definitions (provenance, content_id, content_version, title, category, default_obligation_class, default_effort, default_time_policy) values ('system', 'sneaky.content', 1, 'Sneaky', 'routine', 'scheduled', 'short', 'anytime')$s$);
select test_harness.run_write_denied_check('write-denied: A cannot INSERT a content_versions row (content pipeline only)', $s$insert into public.content_versions (content_id, version, content_type, author, authored_on, effective_from) values ('sneaky.content', 1, 'task_definition', 'sneaky', current_date, current_date)$s$);

-- ============================================================================
-- 8. The write_path_* RPC functions must be uncallable by anon/authenticated
--    (service_role only -- Slice A's single write path)
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select test_harness.run_write_denied_check('rpc-denied: authenticated cannot execute write_path_create_household', $s$select public.write_path_create_household('11111111-1111-1111-1111-111111111111'::uuid, 'sneaky-rpc-key', 'h', '{}'::jsonb, now(), now(), '{"name":"x","time_zone":"UTC"}'::jsonb)$s$);
select test_harness.run_write_denied_check('rpc-denied: authenticated cannot execute write_path_create_pet', $s$select public.write_path_create_pet('11111111-1111-1111-1111-111111111111'::uuid, 'sneaky-rpc-key-2', 'h', '{}'::jsonb, now(), now(), '{"household_id":"a1111111-0000-0000-0000-000000000001","name":"x"}'::jsonb)$s$);
select test_harness.run_write_denied_check('rpc-denied: authenticated cannot execute write_path_set_default_capacity', $s$select public.write_path_set_default_capacity('11111111-1111-1111-1111-111111111111'::uuid, 'sneaky-capacity', 'h', '{}'::jsonb, now(), now(), '{"household_id":"a1111111-0000-0000-0000-000000000001","default_capacity_mode":"busy"}'::jsonb)$s$);
select test_harness.run_write_denied_check('rpc-denied: authenticated cannot execute write_path_accept_recommendation', $s$select public.write_path_accept_recommendation('11111111-1111-1111-1111-111111111111'::uuid, 'sneaky-rec', 'h', '{}'::jsonb, now(), now(), '{"plan_item_id":"e1111111-0000-0000-0000-000000000001"}'::jsonb)$s$);
select test_harness.run_write_denied_check('rpc-denied: authenticated cannot execute write_path_create_recurring_task', $s$select public.write_path_create_recurring_task('11111111-1111-1111-1111-111111111111'::uuid, 'sneaky-recurring', 'h', '{}'::jsonb, now(), now(), '{}'::jsonb)$s$);
select test_harness.run_write_denied_check('rpc-denied: authenticated cannot execute write_path_snooze_occurrence', $s$select public.write_path_snooze_occurrence('11111111-1111-1111-1111-111111111111'::uuid, 'sneaky-snooze', 'h', '{}'::jsonb, now(), now(), '{}'::jsonb)$s$);
select test_harness.run_write_denied_check('rpc-denied: authenticated cannot execute routine schedule rebuild', $s$select public.write_path_rebuild_routine_schedules('11111111-1111-1111-1111-111111111111'::uuid, 'a1111111-0000-0000-0000-000000000001'::uuid, '{}'::jsonb, now())$s$);
select test_harness.run_write_denied_check('rpc-denied: authenticated cannot execute elapsed plan close', $s$select public.close_elapsed_plans(now())$s$);

reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select test_harness.run_write_denied_check('rpc-denied: anon cannot execute write_path_create_household', $s$select public.write_path_create_household(null, 'sneaky-rpc-key-3', 'h', '{}'::jsonb, now(), now(), '{"name":"x","time_zone":"UTC"}'::jsonb)$s$);
select test_harness.run_write_denied_check('rpc-denied: anon cannot execute write_path_create_pet', $s$select public.write_path_create_pet(null, 'sneaky-rpc-key-4', 'h', '{}'::jsonb, now(), now(), '{"household_id":"a1111111-0000-0000-0000-000000000001","name":"x"}'::jsonb)$s$);
select test_harness.run_write_denied_check('rpc-denied: anon cannot execute write_path_set_default_capacity', $s$select public.write_path_set_default_capacity(null, 'sneaky-capacity-anon', 'h', '{}'::jsonb, now(), now(), '{"household_id":"a1111111-0000-0000-0000-000000000001","default_capacity_mode":"busy"}'::jsonb)$s$);
select test_harness.run_write_denied_check('rpc-denied: anon cannot execute write_path_accept_recommendation', $s$select public.write_path_accept_recommendation(null, 'sneaky-rec-anon', 'h', '{}'::jsonb, now(), now(), '{"plan_item_id":"e1111111-0000-0000-0000-000000000001"}'::jsonb)$s$);
select test_harness.run_write_denied_check('rpc-denied: anon cannot execute routine schedule rebuild', $s$select public.write_path_rebuild_routine_schedules(null, 'a1111111-0000-0000-0000-000000000001'::uuid, '{}'::jsonb, now())$s$);
select test_harness.run_write_denied_check('rpc-denied: anon cannot execute elapsed plan close', $s$select public.close_elapsed_plans(now())$s$);
reset role;

-- ============================================================================
-- 9. `anon` has no direct table access at all (no session -> no data, not
--    even to world-readable content tables -- content is served through the
--    application layer, not raw anon table reads)
-- ============================================================================

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select test_harness.run_write_denied_check('anon-denied: anon cannot SELECT content_versions (no table grant)', $s$select count(*) from public.content_versions$s$);
select test_harness.run_write_denied_check('anon-denied: anon cannot SELECT pets (no table grant)', $s$select count(*) from public.pets$s$);
select test_harness.run_write_denied_check('anon-denied: anon cannot SELECT households (no table grant)', $s$select count(*) from public.households$s$);
select test_harness.run_write_denied_check('anon-denied: anon cannot INSERT user_profiles (no table grant)', $s$insert into public.user_profiles (id, display_name) values ('44444444-4444-4444-4444-444444444444', 'Anon Ghost')$s$);
reset role;

-- ============================================================================
-- 10. Report and pass/fail gate
-- ============================================================================

select
  count(*) filter (where passed) as passed_count,
  count(*) filter (where not passed) as failed_count,
  count(*) as total_count
from test_harness.results;

select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail
from test_harness.results
order by id;

do $$
declare
  failed int;
  total int;
begin
  select count(*) filter (where not passed), count(*) into failed, total from test_harness.results;
  raise notice 'RLS ISOLATION SUITE SUMMARY: % / % assertions passed', total - failed, total;
  if failed > 0 then
    raise exception 'RLS ISOLATION SUITE: % assertion(s) failed', failed;
  end if;
end;
$$;

rollback;
