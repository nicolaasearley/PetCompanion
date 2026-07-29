-- Care note document attachments (F10, DM §11.1 / §12.6, US-077, Scenario H).
--
-- Additive on top of `*_care_notes.sql` + `*_life_milestone_media.sql`.
-- Reuses private `household-media` bucket, `media` metadata, path shape
-- `{household_id}/{media_id}`, and INSERT+SELECT+UPDATE Storage RLS.
-- Does NOT alter Life milestone media write paths or MIME/size rules.
--
-- Model:
--   * care_notes.media_refs filled only via prepare_care_note_media (not create/edit)
--   * attached_to = {"type":"care_note","id":"<uuid>"}
--   * note text still saves when upload fails (Scenario H)
--   * kind = 'document' enabled (title required); general_note stays optional-title

-- ---------------------------------------------------------------------------
-- Comments + attachment index
-- ---------------------------------------------------------------------------

comment on column public.care_notes.media_refs is
  'jsonb array of media ids attached to this care note. Empty/null until attach.';
comment on column public.care_notes.kind is
  'general_note or document. Document requires a title; media attaches via write_path.';
comment on type public.care_note_kind is
  'Health record subtype for care_notes. document writes are live with Storage attach.';

create index if not exists media_attached_care_note
  on public.media ((attached_to->>'id'))
  where attached_to->>'type' = 'care_note' and status <> 'removed';

-- ---------------------------------------------------------------------------
-- create_care_note: allow document kind; still reject media_refs on create
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
  if kind_value = 'document' and title_value is null then
    raise exception 'document notes require a title' using errcode = '22023';
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

  -- Attachments go through prepare_care_note_media after the text save.
  media_refs_value := payload_input->'media_refs';
  if media_refs_value is not null and jsonb_typeof(media_refs_value) = 'null' then
    media_refs_value := null;
  end if;
  if media_refs_value is not null and jsonb_typeof(media_refs_value) <> 'array' then
    raise exception 'media_refs must be an array' using errcode = '22023';
  end if;
  if media_refs_value is not null and jsonb_array_length(media_refs_value) > 0 then
    raise exception 'attach documents via prepare_care_note_media' using errcode = '22023';
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
-- edit_care_note: reject direct media_refs; document title stays required
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
  if target.kind = 'document' and title_value is null then
    raise exception 'document notes require a title' using errcode = '22023';
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
      raise exception 'attach documents via prepare_care_note_media' using errcode = '22023';
    end if;
  end if;

  update public.care_notes
  set title = title_value,
      body = body_value,
      effective_date = effective_date_value,
      provenance = provenance_value,
      provider_id = provider_value,
      -- Never clear media_refs from edit payload; attach/remove go through media commands.
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
-- write_path_prepare_care_note_media
-- ---------------------------------------------------------------------------

