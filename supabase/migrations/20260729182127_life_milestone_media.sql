-- Life milestone media (F12, DM §12.6, US-090/US-091/US-093, Scenario H).
--
-- Additive on top of `*_life_milestones.sql`. Does NOT touch Care notes,
-- Planner, Auth, or socialization media_refs.
--
-- Model:
--   * `media` metadata rows (pending_upload → available | upload_failed | removed)
--   * private Storage bucket `household-media`, object path `{household_id}/{media_id}`
--   * Storage RLS: household members only; INSERT + SELECT + UPDATE (upsert)
--   * Objects are only writable when a matching `media` row authorizes the path
--   * Milestone text still saves without media; attach goes through write_path_*
--
-- Clients SELECT media/milestones. Mutations go through write_path SECURITY DEFINER.

-- ---------------------------------------------------------------------------
-- media (DM §12.6)
-- ---------------------------------------------------------------------------

create table public.media (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid references public.pets(id) on delete set null,
  uploaded_by uuid not null references auth.users(id),
  storage_bucket text not null default 'household-media'
    check (storage_bucket = 'household-media'),
  storage_path text not null,
  mime_type text not null
    check (mime_type in ('image/jpeg', 'image/png', 'image/heic', 'image/webp')),
  byte_size bigint not null
    check (byte_size > 0 and byte_size <= 10485760),
  capture_time timestamptz,
  uploaded_at timestamptz,
  status text not null default 'pending_upload'
    check (status in ('pending_upload', 'available', 'upload_failed', 'removed')),
  -- Polymorphic owner for this Life slice: {"type":"milestone","id":"<uuid>"}.
  attached_to jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint media_storage_path_unique unique (storage_bucket, storage_path),
  constraint media_pet_household_fkey
    foreign key (pet_id, household_id) references public.pets (id, household_id),
  constraint media_storage_path_shape check (
    storage_path = (household_id::text || '/' || id::text)
  ),
  constraint media_attached_to_shape check (
    attached_to is null
    or (
      jsonb_typeof(attached_to) = 'object'
      and attached_to ? 'type'
      and attached_to ? 'id'
    )
  ),
  constraint media_available_has_uploaded_at check (
    status <> 'available' or uploaded_at is not null
  )
);

comment on table public.media is
  'Household-private photo metadata (DM §12.6). Bytes live in Storage; never publicly addressable.';
comment on column public.media.capture_time is
  'Client-extracted capture time when available. Distinct from uploaded_at / milestone effective_date.';
comment on column public.media.status is
  'Upload lifecycle: pending_upload → available | upload_failed; removed detaches without claiming device copy deletion.';

create index media_household_active
  on public.media (household_id, created_at desc)
  where status <> 'removed';

create index media_attached_milestone
  on public.media ((attached_to->>'id'))
  where attached_to->>'type' = 'milestone' and status <> 'removed';

create trigger media_set_updated_at
  before update on public.media
  for each row execute function public.set_updated_at();

create or replace function public.media_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  household_row public.households%rowtype;
  pet_row public.pets%rowtype;
begin
  select * into household_row from public.households where id = new.household_id;
  if not found or household_row.status <> 'active' then
    raise exception 'cannot write media for a closed household' using errcode = '22023';
  end if;

  if new.pet_id is not null then
    select * into pet_row from public.pets where id = new.pet_id;
    if not found then
      raise exception 'pet % does not exist', new.pet_id using errcode = '22023';
    end if;
    if pet_row.household_id <> new.household_id then
      raise exception 'media household_id must match the pet' using errcode = '22023';
    end if;
  end if;

  return new;
end;
$$;

create trigger media_guard
  before insert or update on public.media
  for each row execute function public.media_guard();

alter table public.media enable row level security;

create policy "media active member read"
  on public.media for select
  using (
    public.is_active_household_member(household_id)
    and status <> 'removed'
  );

grant select on public.media to authenticated;
grant all on public.media to service_role;

