-- Slice B training: TrainingGoal and TrainingSession (F08, epic E06).
--
-- Until now the training catalogue existed as seeded global content with
-- nowhere to record what a household is actually working on, so
-- `write_path_generation_context` hardcoded `training_state` to '[]' and three
-- engine rules were starved: `rule.start_next_skill` always read zero active
-- goals, `rule.active_skill_practice` had no goals to select, and
-- `rule.alone_time` could never satisfy its `skill.crate_comfort` prerequisite.
--
-- Implements DM 10 §12.2/§12.3 and the §18 invariants they touch:
--   * at most one non-retired goal per (pet, skill) -- a partial unique index,
--     so "start twice" is idempotent at the storage layer, not just in the
--     command (§18 "starting twice is idempotent", US-061);
--   * a session pins the exact skill version it used, enforced by a composite
--     foreign key into `training_skills(content_id, version)` (§12.3);
--   * goals and sessions reference PUBLISHED content only (§18.11 extended to
--     the training entities: a plan may not be built on draft guidance);
--   * every household-owned mutable record carries actor + timestamp metadata
--     and its own `household_id` (§18.10), kept consistent with the pet's
--     household by a trigger (§18.8's "one household" rule);
--   * progress state NEVER advances without explicit user input (§12.2,
--     engine §19.2 "Claiming the puppy has mastered a skill without explicit
--     user input" is not allowed) -- logging a session sets `progress_state`
--     only when the payload carries an explicit `progress_state_after`.
--
-- The seven owner-reported progress states are F08's list. Their seventh,
-- "Paused", is a LIFECYCLE fact, not a judgement about the puppy's learning,
-- so it lives in `status` rather than `progress_state`: pausing a goal must
-- not erase the substantive state the household reported (US-064 "Pausing
-- does not mark the skill complete"). The enum still carries the value for
-- parity with the published list, and the write path refuses to set it
-- directly so the two columns can never disagree.

-- ---------------------------------------------------------------------------
-- Enumerations
-- ---------------------------------------------------------------------------

create type public.training_goal_status as enum ('active', 'paused', 'retired');

create type public.training_progress_state as enum (
  'not_started',
  'introduced',
  'practicing',
  'reliable_in_familiar_setting',
  'generalizing',
  'maintained',
  'paused'
);

comment on type public.training_progress_state is
  'The seven owner-reported progress states of Core Features F08. Owner-reported, never inferred, and never a certification (US-065).';

-- ---------------------------------------------------------------------------
-- TrainingGoal (DM 10 §12.2)
-- ---------------------------------------------------------------------------

create table public.training_goals (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  -- Content id only: sessions pin versions individually (§12.2), so a
  -- catalogue revision never rewrites the history of what was practised.
  skill_ref text not null,
  status public.training_goal_status not null default 'active',
  progress_state public.training_progress_state not null default 'not_started',
  started_at timestamptz not null default now(),
  started_by uuid references auth.users(id),
  paused_at timestamptz,
  resumed_at timestamptz,
  retired_at timestamptz,
  -- US-065: "Progress history identifies who changed it."
  progress_state_updated_at timestamptz,
  progress_state_updated_by uuid references auth.users(id),
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  constraint training_goals_skill_ref_shape check (skill_ref like 'skill.%'),
  -- Lifecycle timestamps must agree with the status they describe.
  constraint training_goals_paused_shape check ((status = 'paused') = (paused_at is not null)),
  constraint training_goals_retired_shape check ((status = 'retired') = (retired_at is not null)),
  -- "Paused" is surfaced from `status`; storing it in both places would let
  -- them drift and would destroy the reported progress on pause.
  constraint training_goals_progress_not_paused check (progress_state <> 'paused')
);

-- DM §18: at most one non-retired goal per (pet, skill). Retiring frees the
-- pair so a household can genuinely start over later.
create unique index training_goals_one_non_retired_per_pet_skill
  on public.training_goals (pet_id, skill_ref)
  where status <> 'retired';

create index training_goals_pet_status on public.training_goals (pet_id, status);
create index training_goals_household on public.training_goals (household_id);

comment on table public.training_goals is
  'A pet''s active pursuit of a catalogue skill (DM 10 §12.2). At most one non-retired goal per (pet, skill).';

-- ---------------------------------------------------------------------------
-- TrainingSession (DM 10 §12.3)
-- ---------------------------------------------------------------------------

create table public.training_sessions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  goal_id uuid not null references public.training_goals(id) on delete cascade,
  -- The version is pinned, not resolved at read time: a session records what
  -- the caregiver actually followed (§12.3).
  skill_ref text not null,
  skill_version integer not null,
  effective_date date not null,
  effective_time time,
  duration_minutes integer check (duration_minutes between 1 and 600),
  outcome_note text,
  -- Explicit user selection only. NULL means "the household said nothing
  -- about progress", which is the common case and must stay distinguishable
  -- from "they reconfirmed the current state".
  progress_state_after public.training_progress_state,
  media_refs jsonb,
  actor_user_id uuid references auth.users(id),
  client_idempotency_key text not null,
  recorded_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  -- Pinning is a foreign key, not a convention: a session can only ever name
  -- a skill version that exists.
  foreign key (skill_ref, skill_version) references public.training_skills(content_id, version),
  constraint training_sessions_progress_not_paused check (
    progress_state_after is null or progress_state_after <> 'paused'
  ),
  constraint training_sessions_media_shape check (
    media_refs is null or jsonb_typeof(media_refs) = 'array'
  )
);

-- DM §18.3: unique client_idempotency_key per actor.
create unique index training_sessions_client_idempotency_per_actor
  on public.training_sessions (actor_user_id, client_idempotency_key);

create index training_sessions_goal_date on public.training_sessions (goal_id, effective_date desc);
create index training_sessions_pet_date on public.training_sessions (pet_id, effective_date desc);

comment on table public.training_sessions is
  'One logged practice session (DM 10 §12.3). Pins the skill version used and never auto-advances mastery (US-063).';

-- ---------------------------------------------------------------------------
-- Invariant triggers
-- ---------------------------------------------------------------------------

-- DM §18.10/§18.8: a record reachable from a household carries ITS household,
-- not some other one. Without this a service-role write could file a goal
-- under household A for a pet owned by household B and every RLS read after
-- it would be wrong.
create or replace function public.enforce_training_household_matches_pet()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  pet_household uuid;
begin
  select p.household_id into pet_household from public.pets p where p.id = new.pet_id;
  if pet_household is null then
    raise exception 'training record references an unknown pet' using errcode = '23503';
  end if;
  if new.household_id <> pet_household then
    raise exception 'training record household must match its pet''s household'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger training_goals_household_matches_pet
  before insert or update on public.training_goals
  for each row execute function public.enforce_training_household_matches_pet();

create trigger training_sessions_household_matches_pet
  before insert or update on public.training_sessions
  for each row execute function public.enforce_training_household_matches_pet();

-- DM §18.11 ("PlanItems reference only published content versions") applied to
-- the training entities. A goal is the thing the engine turns into a plan
-- item, so allowing a draft skill here would smuggle unreviewed guidance into
-- a plan through the back door.
create or replace function public.enforce_published_training_skill()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_table_name = 'training_goals' then
    if not exists (
      select 1
      from public.training_skills ts
      join public.content_versions cv using (content_id, version)
      where ts.content_id = new.skill_ref
        and cv.publication_status = 'published'
        and ts.retired_at is null
    ) then
      raise exception 'training goals may only reference a published skill (%)', new.skill_ref
        using errcode = '22023';
    end if;
  else
    if not exists (
      select 1
      from public.content_versions cv
      where cv.content_id = new.skill_ref
        and cv.version = new.skill_version
        and cv.publication_status = 'published'
    ) then
      raise exception 'training sessions may only pin a published skill version (%@%)',
        new.skill_ref, new.skill_version
        using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;

create trigger training_goals_published_skill_only
  before insert or update on public.training_goals
  for each row execute function public.enforce_published_training_skill();

-- Sessions are checked on INSERT only. A skill version that is retired after
-- the fact must not make an already-recorded session unwritable, and sessions
-- are never re-pointed at a different version.
create trigger training_sessions_published_skill_only
  before insert on public.training_sessions
  for each row execute function public.enforce_published_training_skill();

-- ---------------------------------------------------------------------------
-- RLS: household-scoped reads, no client writes
-- ---------------------------------------------------------------------------

alter table public.training_goals enable row level security;
alter table public.training_sessions enable row level security;

create policy "training goals active member read" on public.training_goals
  for select using (public.is_active_household_member(household_id));
create policy "training sessions active member read" on public.training_sessions
  for select using (public.is_active_household_member(household_id));

-- Both tables carry invariants (one non-retired goal per pet+skill; the
-- version pin; published-content-only) that only the write path can uphold
-- with its validation and audit trail, so clients get SELECT and nothing else.
-- Slice A's `grant select on all tables` does not reach tables created later,
-- so these are named explicitly.
grant select on public.training_goals, public.training_sessions to authenticated;
grant all on public.training_goals, public.training_sessions to service_role;

-- ---------------------------------------------------------------------------
-- Shared helpers for the training write commands
-- ---------------------------------------------------------------------------

-- Every training command resolves the same three things: the pet must be
-- active, the actor must be an active member of its (active) household, and
-- the caller wants the household row back for its time zone.
create or replace function public.training_resolve_pet(actor_id uuid, target_pet_id uuid)
returns public.pets
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  target_pet public.pets%rowtype;
begin
  if target_pet_id is null then
    raise exception 'pet_id is required' using errcode = '22023';
  end if;

  select p.* into target_pet
  from public.pets p
  where p.id = target_pet_id and p.status = 'active' and p.deleted_at is null;
  if not found then
    raise exception 'active pet not found' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.households h
    join public.household_memberships hm on hm.household_id = h.id
    where h.id = target_pet.household_id
      and h.status = 'active'
      and hm.user_id = actor_id
      and hm.status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  return target_pet;
end;
$$;

-- The response shape shared by every goal command, so a client can apply one
-- decoder and one merge regardless of which lifecycle transition it sent.
create or replace function public.training_goal_response(target_goal_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'goal', jsonb_build_object(
      'id', g.id,
      'household_id', g.household_id,
      'pet_id', g.pet_id,
      'skill_ref', g.skill_ref,
      'status', g.status,
      'progress_state', g.progress_state,
      'started_at', g.started_at,
      'started_by', g.started_by,
      'paused_at', g.paused_at,
      'resumed_at', g.resumed_at,
      'retired_at', g.retired_at,
      'progress_state_updated_at', g.progress_state_updated_at,
      'progress_state_updated_by', g.progress_state_updated_by,
      'revision', g.revision,
      'last_session_on', (
        select max(s.effective_date) from public.training_sessions s where s.goal_id = g.id
      ),
      'session_count', (
        select count(*) from public.training_sessions s where s.goal_id = g.id
      )
    )
  ))
  from public.training_goals g
  where g.id = target_goal_id;
$$;

-- Optional optimistic concurrency. The lifecycle transitions are small and
-- idempotent by design, so a client that does not track revisions may omit
-- `expected_revision`; one that does gets a clean conflict instead of a
-- silent last-writer-wins.
create or replace function public.training_assert_revision(
  goal_revision integer,
  payload_input jsonb
)
returns void
language plpgsql
immutable
as $$
declare
  expected integer;
begin
  expected := nullif(payload_input->>'expected_revision', '')::integer;
  if expected is not null and expected <> goal_revision then
    raise exception 'this training goal changed on another device' using errcode = '40001';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Locked-goal helper: every command after the first addresses an existing
-- goal, by id or by (pet, skill)
-- ---------------------------------------------------------------------------

create or replace function public.training_locked_goal(actor_id uuid, payload_input jsonb)
returns public.training_goals
language plpgsql
security definer
set search_path = public
as $$
declare
  target_goal public.training_goals%rowtype;
  goal_id uuid;
  skill_ref_value text;
  target_pet public.pets%rowtype;
begin
  goal_id := nullif(payload_input->>'goal_id', '')::uuid;
  skill_ref_value := nullif(trim(payload_input->>'skill_ref'), '');

  if goal_id is not null then
    select * into target_goal from public.training_goals where id = goal_id for update;
    if not found then
      raise exception 'training goal not found' using errcode = '22023';
    end if;
    -- Membership is re-derived from the goal's own pet, never trusted from
    -- the payload: a client may not name a goal in someone else's household.
    perform public.training_resolve_pet(actor_id, target_goal.pet_id);
    return target_goal;
  end if;

  -- (pet_id, skill_ref) addressing lets the client act on "the goal for this
  -- skill" without having read its id first, which is what the lesson screen
  -- (TR-03) actually has in hand.
  if skill_ref_value is null then
    raise exception 'goal_id or (pet_id and skill_ref) is required' using errcode = '22023';
  end if;
  target_pet := public.training_resolve_pet(actor_id, nullif(payload_input->>'pet_id', '')::uuid);
  select * into target_goal from public.training_goals
  where pet_id = target_pet.id and skill_ref = skill_ref_value and status <> 'retired'
  for update;
  if not found then
    raise exception 'no active goal for this skill' using errcode = '22023';
  end if;
  return target_goal;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_start_training_goal (US-061)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_start_training_goal(
  actor_id uuid,
  idempotency_key text,
  payload_hash_input text,
  request_body_input jsonb,
  recorded_at_input timestamptz,
  effective_at_input timestamptz,
  payload_input jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.command_log%rowtype;
  target_pet public.pets%rowtype;
  skill_ref_value text;
  existing_goal public.training_goals%rowtype;
  goal_id uuid;
  started_at_value timestamptz;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'start_training_goal' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_pet := public.training_resolve_pet(actor_id, nullif(payload_input->>'pet_id', '')::uuid);

  skill_ref_value := nullif(trim(payload_input->>'skill_ref'), '');
  if skill_ref_value is null then
    raise exception 'skill_ref is required' using errcode = '22023';
  end if;

  -- Serialises two devices starting the same skill at the same instant. The
  -- partial unique index would catch it anyway, but as a 23505 that reads to
  -- the client as an idempotency conflict rather than "you already have this".
  perform pg_advisory_xact_lock(hashtextextended('training_goal:' || target_pet.id::text || ':' || skill_ref_value, 0));

  select * into existing_goal from public.training_goals
  where pet_id = target_pet.id and skill_ref = skill_ref_value and status <> 'retired'
  for update;

  if found then
    -- US-061: "Starting the same goal twice remains idempotent." A paused
    -- goal is deliberately returned untouched rather than silently resumed --
    -- resuming is its own explicit action (TR-03 shows [ Resume ]).
    goal_id := existing_goal.id;
  else
    started_at_value := coalesce(effective_at_input, recorded_at_input, now());
    insert into public.training_goals (
      household_id, pet_id, skill_ref, status, progress_state,
      started_at, started_by, created_by, updated_by
    ) values (
      target_pet.household_id, target_pet.id, skill_ref_value, 'active', 'not_started',
      started_at_value, actor_id, actor_id, actor_id
    )
    returning id into goal_id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target_pet.household_id, actor_id,
      jsonb_build_object('type', 'training_goal', 'id', goal_id),
      'training_goal.started',
      jsonb_build_object('pet_id', target_pet.id, 'skill_ref', skill_ref_value),
      recorded_at_input
    );
  end if;

  response := public.training_goal_response(goal_id);

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'start_training_goal', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_pause_training_goal (US-064)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_pause_training_goal(
  actor_id uuid,
  idempotency_key text,
  payload_hash_input text,
  request_body_input jsonb,
  recorded_at_input timestamptz,
  effective_at_input timestamptz,
  payload_input jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.command_log%rowtype;
  target_goal public.training_goals%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'pause_training_goal' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_goal := public.training_locked_goal(actor_id, payload_input);
  perform public.training_assert_revision(target_goal.revision, payload_input);

  if target_goal.status = 'retired' then
    raise exception 'this goal was retired; start it again to practise it' using errcode = '22023';
  end if;

  if target_goal.status = 'active' then
    update public.training_goals
    set status = 'paused',
        paused_at = coalesce(effective_at_input, recorded_at_input, now()),
        -- US-064: "Pausing does not mark the skill complete." `progress_state`
        -- is untouched, so resuming restores the reported progress exactly.
        revision = revision + 1,
        updated_at = now(),
        updated_by = actor_id
    where id = target_goal.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target_goal.household_id, actor_id,
      jsonb_build_object('type', 'training_goal', 'id', target_goal.id),
      'training_goal.paused',
      jsonb_build_object('skill_ref', target_goal.skill_ref, 'progress_state', target_goal.progress_state),
      recorded_at_input
    );
  end if;

  response := public.training_goal_response(target_goal.id);

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'pause_training_goal', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_resume_training_goal (US-064 "Resuming restores eligibility")
-- ---------------------------------------------------------------------------

create or replace function public.write_path_resume_training_goal(
  actor_id uuid,
  idempotency_key text,
  payload_hash_input text,
  request_body_input jsonb,
  recorded_at_input timestamptz,
  effective_at_input timestamptz,
  payload_input jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.command_log%rowtype;
  target_goal public.training_goals%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'resume_training_goal' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_goal := public.training_locked_goal(actor_id, payload_input);
  perform public.training_assert_revision(target_goal.revision, payload_input);

  if target_goal.status = 'retired' then
    raise exception 'this goal was retired; start it again to practise it' using errcode = '22023';
  end if;

  if target_goal.status = 'paused' then
    update public.training_goals
    set status = 'active',
        paused_at = null,
        resumed_at = coalesce(effective_at_input, recorded_at_input, now()),
        revision = revision + 1,
        updated_at = now(),
        updated_by = actor_id
    where id = target_goal.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target_goal.household_id, actor_id,
      jsonb_build_object('type', 'training_goal', 'id', target_goal.id),
      'training_goal.resumed',
      jsonb_build_object('skill_ref', target_goal.skill_ref, 'progress_state', target_goal.progress_state),
      recorded_at_input
    );
  end if;

  response := public.training_goal_response(target_goal.id);

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'resume_training_goal', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_retire_training_goal (F08 "Start, pause, resume, and retire")
-- ---------------------------------------------------------------------------

create or replace function public.write_path_retire_training_goal(
  actor_id uuid,
  idempotency_key text,
  payload_hash_input text,
  request_body_input jsonb,
  recorded_at_input timestamptz,
  effective_at_input timestamptz,
  payload_input jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.command_log%rowtype;
  target_goal public.training_goals%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'retire_training_goal' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_goal := public.training_locked_goal(actor_id, payload_input);
  perform public.training_assert_revision(target_goal.revision, payload_input);

  if target_goal.status <> 'retired' then
    update public.training_goals
    set status = 'retired',
        paused_at = null,
        retired_at = coalesce(effective_at_input, recorded_at_input, now()),
        revision = revision + 1,
        updated_at = now(),
        updated_by = actor_id
    where id = target_goal.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target_goal.household_id, actor_id,
      jsonb_build_object('type', 'training_goal', 'id', target_goal.id),
      'training_goal.retired',
      jsonb_build_object(
        'skill_ref', target_goal.skill_ref,
        'previous_status', target_goal.status,
        'progress_state', target_goal.progress_state
      ),
      recorded_at_input
    );
  end if;

  response := public.training_goal_response(target_goal.id);

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'retire_training_goal', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_update_training_progress (US-065)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_update_training_progress(
  actor_id uuid,
  idempotency_key text,
  payload_hash_input text,
  request_body_input jsonb,
  recorded_at_input timestamptz,
  effective_at_input timestamptz,
  payload_input jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.command_log%rowtype;
  target_goal public.training_goals%rowtype;
  requested text;
  next_state public.training_progress_state;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'update_training_progress' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_goal := public.training_locked_goal(actor_id, payload_input);
  perform public.training_assert_revision(target_goal.revision, payload_input);

  requested := nullif(trim(payload_input->>'progress_state'), '');
  if requested is null then
    raise exception 'progress_state is required' using errcode = '22023';
  end if;
  if requested = 'paused' then
    raise exception 'pausing is a goal status change, not a progress state' using errcode = '22023';
  end if;
  if requested not in (
    'not_started', 'introduced', 'practicing',
    'reliable_in_familiar_setting', 'generalizing', 'maintained'
  ) then
    raise exception 'progress_state is not one of the owner-reported states' using errcode = '22023';
  end if;
  next_state := requested::public.training_progress_state;

  if target_goal.status = 'retired' then
    raise exception 'this goal was retired; start it again to record progress' using errcode = '22023';
  end if;

  -- Re-selecting the same state is a no-op rather than an error: a retry
  -- with a fresh idempotency key must not fail the caregiver.
  if target_goal.progress_state <> next_state then
    update public.training_goals
    set progress_state = next_state,
        progress_state_updated_at = coalesce(effective_at_input, recorded_at_input, now()),
        progress_state_updated_by = actor_id,
        revision = revision + 1,
        updated_at = now(),
        updated_by = actor_id
    where id = target_goal.id;

    -- US-065: progress changes are attributed, and the audit trail is the
    -- history the interface reads back ("who changed it").
    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target_goal.household_id, actor_id,
      jsonb_build_object('type', 'training_goal', 'id', target_goal.id),
      'training_goal.progress_changed',
      jsonb_build_object(
        'skill_ref', target_goal.skill_ref,
        'from', target_goal.progress_state,
        'to', next_state,
        'source', 'explicit_user_selection'
      ),
      recorded_at_input
    );
  end if;

  response := public.training_goal_response(target_goal.id);

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'update_training_progress', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_log_training_session (US-063)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_log_training_session(
  actor_id uuid,
  idempotency_key text,
  payload_hash_input text,
  request_body_input jsonb,
  recorded_at_input timestamptz,
  effective_at_input timestamptz,
  payload_input jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.command_log%rowtype;
  target_goal public.training_goals%rowtype;
  target_household public.households%rowtype;
  today_local date;
  session_id uuid;
  effective_date_value date;
  effective_time_value time;
  duration_value integer;
  skill_version_value integer;
  requested_progress text;
  next_state public.training_progress_state;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'log_training_session' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_goal := public.training_locked_goal(actor_id, payload_input);

  if target_goal.status = 'retired' then
    raise exception 'this goal was retired; start it again to log a session' using errcode = '22023';
  end if;

  select h.* into target_household from public.households h where h.id = target_goal.household_id;
  today_local := public.household_current_local_date(target_household.id, coalesce(recorded_at_input, now()));

  effective_date_value := coalesce(
    nullif(payload_input->>'effective_date', '')::date,
    today_local
  );
  -- TR-04: "back-dateable within bounds". A month of history covers a missed
  -- week without letting a typo file a session in the puppy's past life, and
  -- a future-dated session would be a plan, not a record.
  if effective_date_value > today_local then
    raise exception 'a training session cannot be logged in the future' using errcode = '22023';
  end if;
  if effective_date_value < today_local - 30 then
    raise exception 'a training session can be back-dated by at most 30 days' using errcode = '22023';
  end if;

  effective_time_value := nullif(payload_input->>'effective_time', '')::time;

  duration_value := nullif(payload_input->>'duration_minutes', '')::integer;
  if duration_value is not null and (duration_value < 1 or duration_value > 600) then
    raise exception 'duration_minutes must be between 1 and 600' using errcode = '22023';
  end if;

  -- The version the caregiver actually followed is pinned at write time, from
  -- the current published version of the goal's skill (§12.3).
  select max(ts.version) into skill_version_value
  from public.training_skills ts
  join public.content_versions cv using (content_id, version)
  where ts.content_id = target_goal.skill_ref
    and cv.publication_status = 'published';
  if skill_version_value is null then
    raise exception 'no published version of % is available', target_goal.skill_ref using errcode = '22023';
  end if;

  requested_progress := nullif(trim(payload_input->>'progress_state_after'), '');
  if requested_progress = 'paused' then
    raise exception 'pausing is a goal status change, not a progress state' using errcode = '22023';
  end if;
  if requested_progress is not null and requested_progress not in (
    'not_started', 'introduced', 'practicing',
    'reliable_in_familiar_setting', 'generalizing', 'maintained'
  ) then
    raise exception 'progress_state_after is not one of the owner-reported states' using errcode = '22023';
  end if;
  next_state := requested_progress::public.training_progress_state;

  insert into public.training_sessions (
    household_id, pet_id, goal_id, skill_ref, skill_version,
    effective_date, effective_time, duration_minutes, outcome_note,
    progress_state_after, media_refs, actor_user_id, client_idempotency_key,
    recorded_at, created_by, updated_by
  ) values (
    target_goal.household_id, target_goal.pet_id, target_goal.id,
    target_goal.skill_ref, skill_version_value,
    effective_date_value, effective_time_value, duration_value,
    nullif(trim(payload_input->>'outcome_note'), ''),
    next_state,
    case when jsonb_typeof(payload_input->'media_refs') = 'array' then payload_input->'media_refs' end,
    actor_id, idempotency_key, recorded_at_input, actor_id, actor_id
  )
  returning id into session_id;

  -- US-063: "A single session does not automatically declare mastery."
  -- `progress_state` moves only when the payload carried an explicit
  -- selection from the separate progress picker (TR-04).
  if next_state is not null and next_state <> target_goal.progress_state then
    update public.training_goals
    set progress_state = next_state,
        progress_state_updated_at = coalesce(effective_at_input, recorded_at_input, now()),
        progress_state_updated_by = actor_id,
        revision = revision + 1,
        updated_at = now(),
        updated_by = actor_id
    where id = target_goal.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target_goal.household_id, actor_id,
      jsonb_build_object('type', 'training_goal', 'id', target_goal.id),
      'training_goal.progress_changed',
      jsonb_build_object(
        'skill_ref', target_goal.skill_ref,
        'from', target_goal.progress_state,
        'to', next_state,
        'source', 'explicit_user_selection',
        'session_id', session_id
      ),
      recorded_at_input
    );
  end if;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_goal.household_id, actor_id,
    jsonb_build_object('type', 'training_session', 'id', session_id),
    'training_session.logged',
    jsonb_build_object(
      'goal_id', target_goal.id,
      'skill_ref', target_goal.skill_ref,
      'skill_version', skill_version_value,
      'effective_date', effective_date_value
    ),
    recorded_at_input
  );

  response := public.training_goal_response(target_goal.id) || jsonb_build_object(
    'session', jsonb_strip_nulls(jsonb_build_object(
      'id', session_id,
      'goal_id', target_goal.id,
      'pet_id', target_goal.pet_id,
      'skill_ref', target_goal.skill_ref,
      'skill_version', skill_version_value,
      'effective_date', effective_date_value,
      'effective_time', case when effective_time_value is not null then to_char(effective_time_value, 'HH24:MI:SS') end,
      'duration_minutes', duration_value,
      'outcome_note', nullif(trim(payload_input->>'outcome_note'), ''),
      'progress_state_after', next_state,
      'actor_user_id', actor_id,
      'recorded_at', recorded_at_input
    ))
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'log_training_session', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- Generation context: real `training_state` and real practice recency
-- ---------------------------------------------------------------------------

-- Deliberately factored out of `write_path_generation_context` rather than
-- inlined. That function is a shared surface several slices extend at once;
-- keeping each slice's contribution behind a one-line call means a
-- concurrently-authored `create or replace` of the context can be rebased by
-- re-adding one line instead of re-deriving a block.
create or replace function public.training_state_for_pet(
  target_pet_id uuid,
  time_zone_input text
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(state order by state->>'skill_content_id'), '[]'::jsonb)
  from (
    select jsonb_strip_nulls(jsonb_build_object(
      'skill_content_id', g.skill_ref,
      -- The engine's four-value vocabulary has no "retired", so it is carried
      -- through as its own value: a retired goal must neither be re-proposed
      -- by `rule.start_next_skill` nor silently satisfy another skill's
      -- prerequisite the way "completed" would (engine §12.3).
      'status', g.status::text,
      -- Every goal exists because a caregiver chose it (DM §12.2), which is
      -- exactly what the engine's user_selected_goal weight means (§19.2
      -- "Continue a skill that the owner actively selected").
      'user_selected_goal', true,
      'progress_state', g.progress_state,
      'started_on', (g.started_at at time zone time_zone_input)::date,
      'last_practiced_on', (
        select max(s.effective_date) from public.training_sessions s where s.goal_id = g.id
      )
    )) as state
    from public.training_goals g
    where g.pet_id = target_pet_id
  ) goals;
