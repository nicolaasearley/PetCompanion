-- Life milestones (F12, DM §12.5, LF-01–LF-03).
--
-- First real Life write paths. Media metadata + Storage are deliberately
-- absent: milestone text must save independently of photo upload (Scenario H /
-- US-090), and half-wired Storage is worse than honest "photos later" copy.
-- `media_refs` is reserved as a nullable jsonb array for a future media pass.
--
-- Clients SELECT only. Mutations go through write_path_* SECURITY DEFINER RPCs
-- (same shape as Care weight / socialization). This migration does NOT
-- replace write_path_generation_context or any Care/Planner/training function.
--
-- DM §18 invariants:
--   §18.6  no new record for an archived pet or a closed household
--   §18.10 household_id on every row + composite FK (pet_id, household_id)
--   §18.3  unique client_idempotency_key per actor via command_log
--
-- Product exclusions expressed structurally: no streak, score, or engagement
-- columns — Life is a calm timeline of memories, not a feed.

-- Composite pet/household unique index already exists from socialization.
create unique index if not exists pets_id_household_unique on public.pets (id, household_id);

-- ---------------------------------------------------------------------------
-- Milestone (DM §12.5)
-- ---------------------------------------------------------------------------

create table public.milestones (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  title text not null check (char_length(trim(title)) > 0 and char_length(title) <= 200),
  effective_date date not null,
  note text,
  -- Reserved for a future media pass (DM §12.6). Always null in this slice;
  -- shape-checked so a later attach path can land without a type migration.
  media_refs jsonb,
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id),
  constraint milestones_pet_household_fkey
    foreign key (pet_id, household_id) references public.pets (id, household_id),
  constraint milestones_media_array check (
    media_refs is null or jsonb_typeof(media_refs) = 'array'
  ),
  constraint milestones_deleted_shape check (
    (deleted_at is null and deleted_by is null) or deleted_at is not null
  )
);

comment on table public.milestones is
  'A dated life moment for a pet (DM §12.5, F12/US-090). Text saves independently of media; no score or streak is stored.';
comment on column public.milestones.media_refs is
  'Reserved jsonb array of media ids. Unused until Storage + media metadata ship; never required for a save.';
comment on column public.milestones.effective_date is
  'Timeline order key (capture/event date). Not upload order (F12 acceptance).';

create index milestones_pet_recent
  on public.milestones (pet_id, effective_date desc, created_at desc)
  where deleted_at is null;

create trigger milestones_set_updated_at
  before update on public.milestones
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Guard (DM §18.6 / §18.10)
-- ---------------------------------------------------------------------------

create or replace function public.milestone_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  pet_row public.pets%rowtype;
  household_row public.households%rowtype;
begin
  select * into pet_row from public.pets where id = new.pet_id;
  if not found then
    raise exception 'pet % does not exist', new.pet_id using errcode = '22023';
  end if;
  if pet_row.household_id <> new.household_id then
    raise exception 'milestone household_id must match the pet' using errcode = '22023';
  end if;
  if pet_row.status <> 'active' or pet_row.deleted_at is not null then
    raise exception 'cannot write a milestone for an archived or deleted pet' using errcode = '22023';
  end if;

  select * into household_row from public.households where id = new.household_id;
  if not found or household_row.status <> 'active' then
    raise exception 'cannot write a milestone for a closed household' using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger milestones_guard
  before insert or update on public.milestones
  for each row execute function public.milestone_guard();

-- ---------------------------------------------------------------------------
-- RLS — SELECT only for clients
-- ---------------------------------------------------------------------------

alter table public.milestones enable row level security;

create policy "milestones active member read"
  on public.milestones for select
  using (public.is_active_household_member(household_id));

grant select on public.milestones to authenticated;
grant all on public.milestones to service_role;

-- ---------------------------------------------------------------------------
-- Read shape
-- ---------------------------------------------------------------------------

