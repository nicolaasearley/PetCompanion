-- Events foundation hosted apply (repair).
--
-- `20260729180221_events_foundation` was recorded on hosted as applied during
-- an aborted push but left no objects (`events` missing; generation context
-- still hard-codes events to []). This forward migration applies the real
-- foundation idempotently so local (already complete) and hosted converge.
--
-- generation_context extension preserves training_state + socialization
-- fields from 20260728001200 — only the events array changes.

do $$ begin
  create type public.event_kind as enum (
    'vet_appointment', 'class', 'grooming_visit', 'other'
  );
exception when duplicate_object then null;
end $$;

comment on type public.event_kind is
  'Dated household commitment kind (DM §11.5, F11).';

do $$ begin
  create type public.event_status as enum (
    'confirmed', 'cancelled'
  );
exception when duplicate_object then null;
end $$;

comment on type public.event_status is
  'Event lifecycle. Cancellation retains the row; archive soft-deletes.';

create unique index if not exists pets_id_household_unique on public.pets (id, household_id);

-- ---------------------------------------------------------------------------
-- Event (DM §11.5)
-- ---------------------------------------------------------------------------

create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid references public.pets(id) on delete cascade,
  kind public.event_kind not null,
  title text not null check (char_length(trim(title)) > 0),
  start_date date not null,
  start_time time,
  end_time time,
  all_day boolean not null default true,
  location_text text,
  provider_id uuid references public.providers(id) on delete set null,
  notes text,
  reminder_config jsonb,
  status public.event_status not null default 'confirmed',
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id),
  constraint events_pet_household_fkey
    foreign key (pet_id, household_id) references public.pets (id, household_id),
  constraint events_deleted_shape check (
    (deleted_at is null and deleted_by is null) or deleted_at is not null
  ),
  constraint events_reminder_config_object check (
    reminder_config is null or jsonb_typeof(reminder_config) = 'object'
  ),
  constraint events_time_shape check (
    (all_day and start_time is null and end_time is null)
    or (not all_day and start_time is not null)
  ),
  constraint events_end_after_start check (
    end_time is null or start_time is null or end_time >= start_time
  )
);

comment on table public.events is
  'Dated household commitment — vet appointment, class, grooming, or other (DM §11.5, F11).';
comment on column public.events.pet_id is
  'Optional pet link. Null = household-level event visible for every pet plan.';
comment on column public.events.reminder_config is
  'Lead times object, e.g. {"lead_minutes":[60,1440]}. Delivery is a later slice.';

create index if not exists events_household_upcoming
  on public.events (household_id, start_date, start_time nulls first)
  where deleted_at is null and status = 'confirmed';

create index if not exists events_pet_upcoming
  on public.events (pet_id, start_date)
  where deleted_at is null and status = 'confirmed' and pet_id is not null;

drop trigger if exists events_set_updated_at on public.events;
create trigger events_set_updated_at
  before update on public.events
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Guards (DM §18.6 / §18.10)
-- ---------------------------------------------------------------------------

create or replace function public.event_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  pet_row public.pets%rowtype;
  household_row public.households%rowtype;
  provider_row public.providers%rowtype;
begin
  select * into household_row from public.households where id = new.household_id;
  if not found or household_row.status <> 'active' then
    raise exception 'cannot write an event for a closed household' using errcode = '22023';
  end if;

  if new.pet_id is not null then
    select * into pet_row from public.pets where id = new.pet_id;
    if not found then
      raise exception 'pet % does not exist', new.pet_id using errcode = '22023';
    end if;
    if pet_row.household_id <> new.household_id then
      raise exception 'event household_id must match the pet' using errcode = '22023';
    end if;
    if tg_op = 'INSERT' then
      if pet_row.status <> 'active' or pet_row.deleted_at is not null then
        raise exception 'cannot create an event for an archived or deleted pet'
          using errcode = '22023';
      end if;
    end if;
  end if;

  if new.provider_id is not null then
    select * into provider_row from public.providers where id = new.provider_id;
    if not found or provider_row.deleted_at is not null then
      raise exception 'provider not found' using errcode = '22023';
    end if;
    if provider_row.household_id <> new.household_id then
      raise exception 'provider must belong to the same household' using errcode = '22023';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists events_guard on public.events;