$$;

-- Logged sessions are practice history in their own right: without them the
-- engine's cooldown and due-frequency scoring for `rule.active_skill_practice`
-- would only ever see plan-item dispositions, so a session logged from the
-- Training tab would not delay the next practice suggestion.
create or replace function public.training_practice_history_for_pet(
  target_pet_id uuid,
  from_date date
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(entry order by entry->>'local_date' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'local_date', s.effective_date,
      'content_id', s.skill_ref,
      'category', 'training',
      'outcome', 'completed'
    ) as entry
    from public.training_sessions s
    where s.pet_id = target_pet_id
      and s.effective_date >= from_date
  ) sessions;
$$;


-- ---------------------------------------------------------------------------
-- write_path_generation_context: emit real training state
-- ---------------------------------------------------------------------------

-- Replaces the 20260728000100 body verbatim except for the two marked lines.
-- Nothing else in it is touched, so a diff against that migration shows
-- exactly what this slice contributes.

create or replace function public.write_path_generation_context(
  actor_id uuid,
  target_pet_id uuid,
  capacity_override public.capacity_mode default null,
  at_instant timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target_pet public.pets%rowtype;
  target_household public.households%rowtype;
  preferences public.household_preferences%rowtype;
  pet_preferences_row public.pet_preferences%rowtype;
  paused_categories public.task_category[];
  target_date date;
  next_plan_version integer;
  context jsonb;
begin
  select p.* into target_pet
  from public.pets p
  where p.id = target_pet_id and p.status = 'active' and p.deleted_at is null;

  if not found then
    raise exception 'active pet not found' using errcode = '22023';
  end if;

  select h.* into target_household
  from public.households h
  join public.household_memberships hm
    on hm.household_id = h.id and hm.user_id = actor_id and hm.status = 'active'
  where h.id = target_pet.household_id and h.status = 'active';

  if not found then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  select hp.* into preferences
  from public.household_preferences hp
  where hp.household_id = target_household.id;

  select pp.* into pet_preferences_row
  from public.pet_preferences pp
  where pp.pet_id = target_pet.id;

  -- PetPreference.paused_recommendation_categories is stored per task category,
  -- while the engine pauses individual content. Resolving the categories to the
  -- published content they cover is the only lever that honours the setting
  -- (engine §12.3, §19.1) without a second preference store.
  paused_categories := coalesce(pet_preferences_row.paused_recommendation_categories, '{}'::public.task_category[]);

  target_date := public.household_current_local_date(target_household.id, at_instant);
  perform public.write_path_materialize_occurrences(actor_id, target_pet.id, target_date, 14);

  select coalesce(max(p.plan_version), 0) + 1 into next_plan_version
  from public.plans p
  where p.pet_id = target_pet.id and p.local_date = target_date;

  context := jsonb_build_object(
    'local_date', target_date,
    'now_instant', at_instant,
    'plan_version', next_plan_version,
    'pet', jsonb_build_object(
      'pet_id', target_pet.id,
      'household_id', target_household.id,
      'name', target_pet.name,
      'species', target_pet.species,
      'birth_info', case target_pet.birth_date_kind
        when 'exact' then jsonb_build_object('kind', 'exact', 'birth_date', target_pet.birth_date)
        else jsonb_build_object(
          'kind', 'estimated',
          'estimated_age_weeks', target_pet.estimated_age_weeks,
          'estimated_as_of_date', target_pet.estimated_as_of_date
        )
      end,
      'expected_homecoming_date', target_pet.homecoming_date,
      'stage_override', target_pet.stage_override
    ),
    'household', jsonb_build_object(
      'time_zone', target_household.time_zone,
      'capacity_mode', coalesce(capacity_override, preferences.default_capacity_mode, target_household.default_capacity_mode),
      'custom_recommendation_budget',
        case when coalesce(capacity_override, preferences.default_capacity_mode, target_household.default_capacity_mode) = 'custom'
          then coalesce((pet_preferences_row.suggestion_frequency_adjustments->>'custom_recommendation_budget')::integer, 3)
        end,
      'routine_windows', coalesce((
        select jsonb_agg(jsonb_build_object(
          'window_ref', rw.key,
          'start_time', rw.value->>'start',
          'end_time', rw.value->>'end'
        ) order by rw.key)
        from jsonb_each(coalesce(preferences.routine_windows, '{}'::jsonb)) rw
        where rw.key in ('morning', 'midday', 'afternoon', 'evening', 'sleep')
          and jsonb_typeof(rw.value) = 'object'
          and rw.value ? 'start'
          and rw.value ? 'end'
      ), '[]'::jsonb),
      -- No SocializationExclusion entity in this slice (see header).
      'excluded_socialization_categories', '[]'::jsonb,
      'excluded_content_ids', '[]'::jsonb,
      'paused_content_ids', coalesce((
        select jsonb_agg(paused.content_id order by paused.content_id)
        from (
          select td.content_id
          from public.task_definitions td
          join public.content_versions cv
            on cv.content_id = td.content_id and cv.version = td.content_version
          where td.provenance = 'system'
            and td.deleted_at is null
            and cv.publication_status = 'published'
            and td.category = any (paused_categories)
          union
          select ts.content_id
          from public.training_skills ts
          join public.content_versions cv using (content_id, version)
          where cv.publication_status = 'published'
            and 'training'::public.task_category = any (paused_categories)
          union
          select sc.content_id
          from public.socialization_catalog sc
          join public.content_versions cv using (content_id, version)
          where cv.publication_status = 'published'
            and 'socialization'::public.task_category = any (paused_categories)
        ) paused
      ), '[]'::jsonb),
      'brushing_cooldown_days',
        coalesce((pet_preferences_row.suggestion_frequency_adjustments->>'brushing_cooldown_days')::integer, 3)
    ),
    'active_occurrences', coalesce((
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'id', o.id,
        'occurrence_key', o.occurrence_key,
        'schedule_id', o.schedule_id,
        'title', td.title,
        'content_id', td.content_id,
        'content_version', td.content_version,
        'category', td.category,
        'obligation_class', o.obligation_class,
        'origin', o.origin,
        'origin_ref', o.origin_ref,
        'local_due_date', o.local_due_date,
        'original_local_due_date', o.original_local_due_date,
        'time_policy', o.time_policy,
        'due_time', case when o.due_time is not null then to_char(o.due_time, 'HH24:MI:SS') end,
        'window_ref', o.window_ref,
        'effort_band', td.default_effort,
        'state', o.state,
        'completion', (
          select jsonb_strip_nulls(jsonb_build_object(
            'completed_at', d.effective_at,
            'completed_by_user_id', d.actor_user_id,
            'completed_by_name', up.display_name
          ))
          from public.dispositions d
          left join public.user_profiles up on up.id = d.actor_user_id
          where d.occurrence_id = o.id and d.action = 'complete' and not d.superseded
          order by d.effective_at
          limit 1
        )
      )) order by o.local_due_date, o.occurrence_key)
      from public.task_occurrences o
      join public.task_schedules s on s.id = o.schedule_id
      join public.task_definitions td on td.id = s.task_definition_id
      where o.pet_id = target_pet.id
        and o.deleted_at is null
        and o.local_due_date between target_date - 30 and target_date + 7
        and o.state not in ('cancelled', 'expired')
    ), '[]'::jsonb),
    -- No Event entity in this slice (see header).
    'events', '[]'::jsonb,
    'catalogue', jsonb_build_object(
      'development_stages', coalesce((
        select jsonb_agg(to_jsonb(ds) - 'review_status' order by ds.content_id, ds.version)
        from public.development_stages ds
        join public.content_versions cv using (content_id, version)
        where cv.publication_status = 'published'
      ), '[]'::jsonb),
      'task_definitions', coalesce((
        select jsonb_agg(jsonb_build_object(
          'content_id', td.content_id, 'version', td.content_version, 'title', td.title,
          'category', td.category, 'default_obligation_class', td.default_obligation_class,
          'default_effort', td.default_effort, 'default_time_policy', td.default_time_policy,
          'metadata', td.metadata
        ) order by td.content_id, td.content_version)
        from public.task_definitions td
        join public.content_versions cv
          on cv.content_id = td.content_id and cv.version = td.content_version
        where td.provenance = 'system' and cv.publication_status = 'published'
      ), '[]'::jsonb),
      'recommendation_rules', coalesce((
        select jsonb_agg(to_jsonb(rr) - 'review_status' order by rr.content_id, rr.version)
        from public.recommendation_rules rr
        join public.content_versions cv using (content_id, version)
        where cv.publication_status = 'published'
      ), '[]'::jsonb),
      'training_skills', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'content_id', ts.content_id, 'version', ts.version, 'skill_group', ts.skill_group,
            'title', ts.title, 'prerequisite_skill_refs', ts.prerequisite_skill_refs,
            'stage_guidance', ts.stage_guidance, 'effort_band', ts.effort_band,
            'recommended_frequency', ts.recommended_frequency,
            'effective_from', ts.effective_from, 'retired_at', ts.retired_at
          ) order by ts.content_id, ts.version
        )
        from public.training_skills ts
        join public.content_versions cv using (content_id, version)
        where cv.publication_status = 'published'
      ), '[]'::jsonb),
      'socialization_catalog', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'content_id', sc.content_id, 'version', sc.version, 'category', sc.category,
            'experience_key', sc.experience_key, 'label', sc.label,
            'caution_text', sc.caution_text, 'response_vocabulary', sc.response_vocabulary,
            'effective_from', sc.effective_from, 'retired_at', sc.retired_at
          ) order by sc.content_id, sc.version
        )
        from public.socialization_catalog sc
        join public.content_versions cv using (content_id, version)
        where cv.publication_status = 'published'
      ), '[]'::jsonb)
    ),
    -- Real goal status, ownership and practice recency now that TrainingGoal
    -- and TrainingSession exist (migration 20260728001000). Behind a helper so
    -- a concurrently-authored replacement of this function can be rebased by
    -- re-adding one line.
    'training_state', public.training_state_for_pet(target_pet.id, target_household.time_zone),
    'recent_history', coalesce((
      select jsonb_agg(history.row order by history.row->>'local_date' desc)
      from (
        select jsonb_strip_nulls(jsonb_build_object(
          'local_date', p.local_date,
          'content_id', pi.content_ref->>'content_id',
          'rule_content_id', pi.recommendation_rule_ref->>'content_id',
          'category', pi.category,
          'socialization_category', public.socialization_category_for_content(pi.content_ref->>'content_id'),
          'outcome', case
            when pi.display_state = 'completed' then 'completed'
            when pi.display_state = 'skipped' then 'skipped'
            when pi.display_state = 'expired' then 'expired'
            else 'shown'
          end
        )) as row
        from public.plan_items pi
        join public.plans p on p.id = pi.plan_id
        where p.pet_id = target_pet.id
          and p.local_date >= target_date - 30
        union all
        select jsonb_strip_nulls(jsonb_build_object(
          'local_date', (d.effective_at at time zone target_household.time_zone)::date,
          -- A recommendation accepted into the plan becomes a user-provenance
          -- TaskDefinition, which carries no content_id of its own; the promoted
          -- content reference is the only link back to the catalogue, and
          -- without it completions never fed cooldowns or category recency.
          'content_id', coalesce(td.content_id, td.metadata->'content_ref'->>'content_id'),
          'category', td.category,
          'socialization_category', public.socialization_category_for_content(
            coalesce(td.content_id, td.metadata->'content_ref'->>'content_id')
          ),
          'outcome', case
            when d.action = 'complete' then 'completed'
            -- "Do not suggest for now" (engine §16.3) is a dismissal, not an
            -- ordinary skip: it must reach the engine's dismissal cooldown and
            -- penalty (§12.3, §12.2) rather than read as a one-day skip.
            when d.action = 'skip' and d.skip_reason = 'do_not_suggest_for_now' then 'dismissed'
            when d.action = 'skip' then 'skipped'
            when d.action = 'dismiss_required' then 'dismissed'
          end
        )) as row
        from public.dispositions d
        join public.task_occurrences o on o.id = d.occurrence_id
        join public.task_schedules s on s.id = o.schedule_id
        join public.task_definitions td on td.id = s.task_definition_id
        where o.pet_id = target_pet.id
          and d.action in ('complete', 'skip', 'dismiss_required')
          and not d.superseded
          and (d.effective_at at time zone target_household.time_zone)::date >= target_date - 30
      ) history
    ), '[]'::jsonb)
      -- Sessions logged from the Training tab are practice history in their
      -- own right; without them `rule.active_skill_practice` cooldowns and
      -- due-frequency scoring would only ever see plan-item dispositions.
      || public.training_practice_history_for_pet(target_pet.id, target_date - 30)
  );

  return context;
