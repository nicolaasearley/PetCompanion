-- Care medications: MedicationSchedule + occurrence safety contract
-- (F10, DM §11.2, docs/12 §22.3, docs/13 2026-07-29 Accepted).
--
-- Dose/instructions stored VERBATIM — never computed or normalized.
-- Occurrences come only from explicit owner/professional schedules.
-- Field-level change history on material edits via audit_events.
-- Preventive flea/tick etc. use this same path when the owner sets a schedule.
--
-- Clients SELECT only. Mutations go through write_path_* SECURITY DEFINER RPCs.
-- This migration does NOT replace write_path_generation_context or any
-- training/socialization/weight/provider function (docs/22 handoff trap).

-- ---------------------------------------------------------------------------
-- Vocabularies
-- ---------------------------------------------------------------------------

create type public.medication_provenance as enum (
  'owner_entered',
  'professional_instruction'
);

comment on type public.medication_provenance is
  'Who provided the medication instruction (DM §11.2). Never alters professional content.';

create type public.medication_schedule_status as enum (
  'active',
  'archived',
  'superseded'
);

comment on type public.medication_schedule_status is
  'Lifecycle of a MedicationSchedule (DM §11.2).';

-- ---------------------------------------------------------------------------
-- MedicationSchedule (DM §11.2)
-- ---------------------------------------------------------------------------

create table public.medication_schedules (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  -- As entered — the product never computes, converts, or suggests a dose.
  medication_name text not null check (char_length(trim(medication_name)) > 0),
  dose_text text,
  instructions_text text,
  provenance public.medication_provenance not null default 'owner_entered',
  provider_id uuid references public.providers(id),
  recurrence jsonb not null check (public.recurrence_rule_is_valid(recurrence)),
  status public.medication_schedule_status not null default 'active',
  superseded_by uuid references public.medication_schedules(id),
  task_schedule_id uuid not null references public.task_schedules(id),
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id),
  constraint medication_schedules_pet_household_fkey
    foreign key (pet_id, household_id) references public.pets (id, household_id),
  constraint medication_schedules_deleted_shape check (
    (deleted_at is null and deleted_by is null) or deleted_at is not null
  ),
  constraint medication_schedules_dose_shape check (
    dose_text is null or char_length(trim(dose_text)) > 0
  ),
  constraint medication_schedules_instructions_shape check (
    instructions_text is null or char_length(trim(instructions_text)) > 0
  ),
  constraint medication_schedules_supersede_shape check (
    (status = 'superseded' and superseded_by is not null)
    or (status <> 'superseded' and superseded_by is null)
  )
);

comment on table public.medication_schedules is
  'Authoritative medication instruction + schedule (DM §11.2). Highest-sensitivity Care entity.';
comment on column public.medication_schedules.medication_name is
  'As entered. Never normalized.';
comment on column public.medication_schedules.dose_text is
  'As entered. Never computed, converted, or suggested.';
comment on column public.medication_schedules.task_schedule_id is
  'Owns exactly one required TaskSchedule (origin health_schedule).';

create unique index medication_schedules_task_schedule_unique
  on public.medication_schedules (task_schedule_id)
  where deleted_at is null;

create index medication_schedules_pet_active
  on public.medication_schedules (pet_id, status, created_at desc)
  where deleted_at is null;

create index medication_schedules_household_active
  on public.medication_schedules (household_id, status)
  where deleted_at is null and status = 'active';

create trigger medication_schedules_set_updated_at
  before update on public.medication_schedules
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Guard (DM §18.6 / §18.10)
-- ---------------------------------------------------------------------------

create or replace function public.medication_schedule_guard()
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
    raise exception 'medication schedule household_id must match the pet' using errcode = '22023';
  end if;
  if pet_row.status <> 'active' or pet_row.deleted_at is not null then
    raise exception 'cannot write medication for an archived or deleted pet' using errcode = '22023';
  end if;

  select * into household_row from public.households where id = new.household_id;
  if not found or household_row.status <> 'active' then
    raise exception 'cannot write medication for a closed household' using errcode = '22023';
  end if;

  if new.provider_id is not null and not exists (
    select 1 from public.providers p
    where p.id = new.provider_id
      and p.household_id = new.household_id
      and p.deleted_at is null
  ) then
    raise exception 'provider must belong to the same household' using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger medication_schedules_guard
  before insert or update on public.medication_schedules
  for each row execute function public.medication_schedule_guard();

