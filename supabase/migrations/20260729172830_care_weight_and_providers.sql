-- Care records: weight measurements and providers (F10, DM §11.3–§11.4).
--
-- First real Care write paths. Medication schedules are deliberately absent
-- (docs/22 §5.1 / docs/12 §22) — this migration must not add dose scheduling,
-- occurrence generation, or "due in N days" medication surfaces.
--
-- Clients SELECT only. Mutations go through write_path_* SECURITY DEFINER RPCs
-- (same shape as socialization). This migration does NOT replace
-- write_path_generation_context or any training/socialization function.
--
-- DM §18 invariants:
--   §18.6  no new record for an archived pet or a closed household
--   §18.10 household_id on every row + composite FK (pet_id, household_id)
--   §18.3  unique client_idempotency_key per actor via command_log

-- ---------------------------------------------------------------------------
-- Vocabularies
-- ---------------------------------------------------------------------------

create type public.weight_unit as enum ('kg', 'lb');

comment on type public.weight_unit is
  'Original unit of a weight measurement (DM §11.3, US-075). Conversions are display-time only.';

create type public.provider_kind as enum (
  'veterinarian', 'groomer', 'trainer', 'other'
);

comment on type public.provider_kind is
  'Household care contact kind (DM §11.4).';

-- Composite pet/household unique index already exists from socialization
-- (pets_id_household_unique). Re-assert so this migration stands alone if
-- applied out of order in a future restore path.
create unique index if not exists pets_id_household_unique on public.pets (id, household_id);

-- ---------------------------------------------------------------------------
-- WeightMeasurement (DM §11.3)
-- ---------------------------------------------------------------------------

create table public.weight_measurements (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  -- Stored as entered; never recomputed. Precision preserved as numeric.
  value numeric not null check (value > 0 and value < 10000),
  unit public.weight_unit not null,
  effective_date date not null,
  note text,
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id),
  constraint weight_measurements_pet_household_fkey
    foreign key (pet_id, household_id) references public.pets (id, household_id),
  constraint weight_measurements_deleted_shape check (
    (deleted_at is null and deleted_by is null) or deleted_at is not null
  )
);

comment on table public.weight_measurements is
  'Dated weight entry for a pet (DM §11.3, US-075). Original value+unit preserved; never a clinical assessment.';
comment on column public.weight_measurements.value is
  'As entered. Display conversion must not overwrite this column.';

create index weight_measurements_pet_recent
  on public.weight_measurements (pet_id, effective_date desc, created_at desc)
  where deleted_at is null;

create trigger weight_measurements_set_updated_at
  before update on public.weight_measurements
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Provider (DM §11.4)
-- ---------------------------------------------------------------------------

create table public.providers (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  kind public.provider_kind not null,
  phone text,
  address text,
  notes text,
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id),
  constraint providers_deleted_shape check (
    (deleted_at is null and deleted_by is null) or deleted_at is not null
  )
);

comment on table public.providers is
  'Household care contact (DM §11.4). Soft-deleted so historical references survive.';

create index providers_household_active
  on public.providers (household_id, name)
  where deleted_at is null;

create trigger providers_set_updated_at
  before update on public.providers
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Guards (DM §18.6 / §18.10)
-- ---------------------------------------------------------------------------

create or replace function public.weight_measurement_guard()
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
    raise exception 'weight measurement household_id must match the pet' using errcode = '22023';
  end if;
  if pet_row.status <> 'active' or pet_row.deleted_at is not null then
    raise exception 'cannot write weight for an archived or deleted pet' using errcode = '22023';
  end if;

  select * into household_row from public.households where id = new.household_id;
  if not found or household_row.status <> 'active' then
    raise exception 'cannot write weight for a closed household' using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger weight_measurements_guard
  before insert or update on public.weight_measurements
  for each row execute function public.weight_measurement_guard();

create or replace function public.provider_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  household_row public.households%rowtype;
begin
  select * into household_row from public.households where id = new.household_id;
  if not found or household_row.status <> 'active' then
    raise exception 'cannot write a provider for a closed household' using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger providers_guard
  before insert or update on public.providers
  for each row execute function public.provider_guard();

-- ---------------------------------------------------------------------------
-- RLS — SELECT only for clients
-- ---------------------------------------------------------------------------

alter table public.weight_measurements enable row level security;
alter table public.providers enable row level security;