-- ---------------------------------------------------------------------------
-- Storage bucket + RLS (household-only; INSERT+SELECT+UPDATE for upsert)
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'household-media',
  'household-media',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/heic', 'image/webp']::text[]
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Authorize object access only when a media row for this household path allows it.
-- Folder prefix alone is not enough: write_path must mint the media row first.
create or replace function public.media_storage_object_allowed(
  object_bucket text,
  object_name text,
  for_write boolean
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  media_row public.media%rowtype;
begin
  if object_bucket is distinct from 'household-media' then
    return false;
  end if;

  select * into media_row
  from public.media
  where storage_bucket = object_bucket
    and storage_path = object_name;

  if not found then
    return false;
  end if;

  if not public.is_active_household_member(media_row.household_id) then
    return false;
  end if;

  if for_write then
    return media_row.status in ('pending_upload', 'upload_failed');
  end if;

  -- Members may download pending/failed (local retry UI) and available objects.
  return media_row.status in ('pending_upload', 'upload_failed', 'available');
end;
$$;

comment on function public.media_storage_object_allowed(text, text, boolean) is
  'Storage RLS helper: household members may read authorized media paths; writes only while pending/failed.';

revoke execute on function public.media_storage_object_allowed(text, text, boolean) from public, anon;
grant execute on function public.media_storage_object_allowed(text, text, boolean) to authenticated, service_role;

drop policy if exists "household media select" on storage.objects;
drop policy if exists "household media insert" on storage.objects;
drop policy if exists "household media update" on storage.objects;

create policy "household media select"
  on storage.objects for select
  to authenticated
  using (public.media_storage_object_allowed(bucket_id, name, false));

create policy "household media insert"
  on storage.objects for insert
  to authenticated
  with check (public.media_storage_object_allowed(bucket_id, name, true));

-- Upsert replaces an object: Storage requires SELECT + UPDATE in addition to INSERT.
create policy "household media update"
  on storage.objects for update
  to authenticated
  using (public.media_storage_object_allowed(bucket_id, name, true))
  with check (public.media_storage_object_allowed(bucket_id, name, true));

-- ---------------------------------------------------------------------------
-- Read helpers
-- ---------------------------------------------------------------------------

create or replace function public.media_json(target_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when m.id is null then null else jsonb_strip_nulls(jsonb_build_object(
    'id', m.id,
    'household_id', m.household_id,
    'pet_id', m.pet_id,
    'uploaded_by', m.uploaded_by,
    'storage_bucket', m.storage_bucket,
    'storage_path', m.storage_path,
    'mime_type', m.mime_type,
    'byte_size', m.byte_size,
    'capture_time', m.capture_time,
    'uploaded_at', m.uploaded_at,
    'status', m.status,
    'attached_to', m.attached_to,
    'created_at', m.created_at,
    'updated_at', m.updated_at
  )) end
  from public.media m
  where m.id = target_id;
$$;

-- Keep milestone_json media_refs as the id array; clients load media rows separately.

comment on column public.milestones.media_refs is
  'jsonb array of media ids attached to this milestone. Empty/null until photos attach.';

-- ---------------------------------------------------------------------------
-- Soft household cap (private MVP: 1000 non-removed items)
-- ---------------------------------------------------------------------------

create or replace function public.media_household_count(target_household_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.media
  where household_id = target_household_id
    and status <> 'removed';
$$;

-- ---------------------------------------------------------------------------
-- write_path_prepare_milestone_media
-- Creates pending media + appends to milestone.media_refs. Bytes upload next.
-- ---------------------------------------------------------------------------

create or replace function public.write_path_prepare_milestone_media(
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
      or existing.command <> 'prepare_milestone_media'
    then
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
    jsonb_build_object('type', 'milestone', 'id', target.id)
  );

  refs := coalesce(target.media_refs, '[]'::jsonb);
  if jsonb_typeof(refs) <> 'array' then
    refs := '[]'::jsonb;
  end if;
  refs := refs || jsonb_build_array(media_id::text);

  update public.milestones
  set media_refs = refs,
      revision = target.revision + 1,
      updated_by = actor_id
  where id = target.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target.household_id, actor_id,
    jsonb_build_object('type', 'media', 'id', media_id),
    'life.milestone_media_prepared',
    jsonb_build_object(
      'milestone_id', target.id,
      'pet_id', target.pet_id,
      'mime_type', mime_value,
      'byte_size', byte_size_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object(
    'media', public.media_json(media_id),
    'milestone', public.milestone_json(target.id),
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
    actor_id, idempotency_key, 'prepare_milestone_media', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_complete_milestone_media
-- ---------------------------------------------------------------------------

create or replace function public.write_path_complete_milestone_media(
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
      or existing.command <> 'complete_milestone_media'
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
  if target.attached_to->>'type' is distinct from 'milestone' then
    raise exception 'media is not attached to a milestone' using errcode = '22023';
  end if;

  if target.pet_id is null then
    raise exception 'media is missing a pet' using errcode = '22023';
  end if;
  perform public.life_authorize_pet(actor_id, target.pet_id);

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
      'life.milestone_media_available',
      jsonb_build_object(
        'milestone_id', target.attached_to->>'id',
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
    actor_id, idempotency_key, 'complete_milestone_media', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_fail_milestone_media
-- ---------------------------------------------------------------------------

create or replace function public.write_path_fail_milestone_media(
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
      or existing.command <> 'fail_milestone_media'
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
  if target.attached_to->>'type' is distinct from 'milestone' then
    raise exception 'media is not attached to a milestone' using errcode = '22023';
  end if;
  if target.pet_id is null then
    raise exception 'media is missing a pet' using errcode = '22023';
  end if;
  perform public.life_authorize_pet(actor_id, target.pet_id);

  -- Never discard the parent milestone. available → fail is refused; only
  -- pending/failed may be marked failed (retry stays open).
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
      'life.milestone_media_failed',
      jsonb_build_object(
        'milestone_id', target.attached_to->>'id',
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
    actor_id, idempotency_key, 'fail_milestone_media', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_remove_milestone_media (US-093)
-- Detaches from milestone; marks media removed. Does not delete device copies.
-- ---------------------------------------------------------------------------

create or replace function public.write_path_remove_milestone_media(
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
  target_milestone public.milestones%rowtype;
  milestone_id uuid;
  next_refs jsonb := '[]'::jsonb;
  element jsonb;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input
      or existing.command <> 'remove_milestone_media'
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
  if target_media.attached_to->>'type' is distinct from 'milestone' then
    raise exception 'media is not attached to a milestone' using errcode = '22023';
  end if;

  milestone_id := nullif(target_media.attached_to->>'id', '')::uuid;
  if milestone_id is null then
    raise exception 'media is missing a milestone attachment' using errcode = '22023';
  end if;

  select * into target_milestone from public.milestones
  where id = milestone_id
  for update;
  if not found then
    raise exception 'milestone not found' using errcode = '22023';
  end if;

  perform public.life_authorize_pet(actor_id, target_milestone.pet_id);

  if target_media.status <> 'removed' then
    update public.media
    set status = 'removed'
    where id = target_media.id;

    if target_milestone.media_refs is not null
      and jsonb_typeof(target_milestone.media_refs) = 'array'
    then
      select coalesce(jsonb_agg(to_jsonb(value)), '[]'::jsonb)
      into next_refs
      from jsonb_array_elements_text(target_milestone.media_refs) as value
      where value is distinct from target_media.id::text;
    end if;

    update public.milestones
    set media_refs = case when jsonb_array_length(next_refs) = 0 then null else next_refs end,
        revision = target_milestone.revision + 1,
        updated_by = actor_id
    where id = target_milestone.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target_milestone.household_id, actor_id,
      jsonb_build_object('type', 'media', 'id', target_media.id),
      'life.milestone_media_removed',
      jsonb_build_object(
        'milestone_id', target_milestone.id,
        'pet_id', target_milestone.pet_id,
        'device_copy_unaffected', true
      ),
      recorded_at_input
    );
  end if;

  response := jsonb_build_object(
    'media', public.media_json(target_media.id),
    'milestone', public.milestone_json(target_milestone.id, true)
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'remove_milestone_media', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- Lockdown
-- ---------------------------------------------------------------------------

revoke execute on function public.write_path_prepare_milestone_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_complete_milestone_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_fail_milestone_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_remove_milestone_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;

grant execute on function public.write_path_prepare_milestone_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_complete_milestone_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_fail_milestone_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_remove_milestone_media(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;

revoke execute on function public.media_json(uuid) from public, anon, authenticated;
revoke execute on function public.media_household_count(uuid) from public, anon, authenticated;
revoke execute on function public.media_guard() from public, anon, authenticated;