-- ---------------------------------------------------------------------------
-- RLS — SELECT only for clients
-- ---------------------------------------------------------------------------

alter table public.medication_schedules enable row level security;

create policy "medication schedules active member read"
  on public.medication_schedules for select
  using (public.is_active_household_member(household_id));

grant select on public.medication_schedules to authenticated;
grant all on public.medication_schedules to service_role;

-- ---------------------------------------------------------------------------
-- Read shape (includes next due + last completion attribution)
-- ---------------------------------------------------------------------------

create or replace function public.medication_schedule_json(
  target_id uuid,
  include_removed boolean default false
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with med as (
    select ms.*
    from public.medication_schedules ms
    where ms.id = target_id
      and (include_removed or ms.deleted_at is null)
  ),
  next_due as (
    select o.id as occurrence_id,
           o.local_due_date,
           o.original_local_due_date,
           o.time_policy,
           o.due_time,
           o.window_ref,
           o.state,
           o.revision as occurrence_revision
    from med
    join public.task_occurrences o
      on o.schedule_id = med.task_schedule_id
     and o.deleted_at is null
     and o.state = 'pending'
    order by o.local_due_date asc, o.created_at asc
    limit 1
  ),
  last_completion as (
    select d.effective_at,
           d.actor_user_id,
           up.display_name as actor_name,
           o.local_due_date as completed_due_date
    from med
    join public.task_occurrences o
      on o.schedule_id = med.task_schedule_id
     and o.deleted_at is null
    join public.dispositions d
      on d.occurrence_id = o.id
     and d.action = 'complete'
     and d.superseded = false
    left join public.user_profiles up on up.id = d.actor_user_id
    order by d.effective_at desc
    limit 1
  ),
  change_history as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'occurred_at', ae.occurred_at,
        'action', ae.action,
        'actor_user_id', ae.actor_user_id,
        'actor_name', up.display_name,
        'summary', ae.summary
      ) order by ae.occurred_at desc
    ), '[]'::jsonb) as entries
    from med
    join public.audit_events ae
      on ae.household_id = med.household_id
     and ae.entity_ref->>'type' = 'medication_schedule'
     and (ae.entity_ref->>'id')::uuid = med.id
    left join public.user_profiles up on up.id = ae.actor_user_id
  )
  select jsonb_strip_nulls(jsonb_build_object(
    'id', med.id,
    'household_id', med.household_id,
    'pet_id', med.pet_id,
    'medication_name', med.medication_name,
    'dose_text', med.dose_text,
    'instructions_text', med.instructions_text,
    'provenance', med.provenance,
    'provider_id', med.provider_id,
    'recurrence', med.recurrence,
    'status', med.status,
    'superseded_by', med.superseded_by,
    'task_schedule_id', med.task_schedule_id,
    'revision', med.revision,
    'created_at', med.created_at,
    'created_by', med.created_by,
    'created_by_name', creator.display_name,
    'updated_at', med.updated_at,
    'updated_by', med.updated_by,
    'removed_at', med.deleted_at,
    'next_due', case when next_due.occurrence_id is null then null else jsonb_build_object(
      'occurrence_id', next_due.occurrence_id,
      'local_due_date', next_due.local_due_date,
      'original_local_due_date', next_due.original_local_due_date,
      'time_policy', next_due.time_policy,
      'due_time', next_due.due_time,
      'window_ref', next_due.window_ref,
      'state', next_due.state,
      'occurrence_revision', next_due.occurrence_revision
    ) end,
    'last_completion', case when last_completion.effective_at is null then null else jsonb_build_object(
      'effective_at', last_completion.effective_at,
      'actor_user_id', last_completion.actor_user_id,
      'actor_name', last_completion.actor_name,
      'completed_due_date', last_completion.completed_due_date
    ) end,
    'change_history', change_history.entries
  ))
  from med
  left join public.user_profiles creator on creator.id = med.created_by
  left join next_due on true
  left join last_completion on true
  left join change_history on true;
$$;

-- ---------------------------------------------------------------------------
-- Helpers (medication-owned; do not replace coordination helpers)
-- ---------------------------------------------------------------------------

