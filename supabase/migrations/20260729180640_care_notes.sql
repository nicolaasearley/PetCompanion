-- Care notes: general health observations (F10, DM §11.1 general_note, US-077).
--
-- NOTES ONLY THIS SLICE. Document kind + Storage upload are deferred:
--   * kind = 'document' is rejected by write_path until Storage RLS + media
--     metadata land;
--   * media_refs is reserved as a nullable jsonb array and non-empty arrays
--     are rejected (same honesty as Life milestones).
-- Never diagnoses or recommends treatment from note text.
--
-- Clients SELECT only. Mutations go through write_path_* SECURITY DEFINER RPCs
-- (same shape as vaccinations/weight). Reuses care_authorize_pet from
-- 20260729172830_care_weight_and_providers.sql. Does NOT replace
-- write_path_generation_context or any training/socialization/medication
-- function (docs/22 handoff trap).

-- ---------------------------------------------------------------------------
-- Vocabulary
-- ---------------------------------------------------------------------------

create type public.care_note_kind as enum (
  'general_note',
  'document'
);

comment on type public.care_note_kind is
  'Health record subtype for care_notes. document writes are deferred until Storage.';

create type public.care_note_provenance as enum (
  'owner_entered',
  'professional_instruction'
);

comment on type public.care_note_provenance is
  'Who provided the note (US-077). Owner observations are labeled as such; never diagnoses.';

create unique index if not exists pets_id_household_unique on public.pets (id, household_id);

-- ---------------------------------------------------------------------------
-- CareNote (DM §11.1 general_note; document reserved)
-- ---------------------------------------------------------------------------

create table public.care_notes (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  kind public.care_note_kind not null default 'general_note',
  title text,
  body text not null check (char_length(trim(body)) > 0 and char_length(body) <= 8000),
  effective_date date not null,
  provenance public.care_note_provenance not null default 'owner_entered',
  provider_id uuid references public.providers(id),
  media_refs jsonb,
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id),
  constraint care_notes_pet_household_fkey
    foreign key (pet_id, household_id) references public.pets (id, household_id),
  constraint care_notes_deleted_shape check (
    (deleted_at is null and deleted_by is null) or deleted_at is not null
  ),
  constraint care_notes_title_shape check (
    title is null or char_length(trim(title)) > 0
  ),
  constraint care_notes_title_length check (
    title is null or char_length(title) <= 200
  ),
  constraint care_notes_media_array check (
    media_refs is null or jsonb_typeof(media_refs) = 'array'
  ),
  constraint care_notes_document_requires_title check (
    kind <> 'document' or title is not null
  )
);

comment on table public.care_notes is
  'Household-private health notes (US-077). Never used for diagnosis or treatment advice.';
comment on column public.care_notes.body is
  'Owner/professional observation text. Private; excluded from analytics.';
comment on column public.care_notes.media_refs is
  'Reserved for a future Storage pass. Non-empty arrays are rejected by write_path.';
comment on column public.care_notes.kind is
  'general_note is live; document is schema-reserved until Storage RLS lands.';

create index care_notes_pet_recent
  on public.care_notes (pet_id, effective_date desc, created_at desc)
  where deleted_at is null;

create trigger care_notes_set_updated_at
  before update on public.care_notes
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Guards (DM §18.6 / §18.10)
-- ---------------------------------------------------------------------------

create or replace function public.care_note_guard()
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
    raise exception 'care note household_id must match the pet' using errcode = '22023';
  end if;
  if pet_row.status <> 'active' or pet_row.deleted_at is not null then
    raise exception 'cannot write care note for an archived or deleted pet'
      using errcode = '22023';
  end if;

  select * into household_row from public.households where id = new.household_id;
  if not found or household_row.status <> 'active' then
    raise exception 'cannot write care note for a closed household'
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

create trigger care_notes_guard
  before insert or update on public.care_notes
  for each row execute function public.care_note_guard();

-- ---------------------------------------------------------------------------
-- RLS — SELECT only for clients
-- ---------------------------------------------------------------------------

alter table public.care_notes enable row level security;

create policy "care notes active member read"
  on public.care_notes for select
  using (public.is_active_household_member(household_id));

grant select on public.care_notes to authenticated;
grant all on public.care_notes to service_role;

-- ---------------------------------------------------------------------------
-- Read shape
-- ---------------------------------------------------------------------------