end;
$$;

revoke execute on function public.write_path_generation_context(uuid, uuid, public.capacity_mode, timestamptz) from public, anon, authenticated;
grant execute on function public.write_path_generation_context(uuid, uuid, public.capacity_mode, timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- SECURITY DEFINER lockdown
-- ---------------------------------------------------------------------------

-- Every write_path_* function trusts its actor_id argument, and every helper
-- below either trusts an actor_id or reads past RLS, so only the edge
-- function's service role may call them.
revoke execute on function public.write_path_start_training_goal(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_pause_training_goal(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_resume_training_goal(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_retire_training_goal(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_update_training_progress(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_log_training_session(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.training_resolve_pet(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.training_locked_goal(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.training_goal_response(uuid) from public, anon, authenticated;
revoke execute on function public.training_assert_revision(integer, jsonb) from public, anon, authenticated;
revoke execute on function public.training_state_for_pet(uuid, text) from public, anon, authenticated;
revoke execute on function public.training_practice_history_for_pet(uuid, date) from public, anon, authenticated;
revoke execute on function public.enforce_training_household_matches_pet() from public, anon, authenticated;
revoke execute on function public.enforce_published_training_skill() from public, anon, authenticated;

grant execute on function public.write_path_start_training_goal(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_pause_training_goal(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_resume_training_goal(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_retire_training_goal(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_update_training_progress(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_log_training_session(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.training_resolve_pet(uuid, uuid) to service_role;
grant execute on function public.training_locked_goal(uuid, jsonb) to service_role;
grant execute on function public.training_goal_response(uuid) to service_role;
grant execute on function public.training_assert_revision(integer, jsonb) to service_role;
grant execute on function public.training_state_for_pet(uuid, text) to service_role;
grant execute on function public.training_practice_history_for_pet(uuid, date) to service_role;
grant execute on function public.enforce_training_household_matches_pet() to service_role;
grant execute on function public.enforce_published_training_skill() to service_role;
