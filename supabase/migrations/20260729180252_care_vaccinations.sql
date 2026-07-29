-- Care vaccinations: history-only records (F10, DM §11.1 vaccination fields,
-- US-070, CA-05 vaccination editor / CA-01 hub row).
--
-- HISTORY ONLY. This migration must not add:
--   * computed vaccination schedules or "due in N days" engine surfaces;
--   * dose advice, packaging/breed inference, or clinical recommendations;
--   * medication occurrence generation.
-- next_due_date is an optional owner/vet-entered FACT for display only —
-- never computed by PetCompanion.
--
-- Clients SELECT only. Mutations go through write_path_* SECURITY DEFINER RPCs
-- (same shape as weight/providers). Reuses care_authorize_pet from
-- 20260729172830_care_weight_and_providers.sql. Does NOT replace
-- write_path_generation_context or any training/socialization/medication
-- function (docs/22 handoff trap).

-- ---------------------------------------------------------------------------
-- Vocabulary
-- ---------------------------------------------------------------------------

create type public.vaccination_provenance as enum (
  'owner_entered',
  'professional_instruction'
);

comment on type public.vaccination_provenance is
  'Who provided the vaccination record (US-070). Never alters professionally sourced content.';

create unique index if not exists pets_id_household_unique on public.pets (id, household_id);

-- ---------------------------------------------------------------------------
-- VaccinationRecord (DM §11.1 vaccination type-specific fields)
-- ---------------------------------------------------------------------------

create table public.vaccination_records (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  vaccine_name text not null check (char_length(trim(vaccine_name)) > 0),
  -- Date the vaccine was given (household-local).
  effective_date date not null,
  -- Optional owner/vet-entered next due date. Display only — never computed.
  next_due_date date,
  provenance public.vaccination_provenance not null default 'owner_entered',
  provider_id uuid references public.providers(id),
  note text,
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id),
  constraint vaccination_records_pet_household_fkey
    foreign key (pet_id, household_id) references public.pets (id, household_id),
  constraint vaccination_records_deleted_shape check (
    (deleted_at is null and deleted_by is null) or deleted_at is not null
  ),
  constraint vaccination_records_note_shape check (
    note is null or char_length(trim(note)) > 0
  ),
  constraint vaccination_records_next_due_after_given check (
    next_due_date is null or next_due_date >= effective_date
  )
);

comment on table public.vaccination_records is
  'Owner/vet-entered vaccination history (US-070). No schedule computation.';
comment on column public.vaccination_records.vaccine_name is
  'As entered from documents or vet. Never normalized into a clinical catalogue.';
comment on column public.vaccination_records.next_due_date is
  'Optional fact entered by owner/vet when explicitly known. Never computed.';

create index vaccination_records_pet_recent
  on public.vaccination_records (pet_id, effective_date desc, created_at desc)
  where deleted_at is null;

create index vaccination_records_pet_name_date
  on public.vaccination_records (pet_id, lower(trim(vaccine_name)), effective_date)
  where deleted_at is null;

create trigger vaccination_records_set_updated_at
  before update on public.vaccination_records
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Guards (DM §18.6 / §18.10)
-- ---------------------------------------------------------------------------

create or replace function public.vaccination_record_guard()
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
  select * into pet_row from public.pets where id = new.pet_id;
  if not found then
    raise exception 'pet % does not exist', new.pet_id using errcode = '22023';
  end if;
  if pet_row.household_id <> new.household_id then
    raise exception 'vaccination household_id must match the pet' using errcode = '22023';
  end if;
  if pet_row.status <> 'active' or pet_row.deleted_at is not null then
    raise exception 'cannot write vaccination for an archived or deleted pet'
      using errcode = '22023';
  end if;

  select * into household_row from public.households where id = new.household_id;
  if not found or household_row.status <> 'active' then
    raise exception 'cannot write vaccination for a closed household'
      using errcode = '22023';
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

create trigger vaccination_records_guard
  before insert or update on public.vaccination_records
  for each row execute function public.vaccination_record_guard();

-- ---------------------------------------------------------------------------
-- RLS — SELECT only for clients
-- ---------------------------------------------------------------------------

alter table public.vaccination_records enable row level security;

create policy "vaccination records active member read"
  on public.vaccination_records for select
  using (public.is_active_household_member(household_id));