create or replace function public.care_note_json(
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
    'id', cn.id,
    'household_id', cn.household_id,
    'pet_id', cn.pet_id,
    'kind', cn.kind,
    'title', cn.title,
    'body', cn.body,
    'effective_date', cn.effective_date,
    'provenance', cn.provenance,
    'provider_id', cn.provider_id,
    'media_refs', cn.media_refs,
    'revision', cn.revision,
    'created_at', cn.created_at,
    'created_by', cn.created_by,
    'created_by_name', up.display_name,
    'updated_at', cn.updated_at,
    'updated_by', cn.updated_by,
    'removed_at', cn.deleted_at
  ))
  from public.care_notes cn
  left join public.user_profiles up on up.id = cn.created_by
  where cn.id = target_id
    and (include_removed or cn.deleted_at is null);
$$;

-- ---------------------------------------------------------------------------
-- write_path_create_care_note (US-077)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_create_care_note(
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
  note_id uuid;
  kind_value public.care_note_kind;
  title_value text;
  body_value text;
  effective_date_value date;
  provenance_value public.care_note_provenance;
  provider_value uuid;
  media_refs_value jsonb;
  today_local date;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
       or existing.command <> 'create_care_note' then
      raise exception 'idempotency key reused with different command or payload'
        using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_pet := public.care_authorize_pet(
    actor_id, nullif(payload_input->>'pet_id', '')::uuid
  );

  begin
    kind_value := coalesce(
      nullif(payload_input->>'kind', '')::public.care_note_kind,
      'general_note'::public.care_note_kind
    );
  exception when invalid_text_representation then
    raise exception 'kind must be general_note or document' using errcode = '22023';
  end;
  if kind_value <> 'general_note' then
    raise exception 'document notes are not available yet' using errcode = '22023';
  end if;

  body_value := nullif(trim(payload_input->>'body'), '');
  if body_value is null then
    raise exception 'body is required' using errcode = '22023';
  end if;
  if char_length(body_value) > 8000 then
    raise exception 'body must be 8000 characters or fewer' using errcode = '22023';
  end if;

  title_value := nullif(trim(payload_input->>'title'), '');
  if title_value is not null and char_length(title_value) > 200 then
    raise exception 'title must be 200 characters or fewer' using errcode = '22023';
  end if;

  today_local := public.household_current_local_date(target_pet.household_id, now());
  effective_date_value := coalesce(
    nullif(payload_input->>'effective_date', '')::date,
    today_local
  );
  if effective_date_value > today_local then
    raise exception 'a care note cannot be recorded for a future date'
      using errcode = '22023';
  end if;
  if effective_date_value < today_local - (365 * 20) then
    raise exception 'effective_date is more than twenty years ago'
      using errcode = '22023';
  end if;

  begin
    provenance_value := coalesce(
      nullif(payload_input->>'provenance', '')::public.care_note_provenance,
      'owner_entered'::public.care_note_provenance
    );
  exception when invalid_text_representation then
    raise exception 'provenance must be owner_entered or professional_instruction'
      using errcode = '22023';
  end;

  provider_value := nullif(payload_input->>'provider_id', '')::uuid;

  media_refs_value := payload_input->'media_refs';
  if media_refs_value is not null and jsonb_typeof(media_refs_value) = 'null' then
    media_refs_value := null;
  end if;
  if media_refs_value is not null and jsonb_typeof(media_refs_value) <> 'array' then
    raise exception 'media_refs must be an array' using errcode = '22023';
  end if;
  if media_refs_value is not null and jsonb_array_length(media_refs_value) > 0 then
    raise exception 'document attachments are not available yet' using errcode = '22023';
  end if;

  note_id := coalesce(nullif(payload_input->>'care_note_id', '')::uuid, gen_random_uuid());

  insert into public.care_notes (
    id, household_id, pet_id, kind, title, body, effective_date,
    provenance, provider_id, media_refs, created_by, updated_by
  ) values (
    note_id, target_pet.household_id, target_pet.id, kind_value, title_value,
    body_value, effective_date_value, provenance_value, provider_value, null,
    actor_id, actor_id
  );

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_pet.household_id, actor_id,
    jsonb_build_object('type', 'care_note', 'id', note_id),
    'care.note_created',
    jsonb_build_object(
      'pet_id', target_pet.id,
      'kind', kind_value,
      'effective_date', effective_date_value,
      'provenance', provenance_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('care_note', public.care_note_json(note_id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'create_care_note', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_edit_care_note
-- ---------------------------------------------------------------------------

create or replace function public.write_path_edit_care_note(
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
  target public.care_notes%rowtype;
  expected_revision integer;
  title_value text;
  body_value text;
  effective_date_value date;
  provenance_value public.care_note_provenance;
  provider_value uuid;
  media_refs_value jsonb;
  today_local date;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
       or existing.command <> 'edit_care_note' then
      raise exception 'idempotency key reused with different command or payload'
        using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.care_notes
  where id = nullif(payload_input->>'care_note_id', '')::uuid
    and deleted_at is null
  for update;
  if not found then
    raise exception 'care note not found' using errcode = '22023';
  end if;

  perform public.care_authorize_pet(actor_id, target.pet_id);

  expected_revision := nullif(payload_input->>'expected_revision', '')::integer;
  if expected_revision is null then
    raise exception 'expected_revision is required' using errcode = '22023';
  end if;
  if expected_revision <> target.revision then
    raise exception 'this record changed since you opened it' using errcode = '40001';
  end if;

  if payload_input ? 'body' then
    body_value := nullif(trim(payload_input->>'body'), '');
    if body_value is null then
      raise exception 'body is required' using errcode = '22023';
    end if;
    if char_length(body_value) > 8000 then
      raise exception 'body must be 8000 characters or fewer' using errcode = '22023';
    end if;
  else
    body_value := target.body;
  end if;

  if payload_input ? 'title' then
    title_value := nullif(trim(payload_input->>'title'), '');
    if title_value is not null and char_length(title_value) > 200 then
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
    raise exception 'a care note cannot be recorded for a future date'
      using errcode = '22023';
  end if;

  if payload_input ? 'provenance' then
    begin
      provenance_value := (payload_input->>'provenance')::public.care_note_provenance;
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

  if payload_input ? 'media_refs' then
    media_refs_value := payload_input->'media_refs';
    if media_refs_value is not null and jsonb_typeof(media_refs_value) = 'null' then
      media_refs_value := null;
    end if;
    if media_refs_value is not null and jsonb_typeof(media_refs_value) <> 'array' then
      raise exception 'media_refs must be an array' using errcode = '22023';
    end if;
    if media_refs_value is not null and jsonb_array_length(media_refs_value) > 0 then
      raise exception 'document attachments are not available yet' using errcode = '22023';
    end if;
  end if;

  update public.care_notes
  set title = title_value,
      body = body_value,
      effective_date = effective_date_value,
      provenance = provenance_value,
      provider_id = provider_value,
      media_refs = case when payload_input ? 'media_refs' then null else media_refs end,
      revision = target.revision + 1,
      updated_by = actor_id
  where id = target.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target.household_id, actor_id,
    jsonb_build_object('type', 'care_note', 'id', target.id),
    'care.note_edited',
    jsonb_build_object(
      'pet_id', target.pet_id,
      'previous_effective_date', target.effective_date,
      'effective_date', effective_date_value,
      'previous_provenance', target.provenance,
      'provenance', provenance_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('care_note', public.care_note_json(target.id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'edit_care_note', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_remove_care_note
-- ---------------------------------------------------------------------------

create or replace function public.write_path_remove_care_note(
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
  target public.care_notes%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
       or existing.command <> 'remove_care_note' then
      raise exception 'idempotency key reused with different command or payload'
        using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.care_notes
  where id = nullif(payload_input->>'care_note_id', '')::uuid
  for update;
  if not found then
    raise exception 'care note not found' using errcode = '22023';
  end if;

  perform public.care_authorize_pet(actor_id, target.pet_id);

  if target.deleted_at is null then
    update public.care_notes
    set deleted_at = now(),
        deleted_by = actor_id,
        updated_by = actor_id
    where id = target.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target.household_id, actor_id,
      jsonb_build_object('type', 'care_note', 'id', target.id),
      'care.note_removed',
      jsonb_build_object(
        'pet_id', target.pet_id,
        'kind', target.kind
      ),
      recorded_at_input
    );
  end if;

  response := jsonb_build_object(
    'care_note', public.care_note_json(target.id, true)
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'remove_care_note', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- Lockdown
-- ---------------------------------------------------------------------------

revoke execute on function public.write_path_create_care_note(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_edit_care_note(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_remove_care_note(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;

grant execute on function public.write_path_create_care_note(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_edit_care_note(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_remove_care_note(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;

revoke execute on function public.care_note_json(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.care_note_guard() from public, anon, authenticated;