create policy "weight measurements active member read"
  on public.weight_measurements for select
  using (public.is_active_household_member(household_id));

create policy "providers active member read"
  on public.providers for select
  using (public.is_active_household_member(household_id));

grant select on public.weight_measurements to authenticated;
grant select on public.providers to authenticated;
grant all on public.weight_measurements to service_role;
grant all on public.providers to service_role;

-- ---------------------------------------------------------------------------
-- Read shapes
-- ---------------------------------------------------------------------------

create or replace function public.weight_measurement_json(
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
    'id', wm.id,
    'household_id', wm.household_id,
    'pet_id', wm.pet_id,
    'value', wm.value,
    'unit', wm.unit,
    'effective_date', wm.effective_date,
    'note', wm.note,
    'revision', wm.revision,
    'created_at', wm.created_at,
    'created_by', wm.created_by,
    'created_by_name', up.display_name,
    'updated_at', wm.updated_at,
    'updated_by', wm.updated_by,
    'removed_at', wm.deleted_at
  ))
  from public.weight_measurements wm
  left join public.user_profiles up on up.id = wm.created_by
  where wm.id = target_id
    and (include_removed or wm.deleted_at is null);
$$;

create or replace function public.provider_json(
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
    'id', p.id,
    'household_id', p.household_id,
    'name', p.name,
    'kind', p.kind,
    'phone', p.phone,
    'address', p.address,
    'notes', p.notes,
    'revision', p.revision,
    'created_at', p.created_at,
    'created_by', p.created_by,
    'updated_at', p.updated_at,
    'updated_by', p.updated_by,
    'removed_at', p.deleted_at
  ))
  from public.providers p
  where p.id = target_id
    and (include_removed or p.deleted_at is null);
$$;

-- ---------------------------------------------------------------------------
-- Shared authorize helpers (Care-owned; do not replace socialization helpers)
-- ---------------------------------------------------------------------------