create trigger events_guard
  before insert or update on public.events
  for each row execute function public.event_guard();

-- ---------------------------------------------------------------------------
-- RLS — SELECT only for clients
-- ---------------------------------------------------------------------------

alter table public.events enable row level security;

drop policy if exists "events active member read" on public.events;
create policy "events active member read"
  on public.events for select
  using (public.is_active_household_member(household_id));

revoke insert, update, delete on public.events from anon, authenticated;
grant select on public.events to authenticated;
grant all on public.events to service_role;

-- ---------------------------------------------------------------------------
-- Read shape
-- ---------------------------------------------------------------------------

create or replace function public.event_json(
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
    'id', e.id,
    'household_id', e.household_id,
    'pet_id', e.pet_id,
    'kind', e.kind,
    'title', e.title,
    'start_date', e.start_date,
    'start_time', case when e.start_time is not null then to_char(e.start_time, 'HH24:MI') end,
    'end_time', case when e.end_time is not null then to_char(e.end_time, 'HH24:MI') end,
    'all_day', e.all_day,
    'location_text', e.location_text,
    'provider_id', e.provider_id,
    'notes', e.notes,
    'reminder_config', e.reminder_config,
    'status', e.status,
    'revision', e.revision,
    'created_at', e.created_at,
    'created_by', e.created_by,
    'updated_at', e.updated_at,
    'updated_by', e.updated_by,
    'removed_at', e.deleted_at
  ))
  from public.events e
  where e.id = target_id
    and (include_removed or e.deleted_at is null);
$$;

-- ---------------------------------------------------------------------------
-- Authorize helpers
-- ---------------------------------------------------------------------------

create or replace function public.event_authorize_household(
  actor_id uuid,
  target_household_id uuid
)
returns public.households
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  target_household public.households%rowtype;
begin
  select h.* into target_household
  from public.households h
  join public.household_memberships hm
    on hm.household_id = h.id and hm.user_id = actor_id and hm.status = 'active'
  where h.id = target_household_id
    and h.status = 'active';

  if not found then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  return target_household;
end;
$$;