grant select on public.vaccination_records to authenticated;
grant all on public.vaccination_records to service_role;

-- ---------------------------------------------------------------------------
-- Read shape
-- ---------------------------------------------------------------------------

create or replace function public.vaccination_record_json(
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
    'id', vr.id,
    'household_id', vr.household_id,
    'pet_id', vr.pet_id,
    'vaccine_name', vr.vaccine_name,
    'effective_date', vr.effective_date,
    'next_due_date', vr.next_due_date,
    'provenance', vr.provenance,
    'provider_id', vr.provider_id,
    'note', vr.note,
    'revision', vr.revision,
    'created_at', vr.created_at,
    'created_by', vr.created_by,
    'created_by_name', up.display_name,
    'updated_at', vr.updated_at,
    'updated_by', vr.updated_by,
    'removed_at', vr.deleted_at
  ))
  from public.vaccination_records vr
  left join public.user_profiles up on up.id = vr.created_by
  where vr.id = target_id
    and (include_removed or vr.deleted_at is null);
$$;

-- ---------------------------------------------------------------------------
-- write_path_record_vaccination (US-070)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_record_vaccination(
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
  name_value text;
  effective_date_value date;
  next_due_value date;
  provenance_value public.vaccination_provenance;
  provider_value uuid;
  today_local date;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
       or existing.command <> 'record_vaccination' then
      raise exception 'idempotency key reused with different command or payload'
        using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_pet := public.care_authorize_pet(
    actor_id, nullif(payload_input->>'pet_id', '')::uuid
  );

  name_value := nullif(trim(payload_input->>'vaccine_name'), '');
  if name_value is null then
    raise exception 'vaccine_name is required' using errcode = '22023';
  end if;

  today_local := public.household_current_local_date(target_pet.household_id, now());
  effective_date_value := coalesce(
    nullif(payload_input->>'effective_date', '')::date,
    today_local
  );
  if effective_date_value > today_local then
    raise exception 'a vaccination cannot be recorded for a future date'
      using errcode = '22023';
  end if;
  if effective_date_value < today_local - (365 * 20) then
    raise exception 'effective_date is more than twenty years ago'
      using errcode = '22023';
  end if;

  next_due_value := nullif(payload_input->>'next_due_date', '')::date;
  if next_due_value is not null and next_due_value < effective_date_value then
    raise exception 'next_due_date cannot be before the date given'
      using errcode = '22023';
  end if;

  begin
    provenance_value := coalesce(
      nullif(payload_input->>'provenance', '')::public.vaccination_provenance,
      'owner_entered'::public.vaccination_provenance
    );
  exception when invalid_text_representation then
    raise exception 'provenance must be owner_entered or professional_instruction'
      using errcode = '22023';
  end;

  provider_value := nullif(payload_input->>'provider_id', '')::uuid;

  record_id := coalesce(nullif(payload_input->>'vaccination_id', '')::uuid, gen_random_uuid());

  insert into public.vaccination_records (
    id, household_id, pet_id, vaccine_name, effective_date, next_due_date,
    provenance, provider_id, note, created_by, updated_by
  ) values (
    record_id, target_pet.household_id, target_pet.id, name_value,
    effective_date_value, next_due_value, provenance_value, provider_value,
    nullif(trim(payload_input->>'note'), ''),
    actor_id, actor_id
  );

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_pet.household_id, actor_id,
    jsonb_build_object('type', 'vaccination_record', 'id', record_id),
    'care.vaccination_recorded',
    jsonb_build_object(
      'pet_id', target_pet.id,
      'vaccine_name', name_value,
      'effective_date', effective_date_value,
      'next_due_date', next_due_value,
      'provenance', provenance_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('vaccination', public.vaccination_record_json(record_id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'record_vaccination', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_edit_vaccination
-- ---------------------------------------------------------------------------

create or replace function public.write_path_edit_vaccination(
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
  target public.vaccination_records%rowtype;
  expected_revision integer;
  name_value text;
  effective_date_value date;
  next_due_value date;
  provenance_value public.vaccination_provenance;
  provider_value uuid;
  today_local date;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
       or existing.command <> 'edit_vaccination' then
      raise exception 'idempotency key reused with different command or payload'
        using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.vaccination_records
  where id = nullif(payload_input->>'vaccination_id', '')::uuid
    and deleted_at is null
  for update;
  if not found then
    raise exception 'vaccination record not found' using errcode = '22023';
  end if;

  perform public.care_authorize_pet(actor_id, target.pet_id);

  expected_revision := nullif(payload_input->>'expected_revision', '')::integer;
  if expected_revision is null then
    raise exception 'expected_revision is required' using errcode = '22023';
  end if;
  if expected_revision <> target.revision then
    raise exception 'this record changed since you opened it' using errcode = '40001';
  end if;

  if payload_input ? 'vaccine_name' then
    name_value := nullif(trim(payload_input->>'vaccine_name'), '');
    if name_value is null then
      raise exception 'vaccine_name is required' using errcode = '22023';
    end if;
  else
    name_value := target.vaccine_name;
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
    raise exception 'a vaccination cannot be recorded for a future date'
      using errcode = '22023';
  end if;

  if payload_input ? 'next_due_date' then
    next_due_value := nullif(payload_input->>'next_due_date', '')::date;
  else
    next_due_value := target.next_due_date;
  end if;
  if next_due_value is not null and next_due_value < effective_date_value then
    raise exception 'next_due_date cannot be before the date given'
      using errcode = '22023';
  end if;

  if payload_input ? 'provenance' then
    begin
      provenance_value := (payload_input->>'provenance')::public.vaccination_provenance;
    exception when invalid_text_representation then
      raise exception 'provenance must be owner_entered or professional_instruction'
        using errcode = '22023';
    end;
    if provenance_value is null then
      raise exception 'provenance is required when provided' using errcode = '22023';
    end if;
  else
    provenance_value := target.provenance;
  end if;

  if payload_input ? 'provider_id' then
    provider_value := nullif(payload_input->>'provider_id', '')::uuid;
  else
    provider_value := target.provider_id;
  end if;

  update public.vaccination_records
  set vaccine_name = name_value,
      effective_date = effective_date_value,
      next_due_date = next_due_value,
      provenance = provenance_value,
      provider_id = provider_value,
      note = case when payload_input ? 'note'
        then nullif(trim(payload_input->>'note'), '') else note end,
      revision = target.revision + 1,
      updated_by = actor_id
  where id = target.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target.household_id, actor_id,
    jsonb_build_object('type', 'vaccination_record', 'id', target.id),
    'care.vaccination_edited',
    jsonb_build_object(
      'pet_id', target.pet_id,
      'previous_vaccine_name', target.vaccine_name,
      'vaccine_name', name_value,
      'previous_effective_date', target.effective_date,
      'effective_date', effective_date_value,
      'previous_next_due_date', target.next_due_date,
      'next_due_date', next_due_value,
      'previous_provenance', target.provenance,
      'provenance', provenance_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('vaccination', public.vaccination_record_json(target.id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'edit_vaccination', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_remove_vaccination
-- ---------------------------------------------------------------------------

create or replace function public.write_path_remove_vaccination(
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
  target public.vaccination_records%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
       or existing.command <> 'remove_vaccination' then
      raise exception 'idempotency key reused with different command or payload'
        using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.vaccination_records
  where id = nullif(payload_input->>'vaccination_id', '')::uuid
  for update;
  if not found then
    raise exception 'vaccination record not found' using errcode = '22023';
  end if;

  perform public.care_authorize_pet(actor_id, target.pet_id);

  if target.deleted_at is null then
    update public.vaccination_records
    set deleted_at = now(),
        deleted_by = actor_id,
        updated_by = actor_id
    where id = target.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target.household_id, actor_id,
      jsonb_build_object('type', 'vaccination_record', 'id', target.id),
      'care.vaccination_removed',
      jsonb_build_object(
        'pet_id', target.pet_id,
        'vaccine_name', target.vaccine_name
      ),
      recorded_at_input
    );
  end if;

  response := jsonb_build_object(
    'vaccination', public.vaccination_record_json(target.id, true)
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'remove_vaccination', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- Lockdown
-- ---------------------------------------------------------------------------

revoke execute on function public.write_path_record_vaccination(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_edit_vaccination(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_remove_vaccination(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;

grant execute on function public.write_path_record_vaccination(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_edit_vaccination(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_remove_vaccination(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;

revoke execute on function public.vaccination_record_json(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.vaccination_record_guard() from public, anon, authenticated;