create or replace function public.medication_parse_recurrence(payload_input jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  recurrence_value jsonb;
begin
  if payload_input ? 'recurrence' and jsonb_typeof(payload_input->'recurrence') = 'object' then
    recurrence_value := payload_input->'recurrence';
  else
    raise exception 'recurrence is required' using errcode = '22023';
  end if;
  if not public.recurrence_rule_is_valid(recurrence_value) then
    raise exception 'unsupported recurrence — use a supported explicit schedule' using errcode = '22023';
  end if;
  return recurrence_value;
end;
$$;

create or replace function public.medication_seed_occurrence(
  actor_id uuid,
  schedule_id uuid,
  recurrence_value jsonb,
  household_id uuid,
  pet_id uuid,
  obligation public.obligation_class
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  occurrence_id uuid;
  schedule_row public.task_schedules%rowtype;
begin
  select * into schedule_row from public.task_schedules where id = schedule_id;
  if recurrence_value->>'type' = 'interval_after_completion' then
    occurrence_id := gen_random_uuid();
    insert into public.task_occurrences (
      id, occurrence_key, household_id, pet_id, schedule_id, local_due_date,
      original_local_due_date, time_policy, due_time, window_ref,
      assignment_kind, assignment_user_id, state, obligation_class, origin,
      origin_ref, created_by, updated_by
    ) values (
      occurrence_id, schedule_id::text || ':ordinal:1',
      household_id, pet_id, schedule_id,
      (recurrence_value->>'anchor_date')::date,
      (recurrence_value->>'anchor_date')::date,
      (recurrence_value->>'time_policy')::public.time_policy,
      case when recurrence_value->>'time_policy' = 'exact_time'
        then (recurrence_value->>'exact_time')::time end,
      case when recurrence_value->>'time_policy' = 'window'
        then recurrence_value->>'window_ref' end,
      schedule_row.assignment_kind, schedule_row.assignment_user_id, 'pending',
      obligation, 'health_schedule',
      jsonb_build_object(
        'medication_schedule_id', schedule_row.origin_ref->>'medication_schedule_id',
        'interval_ordinal', 1
      ),
      actor_id, actor_id
    );
  else
    perform public.write_path_materialize_occurrences(
      actor_id, pet_id, (recurrence_value->>'anchor_date')::date, 14
    );
    select o.id into occurrence_id
    from public.task_occurrences o
    where o.schedule_id = schedule_id
      and o.state = 'pending'
      and o.deleted_at is null
    order by o.local_due_date asc
    limit 1;
  end if;
  return occurrence_id;
end;
$$;

create or replace function public.medication_cancel_pending_occurrences(
  target_schedule_id uuid,
  actor_id uuid,
  recorded_at_input timestamptz
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  cancelled_count integer;
begin
  update public.task_occurrences
  set state = 'cancelled',
      revision = revision + 1,
      updated_at = recorded_at_input,
      updated_by = actor_id
  where schedule_id = target_schedule_id
    and state = 'pending'
    and deleted_at is null;
  get diagnostics cancelled_count = row_count;
  return cancelled_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_create_medication_schedule
-- ---------------------------------------------------------------------------

create or replace function public.write_path_create_medication_schedule(
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
  medication_id uuid;
  definition_id uuid;
  schedule_id uuid;
  recurrence_value jsonb;
  provenance_value public.medication_provenance;
  provider_value uuid;
  name_value text;
  dose_value text;
  instructions_value text;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
       or existing.command <> 'create_medication_schedule' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_pet := public.care_authorize_pet(
    actor_id, nullif(payload_input->>'pet_id', '')::uuid
  );

  name_value := nullif(trim(payload_input->>'medication_name'), '');
  if name_value is null then
    raise exception 'medication_name is required' using errcode = '22023';
  end if;

  dose_value := nullif(trim(payload_input->>'dose_text'), '');
  instructions_value := nullif(trim(payload_input->>'instructions_text'), '');
  recurrence_value := public.medication_parse_recurrence(payload_input);

  begin
    provenance_value := coalesce(
      nullif(payload_input->>'provenance', '')::public.medication_provenance,
      'owner_entered'::public.medication_provenance
    );
  exception when invalid_text_representation then
    raise exception 'provenance must be owner_entered or professional_instruction' using errcode = '22023';
  end;

  provider_value := nullif(payload_input->>'provider_id', '')::uuid;
  if provider_value is not null and not exists (
    select 1 from public.providers p
    where p.id = provider_value
      and p.household_id = target_pet.household_id
      and p.deleted_at is null
  ) then
    raise exception 'provider must belong to the same household' using errcode = '22023';
  end if;

  medication_id := coalesce(nullif(payload_input->>'medication_schedule_id', '')::uuid, gen_random_uuid());
  definition_id := gen_random_uuid();
  schedule_id := gen_random_uuid();

  insert into public.task_definitions (
    id, provenance, household_id, title, category, default_obligation_class,
    default_effort, default_time_policy, created_by, updated_by
  ) values (
    definition_id, 'user', target_pet.household_id, name_value,
    'health', 'required', 'short',
    (recurrence_value->>'time_policy')::public.time_policy,
    actor_id, actor_id
  );

  insert into public.task_schedules (
    id, household_id, pet_id, task_definition_id, recurrence,
    assignment_kind, origin, origin_ref, obligation_class,
    active_range_start_date, active_range_until,
    created_by, updated_by
  ) values (
    schedule_id, target_pet.household_id, target_pet.id, definition_id,
    recurrence_value, 'anyone', 'health_schedule',
    jsonb_build_object('medication_schedule_id', medication_id),
    'required',
    (recurrence_value->>'anchor_date')::date,
    nullif(recurrence_value->>'until', '')::date,
    actor_id, actor_id
  );

  insert into public.medication_schedules (
    id, household_id, pet_id, medication_name, dose_text, instructions_text,
    provenance, provider_id, recurrence, status, task_schedule_id,
    created_by, updated_by
  ) values (
    medication_id, target_pet.household_id, target_pet.id, name_value,
    dose_value, instructions_value, provenance_value, provider_value,
    recurrence_value, 'active', schedule_id, actor_id, actor_id
  );

  perform public.medication_seed_occurrence(
    actor_id, schedule_id, recurrence_value,
    target_pet.household_id, target_pet.id, 'required'
  );

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_pet.household_id, actor_id,
    jsonb_build_object('type', 'medication_schedule', 'id', medication_id),
    'care.medication_schedule_created',
    jsonb_build_object(
      'pet_id', target_pet.id,
      'medication_name', name_value,
      'dose_text', dose_value,
      'provenance', provenance_value,
      'recurrence', recurrence_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object(
    'medication_schedule', public.medication_schedule_json(medication_id)
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'create_medication_schedule', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_edit_medication_schedule (field-level audit)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_edit_medication_schedule(
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
  target public.medication_schedules%rowtype;
  expected_revision integer;
  name_value text;
  dose_value text;
  instructions_value text;
  provenance_value public.medication_provenance;
  provider_value uuid;
  recurrence_value jsonb;
  recurrence_changed boolean := false;
  changes jsonb := '{}'::jsonb;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
       or existing.command <> 'edit_medication_schedule' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.medication_schedules
  where id = nullif(payload_input->>'medication_schedule_id', '')::uuid
    and deleted_at is null
  for update;
  if not found then
    raise exception 'medication schedule not found' using errcode = '22023';
  end if;
  if target.status <> 'active' then
    raise exception 'only an active medication schedule can be edited' using errcode = '22023';
  end if;

  perform public.care_authorize_pet(actor_id, target.pet_id);

  expected_revision := nullif(payload_input->>'expected_revision', '')::integer;
  if expected_revision is null then
    raise exception 'expected_revision is required' using errcode = '22023';
  end if;
  if expected_revision <> target.revision then
    raise exception 'this record changed since you opened it' using errcode = '40001';
  end if;

  name_value := target.medication_name;
  if payload_input ? 'medication_name' then
    name_value := nullif(trim(payload_input->>'medication_name'), '');
    if name_value is null then
      raise exception 'medication_name is required when provided' using errcode = '22023';
    end if;
    if name_value is distinct from target.medication_name then
      changes := changes || jsonb_build_object(
        'medication_name', jsonb_build_object('before', target.medication_name, 'after', name_value)
      );
    end if;
  end if;

  dose_value := target.dose_text;
  if payload_input ? 'dose_text' then
    dose_value := nullif(trim(payload_input->>'dose_text'), '');
    if dose_value is distinct from target.dose_text then
      changes := changes || jsonb_build_object(
        'dose_text', jsonb_build_object('before', target.dose_text, 'after', dose_value)
      );
    end if;
  end if;

  instructions_value := target.instructions_text;
  if payload_input ? 'instructions_text' then
    instructions_value := nullif(trim(payload_input->>'instructions_text'), '');
    if instructions_value is distinct from target.instructions_text then
      changes := changes || jsonb_build_object(
        'instructions_text',
        jsonb_build_object('before', target.instructions_text, 'after', instructions_value)
      );
    end if;
  end if;

  provenance_value := target.provenance;
  if payload_input ? 'provenance' then
    begin
      provenance_value := (payload_input->>'provenance')::public.medication_provenance;
    exception when invalid_text_representation then
      raise exception 'provenance must be owner_entered or professional_instruction' using errcode = '22023';
    end;
    if provenance_value is null then
      raise exception 'provenance is required when provided' using errcode = '22023';
    end if;
    if provenance_value is distinct from target.provenance then
      changes := changes || jsonb_build_object(
        'provenance', jsonb_build_object('before', target.provenance, 'after', provenance_value)
      );
    end if;
  end if;

  provider_value := target.provider_id;
  if payload_input ? 'provider_id' then
    provider_value := nullif(payload_input->>'provider_id', '')::uuid;
    if provider_value is not null and not exists (
      select 1 from public.providers p
      where p.id = provider_value
        and p.household_id = target.household_id
        and p.deleted_at is null
    ) then
      raise exception 'provider must belong to the same household' using errcode = '22023';
    end if;
    if provider_value is distinct from target.provider_id then
      changes := changes || jsonb_build_object(
        'provider_id', jsonb_build_object('before', target.provider_id, 'after', provider_value)
      );
    end if;
  end if;

  recurrence_value := target.recurrence;
  if payload_input ? 'recurrence' then
    recurrence_value := public.medication_parse_recurrence(payload_input);
    if recurrence_value is distinct from target.recurrence then
      recurrence_changed := true;
      changes := changes || jsonb_build_object(
        'recurrence', jsonb_build_object('before', target.recurrence, 'after', recurrence_value)
      );
    end if;
  end if;

  if changes = '{}'::jsonb then
    response := jsonb_build_object(
      'medication_schedule', public.medication_schedule_json(target.id)
    );
    insert into public.command_log (
      actor_user_id, client_idempotency_key, command, payload_hash, request_body,
      response_body, status, recorded_at, effective_at, completed_at
    ) values (
      actor_id, idempotency_key, 'edit_medication_schedule', payload_hash_input,
      request_body_input, response, 'succeeded', recorded_at_input,
      effective_at_input, now()
    );
    return response;
  end if;

  update public.medication_schedules
  set medication_name = name_value,
      dose_text = dose_value,
      instructions_text = instructions_value,
      provenance = provenance_value,
      provider_id = provider_value,
      recurrence = recurrence_value,
      revision = target.revision + 1,
      updated_by = actor_id
  where id = target.id;

  update public.task_definitions
  set title = name_value,
      default_time_policy = (recurrence_value->>'time_policy')::public.time_policy,
      revision = revision + 1,
      updated_at = recorded_at_input,
      updated_by = actor_id
  where id = (
    select task_definition_id from public.task_schedules where id = target.task_schedule_id
  );

  if recurrence_changed then
    update public.task_schedules
    set recurrence = recurrence_value,
        active_range_start_date = (recurrence_value->>'anchor_date')::date,
        active_range_until = nullif(recurrence_value->>'until', '')::date,
        revision = revision + 1,
        updated_at = recorded_at_input,
        updated_by = actor_id
    where id = target.task_schedule_id;

    perform public.medication_cancel_pending_occurrences(
      target.task_schedule_id, actor_id, recorded_at_input
    );
    perform public.medication_seed_occurrence(
      actor_id, target.task_schedule_id, recurrence_value,
      target.household_id, target.pet_id, 'required'
    );
  end if;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target.household_id, actor_id,
    jsonb_build_object('type', 'medication_schedule', 'id', target.id),
    'care.medication_schedule_edited',
    jsonb_build_object(
      'pet_id', target.pet_id,
      'changes', changes,
      'revision_before', target.revision,
      'revision_after', target.revision + 1
    ),
    recorded_at_input
  );

  response := jsonb_build_object(
    'medication_schedule', public.medication_schedule_json(target.id)
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'edit_medication_schedule', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_archive_medication_schedule
-- ---------------------------------------------------------------------------

create or replace function public.write_path_archive_medication_schedule(
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
  target public.medication_schedules%rowtype;
  expected_revision integer;
  cancelled_count integer := 0;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
       or existing.command <> 'archive_medication_schedule' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.medication_schedules
  where id = nullif(payload_input->>'medication_schedule_id', '')::uuid
    and deleted_at is null
  for update;
  if not found then
    raise exception 'medication schedule not found' using errcode = '22023';
  end if;

  perform public.care_authorize_pet(actor_id, target.pet_id);

  expected_revision := nullif(payload_input->>'expected_revision', '')::integer;
  if expected_revision is null then
    raise exception 'expected_revision is required' using errcode = '22023';
  end if;
  if expected_revision <> target.revision then
    raise exception 'this record changed since you opened it' using errcode = '40001';
  end if;

  if target.status = 'active' then
    update public.medication_schedules
    set status = 'archived',
        revision = target.revision + 1,
        updated_by = actor_id
    where id = target.id;

    update public.task_schedules
    set status = 'archived',
        revision = revision + 1,
        updated_at = recorded_at_input,
        updated_by = actor_id
    where id = target.task_schedule_id
      and status = 'active';

    cancelled_count := public.medication_cancel_pending_occurrences(
      target.task_schedule_id, actor_id, recorded_at_input
    );

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target.household_id, actor_id,
      jsonb_build_object('type', 'medication_schedule', 'id', target.id),
      'care.medication_schedule_archived',
      jsonb_build_object(
        'pet_id', target.pet_id,
        'medication_name', target.medication_name,
        'occurrences_cancelled', cancelled_count
      ),
      recorded_at_input
    );
  end if;

  response := jsonb_build_object(
    'medication_schedule', public.medication_schedule_json(target.id),
    'occurrences_cancelled', cancelled_count
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'archive_medication_schedule', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_complete_medication_occurrence
-- Always surfaces pet/med/dose/last completion on the client. Server requires
-- acknowledged_recent_completion when another caregiver completed recently
-- (docs/12 §22.3 / docs/13 confirmation UX). Never suggests doubling/skipping.
-- ---------------------------------------------------------------------------

create or replace function public.write_path_complete_medication_occurrence(
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
  target_occurrence public.task_occurrences%rowtype;
  medication public.medication_schedules%rowtype;
  current_completion public.dispositions%rowtype;
  recent_partner public.dispositions%rowtype;
  recent_partner_name text;
  disposition_id uuid := gen_random_uuid();
  effective_value timestamptz := coalesce(effective_at_input, recorded_at_input);
  new_superseded boolean := false;
  effective_completion_id uuid;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
       or existing.command <> 'complete_medication_occurrence' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  if nullif(trim(payload_input->>'occurrence_id'), '') is null then
    raise exception 'occurrence_id is required' using errcode = '22023';
  end if;
  if effective_value > recorded_at_input + interval '5 minutes'
     or effective_value < recorded_at_input - interval '7 days' then
    raise exception 'effective_at must be between recorded_at - 7 days and recorded_at + 5 minutes'
      using errcode = '22023';
  end if;

  select * into target_occurrence
  from public.task_occurrences
  where id = (payload_input->>'occurrence_id')::uuid
    and deleted_at is null
  for update;
  if not found then
    raise exception 'occurrence not found' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.households h
    join public.household_memberships hm on hm.household_id = h.id
    where h.id = target_occurrence.household_id
      and h.status = 'active'
      and hm.user_id = actor_id
      and hm.status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  if target_occurrence.origin <> 'health_schedule' then
    raise exception 'only medication occurrences can use this command' using errcode = '22023';
  end if;
  if target_occurrence.state not in ('pending', 'completed') then
    raise exception 'only a pending or completed occurrence can be completed' using errcode = '22023';
  end if;

  select * into medication
  from public.medication_schedules
  where task_schedule_id = target_occurrence.schedule_id
    and deleted_at is null
    and status = 'active';
  if not found then
    raise exception 'medication schedule not found for occurrence' using errcode = '22023';
  end if;

  -- Recent partner completion on this schedule (24h) requires extra confirm.
  select d.* into recent_partner
  from public.dispositions d
  join public.task_occurrences o on o.id = d.occurrence_id
  where o.schedule_id = medication.task_schedule_id
    and d.action = 'complete'
    and d.superseded = false
    and d.actor_user_id <> actor_id
    and d.effective_at > recorded_at_input - interval '24 hours'
  order by d.effective_at desc
  limit 1;

  if found
     and coalesce((payload_input->>'acknowledged_recent_completion')::boolean, false) is not true
  then
    select display_name into recent_partner_name
    from public.user_profiles where id = recent_partner.actor_user_id;
    raise exception
      'another caregiver recently recorded this medication (%). Confirm before recording again.',
      coalesce(recent_partner_name, 'a household member')
      using errcode = 'PC001';
  end if;

  select * into current_completion
  from public.dispositions
  where occurrence_id = target_occurrence.id
    and action = 'complete'
    and superseded = false
  for update;

  if found and current_completion.effective_at <= effective_value then
    new_superseded := true;
    effective_completion_id := current_completion.id;
  else
    if found then
      update public.dispositions set superseded = true where id = current_completion.id;
    end if;
    effective_completion_id := disposition_id;
  end if;

  insert into public.dispositions (
    id, household_id, occurrence_id, action, actor_user_id, recorded_at,
    effective_at, note, client_idempotency_key, superseded
  ) values (
    disposition_id, target_occurrence.household_id, target_occurrence.id, 'complete',
    actor_id, recorded_at_input, effective_value,
    nullif(trim(payload_input->>'note'), ''),
    idempotency_key, new_superseded
  );

  update public.task_occurrences
  set state = 'completed',
      revision = revision + 1,
      updated_at = recorded_at_input,
      updated_by = actor_id
  where id = target_occurrence.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_occurrence.household_id, actor_id,
    jsonb_build_object('type', 'medication_schedule', 'id', medication.id),
    'care.medication_occurrence_completed',
    jsonb_build_object(
      'occurrence_id', target_occurrence.id,
      'medication_name', medication.medication_name,
      'dose_text', medication.dose_text,
      'effective_at', effective_value,
      'disposition_id', disposition_id,
      'effective_completion_id', effective_completion_id,
      'acknowledged_recent_completion',
        coalesce((payload_input->>'acknowledged_recent_completion')::boolean, false)
    ),
    recorded_at_input
  );

  -- Calendar schedules: keep a bounded forward window after completion.
  if medication.recurrence->>'type' <> 'interval_after_completion' then
    perform public.write_path_materialize_occurrences(
      actor_id, medication.pet_id,
      public.household_current_local_date(medication.household_id, now()),
      14
    );
  end if;

  response := jsonb_build_object(
    'medication_schedule', public.medication_schedule_json(medication.id),
    'disposition', jsonb_build_object(
      'id', disposition_id,
      'occurrence_id', target_occurrence.id,
      'action', 'complete',
      'effective_at', effective_value,
      'superseded', new_superseded,
      'effective_completion_id', effective_completion_id
    )
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'complete_medication_occurrence', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- Authenticated read RPC (SECURITY DEFINER with membership check)
-- Clients cannot SELECT through medication_schedule_json alone (service helpers
-- are locked down); this wrapper authorizes the pet then returns list shapes.
-- ---------------------------------------------------------------------------

create or replace function public.list_medication_schedules_for_pet(target_pet_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  actor uuid := auth.uid();
  target_pet public.pets%rowtype;
begin
  if actor is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  target_pet := public.care_authorize_pet(actor, target_pet_id);
  return coalesce((
    select jsonb_agg(public.medication_schedule_json(ms.id) order by ms.medication_name)
    from public.medication_schedules ms
    where ms.pet_id = target_pet.id
      and ms.deleted_at is null
      and ms.status = 'active'
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.list_medication_schedules_for_pet(uuid) from public, anon;
grant execute on function public.list_medication_schedules_for_pet(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Lockdown
-- ---------------------------------------------------------------------------

revoke execute on function public.write_path_create_medication_schedule(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_edit_medication_schedule(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_archive_medication_schedule(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_complete_medication_occurrence(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;

grant execute on function public.write_path_create_medication_schedule(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_edit_medication_schedule(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_archive_medication_schedule(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_complete_medication_occurrence(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;

revoke execute on function public.medication_schedule_json(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.medication_parse_recurrence(jsonb) from public, anon, authenticated;
revoke execute on function public.medication_seed_occurrence(uuid, uuid, jsonb, uuid, uuid, public.obligation_class) from public, anon, authenticated;
revoke execute on function public.medication_cancel_pending_occurrences(uuid, uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.medication_schedule_guard() from public, anon, authenticated;
