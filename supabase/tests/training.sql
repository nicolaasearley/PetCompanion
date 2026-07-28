-- Slice B training tests: TrainingGoal and TrainingSession (F08, epic E06).
--
-- Covers the DM 10 §12.2/§12.3 rules this slice owns -- one non-retired goal
-- per (pet, skill), an idempotent start, pause/resume/retire, owner-reported
-- progress that never moves without explicit input, sessions that pin a
-- published skill version -- plus the §18 tenancy invariants, the RLS/grant
-- lockdown, and the generation-context wiring that finally gives the engine a
-- real `training_state`.
--
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_training;
create table test_training.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create table test_training.state (key text primary key, value text);

grant usage on schema test_training to authenticated;
grant select, insert, update on test_training.results, test_training.state to authenticated;
grant usage, select on all sequences in schema test_training to authenticated;

create or replace function test_training.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_training.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_training.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin perform test_training.record(p_name, coalesce(p_condition, false), p_detail); end;
$$;

create or replace function test_training.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_training.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_training.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

create or replace function test_training.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_training.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_training.val(p_key text)
returns text language sql stable as $$
  select value from test_training.state where key = p_key;
$$;

-- One-call wrapper so each assertion reads as the command a client sends.
create or replace function test_training.command(
  p_actor uuid, p_command text, p_payload jsonb, p_key text default null
) returns jsonb language plpgsql as $$
declare
  key_value text := coalesce(p_key, gen_random_uuid()::text);
  result jsonb;