create or replace function public.write_path_prepare_care_note_media(
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
  media_id uuid;
  mime_value text;
  byte_size_value bigint;
  capture_time_value timestamptz;
  storage_path_value text;
  refs jsonb;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
      or existing.command <> 'prepare_care_note_media'
    then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
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

  if public.media_household_count(target.household_id) >= 1000 then
    raise exception 'this household has reached the photo limit' using errcode = '22023';
  end if;

  mime_value := nullif(trim(payload_input->>'mime_type'), '');
  if mime_value is null
    or mime_value not in ('image/jpeg', 'image/png', 'image/heic', 'image/webp')
  then
    raise exception 'mime_type must be an allowed image type' using errcode = '22023';
  end if;

  begin
    byte_size_value := nullif(payload_input->>'byte_size', '')::bigint;
  exception when others then
    raise exception 'byte_size must be a positive integer' using errcode = '22023';
  end;
  if byte_size_value is null or byte_size_value <= 0 then
    raise exception 'byte_size must be a positive integer' using errcode = '22023';
  end if;
  if byte_size_value > 10485760 then
    raise exception 'photos must be 10 MB or smaller' using errcode = '22023';
  end if;

  if payload_input ? 'capture_time' and nullif(payload_input->>'capture_time', '') is not null then
    begin
      capture_time_value := (payload_input->>'capture_time')::timestamptz;
    exception when others then
      raise exception 'capture_time must be an ISO-8601 timestamp' using errcode = '22023';
    end;
  end if;

  media_id := coalesce(nullif(payload_input->>'media_id', '')::uuid, gen_random_uuid());
  storage_path_value := target.household_id::text || '/' || media_id::text;

  insert into public.media (
    id, household_id, pet_id, uploaded_by, storage_bucket, storage_path,
    mime_type, byte_size, capture_time, status, attached_to
  ) values (
    media_id, target.household_id, target.pet_id, actor_id, 'household-media',
    storage_path_value, mime_value, byte_size_value, capture_time_value,
    'pending_upload',
    jsonb_build_object('type', 'care_note', 'id', target.id)
  );

  refs := coalesce(target.media_refs, '[]'::jsonb);
  if jsonb_typeof(refs) <> 'array' then
    refs := '[]'::jsonb;
  end if;
  refs := refs || jsonb_build_array(media_id::text);

  update public.care_notes
  set media_refs = refs,
      revision = target.revision + 1,
      updated_by = actor_id
  where id = target.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target.household_id, actor_id,
    jsonb_build_object('type', 'media', 'id', media_id),
    'care.note_media_prepared',
    jsonb_build_object(
      'care_note_id', target.id,
      'pet_id', target.pet_id,
      'mime_type', mime_value,
      'byte_size', byte_size_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object(
    'media', public.media_json(media_id),
    'care_note', public.care_note_json(target.id),
    'upload', jsonb_build_object(
      'bucket', 'household-media',
      'path', storage_path_value,
      'upsert', true
    )
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'prepare_care_note_media', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_complete_care_note_media
-- ---------------------------------------------------------------------------

create or replace function public.write_path_complete_care_note_media(
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
  target public.media%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
      or existing.command <> 'complete_care_note_media'
    then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.media
  where id = nullif(payload_input->>'media_id', '')::uuid
  for update;
  if not found then
    raise exception 'media not found' using errcode = '22023';
  end if;
  if target.status = 'removed' then
    raise exception 'media not found' using errcode = '22023';
  end if;
  if target.attached_to->>'type' is distinct from 'care_note' then
    raise exception 'media is not attached to a care note' using errcode = '22023';
  end if;

  if target.pet_id is null then
    raise exception 'media is missing a pet' using errcode = '22023';
  end if;
  perform public.care_authorize_pet(actor_id, target.pet_id);

  if target.status <> 'available' then
    update public.media
    set status = 'available',
        uploaded_at = coalesce(uploaded_at, now()),
        byte_size = coalesce(
          nullif(payload_input->>'byte_size', '')::bigint,
          byte_size
        )
    where id = target.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target.household_id, actor_id,
      jsonb_build_object('type', 'media', 'id', target.id),
      'care.note_media_available',
      jsonb_build_object(
        'care_note_id', target.attached_to->>'id',
        'pet_id', target.pet_id
      ),
      recorded_at_input
    );
  end if;

  response := jsonb_build_object('media', public.media_json(target.id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'complete_care_note_media', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_fail_care_note_media
-- ---------------------------------------------------------------------------

create or replace function public.write_path_fail_care_note_media(
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
  target public.media%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
      or existing.command <> 'fail_care_note_media'
    then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target from public.media
  where id = nullif(payload_input->>'media_id', '')::uuid
  for update;
  if not found then
    raise exception 'media not found' using errcode = '22023';
  end if;
  if target.status = 'removed' then
    raise exception 'media not found' using errcode = '22023';
  end if;
  if target.attached_to->>'type' is distinct from 'care_note' then
    raise exception 'media is not attached to a care note' using errcode = '22023';
  end if;
  if target.pet_id is null then
    raise exception 'media is missing a pet' using errcode = '22023';
  end if;
  perform public.care_authorize_pet(actor_id, target.pet_id);

  if target.status = 'available' then
    raise exception 'an available photo cannot be marked failed' using errcode = '22023';
  end if;

  if target.status <> 'upload_failed' then
    update public.media
    set status = 'upload_failed'
    where id = target.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target.household_id, actor_id,
      jsonb_build_object('type', 'media', 'id', target.id),
      'care.note_media_failed',
      jsonb_build_object(
        'care_note_id', target.attached_to->>'id',
        'pet_id', target.pet_id
      ),
      recorded_at_input
    );
  end if;

  response := jsonb_build_object('media', public.media_json(target.id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'fail_care_note_media', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_remove_care_note_media
-- ---------------------------------------------------------------------------

create or replace function public.write_path_remove_care_note_media(
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
  target_media public.media%rowtype;
  target_note public.care_notes%rowtype;
  note_id uuid;
  next_refs jsonb := '[]'::jsonb;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
      or existing.command <> 'remove_care_note_media'
    then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target_media from public.media
  where id = nullif(payload_input->>'media_id', '')::uuid
  for update;
  if not found then
    raise exception 'media not found' using errcode = '22023';
  end if;
  if target_media.attached_to->>'type' is distinct from 'care_note' then
    raise exception 'media is not attached to a care note' using errcode = '22023';
  end if;

  note_id := nullif(target_media.attached_to->>'id', '')::uuid;
  if note_id is null then
    raise exception 'media is missing a care note attachment' using errcode = '22023';
  end if;

  select * into target_note from public.care_notes
  where id = note_id
  for update;
  if not found then
    raise exception 'care note not found' using errcode = '22023';
  end if;

  perform public.care_authorize_pet(actor_id, target_note.pet_id);

  if target_media.status <> 'removed' then
    update public.media
    set status = 'removed'
    where id = target_media.id;

    if target_note.media_refs is not null
      and jsonb_typeof(target_note.media_refs) = 'array'
    then
      select coalesce(jsonb_agg(to_jsonb(value)), '[]'::jsonb)
      into next_refs
      from jsonb_array_elements_text(target_note.media_refs) as value
      where value is distinct from target_media.id::text;
    end if;

    update public.care_notes
    set media_refs = case when jsonb_array_length(next_refs) = 0 then null else next_refs end,
        revision = target_note.revision + 1,
        updated_by = actor_id
    where id = target_note.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target_note.household_id, actor_id,
      jsonb_build_object('type', 'media', 'id', target_media.id),
      'care.note_media_removed',
      jsonb_build_object(
        'care_note_id', target_note.id,
        'pet_id', target_note.pet_id,
        'device_copy_unaffected', true
      ),
      recorded_at_input
    );
  end if;

  response := jsonb_build_object(
    'media', public.media_json(target_media.id),
    'care_note', public.care_note_json(target_note.id, true)
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'remove_care_note_media', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- Lockdown
-- ---------------------------------------------------------------------------

revoke execute on function public.write_path_prepare_care_note_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_complete_care_note_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_fail_care_note_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_remove_care_note_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;

grant execute on function public.write_path_prepare_care_note_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_complete_care_note_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_fail_care_note_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_remove_care_note_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;

revoke execute on function public.write_path_create_care_note(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_edit_care_note(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
grant execute on function public.write_path_create_care_note(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_edit_care_note(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