create or replace function public.milestone_json(
  target_id uuid,
  include_removed boolean default false
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', m.id,
    'household_id', m.household_id,
    'pet_id', m.pet_id,
    'title', m.title,
    'effective_date', m.effective_date,
    'note', m.note,
    'media_refs', m.media_refs,
    'revision', m.revision,
    'created_at', m.created_at,
    'created_by', m.created_by,
    'created_by_name', up.display_name,
    'updated_at', m.updated_at,
    'updated_by', m.updated_by,
    'removed_at', m.deleted_at
  ))
  from public.milestones m
  left join public.user_profiles up on up.id = m.created_by
  where m.id = target_id
    and (include_removed or m.deleted_at is null);
$$;

-- ---------------------------------------------------------------------------
-- Authorize helper (Life-owned; do not replace Care helpers)
-- ---------------------------------------------------------------------------

create or replace function public.life_authorize_pet(
  actor_id uuid,
  target_pet_id uuid
)
returns public.pets
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  target_pet public.pets%rowtype;
begin
  select p.* into target_pet
  from public.pets p
  join public.households h on h.id = p.household_id
  join public.household_memberships hm
    on hm.household_id = h.id and hm.user_id = actor_id and hm.status = 'active'
  where p.id = target_pet_id
    and p.status = 'active'
    and p.deleted_at is null
    and h.status = 'active';

  if not found then
    raise exception 'active pet not found in a household you belong to' using errcode = '42501';
  end if;

  return target_pet;
end;
$$;

comment on function public.life_authorize_pet(uuid, uuid) is
  'Resolves a pet the actor may write Life milestones for, or raises 42501.';

