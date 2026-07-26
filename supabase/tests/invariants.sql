-- WP-1 exit test: invariant violations are rejected
--
-- Attempts to violate every DB-enforced invariant named in the migration
-- (constraints, unique indexes, and BEFORE triggers) and asserts each attempt
-- fails. Runs entirely as the `postgres` superuser (bypasses RLS -- these are
-- data-layer invariants, not authorization checks, and must hold regardless
-- of who is writing, including the service-role write path itself).
--
-- Covers, per docs/10-data-model.md §18 and the migration's own constraints:
--   1. At most one active membership per (user, household)
--      -- household_memberships_one_active_per_user_household
--   2. Unique (pet, local_date) Plan -- plans_one_per_pet_day
--   3. Unique occurrence_key -- task_occurrences.occurrence_key
--   4. At most one effective (non-superseded) completion per occurrence
--      -- dispositions_one_effective_completion
--   5. Pet birth information: exactly one of exact/estimated shapes populated
--      -- pets_birth_shape (both the "exact" and "estimated" violation shapes)
--   6. homecoming_date >= birth_date when both exact -- pets_homecoming_after_birth
--   7. Closed plans and their plan_items are immutable
--      -- deny_closed_plan_mutation / deny_closed_plan_item_mutation triggers
--      (both UPDATE and DELETE attempts)
--   8. audit_events is append-only -- deny_audit_mutation trigger
--      (both UPDATE and DELETE attempts)
--   9. (bonus, same family as #4/#8) dispositions_effective_not_future: both
--      bounds of the disposition back-dating window -- effective_at may not
--      be more than 5 minutes in the future of recorded_at, NOR more than 7
--      days in the past of it.
--
-- The whole file runs inside one transaction and is rolled back at the end:
-- no fixture rows persist, and no migration file is touched.

\set ON_ERROR_STOP on
begin;

-- ============================================================================
-- 0. Test harness (same pattern as rls_isolation.sql; independent copy so
--    this file can run standalone)
-- ============================================================================

create schema test_harness;

create table test_harness.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text,
  created_at timestamptz not null default clock_timestamp()
);

create or replace function test_harness.record(p_name text, p_passed boolean, p_detail text default null)
returns void
language plpgsql
as $$
begin
  insert into test_harness.results (name, passed, detail) values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %', case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

-- Runs p_stmt and expects it to fail (a constraint/index/trigger violation).
create or replace function test_harness.expect_violation(p_name text, p_stmt text)
returns void
language plpgsql
as $$
begin
  begin
    execute p_stmt;
    perform test_harness.record(p_name, false, 'statement UNEXPECTEDLY succeeded (no violation raised)');
  exception when others then
    perform test_harness.record(p_name, true, format('rejected as expected [%s]: %s', sqlstate, sqlerrm));
  end;
end;
$$;

-- Runs p_stmt and expects it to succeed (used for legitimate setup steps
-- inside the test, so a broken fixture shows up as a clear failure rather
-- than masquerading as a passed "expect_violation").
create or replace function test_harness.expect_success(p_name text, p_stmt text)
returns void
language plpgsql
as $$
begin
  begin
    execute p_stmt;
    perform test_harness.record(p_name, true, 'setup statement succeeded as expected');
  exception when others then
    perform test_harness.record(p_name, false, format('setup statement unexpectedly failed [%s]: %s', sqlstate, sqlerrm));
  end;
end;
$$;