create or replace function public.care_authorize_pet(
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

comment on function public.care_authorize_pet(uuid, uuid) is
  'Resolves a pet the actor may write Care records for, or raises 42501.';

create or replace function public.care_authorize_household(
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

-- ---------------------------------------------------------------------------
-- write_path_record_weight (US-075, CA-08)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_record_weight(
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
  measurement_id uuid;
  value_text text;
  value_num numeric;
  unit_value public.weight_unit;
  effective_date_value date;
  today_local date;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'record_weight' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_pet := public.care_authorize_pet(
    actor_id, nullif(payload_input->>'pet_id', '')::uuid
  );

  value_text := nullif(trim(payload_input->>'value'), '');
  if value_text is null then
    raise exception 'value is required' using errcode = '22023';
  end if;
  begin
    value_num := value_text::numeric;
  exception when invalid_text_representation then
    raise exception 'value must be a number' using errcode = '22023';
  end;
  if value_num <= 0 or value_num >= 10000 then
    raise exception 'value must be greater than 0' using errcode = '22023';
  end if;

  begin
    unit_value := (payload_input->>'unit')::public.weight_unit;
  exception when invalid_text_representation then
    raise exception 'unit must be kg or lb' using errcode = '22023';
  end;
  if unit_value is null then
    raise exception 'unit is required' using errcode = '22023';
  end if;

  today_local := public.household_current_local_date(target_pet.household_id, now());
  effective_date_value := coalesce(
    nullif(payload_input->>'effective_date', '')::date,
    today_local
  );
  if effective_date_value > today_local then
    raise exception 'a weight cannot be recorded for a future date' using errcode = '22023';
  end if;
  if effective_date_value < today_local - (365 * 5) then
    raise exception 'effective_date is more than five years ago' using errcode = '22023';
  end if;

  measurement_id := coalesce(nullif(payload_input->>'measurement_id', '')::uuid, gen_random_uuid());

  insert into public.weight_measurements (
    id, household_id, pet_id, value, unit, effective_date, note, created_by, updated_by
  ) values (
    measurement_id, target_pet.household_id, target_pet.id, value_num, unit_value,
    effective_date_value, nullif(trim(payload_input->>'note'), ''),
    actor_id, actor_id
  );

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_pet.household_id, actor_id,
    jsonb_build_object('type', 'weight_measurement', 'id', measurement_id),
    'care.weight_recorded',
    jsonb_build_object(
      'pet_id', target_pet.id,
      'value', value_num,
      'unit', unit_value,
      'effective_date', effective_date_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('measurement', public.weight_measurement_json(measurement_id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'record_weight', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_edit_weight
-- ---------------------------------------------------------------------------

create or replace function public.write_path_edit_weight(
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
  target public.weight_measurements%rowtype;
  expected_revision integer;
  value_num numeric;
  unit_value public.weight_unit;
  effective_date_value date;
  today_local date;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'edit_weight' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.weight_measurements
  where id = nullif(payload_input->>'measurement_id', '')::uuid
    and deleted_at is null
  for update;
  if not found then
    raise exception 'weight measurement not found' using errcode = '22023';
  end if;

  perform public.care_authorize_pet(actor_id, target.pet_id);

  expected_revision := nullif(payload_input->>'expected_revision', '')::integer;
  if expected_revision is null then
    raise exception 'expected_revision is required' using errcode = '22023';
  end if;
  if expected_revision <> target.revision then
    raise exception 'this record changed since you opened it' using errcode = '40001';
  end if;

  if payload_input ? 'value' then
    begin
      value_num := nullif(trim(payload_input->>'value'), '')::numeric;
    exception when invalid_text_representation then
      raise exception 'value must be a number' using errcode = '22023';
    end;
    if value_num is null or value_num <= 0 or value_num >= 10000 then
      raise exception 'value must be greater than 0' using errcode = '22023';
    end if;
  else
    value_num := target.value;
  end if;

  if payload_input ? 'unit' then
    begin
      unit_value := (payload_input->>'unit')::public.weight_unit;
    exception when invalid_text_representation then
      raise exception 'unit must be kg or lb' using errcode = '22023';
    end;
    if unit_value is null then
      raise exception 'unit is required' using errcode = '22023';
    end if;
  else
    unit_value := target.unit;
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
    raise exception 'a weight cannot be recorded for a future date' using errcode = '22023';
  end if;

  update public.weight_measurements
  set value = value_num,
      unit = unit_value,
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
    jsonb_build_object('type', 'weight_measurement', 'id', target.id),
    'care.weight_edited',
    jsonb_build_object(
      'pet_id', target.pet_id,
      'previous_value', target.value,
      'value', value_num,
      'previous_unit', target.unit,
      'unit', unit_value,
      'previous_effective_date', target.effective_date,
      'effective_date', effective_date_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('measurement', public.weight_measurement_json(target.id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'edit_weight', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_remove_weight
-- ---------------------------------------------------------------------------

create or replace function public.write_path_remove_weight(
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
  target public.weight_measurements%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'remove_weight' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.weight_measurements
  where id = nullif(payload_input->>'measurement_id', '')::uuid
  for update;
  if not found then
    raise exception 'weight measurement not found' using errcode = '22023';
  end if;

  perform public.care_authorize_pet(actor_id, target.pet_id);

  if target.deleted_at is null then
    update public.weight_measurements
    set deleted_at = now(),
        deleted_by = actor_id,
        updated_by = actor_id
    where id = target.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target.household_id, actor_id,
      jsonb_build_object('type', 'weight_measurement', 'id', target.id),
      'care.weight_removed',
      jsonb_build_object('pet_id', target.pet_id),
      recorded_at_input
    );
  end if;

  response := jsonb_build_object(
    'measurement', public.weight_measurement_json(target.id, true)
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'remove_weight', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_create_provider (CA-09)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_create_provider(
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
  provider_id uuid;
  name_value text;
  kind_value public.provider_kind;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'create_provider' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_household := public.care_authorize_household(
    actor_id, nullif(payload_input->>'household_id', '')::uuid
  );

  name_value := nullif(trim(payload_input->>'name'), '');
  if name_value is null then
    raise exception 'name is required' using errcode = '22023';
  end if;

  begin
    kind_value := (payload_input->>'kind')::public.provider_kind;
  exception when invalid_text_representation then
    raise exception 'kind must be veterinarian, groomer, trainer, or other'
      using errcode = '22023';
  end;
  if kind_value is null then
    raise exception 'kind is required' using errcode = '22023';
  end if;

  provider_id := coalesce(nullif(payload_input->>'provider_id', '')::uuid, gen_random_uuid());

  insert into public.providers (
    id, household_id, name, kind, phone, address, notes, created_by, updated_by
  ) values (
    provider_id, target_household.id, name_value, kind_value,
    nullif(trim(payload_input->>'phone'), ''),
    nullif(trim(payload_input->>'address'), ''),
    nullif(trim(payload_input->>'notes'), ''),
    actor_id, actor_id
  );

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_household.id, actor_id,
    jsonb_build_object('type', 'provider', 'id', provider_id),
    'care.provider_created',
    jsonb_build_object('name', name_value, 'kind', kind_value),
    recorded_at_input
  );

  response := jsonb_build_object('provider', public.provider_json(provider_id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'create_provider', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_edit_provider
-- ---------------------------------------------------------------------------

create or replace function public.write_path_edit_provider(
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
  target public.providers%rowtype;
  expected_revision integer;
  name_value text;
  kind_value public.provider_kind;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'edit_provider' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.providers
  where id = nullif(payload_input->>'provider_id', '')::uuid
    and deleted_at is null
  for update;
  if not found then
    raise exception 'provider not found' using errcode = '22023';
  end if;

  perform public.care_authorize_household(actor_id, target.household_id);

  expected_revision := nullif(payload_input->>'expected_revision', '')::integer;
  if expected_revision is null then
    raise exception 'expected_revision is required' using errcode = '22023';
  end if;
  if expected_revision <> target.revision then
    raise exception 'this record changed since you opened it' using errcode = '40001';
  end if;

  if payload_input ? 'name' then
    name_value := nullif(trim(payload_input->>'name'), '');
    if name_value is null then
      raise exception 'name is required' using errcode = '22023';
    end if;
  else
    name_value := target.name;
  end if;

  if payload_input ? 'kind' then
    begin
      kind_value := (payload_input->>'kind')::public.provider_kind;
    exception when invalid_text_representation then
      raise exception 'kind must be veterinarian, groomer, trainer, or other'
        using errcode = '22023';
    end;
    if kind_value is null then
      raise exception 'kind is required' using errcode = '22023';
    end if;
  else
    kind_value := target.kind;
  end if;

  update public.providers
  set name = name_value,
      kind = kind_value,
      phone = case when payload_input ? 'phone'
        then nullif(trim(payload_input->>'phone'), '') else phone end,
      address = case when payload_input ? 'address'
        then nullif(trim(payload_input->>'address'), '') else address end,
      notes = case when payload_input ? 'notes'
        then nullif(trim(payload_input->>'notes'), '') else notes end,
      revision = target.revision + 1,
      updated_by = actor_id
  where id = target.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target.household_id, actor_id,
    jsonb_build_object('type', 'provider', 'id', target.id),
    'care.provider_edited',
    jsonb_build_object(
      'previous_name', target.name,
      'name', name_value,
      'previous_kind', target.kind,
      'kind', kind_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('provider', public.provider_json(target.id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'edit_provider', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_remove_provider
-- ---------------------------------------------------------------------------

create or replace function public.write_path_remove_provider(
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
  target public.providers%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'remove_provider' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.providers
  where id = nullif(payload_input->>'provider_id', '')::uuid
  for update;
  if not found then
    raise exception 'provider not found' using errcode = '22023';
  end if;

  perform public.care_authorize_household(actor_id, target.household_id);

  if target.deleted_at is null then
    update public.providers
    set deleted_at = now(),
        deleted_by = actor_id,
        updated_by = actor_id
    where id = target.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target.household_id, actor_id,
      jsonb_build_object('type', 'provider', 'id', target.id),
      'care.provider_removed',
      jsonb_build_object('name', target.name, 'kind', target.kind),
      recorded_at_input
    );
  end if;

  response := jsonb_build_object('provider', public.provider_json(target.id, true));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'remove_provider', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- Lockdown
-- ---------------------------------------------------------------------------

revoke execute on function public.write_path_record_weight(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_edit_weight(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_remove_weight(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_create_provider(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_edit_provider(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_remove_provider(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;

grant execute on function public.write_path_record_weight(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_edit_weight(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_remove_weight(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_create_provider(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_edit_provider(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_remove_provider(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;

revoke execute on function public.care_authorize_pet(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.care_authorize_household(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.weight_measurement_json(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.provider_json(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.weight_measurement_guard() from public, anon, authenticated;
revoke execute on function public.provider_guard() from public, anon, authenticated;
