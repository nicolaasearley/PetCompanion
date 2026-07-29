-- Care note document attachments: allow PDF alongside images (US-077).
--
-- Life milestone media stays image-only at the write_path layer.
-- Shared `media.mime_type` check + `household-media` bucket allow-list
-- expand so Care prepare can mint PDF rows; Life prepare still rejects PDF.

-- ---------------------------------------------------------------------------
-- Shared metadata + Storage allow-list
-- ---------------------------------------------------------------------------

alter table public.media
  drop constraint if exists media_mime_type_check;

alter table public.media
  add constraint media_mime_type_check
  check (
    mime_type in (
      'image/jpeg',
      'image/png',
      'image/heic',
      'image/webp',
      'application/pdf'
    )
  );

comment on table public.media is
  'Household-private media metadata (DM §12.6). Images for Life; images+PDF for Care documents. Bytes live in Storage; never publicly addressable.';

update storage.buckets
set allowed_mime_types = array[
  'image/jpeg',
  'image/png',
  'image/heic',
  'image/webp',
  'application/pdf'
]::text[]
where id = 'household-media';

-- ---------------------------------------------------------------------------
-- Care prepare: accept PDF; keep 10 MB cap; Life prepare unchanged
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
    raise exception 'this household has reached the attachment limit' using errcode = '22023';
  end if;

  mime_value := nullif(trim(payload_input->>'mime_type'), '');
  if mime_value is null
    or mime_value not in (
      'image/jpeg', 'image/png', 'image/heic', 'image/webp', 'application/pdf'
    )
  then
    raise exception 'mime_type must be an allowed image or PDF type' using errcode = '22023';
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
    raise exception 'attachments must be 10 MB or smaller' using errcode = '22023';
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

revoke execute on function public.write_path_prepare_care_note_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
grant execute on function public.write_path_prepare_care_note_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