create or replace function public.event_authorize_pet_optional(
  actor_id uuid,
  target_pet_id uuid,
  target_household_id uuid
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
  if target_pet_id is null then
    return null;
  end if;

  select p.* into target_pet
  from public.pets p
  join public.households h on h.id = p.household_id
  join public.household_memberships hm
    on hm.household_id = h.id and hm.user_id = actor_id and hm.status = 'active'
  where p.id = target_pet_id
    and p.household_id = target_household_id
    and p.status = 'active'
    and p.deleted_at is null
    and h.status = 'active';

  if not found then
    raise exception 'active pet not found in a household you belong to' using errcode = '42501';
  end if;

  return target_pet;
end;
$$;

-- ---------------------------------------------------------------------------
-- Shared payload helpers
-- ---------------------------------------------------------------------------

create or replace function public.event_parse_time(value text)
returns time
language plpgsql
immutable
as $$
declare
  trimmed text;
begin
  trimmed := nullif(trim(value), '');
  if trimmed is null then
    return null;
  end if;
  begin
    if trimmed ~ '^\d{2}:\d{2}$' then
      return (trimmed || ':00')::time;
    end if;
    return trimmed::time;
  exception when others then
    raise exception 'time must be HH:MM' using errcode = '22023';
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_create_event
-- ---------------------------------------------------------------------------

create or replace function public.write_path_create_event(
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
  target_household public.households%rowtype;
  event_id uuid;
  kind_value public.event_kind;
  title_value text;
  start_date_value date;
  start_time_value time;
  end_time_value time;
  all_day_value boolean;
  pet_id_value uuid;
  provider_id_value uuid;
  reminder_value jsonb;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'create_event' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_household := public.event_authorize_household(
    actor_id, nullif(payload_input->>'household_id', '')::uuid
  );

  title_value := nullif(trim(payload_input->>'title'), '');
  if title_value is null then
    raise exception 'title is required' using errcode = '22023';
  end if;

  begin
    kind_value := (payload_input->>'kind')::public.event_kind;
  exception when invalid_text_representation then
    raise exception 'kind must be vet_appointment, class, grooming_visit, or other'
      using errcode = '22023';
  end;
  if kind_value is null then
    raise exception 'kind is required' using errcode = '22023';
  end if;

  start_date_value := nullif(payload_input->>'start_date', '')::date;
  if start_date_value is null then
    raise exception 'start_date is required' using errcode = '22023';
  end if;

  all_day_value := coalesce((payload_input->>'all_day')::boolean, true);
  if all_day_value then
    start_time_value := null;
    end_time_value := null;
  else
    start_time_value := public.event_parse_time(payload_input->>'start_time');
    if start_time_value is null then
      raise exception 'start_time is required when the event is not all-day'
        using errcode = '22023';
    end if;
    end_time_value := public.event_parse_time(payload_input->>'end_time');
  end if;

  pet_id_value := nullif(payload_input->>'pet_id', '')::uuid;
  perform public.event_authorize_pet_optional(actor_id, pet_id_value, target_household.id);

  provider_id_value := nullif(payload_input->>'provider_id', '')::uuid;

  if payload_input ? 'reminder_config' and payload_input->'reminder_config' is not null then
    if jsonb_typeof(payload_input->'reminder_config') <> 'object' then
      raise exception 'reminder_config must be an object' using errcode = '22023';
    end if;
    reminder_value := payload_input->'reminder_config';
  else
    reminder_value := null;
  end if;

  event_id := coalesce(nullif(payload_input->>'event_id', '')::uuid, gen_random_uuid());

  insert into public.events (
    id, household_id, pet_id, kind, title, start_date, start_time, end_time,
    all_day, location_text, provider_id, notes, reminder_config, created_by, updated_by
  ) values (
    event_id, target_household.id, pet_id_value, kind_value, title_value,
    start_date_value, start_time_value, end_time_value, all_day_value,
    nullif(trim(payload_input->>'location_text'), ''),
    provider_id_value,
    nullif(trim(payload_input->>'notes'), ''),
    reminder_value,
    actor_id, actor_id
  );

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_household.id, actor_id,
    jsonb_build_object('type', 'event', 'id', event_id),
    'event.created',
    jsonb_build_object(
      'kind', kind_value,
      'title', title_value,
      'start_date', start_date_value,
      'pet_id', pet_id_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('event', public.event_json(event_id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'create_event', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_edit_event
-- ---------------------------------------------------------------------------

create or replace function public.write_path_edit_event(
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
  target public.events%rowtype;
  expected_revision integer;
  kind_value public.event_kind;
  title_value text;
  start_date_value date;
  start_time_value time;
  end_time_value time;
  all_day_value boolean;
  pet_id_value uuid;
  provider_id_value uuid;
  reminder_value jsonb;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'edit_event' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.events
  where id = nullif(payload_input->>'event_id', '')::uuid
    and deleted_at is null
  for update;
  if not found then
    raise exception 'event not found' using errcode = '22023';
  end if;

  perform public.event_authorize_household(actor_id, target.household_id);

  expected_revision := nullif(payload_input->>'expected_revision', '')::integer;
  if expected_revision is null then
    raise exception 'expected_revision is required' using errcode = '22023';
  end if;
  if expected_revision <> target.revision then
    raise exception 'this record changed since you opened it' using errcode = '40001';
  end if;

  title_value := case when payload_input ? 'title'
    then nullif(trim(payload_input->>'title'), '') else target.title end;
  if title_value is null then
    raise exception 'title is required' using errcode = '22023';
  end if;

  if payload_input ? 'kind' then
    begin
      kind_value := (payload_input->>'kind')::public.event_kind;
    exception when invalid_text_representation then
      raise exception 'kind must be vet_appointment, class, grooming_visit, or other'
        using errcode = '22023';
    end;
    if kind_value is null then
      raise exception 'kind is required' using errcode = '22023';
    end if;
  else
    kind_value := target.kind;
  end if;

  start_date_value := case when payload_input ? 'start_date'
    then nullif(payload_input->>'start_date', '')::date else target.start_date end;
  if start_date_value is null then
    raise exception 'start_date is required' using errcode = '22023';
  end if;

  all_day_value := case when payload_input ? 'all_day'
    then coalesce((payload_input->>'all_day')::boolean, true) else target.all_day end;

  if all_day_value then
    start_time_value := null;
    end_time_value := null;
  else
    if payload_input ? 'start_time' or payload_input ? 'all_day' then
      start_time_value := public.event_parse_time(payload_input->>'start_time');
    else
      start_time_value := target.start_time;
    end if;
    if start_time_value is null then
      raise exception 'start_time is required when the event is not all-day'
        using errcode = '22023';
    end if;
    if payload_input ? 'end_time' then
      end_time_value := public.event_parse_time(payload_input->>'end_time');
    elsif payload_input ? 'all_day' then
      end_time_value := null;
    else
      end_time_value := target.end_time;
    end if;
  end if;

  if payload_input ? 'pet_id' then
    pet_id_value := nullif(payload_input->>'pet_id', '')::uuid;
  else
    pet_id_value := target.pet_id;
  end if;
  perform public.event_authorize_pet_optional(actor_id, pet_id_value, target.household_id);

  if payload_input ? 'provider_id' then
    provider_id_value := nullif(payload_input->>'provider_id', '')::uuid;
  else
    provider_id_value := target.provider_id;
  end if;

  if payload_input ? 'reminder_config' then
    if payload_input->'reminder_config' is null then
      reminder_value := null;
    elsif jsonb_typeof(payload_input->'reminder_config') <> 'object' then
      raise exception 'reminder_config must be an object' using errcode = '22023';
    else
      reminder_value := payload_input->'reminder_config';
    end if;
  else
    reminder_value := target.reminder_config;
  end if;

  update public.events
  set kind = kind_value,
      title = title_value,
      start_date = start_date_value,
      start_time = start_time_value,
      end_time = end_time_value,
      all_day = all_day_value,
      pet_id = pet_id_value,
      location_text = case when payload_input ? 'location_text'
        then nullif(trim(payload_input->>'location_text'), '') else location_text end,
      provider_id = provider_id_value,
      notes = case when payload_input ? 'notes'
        then nullif(trim(payload_input->>'notes'), '') else notes end,
      reminder_config = reminder_value,
      -- Reschedule / edit of a cancelled event restores confirmed (US-086 path).
      status = 'confirmed',
      revision = target.revision + 1,
      updated_by = actor_id
  where id = target.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target.household_id, actor_id,
    jsonb_build_object('type', 'event', 'id', target.id),
    'event.edited',
    jsonb_build_object(
      'kind', kind_value,
      'title', title_value,
      'start_date', start_date_value,
      'previous_start_date', target.start_date,
      'pet_id', pet_id_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('event', public.event_json(target.id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'edit_event', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_cancel_event
-- ---------------------------------------------------------------------------

create or replace function public.write_path_cancel_event(
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
  target public.events%rowtype;
  expected_revision integer;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'cancel_event' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.events
  where id = nullif(payload_input->>'event_id', '')::uuid
    and deleted_at is null
  for update;
  if not found then
    raise exception 'event not found' using errcode = '22023';
  end if;

  perform public.event_authorize_household(actor_id, target.household_id);

  expected_revision := nullif(payload_input->>'expected_revision', '')::integer;
  if expected_revision is null then
    raise exception 'expected_revision is required' using errcode = '22023';
  end if;
  if expected_revision <> target.revision then
    raise exception 'this record changed since you opened it' using errcode = '40001';
  end if;

  if target.status = 'cancelled' then
    response := jsonb_build_object('event', public.event_json(target.id));
  else
    update public.events
    set status = 'cancelled',
        revision = target.revision + 1,
        updated_by = actor_id
    where id = target.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target.household_id, actor_id,
      jsonb_build_object('type', 'event', 'id', target.id),
      'event.cancelled',
      jsonb_build_object('title', target.title, 'start_date', target.start_date),
      recorded_at_input
    );

    response := jsonb_build_object('event', public.event_json(target.id));
  end if;

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'cancel_event', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_archive_event (soft delete)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_archive_event(
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
  target public.events%rowtype;
  expected_revision integer;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'archive_event' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.events
  where id = nullif(payload_input->>'event_id', '')::uuid
    and deleted_at is null
  for update;
  if not found then
    raise exception 'event not found' using errcode = '22023';
  end if;

  perform public.event_authorize_household(actor_id, target.household_id);

  expected_revision := nullif(payload_input->>'expected_revision', '')::integer;
  if expected_revision is null then
    raise exception 'expected_revision is required' using errcode = '22023';
  end if;
  if expected_revision <> target.revision then
    raise exception 'this record changed since you opened it' using errcode = '40001';
  end if;

  update public.events
  set deleted_at = now(),
      deleted_by = actor_id,
      revision = target.revision + 1,
      updated_by = actor_id
  where id = target.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target.household_id, actor_id,
    jsonb_build_object('type', 'event', 'id', target.id),
    'event.archived',
    jsonb_build_object('title', target.title, 'start_date', target.start_date),
    recorded_at_input
  );

  response := jsonb_build_object('event', public.event_json(target.id, true));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'archive_event', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

revoke execute on function public.write_path_create_event(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_edit_event(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_cancel_event(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_archive_event(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;

grant execute on function public.write_path_create_event(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_edit_event(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_cancel_event(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_archive_event(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;

revoke execute on function public.event_json(uuid, boolean) from public, anon, authenticated;
grant execute on function public.event_json(uuid, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- Generation context: real events (extends 20260728001200; preserves training
-- + socialization fields — do not revert those arrays to []).
-- ---------------------------------------------------------------------------

create or replace function public.write_path_generation_context(actor_id uuid, target_pet_id uuid, capacity_override capacity_mode DEFAULT NULL::capacity_mode, at_instant timestamp with time zone DEFAULT now())

returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
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
      -- US-068: an active category exclusion is a HARD constraint. The engine
      -- drops the whole category from rotation, so it can never substitute a
      -- near-duplicate from the same excluded category.
      'excluded_socialization_categories', coalesce((
        select jsonb_agg(distinct se.category)
        from public.socialization_exclusions se
        where se.pet_id = target_pet.id
          and se.cleared_at is null
          and se.category is not null
      ), '[]'::jsonb),
      -- Per-experience exclusions. The engine suppresses these by content id
      -- ("content_excluded") while leaving the rest of the category eligible.
      'excluded_content_ids', coalesce((
        select jsonb_agg(distinct se.experience_content_id)
        from public.socialization_exclusions se
        where se.pet_id = target_pet.id
          and se.cleared_at is null
          and se.experience_content_id is not null
      ), '[]'::jsonb),
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
    -- Confirmed household/pet events in the engine lead window (F11 / DM §11.5).
    -- Engine filters further by stage (7 or 14 days); we supply up to 14 days ahead.
    'events', coalesce((
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'event_id', e.id,
        'title', e.title,
        'kind', e.kind,
        'local_date', e.start_date,
        'exact_time', case
          when e.all_day or e.start_time is null then null
          else to_char(e.start_time, 'HH24:MI')
        end,
        'confirmed', (e.status = 'confirmed')
      )) order by e.start_date, e.start_time nulls first, e.title, e.id)
      from public.events e
      where e.household_id = target_household.id
        and e.deleted_at is null
        and e.status = 'confirmed'
        and e.start_date between target_date and target_date + 14
        and (e.pet_id is null or e.pet_id = target_pet.id)
    ), '[]'::jsonb),
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
        union all
        -- Socialization history from the passport itself (US-067: "Recent
        -- completion reduces unnecessary immediate repetition"). Before this
        -- entity existed the only signal was what the PLAN had shown, so an
        -- experience the household did on its own -- the common case, since
        -- socialization happens on walks and doorsteps, not from a checklist
        -- -- left no trace and the breadth rule kept re-suggesting it.
        --
        -- A custom experience contributes no content_id (it has none) but
        -- still carries its category, so it counts toward breadth rotation
        -- without ever colliding with catalogue content.
        select jsonb_strip_nulls(jsonb_build_object(
          'local_date', sr.effective_date,
          'content_id', sr.experience_content_id,
          'category', 'socialization',
          'socialization_category', sr.category,
          'outcome', 'completed'
        )) as row
        from public.socialization_records sr
        where sr.pet_id = target_pet.id
          and sr.deleted_at is null
          and sr.effective_date >= target_date - 30
      ) history
    ), '[]'::jsonb)
      || public.training_practice_history_for_pet(target_pet.id, target_date - 30)
  );

  return context;
end;
$function$

;

