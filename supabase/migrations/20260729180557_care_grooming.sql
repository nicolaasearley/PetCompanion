-- Care grooming: history-only records (F10, DM §11.1 grooming fields, CA-01).
--
-- HISTORY ONLY. This migration must not add:
--   * computed grooming schedules or engine "due in N days" obligations;
--   * clinical advice, dose guidance, or packaging/breed inference;
--   * medication / vaccination occurrence generation.
-- next_due_date is an optional owner-entered FACT for display only —
-- never computed by PetCompanion.
--
-- Clients SELECT only. Mutations go through write_path_* SECURITY DEFINER RPCs
-- (same shape as weight/providers/vaccinations). Reuses care_authorize_pet from
-- 20260729172830_care_weight_and_providers.sql. Does NOT replace
-- write_path_generation_context or any training/socialization/medication
-- function (docs/22 handoff trap).

-- ---------------------------------------------------------------------------
-- Vocabulary
-- ---------------------------------------------------------------------------

create type public.grooming_activity_type as enum (
  'brushing',
  'nails',
  'bath',
  'teeth',
  'ears',
  'other'
);

comment on type public.grooming_activity_type is
  'Owner-entered grooming activity (DM §11.1). Catalogue cadence keys are suggestions only — never auto-scheduled here.';

create unique index if not exists pets_id_household_unique on public.pets (id, household_id);

-- ---------------------------------------------------------------------------
-- GroomingRecord (DM §11.1 grooming type-specific fields)
-- ---------------------------------------------------------------------------

create table public.grooming_records (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  activity_type public.grooming_activity_type not null,
  -- Date the grooming happened (household-local).
  effective_date date not null,
  -- Optional owner-entered next date. Display only — never computed.
  next_due_date date,
  note text,
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id),
  constraint grooming_records_pet_household_fkey
    foreign key (pet_id, household_id) references public.pets (id, household_id),
  constraint grooming_records_deleted_shape check (
    (deleted_at is null and deleted_by is null) or deleted_at is not null
  ),
  constraint grooming_records_note_shape check (
    note is null or char_length(trim(note)) > 0
  ),
  constraint grooming_records_next_due_after_done check (
    next_due_date is null or next_due_date >= effective_date
  )
);

comment on table public.grooming_records is
  'Owner-entered grooming history (DM §11.1). No schedule computation.';
comment on column public.grooming_records.activity_type is
  'brushing | nails | bath | teeth | ears | other — as chosen by the owner.';
comment on column public.grooming_records.next_due_date is
  'Optional fact entered by the owner when they want a reminder date shown. Never computed.';

create index grooming_records_pet_recent
  on public.grooming_records (pet_id, effective_date desc, created_at desc)
  where deleted_at is null;

create index grooming_records_pet_activity_date
  on public.grooming_records (pet_id, activity_type, effective_date desc)
  where deleted_at is null;

create trigger grooming_records_set_updated_at
  before update on public.grooming_records
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Guards (DM §18.6 / §18.10)
-- ---------------------------------------------------------------------------

create or replace function public.grooming_record_guard()
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
    raise exception 'grooming household_id must match the pet' using errcode = '22023';
  end if;
  if pet_row.status <> 'active' or pet_row.deleted_at is not null then
    raise exception 'cannot write grooming for an archived or deleted pet'
      using errcode = '22023';
  end if;

  select * into household_row from public.households where id = new.household_id;
  if not found or household_row.status <> 'active' then
    raise exception 'cannot write grooming for a closed household'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger grooming_records_guard
  before insert or update on public.grooming_records
  for each row execute function public.grooming_record_guard();

-- ---------------------------------------------------------------------------
-- RLS — SELECT only for clients
-- ---------------------------------------------------------------------------

alter table public.grooming_records enable row level security;

create policy "grooming records active member read"
  on public.grooming_records for select
  using (public.is_active_household_member(household_id));

grant select on public.grooming_records to authenticated;
grant all on public.grooming_records to service_role;

-- ---------------------------------------------------------------------------
-- Read shape
-- ---------------------------------------------------------------------------

create or replace function public.grooming_record_json(
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
    'id', gr.id,
    'household_id', gr.household_id,
    'pet_id', gr.pet_id,
    'activity_type', gr.activity_type,
    'effective_date', gr.effective_date,
    'next_due_date', gr.next_due_date,
    'note', gr.note,
    'revision', gr.revision,
    'created_at', gr.created_at,
    'created_by', gr.created_by,
    'created_by_name', up.display_name,
    'updated_at', gr.updated_at,
    'updated_by', gr.updated_by,
    'removed_at', gr.deleted_at
  ))
  from public.grooming_records gr
  left join public.user_profiles up on up.id = gr.created_by
  where gr.id = target_id
    and (include_removed or gr.deleted_at is null);
$$;

-- ---------------------------------------------------------------------------
-- write_path_record_grooming
-- ---------------------------------------------------------------------------