-- ============================================================================
-- 1. Shared fixtures
-- ============================================================================

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
values ('91111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wp1-inv-actor@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.households (id, name, time_zone, status, created_by, updated_by)
values ('92222222-2222-2222-2222-222222222222', 'Invariant Test Household', 'America/Los_Angeles', 'active', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111');

insert into public.pets (id, household_id, name, species, birth_date_kind, birth_date, status, created_by, updated_by)
values ('93333333-3333-3333-3333-333333333333', '92222222-2222-2222-2222-222222222222', 'Fixture Pup', 'dog', 'exact', '2026-01-01', 'active', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111');

insert into public.task_definitions (id, provenance, household_id, title, category, default_obligation_class, default_effort, default_time_policy, created_by, updated_by)
values ('94444444-4444-4444-4444-444444444444', 'user', '92222222-2222-2222-2222-222222222222', 'Fixture Task', 'routine', 'scheduled', 'short', 'anytime', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111');

insert into public.task_schedules (id, household_id, pet_id, task_definition_id, recurrence, origin, obligation_class, active_range_start_date, created_by, updated_by)
values ('95555555-5555-5555-5555-555555555555', '92222222-2222-2222-2222-222222222222', '93333333-3333-3333-3333-333333333333', '94444444-4444-4444-4444-444444444444',
        '{"type":"once","anchor_date":"2026-07-26","time_policy":"anytime"}'::jsonb, 'user_created', 'scheduled', '2026-07-26', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111');

insert into public.task_occurrences (id, occurrence_key, household_id, pet_id, schedule_id, local_due_date, original_local_due_date, time_policy, state, obligation_class, origin, created_by, updated_by)
values ('96666666-6666-6666-6666-666666666666', 'FIXTURE-INV-OCC-1', '92222222-2222-2222-2222-222222222222', '93333333-3333-3333-3333-333333333333', '95555555-5555-5555-5555-555555555555',
        '2026-07-26', '2026-07-26', 'anytime', 'pending', 'scheduled', 'user_created', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111');

-- A second, independent occurrence for the "duplicate occurrence_key" test so
-- it doesn't collide with the completion-related occurrence above.
insert into public.task_occurrences (id, occurrence_key, household_id, pet_id, schedule_id, local_due_date, original_local_due_date, time_policy, state, obligation_class, origin, created_by, updated_by)
values ('97777777-7777-7777-7777-777777777777', 'FIXTURE-INV-OCC-2', '92222222-2222-2222-2222-222222222222', '93333333-3333-3333-3333-333333333333', '95555555-5555-5555-5555-555555555555',
        '2026-07-27', '2026-07-27', 'anytime', 'pending', 'scheduled', 'user_created', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111');

-- ============================================================================
-- 2. Invariant 1: at most one active membership per (user, household)
-- ============================================================================

select test_harness.expect_success('setup: first active membership insert succeeds',
  $s$insert into public.household_memberships (id, household_id, user_id, role, status, joined_at, created_by, updated_by)
     values ('98111111-0000-0000-0000-000000000001', '92222222-2222-2222-2222-222222222222', '91111111-1111-1111-1111-111111111111', 'owner', 'active', now(), '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

select test_harness.expect_violation('invariant: a second ACTIVE membership for the same (user, household) is rejected',
  $s$insert into public.household_memberships (household_id, user_id, role, status, joined_at, created_by, updated_by)
     values ('92222222-2222-2222-2222-222222222222', '91111111-1111-1111-1111-111111111111', 'caregiver', 'active', now(), '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

-- Sanity check: a second NON-active (e.g. removed) membership row for the
-- same pair is fine (it's a historical record, not a second active grant).
select test_harness.expect_success('sanity: a second REMOVED membership row for the same (user, household) is allowed',
  $s$insert into public.household_memberships (household_id, user_id, role, status, joined_at, ended_at, ended_by, created_by, updated_by)
     values ('92222222-2222-2222-2222-222222222222', '91111111-1111-1111-1111-111111111111', 'caregiver', 'removed', now() - interval '5 days', now() - interval '1 day', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

-- ============================================================================
-- 3. Invariant 2: unique (pet, local_date) Plan
-- ============================================================================

select test_harness.expect_success('setup: first plan for (pet, date) succeeds',
  $s$insert into public.plans (id, household_id, pet_id, local_date, time_zone_snapshot, stage_snapshot, capacity_mode_applied, catalogue_version_set, input_digest, created_by, updated_by)
     values ('98222222-0000-0000-0000-000000000001', '92222222-2222-2222-2222-222222222222', '93333333-3333-3333-3333-333333333333', '2026-07-26', 'America/Los_Angeles', '{}'::jsonb, 'normal', '[]'::jsonb, 'digest-1', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

select test_harness.expect_violation('invariant: a second Plan for the same (pet, local_date) is rejected',
  $s$insert into public.plans (household_id, pet_id, local_date, time_zone_snapshot, stage_snapshot, capacity_mode_applied, catalogue_version_set, input_digest, created_by, updated_by)
     values ('92222222-2222-2222-2222-222222222222', '93333333-3333-3333-3333-333333333333', '2026-07-26', 'America/Los_Angeles', '{}'::jsonb, 'normal', '[]'::jsonb, 'digest-2', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

-- ============================================================================
-- 4. Invariant 3: unique occurrence_key
-- ============================================================================

select test_harness.expect_violation('invariant: a duplicate occurrence_key is rejected',
  $s$insert into public.task_occurrences (occurrence_key, household_id, pet_id, schedule_id, local_due_date, original_local_due_date, time_policy, state, obligation_class, origin, created_by, updated_by)
     values ('FIXTURE-INV-OCC-1', '92222222-2222-2222-2222-222222222222', '93333333-3333-3333-3333-333333333333', '95555555-5555-5555-5555-555555555555', '2026-07-28', '2026-07-28', 'anytime', 'pending', 'scheduled', 'user_created', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

-- ============================================================================
-- 5. Invariant 4: at most one effective (non-superseded) completion per
--    occurrence
-- ============================================================================

select test_harness.expect_success('setup: first effective completion disposition succeeds',
  $s$insert into public.dispositions (household_id, occurrence_id, action, actor_user_id, recorded_at, effective_at, client_idempotency_key)
     values ('92222222-2222-2222-2222-222222222222', '96666666-6666-6666-6666-666666666666', 'complete', '91111111-1111-1111-1111-111111111111', now(), now(), 'inv-disp-key-1')$s$);

select test_harness.expect_violation('invariant: a second effective (non-superseded) completion for the same occurrence is rejected',
  $s$insert into public.dispositions (household_id, occurrence_id, action, actor_user_id, recorded_at, effective_at, client_idempotency_key)
     values ('92222222-2222-2222-2222-222222222222', '96666666-6666-6666-6666-666666666666', 'complete', '91111111-1111-1111-1111-111111111111', now(), now(), 'inv-disp-key-2')$s$);

-- Sanity: a SUPERSEDED second completion for the same occurrence is allowed
-- (this is exactly how the completion-convergence rule stores the losing
-- duplicate per DM §9.4).
select test_harness.expect_success('sanity: a SUPERSEDED second completion for the same occurrence is allowed',
  $s$insert into public.dispositions (household_id, occurrence_id, action, actor_user_id, recorded_at, effective_at, client_idempotency_key, superseded)
     values ('92222222-2222-2222-2222-222222222222', '96666666-6666-6666-6666-666666666666', 'complete', '91111111-1111-1111-1111-111111111111', now(), now(), 'inv-disp-key-3', true)$s$);

-- ============================================================================
-- 6. Invariant 5: pet birth information -- exactly one of exact/estimated
--    shapes populated
-- ============================================================================

select test_harness.expect_violation('invariant: birth_date_kind=exact with birth_date NULL is rejected',
  $s$insert into public.pets (household_id, name, species, birth_date_kind, birth_date, status, created_by, updated_by)
     values ('92222222-2222-2222-2222-222222222222', 'Bad Shape Pup 1', 'dog', 'exact', null, 'active', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

select test_harness.expect_violation('invariant: birth_date_kind=exact with estimated fields also populated is rejected',
  $s$insert into public.pets (household_id, name, species, birth_date_kind, birth_date, estimated_age_weeks, estimated_as_of_date, status, created_by, updated_by)
     values ('92222222-2222-2222-2222-222222222222', 'Bad Shape Pup 2', 'dog', 'exact', '2026-01-01', 10, '2026-01-01', 'active', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

select test_harness.expect_violation('invariant: birth_date_kind=estimated with birth_date populated is rejected',
  $s$insert into public.pets (household_id, name, species, birth_date_kind, birth_date, estimated_age_weeks, estimated_as_of_date, status, created_by, updated_by)
     values ('92222222-2222-2222-2222-222222222222', 'Bad Shape Pup 3', 'dog', 'estimated', '2026-01-01', 10, '2026-01-01', 'active', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

select test_harness.expect_violation('invariant: birth_date_kind=estimated with estimated_age_weeks NULL is rejected',
  $s$insert into public.pets (household_id, name, species, birth_date_kind, estimated_age_weeks, estimated_as_of_date, status, created_by, updated_by)
     values ('92222222-2222-2222-2222-222222222222', 'Bad Shape Pup 4', 'dog', 'estimated', null, '2026-01-01', 'active', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

-- ============================================================================
-- 7. Invariant 6: homecoming_date >= birth_date when both exact
-- ============================================================================

select test_harness.expect_violation('invariant: homecoming_date before birth_date (both exact) is rejected',
  $s$insert into public.pets (household_id, name, species, birth_date_kind, birth_date, homecoming_date, status, created_by, updated_by)
     values ('92222222-2222-2222-2222-222222222222', 'Time Traveler Pup', 'dog', 'exact', '2026-01-10', '2026-01-01', 'active', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

select test_harness.expect_success('sanity: homecoming_date equal to birth_date is allowed',
  $s$insert into public.pets (household_id, name, species, birth_date_kind, birth_date, homecoming_date, status, created_by, updated_by)
     values ('92222222-2222-2222-2222-222222222222', 'Same Day Pup', 'dog', 'exact', '2026-01-10', '2026-01-10', 'active', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

-- ============================================================================
-- 8. Invariant 7: closed plans (and their plan_items) are immutable
-- ============================================================================

select test_harness.expect_success('setup: insert a plan that is already closed',
  $s$insert into public.plans (id, household_id, pet_id, local_date, time_zone_snapshot, stage_snapshot, capacity_mode_applied, catalogue_version_set, input_digest, status, created_by, updated_by)
     values ('98333333-0000-0000-0000-000000000001', '92222222-2222-2222-2222-222222222222', '93333333-3333-3333-3333-333333333333', '2026-06-01', 'America/Los_Angeles', '{}'::jsonb, 'normal', '[]'::jsonb, 'closed-digest-1', 'closed', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

select test_harness.expect_violation('invariant: UPDATE on a closed plan is rejected',
  $s$update public.plans set plan_version = plan_version + 1 where id = '98333333-0000-0000-0000-000000000001'$s$);

select test_harness.expect_violation('invariant: DELETE on a closed plan is rejected',
  $s$delete from public.plans where id = '98333333-0000-0000-0000-000000000001'$s$);

-- plan_items on a closed plan: build via an open->closed transition (a
-- straight INSERT of status='closed' is legitimate for the plan itself, but
-- item mutation is only interesting once a plan transitions; the trigger
-- only inspects the CURRENT plan status, so either construction is valid --
-- this path additionally proves an open->closed UPDATE is itself allowed).
select test_harness.expect_success('setup: insert an open plan for the plan_items-immutability test',
  $s$insert into public.plans (id, household_id, pet_id, local_date, time_zone_snapshot, stage_snapshot, capacity_mode_applied, catalogue_version_set, input_digest, status, created_by, updated_by)
     values ('98333333-0000-0000-0000-000000000002', '92222222-2222-2222-2222-222222222222', '93333333-3333-3333-3333-333333333333', '2026-06-02', 'America/Los_Angeles', '{}'::jsonb, 'normal', '[]'::jsonb, 'closed-digest-2', 'open', '91111111-1111-1111-1111-111111111111', '91111111-1111-1111-1111-111111111111')$s$);

select test_harness.expect_success('setup: insert a plan_item on the still-open plan',
  $s$insert into public.plan_items (id, plan_id, item_key, kind, category, obligation_class, priority_tier, section)
     values ('98444444-0000-0000-0000-000000000001', '98333333-0000-0000-0000-000000000002', 'inv-item-1', 'informational', 'routine', 'informational', 'P3', 'today')$s$);

select test_harness.expect_success('setup: closing the plan (open -> closed) is itself allowed',
  $s$update public.plans set status = 'closed' where id = '98333333-0000-0000-0000-000000000002'$s$);

select test_harness.expect_violation('invariant: UPDATE on a plan_item whose plan is now closed is rejected',
  $s$update public.plan_items set pinned = true where id = '98444444-0000-0000-0000-000000000001'$s$);

select test_harness.expect_violation('invariant: DELETE on a plan_item whose plan is now closed is rejected',
  $s$delete from public.plan_items where id = '98444444-0000-0000-0000-000000000001'$s$);

select test_harness.expect_violation('invariant: a second UPDATE attempt on the closed plan itself is still rejected',
  $s$update public.plans set status = 'open' where id = '98333333-0000-0000-0000-000000000002'$s$);

-- ============================================================================
-- 9. Invariant 8: audit_events is append-only
-- ============================================================================

select test_harness.expect_success('setup: insert an audit_event',
  $s$insert into public.audit_events (id, household_id, actor_user_id, entity_ref, action, summary)
     values ('98555555-0000-0000-0000-000000000001', '92222222-2222-2222-2222-222222222222', '91111111-1111-1111-1111-111111111111', '{"type":"household","id":"92222222-2222-2222-2222-222222222222"}'::jsonb, 'household.created', '{}'::jsonb)$s$);

select test_harness.expect_violation('invariant: UPDATE on an audit_event is rejected',
  $s$update public.audit_events set reason = 'tampered' where id = '98555555-0000-0000-0000-000000000001'$s$);

select test_harness.expect_violation('invariant: DELETE on an audit_event is rejected',
  $s$delete from public.audit_events where id = '98555555-0000-0000-0000-000000000001'$s$);

-- ============================================================================
-- 10. Bonus: dispositions_effective_not_future -- both bounds of the
--     back-dating window (effective_at in [recorded_at - 7 days, recorded_at + 5 min])
-- ============================================================================

select test_harness.expect_success('sanity: effective_at exactly at recorded_at is allowed',
  $s$insert into public.dispositions (household_id, occurrence_id, action, actor_user_id, recorded_at, effective_at, client_idempotency_key)
     values ('92222222-2222-2222-2222-222222222222', '97777777-7777-7777-7777-777777777777', 'skip', '91111111-1111-1111-1111-111111111111', now(), now(), 'inv-window-key-0')$s$);

select test_harness.expect_success('sanity: effective_at exactly 7 days before recorded_at (the boundary) is allowed',
  $s$insert into public.dispositions (household_id, occurrence_id, action, actor_user_id, recorded_at, effective_at, client_idempotency_key)
     values ('92222222-2222-2222-2222-222222222222', '97777777-7777-7777-7777-777777777777', 'skip', '91111111-1111-1111-1111-111111111111', now(), now() - interval '7 days', 'inv-window-key-1')$s$);

select test_harness.expect_violation('invariant: effective_at more than 7 days before recorded_at is rejected (back-dating floor)',
  $s$insert into public.dispositions (household_id, occurrence_id, action, actor_user_id, recorded_at, effective_at, client_idempotency_key)
     values ('92222222-2222-2222-2222-222222222222', '97777777-7777-7777-7777-777777777777', 'skip', '91111111-1111-1111-1111-111111111111', now(), now() - interval '7 days 1 hour', 'inv-window-key-2')$s$);

select test_harness.expect_success('sanity: effective_at exactly 5 minutes after recorded_at (the boundary) is allowed',
  $s$insert into public.dispositions (household_id, occurrence_id, action, actor_user_id, recorded_at, effective_at, client_idempotency_key)
     values ('92222222-2222-2222-2222-222222222222', '97777777-7777-7777-7777-777777777777', 'skip', '91111111-1111-1111-1111-111111111111', now(), now() + interval '5 minutes', 'inv-window-key-3')$s$);

select test_harness.expect_violation('invariant: effective_at more than 5 minutes after recorded_at is rejected (no future-dating)',
  $s$insert into public.dispositions (household_id, occurrence_id, action, actor_user_id, recorded_at, effective_at, client_idempotency_key)
     values ('92222222-2222-2222-2222-222222222222', '97777777-7777-7777-7777-777777777777', 'skip', '91111111-1111-1111-1111-111111111111', now(), now() + interval '6 minutes', 'inv-window-key-4')$s$);

-- ============================================================================
-- 11. Report and pass/fail gate
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
  raise notice 'INVARIANTS SUITE SUMMARY: % / % assertions passed', total - failed, total;
  if failed > 0 then
    raise exception 'INVARIANTS SUITE: % assertion(s) failed', failed;
  end if;
end;
$$;

rollback;