-- ---------------------------------------------------------------------------
-- write_path_create_milestone (US-090, LF-03)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_create_milestone(
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
  milestone_id uuid;
  title_value text;
  effective_date_value date;
  today_local date;
  media_refs_value jsonb;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'create_milestone' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_pet := public.life_authorize_pet(
    actor_id, nullif(payload_input->>'pet_id', '')::uuid
  );

  title_value := nullif(trim(payload_input->>'title'), '');
  if title_value is null then
    raise exception 'title is required' using errcode = '22023';
  end if;
  if char_length(title_value) > 200 then
    raise exception 'title must be 200 characters or fewer' using errcode = '22023';
  end if;

  today_local := public.household_current_local_date(target_pet.household_id, now());
  effective_date_value := coalesce(
    nullif(payload_input->>'effective_date', '')::date,
    today_local
  );
  if effective_date_value > today_local then
    raise exception 'a milestone cannot be recorded for a future date' using errcode = '22023';
  end if;
  if effective_date_value < today_local - (365 * 20) then
    raise exception 'effective_date is more than twenty years ago' using errcode = '22023';
  end if;

  media_refs_value := payload_input->'media_refs';
  if media_refs_value is not null and jsonb_typeof(media_refs_value) = 'null' then
    media_refs_value := null;
  end if;
  if media_refs_value is not null and jsonb_typeof(media_refs_value) <> 'array' then
    raise exception 'media_refs must be an array' using errcode = '22023';
  end if;
  -- This slice does not accept media attachments yet. Reject non-empty arrays
  -- so clients cannot claim a photo that Storage cannot serve.
  if media_refs_value is not null and jsonb_array_length(media_refs_value) > 0 then
    raise exception 'photo attachments are not available yet' using errcode = '22023';
  end if;

  milestone_id := coalesce(nullif(payload_input->>'milestone_id', '')::uuid, gen_random_uuid());

  insert into public.milestones (
    id, household_id, pet_id, title, effective_date, note, media_refs,
    created_by, updated_by
  ) values (
    milestone_id, target_pet.household_id, target_pet.id, title_value,
    effective_date_value, nullif(trim(payload_input->>'note'), ''), null,
    actor_id, actor_id
  );

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_pet.household_id, actor_id,
    jsonb_build_object('type', 'milestone', 'id', milestone_id),
    'life.milestone_created',
    jsonb_build_object(
      'pet_id', target_pet.id,
      'title', title_value,
      'effective_date', effective_date_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('milestone', public.milestone_json(milestone_id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'create_milestone', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_edit_milestone
-- ---------------------------------------------------------------------------

create or replace function public.write_path_edit_milestone(
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
  target public.milestones%rowtype;
  expected_revision integer;
  title_value text;
  effective_date_value date;
  today_local date;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'edit_milestone' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.milestones
  where id = nullif(payload_input->>'milestone_id', '')::uuid
    and deleted_at is null
  for update;
  if not found then
    raise exception 'milestone not found' using errcode = '22023';
  end if;

  perform public.life_authorize_pet(actor_id, target.pet_id);

  expected_revision := nullif(payload_input->>'expected_revision', '')::integer;
  if expected_revision is null then
    raise exception 'expected_revision is required' using errcode = '22023';
  end if;
  if expected_revision <> target.revision then
    raise exception 'this record changed since you opened it' using errcode = '40001';
  end if;

  if payload_input ? 'title' then
    title_value := nullif(trim(payload_input->>'title'), '');
    if title_value is null then
      raise exception 'title is required' using errcode = '22023';
    end if;
    if char_length(title_value) > 200 then
      raise exception 'title must be 200 characters or fewer' using errcode = '22023';
    end if;
  else
    title_value := target.title;
  end if;

  today_local := public.household_current_local_date(target.household_id, now());
  if payload_input ? 'effective_date' then
    effective_date_value := nullif(payload_input->>'effective_date', '')::date;
    if effective_date_value is null then
      raise exception 'effective_date is required when provided' using errcode = '22023';
    end if;
  else
    effective_date_value := target.effective_date;
  end if;
  if effective_date_value > today_local then
    raise exception 'a milestone cannot be recorded for a future date' using errcode = '22023';
  end if;

  update public.milestones
  set title = title_value,
      effective_date = effective_date_value,
      note = case when payload_input ? 'note'
        then nullif(trim(payload_input->>'note'), '') else note end,
      revision = target.revision + 1,
      updated_by = actor_id
  where id = target.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target.household_id, actor_id,
    jsonb_build_object('type', 'milestone', 'id', target.id),
    'life.milestone_edited',
    jsonb_build_object(
      'pet_id', target.pet_id,
      'previous_title', target.title,
      'title', title_value,
      'previous_effective_date', target.effective_date,
      'effective_date', effective_date_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('milestone', public.milestone_json(target.id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'edit_milestone', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_remove_milestone
-- ---------------------------------------------------------------------------

create or replace function public.write_path_remove_milestone(
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
  target public.milestones%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'remove_milestone' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.milestones
  where id = nullif(payload_input->>'milestone_id', '')::uuid
  for update;
  if not found then
    raise exception 'milestone not found' using errcode = '22023';
  end if;

  perform public.life_authorize_pet(actor_id, target.pet_id);

  if target.deleted_at is null then
    update public.milestones
    set deleted_at = now(),
        deleted_by = actor_id,
        updated_by = actor_id
    where id = target.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target.household_id, actor_id,
      jsonb_build_object('type', 'milestone', 'id', target.id),
      'life.milestone_removed',
      jsonb_build_object(
        'pet_id', target.pet_id,
        'title', target.title,
        'effective_date', target.effective_date
      ),
      recorded_at_input
    );
  end if;

  response := jsonb_build_object('milestone', public.milestone_json(target.id, true));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'remove_milestone', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- Lockdown
-- ---------------------------------------------------------------------------

revoke execute on function public.write_path_create_milestone(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_edit_milestone(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_remove_milestone(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;

grant execute on function public.write_path_create_milestone(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_edit_milestone(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_remove_milestone(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;

revoke execute on function public.life_authorize_pet(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.milestone_json(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.milestone_guard() from public, anon, authenticated;