create or replace function public.write_path_record_grooming(
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
  record_id uuid;
  activity_value public.grooming_activity_type;
  effective_date_value date;
  next_due_value date;
  today_local date;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
       or existing.command <> 'record_grooming' then
      raise exception 'idempotency key reused with different command or payload'
        using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_pet := public.care_authorize_pet(
    actor_id, nullif(payload_input->>'pet_id', '')::uuid
  );

  begin
    activity_value := (payload_input->>'activity_type')::public.grooming_activity_type;
  exception when invalid_text_representation then
    raise exception 'activity_type must be brushing, nails, bath, teeth, ears, or other'
      using errcode = '22023';
  end;
  if activity_value is null then
    raise exception 'activity_type is required' using errcode = '22023';
  end if;

  today_local := public.household_current_local_date(target_pet.household_id, now());
  effective_date_value := coalesce(
    nullif(payload_input->>'effective_date', '')::date,
    today_local
  );
  if effective_date_value > today_local then
    raise exception 'a grooming entry cannot be recorded for a future date'
      using errcode = '22023';
  end if;
  if effective_date_value < today_local - (365 * 5) then
    raise exception 'effective_date is more than five years ago'
      using errcode = '22023';
  end if;

  next_due_value := nullif(payload_input->>'next_due_date', '')::date;
  if next_due_value is not null and next_due_value < effective_date_value then
    raise exception 'next_due_date cannot be before the date done'
      using errcode = '22023';
  end if;

  record_id := coalesce(nullif(payload_input->>'grooming_id', '')::uuid, gen_random_uuid());

  insert into public.grooming_records (
    id, household_id, pet_id, activity_type, effective_date, next_due_date,
    note, created_by, updated_by
  ) values (
    record_id, target_pet.household_id, target_pet.id, activity_value,
    effective_date_value, next_due_value,
    nullif(trim(payload_input->>'note'), ''),
    actor_id, actor_id
  );

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_pet.household_id, actor_id,
    jsonb_build_object('type', 'grooming_record', 'id', record_id),
    'care.grooming_recorded',
    jsonb_build_object(
      'pet_id', target_pet.id,
      'activity_type', activity_value,
      'effective_date', effective_date_value,
      'next_due_date', next_due_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('grooming', public.grooming_record_json(record_id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'record_grooming', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_edit_grooming
-- ---------------------------------------------------------------------------

create or replace function public.write_path_edit_grooming(
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
  target public.grooming_records%rowtype;
  expected_revision integer;
  activity_value public.grooming_activity_type;
  effective_date_value date;
  next_due_value date;
  today_local date;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
       or existing.command <> 'edit_grooming' then
      raise exception 'idempotency key reused with different command or payload'
        using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.grooming_records
  where id = nullif(payload_input->>'grooming_id', '')::uuid
    and deleted_at is null
  for update;
  if not found then
    raise exception 'grooming record not found' using errcode = '22023';
  end if;

  perform public.care_authorize_pet(actor_id, target.pet_id);

  expected_revision := nullif(payload_input->>'expected_revision', '')::integer;
  if expected_revision is null then
    raise exception 'expected_revision is required' using errcode = '22023';
  end if;
  if expected_revision <> target.revision then
    raise exception 'this record changed since you opened it' using errcode = '40001';
  end if;

  if payload_input ? 'activity_type' then
    begin
      activity_value := (payload_input->>'activity_type')::public.grooming_activity_type;
    exception when invalid_text_representation then
      raise exception 'activity_type must be brushing, nails, bath, teeth, ears, or other'
        using errcode = '22023';
    end;
    if activity_value is null then
      raise exception 'activity_type is required when provided' using errcode = '22023';
    end if;
  else
    activity_value := target.activity_type;
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
    raise exception 'a grooming entry cannot be recorded for a future date'
      using errcode = '22023';
  end if;

  if payload_input ? 'next_due_date' then
    next_due_value := nullif(payload_input->>'next_due_date', '')::date;
  else
    next_due_value := target.next_due_date;
  end if;
  if next_due_value is not null and next_due_value < effective_date_value then
    raise exception 'next_due_date cannot be before the date done'
      using errcode = '22023';
  end if;

  update public.grooming_records
  set activity_type = activity_value,
      effective_date = effective_date_value,
      next_due_date = next_due_value,
      note = case when payload_input ? 'note'
        then nullif(trim(payload_input->>'note'), '') else note end,
      revision = target.revision + 1,
      updated_by = actor_id
  where id = target.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target.household_id, actor_id,
    jsonb_build_object('type', 'grooming_record', 'id', target.id),
    'care.grooming_edited',
    jsonb_build_object(
      'pet_id', target.pet_id,
      'previous_activity_type', target.activity_type,
      'activity_type', activity_value,
      'previous_effective_date', target.effective_date,
      'effective_date', effective_date_value,
      'previous_next_due_date', target.next_due_date,
      'next_due_date', next_due_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('grooming', public.grooming_record_json(target.id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'edit_grooming', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_remove_grooming
-- ---------------------------------------------------------------------------

create or replace function public.write_path_remove_grooming(
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
  target public.grooming_records%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
       or existing.command <> 'remove_grooming' then
      raise exception 'idempotency key reused with different command or payload'
        using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.grooming_records
  where id = nullif(payload_input->>'grooming_id', '')::uuid
  for update;
  if not found then
    raise exception 'grooming record not found' using errcode = '22023';
  end if;

  perform public.care_authorize_pet(actor_id, target.pet_id);

  if target.deleted_at is null then
    update public.grooming_records
    set deleted_at = now(),
        deleted_by = actor_id,
        updated_by = actor_id
    where id = target.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target.household_id, actor_id,
      jsonb_build_object('type', 'grooming_record', 'id', target.id),
      'care.grooming_removed',
      jsonb_build_object(
        'pet_id', target.pet_id,
        'activity_type', target.activity_type
      ),
      recorded_at_input
    );
  end if;

  response := jsonb_build_object(
    'grooming', public.grooming_record_json(target.id, true)
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'remove_grooming', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- Lockdown
-- ---------------------------------------------------------------------------

revoke execute on function public.write_path_record_grooming(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_edit_grooming(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_remove_grooming(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;

grant execute on function public.write_path_record_grooming(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_edit_grooming(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_remove_grooming(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;

revoke execute on function public.grooming_record_json(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.grooming_record_guard() from public, anon, authenticated;