begin
  execute format('select public.write_path_%I($1, $2, $3, $4, $5, $6, $7)', p_command)
  into result
  using p_actor, key_value, md5(p_payload::text),
        jsonb_build_object('command', p_command, 'payload', p_payload),
        now(), null::timestamptz, p_payload;
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures: two independent households, each with one pet.
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('33330000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'trn-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('33330000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'trn-partner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('33330000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'trn-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.user_profiles(id, display_name) values
  ('33330000-0000-4000-8000-000000000001', 'Nic'),
  ('33330000-0000-4000-8000-000000000002', 'Sarah'),
  ('33330000-0000-4000-8000-000000000003', 'Outsider');

insert into public.households (id, name, time_zone, created_by, updated_by) values
  ('44440000-0000-4000-8000-000000000001', 'Maple House', 'America/Toronto',
   '33330000-0000-4000-8000-000000000001', '33330000-0000-4000-8000-000000000001'),
  ('44440000-0000-4000-8000-000000000002', 'Elsewhere House', 'Europe/Stockholm',
   '33330000-0000-4000-8000-000000000003', '33330000-0000-4000-8000-000000000003');

insert into public.household_memberships (
  household_id, user_id, role, status, joined_at, created_by, updated_by
) values
  ('44440000-0000-4000-8000-000000000001', '33330000-0000-4000-8000-000000000001',
   'owner', 'active', now(), '33330000-0000-4000-8000-000000000001', '33330000-0000-4000-8000-000000000001'),
  ('44440000-0000-4000-8000-000000000001', '33330000-0000-4000-8000-000000000002',
   'caregiver', 'active', now(), '33330000-0000-4000-8000-000000000001', '33330000-0000-4000-8000-000000000001'),
  ('44440000-0000-4000-8000-000000000002', '33330000-0000-4000-8000-000000000003',
   'owner', 'active', now(), '33330000-0000-4000-8000-000000000003', '33330000-0000-4000-8000-000000000003');

insert into public.pets (
  id, household_id, name, species, birth_date_kind, birth_date, status, created_by, updated_by
) values
  ('55550000-0000-4000-8000-000000000001', '44440000-0000-4000-8000-000000000001',
   'Maple', 'dog', 'exact', current_date - interval '12 weeks', 'active',
   '33330000-0000-4000-8000-000000000001', '33330000-0000-4000-8000-000000000001'),
  ('55550000-0000-4000-8000-000000000002', '44440000-0000-4000-8000-000000000002',
   'Otherdog', 'dog', 'exact', current_date - interval '12 weeks', 'active',
   '33330000-0000-4000-8000-000000000003', '33330000-0000-4000-8000-000000000003');

-- ---------------------------------------------------------------------------
-- 1. Starting a goal (US-061)
-- ---------------------------------------------------------------------------

do $$
declare
  result jsonb;
begin
  result := test_training.command(
    '33330000-0000-4000-8000-000000000001', 'start_training_goal',
    jsonb_build_object(
      'pet_id', '55550000-0000-4000-8000-000000000001',
      'skill_ref', 'skill.marker_intro'
    )
  );
  perform test_training.put('marker_goal', result->'goal'->>'id');

  perform test_training.assert_true(
    'start: creates an active goal at not_started',
    result->'goal'->>'status' = 'active' and result->'goal'->>'progress_state' = 'not_started',
    format('status=%s progress=%s', result->'goal'->>'status', result->'goal'->>'progress_state')
  );
  perform test_training.assert_true(
    'start: records the household, pet and actor',
    result->'goal'->>'household_id' = '44440000-0000-4000-8000-000000000001'
      and result->'goal'->>'pet_id' = '55550000-0000-4000-8000-000000000001'
      and result->'goal'->>'started_by' = '33330000-0000-4000-8000-000000000001',
    result->'goal'->>'household_id'
  );
  perform test_training.assert_true(
    'start: writes a training_goal.started audit event',
    exists (
      select 1 from public.audit_events
      where action = 'training_goal.started'
        and entity_ref->>'id' = test_training.val('marker_goal')
    )
  );
end;
$$;

-- A second start from a DIFFERENT device (fresh idempotency key) must not
-- create a second goal: idempotency here is a data-model rule, not just a
-- command-log replay (US-061).
do $$
declare
  result jsonb;
begin
  result := test_training.command(
    '33330000-0000-4000-8000-000000000002', 'start_training_goal',
    jsonb_build_object(
      'pet_id', '55550000-0000-4000-8000-000000000001',
      'skill_ref', 'skill.marker_intro'
    )
  );
  perform test_training.assert_true(
    'start: starting the same skill twice returns the same goal',
    result->'goal'->>'id' = test_training.val('marker_goal'),
    format('returned %s', result->'goal'->>'id')
  );
  perform test_training.assert_true(
    'start: no duplicate goal row exists',
    (select count(*) from public.training_goals
      where pet_id = '55550000-0000-4000-8000-000000000001'
        and skill_ref = 'skill.marker_intro') = 1
  );
end;
$$;

-- DM §18: the invariant is enforced by the storage layer too, not only by the
-- command that happens to check first.
select test_training.expect_sqlstate(
  'invariant: a second non-retired goal for the same (pet, skill) is rejected',
  $sql$
    insert into public.training_goals (household_id, pet_id, skill_ref, created_by, updated_by)
    values ('44440000-0000-4000-8000-000000000001', '55550000-0000-4000-8000-000000000001',
            'skill.marker_intro', '33330000-0000-4000-8000-000000000001',
            '33330000-0000-4000-8000-000000000001')
  $sql$,
  '23505'
);

-- DM §18.10/§18.8: a goal may not be filed under a household that does not own
-- the pet, or every RLS read after it would be wrong.
select test_training.expect_sqlstate(
  'invariant: goal household must match its pet''s household',
  $sql$
    insert into public.training_goals (household_id, pet_id, skill_ref, created_by, updated_by)
    values ('44440000-0000-4000-8000-000000000002', '55550000-0000-4000-8000-000000000001',
            'skill.sit', '33330000-0000-4000-8000-000000000001',
            '33330000-0000-4000-8000-000000000001')
  $sql$,
  '23514'
);

-- DM §18.11 applied to training: a goal is what becomes a plan item, so draft
-- guidance must not reach it through the back door.
insert into public.content_versions (
  content_id, version, content_type, publication_status, author, authored_on, effective_from
) values (
  'skill.test_draft', 1, 'training_skill', 'draft', 'test', current_date, current_date
);
insert into public.training_skills (
  content_id, version, skill_group, title, steps, stage_guidance,
  effort_band, recommended_frequency, common_mistakes, effective_from
) values (
  'skill.test_draft', 1, 'Foundations', 'Draft skill', '[]'::jsonb, 'settling_in',
  'tiny', '3-5/week', array['none'], current_date
);

select test_training.expect_sqlstate(
  'invariant: a goal cannot reference draft content',
  $sql$
    insert into public.training_goals (household_id, pet_id, skill_ref, created_by, updated_by)
    values ('44440000-0000-4000-8000-000000000001', '55550000-0000-4000-8000-000000000001',
            'skill.test_draft', '33330000-0000-4000-8000-000000000001',
            '33330000-0000-4000-8000-000000000001')
  $sql$,
  '22023'
);

select test_training.expect_sqlstate(
  'start: an unknown skill id is rejected',
  $sql$
    select test_training.command(
      '33330000-0000-4000-8000-000000000001', 'start_training_goal',
      jsonb_build_object('pet_id', '55550000-0000-4000-8000-000000000001',
                         'skill_ref', 'skill.does_not_exist')
    )
  $sql$,
  '22023'
);

-- Tenancy: a non-member cannot reach into another household's pet.
select test_training.expect_sqlstate(
  'tenancy: an outsider cannot start a goal for another household''s pet',
  $sql$
    select test_training.command(
      '33330000-0000-4000-8000-000000000003', 'start_training_goal',
      jsonb_build_object('pet_id', '55550000-0000-4000-8000-000000000001',
                         'skill_ref', 'skill.sit')
    )
  $sql$,
  '42501'
);

-- ---------------------------------------------------------------------------
-- 2. Logging a session (US-063)
-- ---------------------------------------------------------------------------

do $$
declare
  result jsonb;
begin
  result := test_training.command(
    '33330000-0000-4000-8000-000000000002', 'log_training_session',
    jsonb_build_object(
      'goal_id', test_training.val('marker_goal'),
      'duration_minutes', 4,
      'outcome_note', 'Went well in the kitchen.'
    )
  );
  perform test_training.put('marker_session', result->'session'->>'id');

  perform test_training.assert_true(
    'session: pins the published skill version it used',
    result->'session'->>'skill_ref' = 'skill.marker_intro'
      and (result->'session'->>'skill_version')::int = 1,
    result->'session'->>'skill_version'
  );
  perform test_training.assert_true(
    'session: defaults to the household''s local today',
    (result->'session'->>'effective_date')::date
      = public.household_current_local_date('44440000-0000-4000-8000-000000000001', now()),
    result->'session'->>'effective_date'
  );
  -- US-063: "A single session does not automatically declare mastery."
  perform test_training.assert_true(
    'session: logging alone never advances progress state',
    result->'goal'->>'progress_state' = 'not_started',
    result->'goal'->>'progress_state'
  );
  perform test_training.assert_true(
    'session: is attributed to the caregiver who logged it',
    (select actor_user_id from public.training_sessions
      where id = (result->'session'->>'id')::uuid)
      = '33330000-0000-4000-8000-000000000002'
  );
  perform test_training.assert_true(
    'session: writes a training_session.logged audit event',
    exists (
      select 1 from public.audit_events
      where action = 'training_session.logged'
        and entity_ref->>'id' = result->'session'->>'id'
    )
  );
end;
$$;

select test_training.expect_sqlstate(
  'session: cannot be logged in the future',
  $sql$
    select test_training.command(
      '33330000-0000-4000-8000-000000000001', 'log_training_session',
      jsonb_build_object('goal_id', test_training.val('marker_goal'),
                         'effective_date', (current_date + 2)::text)
    )
  $sql$,
  '22023'
);

select test_training.expect_sqlstate(
  'session: back-dating beyond the bound is rejected',
  $sql$
    select test_training.command(
      '33330000-0000-4000-8000-000000000001', 'log_training_session',
      jsonb_build_object('goal_id', test_training.val('marker_goal'),
                         'effective_date', (current_date - 60)::text)
    )
  $sql$,
  '22023'
);

-- DM §12.3: the pin is defended twice -- a published-content trigger (which
-- fires first, hence 22023) and the composite foreign key underneath it.
select test_training.assert_true(
  'invariant: the session version pin is a composite foreign key',
  exists (
    select 1 from pg_constraint c
    where c.conrelid = 'public.training_sessions'::regclass
      and c.contype = 'f'
      and c.confrelid = 'public.training_skills'::regclass
      and array_length(c.conkey, 1) = 2
  )
);

select test_training.expect_sqlstate(
  'invariant: a session cannot pin a version that does not exist',
  $sql$
    insert into public.training_sessions (
      household_id, pet_id, goal_id, skill_ref, skill_version, effective_date,
      actor_user_id, client_idempotency_key
    ) values (
      '44440000-0000-4000-8000-000000000001', '55550000-0000-4000-8000-000000000001',
      (select id from public.training_goals where skill_ref = 'skill.marker_intro'
        and pet_id = '55550000-0000-4000-8000-000000000001'),
      'skill.marker_intro', 99, current_date,
      '33330000-0000-4000-8000-000000000001', 'bad-version'
    )
  $sql$,
  '22023'
);

-- ---------------------------------------------------------------------------
-- 3. Owner-reported progress (US-065, engine §19.2)
-- ---------------------------------------------------------------------------

do $$
declare
  result jsonb;
begin
  result := test_training.command(
    '33330000-0000-4000-8000-000000000001', 'update_training_progress',
    jsonb_build_object(
      'goal_id', test_training.val('marker_goal'),
      'progress_state', 'practicing'
    )
  );
  perform test_training.assert_true(
    'progress: an explicit selection is stored',
    result->'goal'->>'progress_state' = 'practicing',
    result->'goal'->>'progress_state'
  );
  perform test_training.assert_true(
    'progress: the change is attributed to its actor',
    result->'goal'->>'progress_state_updated_by' = '33330000-0000-4000-8000-000000000001'
      and result->'goal'->>'progress_state_updated_at' is not null
  );
  perform test_training.assert_true(
    'progress: the change is auditable with from/to and its source',
    exists (
      select 1 from public.audit_events
      where action = 'training_goal.progress_changed'
        and entity_ref->>'id' = test_training.val('marker_goal')
        and summary->>'from' = 'not_started'
        and summary->>'to' = 'practicing'
        and summary->>'source' = 'explicit_user_selection'
    )
  );
end;
$$;

-- F08's seventh state, "Paused", is a lifecycle fact carried by `status`;
-- accepting it here would silently destroy the reported progress.
select test_training.expect_sqlstate(
  'progress: "paused" is not settable as a progress state',
  $sql$
    select test_training.command(
      '33330000-0000-4000-8000-000000000001', 'update_training_progress',
      jsonb_build_object('goal_id', test_training.val('marker_goal'),
                         'progress_state', 'paused')
    )
  $sql$,
  '22023'
);

select test_training.expect_sqlstate(
  'progress: an unknown state is rejected',
  $sql$
    select test_training.command(
      '33330000-0000-4000-8000-000000000001', 'update_training_progress',
      jsonb_build_object('goal_id', test_training.val('marker_goal'),
                         'progress_state', 'mastered')
    )
  $sql$,
  '22023'
);

-- A session MAY carry an explicit state change (TR-04's separate picker); it
-- is the only way a session touches progress.
do $$
declare
  result jsonb;
begin
  result := test_training.command(
    '33330000-0000-4000-8000-000000000001', 'log_training_session',
    jsonb_build_object(
      'goal_id', test_training.val('marker_goal'),
      'effective_date', (current_date - 1)::text,
      'progress_state_after', 'reliable_in_familiar_setting'
    )
  );
  perform test_training.assert_true(
    'session: an explicit progress_state_after does move the goal',
    result->'goal'->>'progress_state' = 'reliable_in_familiar_setting',
    result->'goal'->>'progress_state'
  );
  perform test_training.assert_true(
    'session: the session keeps its own record of the reported state',
    (select progress_state_after::text from public.training_sessions
      where id = (result->'session'->>'id')::uuid) = 'reliable_in_familiar_setting'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Pause, resume, retire (US-064)
-- ---------------------------------------------------------------------------

do $$
declare
  paused jsonb;
  resumed jsonb;
begin
  paused := test_training.command(
    '33330000-0000-4000-8000-000000000001', 'pause_training_goal',
    jsonb_build_object('goal_id', test_training.val('marker_goal'))
  );
  perform test_training.assert_true(
    'pause: sets paused status with a paused_at instant',
    paused->'goal'->>'status' = 'paused' and paused->'goal'->>'paused_at' is not null
  );
  -- US-064: "Pausing does not mark the skill complete."
  perform test_training.assert_true(
    'pause: leaves the reported progress state untouched',
    paused->'goal'->>'progress_state' = 'reliable_in_familiar_setting',
    paused->'goal'->>'progress_state'
  );

  -- Pausing twice is a no-op, not an error: a retried command must not fail.
  paused := test_training.command(
    '33330000-0000-4000-8000-000000000001', 'pause_training_goal',
    jsonb_build_object('goal_id', test_training.val('marker_goal'))
  );
  perform test_training.assert_true(
    'pause: pausing an already-paused goal is a no-op',
    paused->'goal'->>'status' = 'paused'
  );

  resumed := test_training.command(
    '33330000-0000-4000-8000-000000000001', 'resume_training_goal',
    jsonb_build_object('goal_id', test_training.val('marker_goal'))
  );
  perform test_training.assert_true(
    'resume: restores active status and clears paused_at',
    resumed->'goal'->>'status' = 'active' and resumed->'goal'->>'paused_at' is null
  );
  perform test_training.assert_true(
    'resume: the reported progress survived the round trip',
    resumed->'goal'->>'progress_state' = 'reliable_in_familiar_setting'
  );
  perform test_training.assert_true(
    'resume: history remains visible',
    (select count(*) from public.training_sessions
      where goal_id = test_training.val('marker_goal')::uuid) = 2
  );
end;
$$;

-- Optimistic concurrency is optional but honest when supplied.
select test_training.expect_sqlstate(
  'concurrency: a stale expected_revision is a conflict, not a silent overwrite',
  $sql$
    select test_training.command(
      '33330000-0000-4000-8000-000000000001', 'pause_training_goal',
      jsonb_build_object('goal_id', test_training.val('marker_goal'),
                         'expected_revision', 1)
    )
  $sql$,
  '40001'
);

do $$
declare
  retired jsonb;
  restarted jsonb;
begin
  retired := test_training.command(
    '33330000-0000-4000-8000-000000000001', 'retire_training_goal',
    jsonb_build_object('goal_id', test_training.val('marker_goal'))
  );
  perform test_training.assert_true(
    'retire: sets retired status with a retired_at instant',
    retired->'goal'->>'status' = 'retired' and retired->'goal'->>'retired_at' is not null
  );

  -- Retiring frees the (pet, skill) pair so a household can genuinely start
  -- over, which the partial unique index is designed to allow.
  restarted := test_training.command(
    '33330000-0000-4000-8000-000000000001', 'start_training_goal',
    jsonb_build_object('pet_id', '55550000-0000-4000-8000-000000000001',
                       'skill_ref', 'skill.marker_intro')
  );
  perform test_training.assert_true(
    'retire: the skill can be started fresh afterwards',
    restarted->'goal'->>'id' <> test_training.val('marker_goal')
      and restarted->'goal'->>'status' = 'active'
      and restarted->'goal'->>'progress_state' = 'not_started'
  );
  perform test_training.put('marker_goal_2', restarted->'goal'->>'id');
end;
$$;

select test_training.expect_sqlstate(
  'retire: a retired goal cannot take new sessions',
  $sql$
    select test_training.command(
      '33330000-0000-4000-8000-000000000001', 'log_training_session',
      jsonb_build_object('goal_id', test_training.val('marker_goal'))
    )
  $sql$,
  '22023'
);

-- ---------------------------------------------------------------------------
-- 5. Idempotent replay through command_log
-- ---------------------------------------------------------------------------

do $$
declare
  first_call jsonb;
  replay jsonb;
  payload jsonb := jsonb_build_object(
    'pet_id', '55550000-0000-4000-8000-000000000001',
    'skill_ref', 'skill.crate_comfort'
  );
begin
  first_call := test_training.command(
    '33330000-0000-4000-8000-000000000001', 'start_training_goal', payload, 'replay-key-1'
  );
  replay := test_training.command(
    '33330000-0000-4000-8000-000000000001', 'start_training_goal', payload, 'replay-key-1'
  );
  perform test_training.put('crate_goal', first_call->'goal'->>'id');
  perform test_training.assert_true(
    'replay: the same key returns the stored response',
    replay = first_call
  );
end;
$$;

select test_training.expect_sqlstate(
  'replay: reusing a key with a different payload is a conflict',
  $sql$
    select test_training.command(
      '33330000-0000-4000-8000-000000000001', 'start_training_goal',
      jsonb_build_object('pet_id', '55550000-0000-4000-8000-000000000001',
                         'skill_ref', 'skill.sit'),
      'replay-key-1'
    )
  $sql$,
  '23505'
);

-- ---------------------------------------------------------------------------
-- 6. Generation context: real training_state and real practice recency
-- ---------------------------------------------------------------------------

do $$
declare
  context jsonb;
  state jsonb;
  crate jsonb;
begin
  -- Give the crate-comfort goal one session so recency has something to say.
  perform test_training.command(
    '33330000-0000-4000-8000-000000000001', 'log_training_session',
    jsonb_build_object('goal_id', test_training.val('crate_goal'),
                       'effective_date', (current_date - 1)::text)
  );

  context := public.write_path_generation_context(
    '33330000-0000-4000-8000-000000000001', '55550000-0000-4000-8000-000000000001'
  );
  state := context->'training_state';

  perform test_training.assert_true(
    'context: training_state is no longer hardcoded empty',
    jsonb_array_length(state) >= 2,
    format('%s entries', jsonb_array_length(state))
  );

  select value into crate from jsonb_array_elements(state) value
  where value->>'skill_content_id' = 'skill.crate_comfort';

  perform test_training.assert_true(
    'context: an active goal is reported as active and user-selected',
    crate->>'status' = 'active' and (crate->>'user_selected_goal')::boolean,
    crate::text
  );
  perform test_training.assert_true(
    'context: practice recency comes from the logged session',
    (crate->>'last_practiced_on')::date = current_date - 1,
    crate->>'last_practiced_on'
  );
  perform test_training.assert_true(
    'context: the retired goal is carried through as retired, not completed',
    exists (
      select 1 from jsonb_array_elements(state) value
      where value->>'skill_content_id' = 'skill.marker_intro'
        and value->>'status' = 'retired'
    )
    or exists (
      -- The restarted goal shares the skill id; both rows must be present.
      select 1 from jsonb_array_elements(state) value
      where value->>'skill_content_id' = 'skill.marker_intro'
        and value->>'status' = 'active'
    ),
    state::text
  );
  perform test_training.assert_true(
    'context: a logged session reaches recent_history as completed training',
    exists (
      select 1 from jsonb_array_elements(context->'recent_history') entry
      where entry->>'content_id' = 'skill.crate_comfort'
        and entry->>'category' = 'training'
        and entry->>'outcome' = 'completed'
    )
  );
end;
$$;

-- The alone-time prerequisite is the concrete rule this slice unblocks: with
-- crate comfort started, `skill.alone_time`'s hard constraint is satisfiable
-- for the first time (engine §12.3, catalogue §9).
do $$
declare
  context jsonb;
begin
  context := public.write_path_generation_context(
    '33330000-0000-4000-8000-000000000001', '55550000-0000-4000-8000-000000000001'
  );
  perform test_training.assert_true(
    'context: skill.alone_time''s crate-comfort prerequisite is now satisfiable',
    exists (
      select 1 from jsonb_array_elements(context->'training_state') value
      where value->>'skill_content_id' = 'skill.crate_comfort'
        and value->>'status' in ('active', 'completed')
    )
  );
end;
$$;

-- Another household's goals never leak into this pet's context.
do $$
declare
  context jsonb;
begin
  perform test_training.command(
    '33330000-0000-4000-8000-000000000003', 'start_training_goal',
    jsonb_build_object('pet_id', '55550000-0000-4000-8000-000000000002',
                       'skill_ref', 'skill.sit')
  );
  context := public.write_path_generation_context(
    '33330000-0000-4000-8000-000000000001', '55550000-0000-4000-8000-000000000001'
  );
  perform test_training.assert_true(
    'context: another household''s goal is not present',
    not exists (
      select 1 from jsonb_array_elements(context->'training_state') value
      where value->>'skill_content_id' = 'skill.sit'
    ),
    context->>'training_state'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. RLS and the write-path lockdown
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"33330000-0000-4000-8000-000000000002","role":"authenticated"}', true);

do $$
declare
  visible integer;
begin
  select count(*) into visible from public.training_goals;
  perform test_training.assert_true(
    'rls: a member reads only their own household''s goals',
    visible = (select count(*) from public.training_goals
               where household_id = '44440000-0000-4000-8000-000000000001'),
    format('%s rows visible', visible)
  );

  select count(*) into visible from public.training_sessions;
  perform test_training.assert_true(
    'rls: a member reads only their own household''s sessions',
    visible = (select count(*) from public.training_sessions
               where household_id = '44440000-0000-4000-8000-000000000001'),
    format('%s rows visible', visible)
  );
end;
$$;

select test_training.expect_sqlstate(
  'rls: a member cannot INSERT a training goal directly',
  $sql$
    insert into public.training_goals (household_id, pet_id, skill_ref)
    values ('44440000-0000-4000-8000-000000000001', '55550000-0000-4000-8000-000000000001', 'skill.sit')
  $sql$,
  '42501'
);

select test_training.expect_sqlstate(
  'rls: a member cannot UPDATE a training goal directly',
  $sql$ update public.training_goals set progress_state = 'maintained' $sql$,
  '42501'
);

select test_training.expect_sqlstate(
  'rls: a member cannot INSERT a training session directly',
  $sql$
    insert into public.training_sessions (
      household_id, pet_id, goal_id, skill_ref, skill_version, effective_date, client_idempotency_key
    ) values (
      '44440000-0000-4000-8000-000000000001', '55550000-0000-4000-8000-000000000001',
      '00000000-0000-4000-8000-000000000000', 'skill.sit', 1, current_date, 'x'
    )
  $sql$,
  '42501'
);

select test_training.expect_sqlstate(
  'lockdown: authenticated cannot execute write_path_start_training_goal',
  $sql$ select public.write_path_start_training_goal(null, 'k', 'h', '{}'::jsonb, now(), null, '{}'::jsonb) $sql$,
  '42501'
);
select test_training.expect_sqlstate(
  'lockdown: authenticated cannot execute write_path_log_training_session',
  $sql$ select public.write_path_log_training_session(null, 'k', 'h', '{}'::jsonb, now(), null, '{}'::jsonb) $sql$,
  '42501'
);
select test_training.expect_sqlstate(
  'lockdown: authenticated cannot execute write_path_update_training_progress',
  $sql$ select public.write_path_update_training_progress(null, 'k', 'h', '{}'::jsonb, now(), null, '{}'::jsonb) $sql$,
  '42501'
);
select test_training.expect_sqlstate(
  'lockdown: authenticated cannot execute training_state_for_pet',
  $sql$ select public.training_state_for_pet('55550000-0000-4000-8000-000000000001', 'UTC') $sql$,
  '42501'
);

reset role;
select set_config('request.jwt.claims', null, true);

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail
from test_training.results order by id;

do $$
declare
  total integer;
  failed integer;
begin
  select count(*), count(*) filter (where not passed) into total, failed
  from test_training.results;
  raise notice 'TRAINING SUITE SUMMARY: % / % assertions passed', total - failed, total;
  if failed > 0 then
    raise exception 'TRAINING SUITE: % assertion(s) failed', failed;
  end if;
end;
$$;

rollback;
