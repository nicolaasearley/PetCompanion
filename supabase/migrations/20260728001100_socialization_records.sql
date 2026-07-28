-- Socialization passport: recorded experiences and exclusions (F09, E06).
--
-- `socialization_catalog` has existed since the Slice A foundation as seeded
-- global content, but nothing recorded what a household actually did with it.
-- Consequently `write_path_generation_context` hardcoded
-- `excluded_socialization_categories` to `[]`, and category recency was only
-- inferable from plan items and dispositions -- which means an experience the
-- household did off-plan was invisible to the breadth rule.
--
-- This migration adds the two entities from Data Model §12.4 and wires them
-- into generation:
--
--   SocializationRecord    -- what happened, when, and how the owner says the
--                             puppy responded. OWNER-REPORTED and explicitly
--                             NON-DIAGNOSTIC: the response is a vocabulary
--                             term (relaxed | curious | neutral | hesitant |
--                             fearful), never a behavioural finding, and this
--                             schema stores no score, rating, or aggregate.
--   SocializationExclusion -- "not available" / "not right for this puppy" /
--                             "paused". An ACTIVE exclusion is a HARD
--                             eligibility constraint (US-068) and is fully
--                             REVERSIBLE: clearing it sets `cleared_at`
--                             instead of deleting the row, so the decision and
--                             who made it stay in the record.
--
-- Data Model §18 invariants enforced here:
--   §18.6  no new record for an archived pet or a closed household
--          -> socialization_record_guard / socialization_exclusion_guard.
--   §18.10 every household-owned mutable record carries actor + timestamp
--          metadata and its household_id
--          -> NOT NULL created_by/updated_by/created_at/updated_at, plus a
--             COMPOSITE foreign key on (pet_id, household_id) so a record can
--             never name a pet from another household.
--   §18.11 records reference only PUBLISHED content versions
--          -> socialization_record_guard checks content_versions.
--   §18.3  unique client_idempotency_key per actor -> command_log, as for
--          every other write_path_* command.
--
-- F09 exclusions ("Universal numeric socialization score",
-- "Automated emotion classification") are structural here, not a UI
-- convention: there is no count, score, streak, or derived-state column on
-- either table, and nothing in this migration computes one.

-- ---------------------------------------------------------------------------
-- Vocabularies
-- ---------------------------------------------------------------------------

-- Content Catalogue §8, verbatim and closed. An enum (rather than free text)
-- is what stops a future caller from writing "anxious", "reactive", or any
-- other word that would read as a diagnosis.
create type public.socialization_response as enum (
  'relaxed', 'curious', 'neutral', 'hesitant', 'fearful'
);

comment on type public.socialization_response is
  'Owner-reported, non-diagnostic response vocabulary (Content Catalogue §8). Never a behavioural assessment.';

-- Data Model §12.4.
create type public.socialization_exclusion_reason as enum (
  'unavailable', 'unsuitable', 'paused'
);

comment on type public.socialization_exclusion_reason is
  'Why an experience or category is excluded (DM 10 §12.4). Every reason is reversible.';

-- The eight F09 categories (core features §14, catalogue §8). Kept as a
-- CHECK against the seeded catalogue vocabulary rather than an enum so that
-- adding a reviewed category later is a content change, not a type migration.
create or replace function public.is_socialization_category(candidate text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select candidate in (
    'People', 'Animals', 'Sounds', 'Surfaces',
    'Environments', 'Handling', 'Transportation', 'Household objects'
  );
$$;

comment on function public.is_socialization_category(text) is
  'The eight F09 socialization categories (core features §14, catalogue §8).';

-- ---------------------------------------------------------------------------
-- Composite key support
-- ---------------------------------------------------------------------------

-- Lets the new tables carry a real FOREIGN KEY on (pet_id, household_id), so
-- DM §18.10 ("every record reachable from a household carries or inherits its
-- household_id") is a database guarantee rather than a write-path promise.
create unique index if not exists pets_id_household_unique on public.pets (id, household_id);

-- ---------------------------------------------------------------------------
-- SocializationRecord (DM §12.4)
-- ---------------------------------------------------------------------------

create table public.socialization_records (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  -- `experience_ref` from the model, mapped to a column pair so the catalogue
  -- reference is a real FK instead of unvalidated JSON.
  experience_content_id text,
  experience_content_version integer,
  custom_label text,
  category text not null,
  effective_date date not null,
  context text,
  response public.socialization_response not null,
  note text,
  media_refs jsonb,
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id),
  constraint socialization_records_pet_household_fkey
    foreign key (pet_id, household_id) references public.pets (id, household_id),
  constraint socialization_records_experience_fkey
    foreign key (experience_content_id, experience_content_version)
    references public.socialization_catalog (content_id, version),
  -- F09 supports both catalogue experiences and "Add a custom experience";
  -- exactly one of the two identifies what happened.
  constraint socialization_records_identity check (
    (experience_content_id is not null and experience_content_version is not null and custom_label is null)
    or (experience_content_id is null and experience_content_version is null
        and custom_label is not null and char_length(trim(custom_label)) > 0)
  ),
  constraint socialization_records_category check (public.is_socialization_category(category)),
  constraint socialization_records_media_array check (
    media_refs is null or jsonb_typeof(media_refs) = 'array'
  ),
  constraint socialization_records_deleted_shape check (
    (deleted_at is null and deleted_by is null) or deleted_at is not null
  )
);

comment on table public.socialization_records is
  'One owner-reported socialization experience (DM 10 §12.4, F09/US-067). The response is a vocabulary term, never a diagnosis; no score is stored or derived.';
comment on column public.socialization_records.response is
  'Owner-reported only (catalogue §8). "hesitant"/"fearful" mean more distance and a softer version next time -- not more repetitions, and not a behavioural finding.';
comment on column public.socialization_records.category is
  'One of the eight F09 categories. Mirrors the catalogue row when experience_content_id is set; supplied by the caregiver for a custom experience.';

-- Recency lookups for the breadth rule (US-067 "recent completion reduces
-- unnecessary immediate repetition") and for TR-06/TR-07.
create index socialization_records_pet_recent
  on public.socialization_records (pet_id, effective_date desc)
  where deleted_at is null;
create index socialization_records_pet_category_recent
  on public.socialization_records (pet_id, category, effective_date desc)
  where deleted_at is null;

create trigger socialization_records_set_updated_at
  before update on public.socialization_records
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- SocializationExclusion (DM §12.4)
-- ---------------------------------------------------------------------------

create table public.socialization_exclusions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  -- Exactly one scope: a whole category, or a single catalogue experience.
  category text,
  experience_content_id text,
  reason public.socialization_exclusion_reason not null,
  note text,
  set_by uuid not null references auth.users(id),
  set_at timestamptz not null default now(),
  cleared_at timestamptz,
  cleared_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  constraint socialization_exclusions_pet_household_fkey
    foreign key (pet_id, household_id) references public.pets (id, household_id),
  constraint socialization_exclusions_scope check (
    (category is not null and experience_content_id is null)
    or (category is null and experience_content_id is not null)
  ),
  constraint socialization_exclusions_category check (
    category is null or public.is_socialization_category(category)
  ),
  -- Reversibility is a shape, not a delete: a cleared exclusion keeps who
  -- cleared it and when (US-068 "The choice can be reversed").
  constraint socialization_exclusions_cleared_shape check (
    (cleared_at is null and cleared_by is null)
    or (cleared_at is not null and cleared_by is not null)
  )
);

comment on table public.socialization_exclusions is
  'An experience or category the household has marked unavailable, unsuitable, or paused (DM 10 §12.4, US-068). Active rows are HARD eligibility constraints; clearing is reversal, never deletion.';

-- One live exclusion per scope per pet: re-marking an already-excluded
-- category must update the existing decision, not stack duplicates that would
-- each have to be cleared separately.
create unique index socialization_exclusions_active_category
  on public.socialization_exclusions (pet_id, category)
  where cleared_at is null and category is not null;
create unique index socialization_exclusions_active_experience
  on public.socialization_exclusions (pet_id, experience_content_id)
  where cleared_at is null and experience_content_id is not null;

create trigger socialization_exclusions_set_updated_at
  before update on public.socialization_exclusions
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Cross-row invariants (DM §18.6, §18.11)
-- ---------------------------------------------------------------------------

create or replace function public.socialization_record_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  catalogue_category text;
begin
  -- §18.6: archived pets and closed households accrue no new records. Edits
  -- to existing rows are still allowed for an archived pet only insofar as
  -- they do not create anything -- history stays readable and correctable.
  if tg_op = 'INSERT' then
    if not exists (
      select 1
      from public.pets p
      join public.households h on h.id = p.household_id
      where p.id = new.pet_id
        and p.status = 'active'
        and p.deleted_at is null
        and h.status = 'active'
    ) then
      raise exception 'socialization records require an active pet in an active household'
        using errcode = '22023';
    end if;
  end if;

  if new.experience_content_id is not null then
    -- §18.11: published content versions only.
    select sc.category into catalogue_category
    from public.socialization_catalog sc
    join public.content_versions cv using (content_id, version)
    where sc.content_id = new.experience_content_id
      and sc.version = new.experience_content_version
      and cv.publication_status = 'published';

    if not found then
      raise exception 'socialization experience % v% is not published content',
        new.experience_content_id, new.experience_content_version
        using errcode = '22023';
    end if;

    -- The catalogue owns the content-to-category mapping; a record may not
    -- file a catalogue experience under a category it does not belong to,
    -- which would silently corrupt breadth reporting.
    if new.category is distinct from catalogue_category then
      raise exception 'category % does not match the catalogue category % for %',
        new.category, catalogue_category, new.experience_content_id
        using errcode = '22023';
    end if;
  end if;

  return new;
end;
$$;

create trigger socialization_records_guard
  before insert or update on public.socialization_records
  for each row execute function public.socialization_record_guard();

create or replace function public.socialization_exclusion_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if not exists (
      select 1
      from public.pets p
      join public.households h on h.id = p.household_id
      where p.id = new.pet_id
        and p.status = 'active'
        and p.deleted_at is null
        and h.status = 'active'
    ) then
      raise exception 'socialization exclusions require an active pet in an active household'
        using errcode = '22023';
    end if;
  end if;

  if new.experience_content_id is not null
     and not exists (
       select 1
       from public.socialization_catalog sc
       join public.content_versions cv using (content_id, version)
       where sc.content_id = new.experience_content_id
         and cv.publication_status = 'published'
     ) then
    raise exception 'socialization experience % is not published content', new.experience_content_id
      using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger socialization_exclusions_guard
  before insert or update on public.socialization_exclusions
  for each row execute function public.socialization_exclusion_guard();

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.socialization_records enable row level security;
alter table public.socialization_exclusions enable row level security;

-- Read-only for clients; every mutation goes through the write path, as for
-- every other household-owned table in this schema (US-067 "visible to
-- authorized household members" -- and to nobody else).
create policy "socialization records active member read"
  on public.socialization_records for select
  using (public.is_active_household_member(household_id));

create policy "socialization exclusions active member read"
  on public.socialization_exclusions for select
  using (public.is_active_household_member(household_id));

-- The Slice A `grant select on all tables` predates these tables, and grants
-- do not flow to objects created later.
grant select on public.socialization_records to authenticated;
grant select on public.socialization_exclusions to authenticated;
grant all on public.socialization_records to service_role;
grant all on public.socialization_exclusions to service_role;

-- ---------------------------------------------------------------------------
-- Read shapes returned by the commands above
-- ---------------------------------------------------------------------------

create or replace function public.socialization_record_json(
  target_record_id uuid,
  include_removed boolean default false
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', sr.id,
    'household_id', sr.household_id,
    'pet_id', sr.pet_id,
    'experience_ref', case when sr.experience_content_id is not null
      then jsonb_build_object('content_id', sr.experience_content_id, 'version', sr.experience_content_version)
    end,
    'label', coalesce(sc.label, sr.custom_label),
    'custom_label', sr.custom_label,
    'category', sr.category,
    'effective_date', sr.effective_date,
    'context', sr.context,
    'response', sr.response,
    'note', sr.note,
    'media_refs', sr.media_refs,
    'revision', sr.revision,
    'created_at', sr.created_at,
    'created_by', sr.created_by,
    'created_by_name', up.display_name,
    'updated_at', sr.updated_at,
    'updated_by', sr.updated_by,
    'removed_at', sr.deleted_at
  ))
  from public.socialization_records sr
  left join public.socialization_catalog sc
    on sc.content_id = sr.experience_content_id and sc.version = sr.experience_content_version
  left join public.user_profiles up on up.id = sr.created_by
  where sr.id = target_record_id
    and (include_removed or sr.deleted_at is null);
$$;

create or replace function public.socialization_exclusion_json(target_exclusion_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', se.id,
    'household_id', se.household_id,
    'pet_id', se.pet_id,
    'category', se.category,
    'experience_content_id', se.experience_content_id,
    'reason', se.reason,
    'note', se.note,
    'set_by', se.set_by,
    'set_at', se.set_at,
    'cleared_at', se.cleared_at,
    'cleared_by', se.cleared_by,
    'active', se.cleared_at is null
  ))
  from public.socialization_exclusions se
  where se.id = target_exclusion_id;
$$;

-- ---------------------------------------------------------------------------
-- Shared helper: authorize an actor against a pet
-- ---------------------------------------------------------------------------

create or replace function public.socialization_authorize_pet(
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
    -- Deliberately indistinguishable from "no such pet": a non-member must
    -- not learn that a pet id exists (F01 "Prevent one user's session from
    -- exposing another household's data").
    raise exception 'active pet not found in a household you belong to' using errcode = '42501';
  end if;

  return target_pet;
end;
$$;

comment on function public.socialization_authorize_pet(uuid, uuid) is
  'Resolves a pet the actor may write to, or raises 42501. Never distinguishes "not yours" from "does not exist".';

-- ---------------------------------------------------------------------------
-- write_path_record_socialization (US-067, TR-08)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_record_socialization(
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
  experience_id text;
  experience_version integer;
  custom_label_value text;
  category_value text;
  effective_date_value date;
  today_local date;
  response_value public.socialization_response;
  media_refs_value jsonb;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'record_socialization' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_pet := public.socialization_authorize_pet(
    actor_id, nullif(payload_input->>'pet_id', '')::uuid
  );

  experience_id := nullif(payload_input->>'experience_content_id', '');
  custom_label_value := nullif(trim(payload_input->>'custom_label'), '');

  if (experience_id is null) = (custom_label_value is null) then
    raise exception 'supply exactly one of experience_content_id or custom_label' using errcode = '22023';
  end if;

  if experience_id is not null then
    -- The catalogue, not the client, decides the version and the category.
    -- A client-supplied category is ignored rather than rejected so an older
    -- app build cannot mis-file an experience.
    select sc.version, sc.category into experience_version, category_value
    from public.socialization_catalog sc
    join public.content_versions cv using (content_id, version)
    where sc.content_id = experience_id
      and cv.publication_status = 'published'
      and (sc.retired_at is null or sc.retired_at > now())
    order by sc.version desc
    limit 1;

    if not found then
      raise exception 'socialization experience % is not available', experience_id using errcode = '22023';
    end if;
  else
    category_value := nullif(payload_input->>'category', '');
    if category_value is null or not public.is_socialization_category(category_value) then
      raise exception 'a custom experience needs one of the eight socialization categories' using errcode = '22023';
    end if;
  end if;

  today_local := public.household_current_local_date(target_pet.household_id, now());
  effective_date_value := coalesce(
    nullif(payload_input->>'effective_date', '')::date,
    today_local
  );
  if effective_date_value > today_local then
    raise exception 'an experience cannot be recorded before it happens' using errcode = '22023';
  end if;
  -- A generous floor, not a cadence rule: it only stops a typo'd year from
  -- silently landing outside every recency window the engine reads.
  if effective_date_value < today_local - 365 then
    raise exception 'effective_date is more than a year ago' using errcode = '22023';
  end if;

  begin
    response_value := (payload_input->>'response')::public.socialization_response;
  exception when invalid_text_representation then
    raise exception 'response must be one of relaxed, curious, neutral, hesitant, fearful'
      using errcode = '22023';
  end;
  if response_value is null then
    raise exception 'response is required' using errcode = '22023';
  end if;

  media_refs_value := payload_input->'media_refs';
  if media_refs_value is not null and jsonb_typeof(media_refs_value) = 'null' then
    media_refs_value := null;
  end if;
  if media_refs_value is not null and jsonb_typeof(media_refs_value) <> 'array' then
    raise exception 'media_refs must be an array' using errcode = '22023';
  end if;

  record_id := coalesce(nullif(payload_input->>'record_id', '')::uuid, gen_random_uuid());

  insert into public.socialization_records (
    id, household_id, pet_id, experience_content_id, experience_content_version,
    custom_label, category, effective_date, context, response, note, media_refs,
    created_by, updated_by
  ) values (
    record_id, target_pet.household_id, target_pet.id, experience_id, experience_version,
    custom_label_value, category_value, effective_date_value,
    nullif(trim(payload_input->>'context'), ''), response_value,
    nullif(trim(payload_input->>'note'), ''), media_refs_value,
    actor_id, actor_id
  );

  -- The audit summary carries the category and the vocabulary term but never
  -- `note` or `context`: those are free text a caregiver wrote about their
  -- puppy, and audit is a longer-lived, more widely readable store (DM §17).
  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_pet.household_id, actor_id,
    jsonb_build_object('type', 'socialization_record', 'id', record_id),
    'socialization.recorded',
    jsonb_build_object(
      'pet_id', target_pet.id,
      'category', category_value,
      'response', response_value,
      'effective_date', effective_date_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('record', public.socialization_record_json(record_id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'record_socialization', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_edit_socialization_record (US-067)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_edit_socialization_record(
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
  target_record public.socialization_records%rowtype;
  expected_revision integer;
  effective_date_value date;
  today_local date;
  response_value public.socialization_response;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'edit_socialization_record' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target_record from public.socialization_records
  where id = nullif(payload_input->>'record_id', '')::uuid
  for update;
  if not found or target_record.deleted_at is not null then
    raise exception 'socialization record not found' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.household_memberships hm
    where hm.household_id = target_record.household_id
      and hm.user_id = actor_id
      and hm.status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  -- DM §13: optimistic concurrency on `revision`. A stale write is rejected
  -- so the conflict can be surfaced with both versions rather than silently
  -- overwriting a co-caregiver's correction (US-055).
  expected_revision := nullif(payload_input->>'expected_revision', '')::integer;
  if expected_revision is null then
    raise exception 'expected_revision is required' using errcode = '22023';
  end if;
  if expected_revision <> target_record.revision then
    raise exception 'this record changed since you opened it' using errcode = '40001';
  end if;

  today_local := public.household_current_local_date(target_record.household_id, now());
  effective_date_value := coalesce(
    nullif(payload_input->>'effective_date', '')::date,
    target_record.effective_date
  );
  if effective_date_value > today_local then
    raise exception 'an experience cannot be recorded before it happens' using errcode = '22023';
  end if;

  if payload_input ? 'response' then
    begin
      response_value := (payload_input->>'response')::public.socialization_response;
    exception when invalid_text_representation then
      raise exception 'response must be one of relaxed, curious, neutral, hesitant, fearful'
        using errcode = '22023';
    end;
  else
    response_value := target_record.response;
  end if;

  -- What an edit may change is deliberately narrow: the observation itself.
  -- Re-pointing a record at a different experience or category would rewrite
  -- history rather than correct it -- remove and re-record instead.
  update public.socialization_records
  set effective_date = effective_date_value,
      response = response_value,
      context = case when payload_input ? 'context'
        then nullif(trim(payload_input->>'context'), '') else context end,
      note = case when payload_input ? 'note'
        then nullif(trim(payload_input->>'note'), '') else note end,
      media_refs = case when payload_input ? 'media_refs'
        then payload_input->'media_refs' else media_refs end,
      revision = target_record.revision + 1,
      updated_by = actor_id
  where id = target_record.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_record.household_id, actor_id,
    jsonb_build_object('type', 'socialization_record', 'id', target_record.id),
    'socialization.record_edited',
    jsonb_build_object(
      'pet_id', target_record.pet_id,
      'category', target_record.category,
      'previous_response', target_record.response,
      'response', response_value,
      'previous_effective_date', target_record.effective_date,
      'effective_date', effective_date_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object('record', public.socialization_record_json(target_record.id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'edit_socialization_record', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_remove_socialization_record (US-068 "Past records remain intact")
-- ---------------------------------------------------------------------------

create or replace function public.write_path_remove_socialization_record(
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
  target_record public.socialization_records%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'remove_socialization_record' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target_record from public.socialization_records
  where id = nullif(payload_input->>'record_id', '')::uuid
  for update;
  if not found then
    raise exception 'socialization record not found' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.household_memberships hm
    where hm.household_id = target_record.household_id
      and hm.user_id = actor_id
      and hm.status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  -- A recoverable tombstone (DM §13 "Deletes / archives"), not a DELETE: the
  -- row stays for the sync window and for history, and every read path in
  -- this migration filters on `deleted_at is null`.
  if target_record.deleted_at is null then
    update public.socialization_records
    set deleted_at = now(),
        deleted_by = actor_id,
        revision = target_record.revision + 1,
        updated_by = actor_id
    where id = target_record.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target_record.household_id, actor_id,
      jsonb_build_object('type', 'socialization_record', 'id', target_record.id),
      'socialization.record_removed',
      jsonb_build_object(
        'pet_id', target_record.pet_id,
        'category', target_record.category,
        'effective_date', target_record.effective_date
      ),
      recorded_at_input
    );
  end if;

  response := jsonb_build_object(
    'record', public.socialization_record_json(target_record.id, true)
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'remove_socialization_record', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_set_socialization_exclusion (US-068, TR-07)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_set_socialization_exclusion(
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
  category_value text;
  experience_id text;
  reason_value public.socialization_exclusion_reason;
  exclusion_id uuid;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'set_socialization_exclusion' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_pet := public.socialization_authorize_pet(
    actor_id, nullif(payload_input->>'pet_id', '')::uuid
  );

  category_value := nullif(payload_input->>'category', '');
  experience_id := nullif(payload_input->>'experience_content_id', '');

  if (category_value is null) = (experience_id is null) then
    raise exception 'supply exactly one of category or experience_content_id' using errcode = '22023';
  end if;
  if category_value is not null and not public.is_socialization_category(category_value) then
    raise exception 'category is not one of the eight socialization categories' using errcode = '22023';
  end if;

  begin
    reason_value := (payload_input->>'reason')::public.socialization_exclusion_reason;
  exception when invalid_text_representation then
    raise exception 'reason must be one of unavailable, unsuitable, paused' using errcode = '22023';
  end;
  if reason_value is null then
    raise exception 'reason is required' using errcode = '22023';
  end if;

  -- Re-marking an already-excluded scope updates the live decision rather
  -- than stacking rows the caregiver would have to clear one at a time.
  select id into exclusion_id
  from public.socialization_exclusions
  where pet_id = target_pet.id
    and cleared_at is null
    and category is not distinct from category_value
    and experience_content_id is not distinct from experience_id
  for update;

  if found then
    update public.socialization_exclusions
    set reason = reason_value,
        note = nullif(trim(payload_input->>'note'), ''),
        set_by = actor_id,
        set_at = now(),
        updated_by = actor_id
    where id = exclusion_id;
  else
    exclusion_id := coalesce(nullif(payload_input->>'exclusion_id', '')::uuid, gen_random_uuid());
    insert into public.socialization_exclusions (
      id, household_id, pet_id, category, experience_content_id, reason, note,
      set_by, created_by, updated_by
    ) values (
      exclusion_id, target_pet.household_id, target_pet.id, category_value, experience_id,
      reason_value, nullif(trim(payload_input->>'note'), ''), actor_id, actor_id, actor_id
    );
  end if;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_pet.household_id, actor_id,
    jsonb_build_object('type', 'socialization_exclusion', 'id', exclusion_id),
    'socialization.exclusion_set',
    jsonb_strip_nulls(jsonb_build_object(
      'pet_id', target_pet.id,
      'category', category_value,
      'experience_content_id', experience_id,
      'reason', reason_value
    )),
    recorded_at_input
  );

  response := jsonb_build_object('exclusion', public.socialization_exclusion_json(exclusion_id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'set_socialization_exclusion', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_clear_socialization_exclusion (US-068 "The choice can be reversed")
-- ---------------------------------------------------------------------------

create or replace function public.write_path_clear_socialization_exclusion(
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
  target_exclusion public.socialization_exclusions%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'clear_socialization_exclusion' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target_exclusion from public.socialization_exclusions
  where id = nullif(payload_input->>'exclusion_id', '')::uuid
  for update;
  if not found then
    raise exception 'socialization exclusion not found' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.household_memberships hm
    where hm.household_id = target_exclusion.household_id
      and hm.user_id = actor_id
      and hm.status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  if target_exclusion.cleared_at is null then
    update public.socialization_exclusions
    set cleared_at = now(), cleared_by = actor_id, updated_by = actor_id
    where id = target_exclusion.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target_exclusion.household_id, actor_id,
      jsonb_build_object('type', 'socialization_exclusion', 'id', target_exclusion.id),
      'socialization.exclusion_cleared',
      jsonb_strip_nulls(jsonb_build_object(
        'pet_id', target_exclusion.pet_id,
        'category', target_exclusion.category,
        'experience_content_id', target_exclusion.experience_content_id,
        'previous_reason', target_exclusion.reason
      )),
      recorded_at_input
    );
  end if;

  response := jsonb_build_object('exclusion', public.socialization_exclusion_json(target_exclusion.id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'clear_socialization_exclusion', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- Generation context (engine §12.3, catalogue §9)
-- ---------------------------------------------------------------------------

-- The predecessor migration hardcoded `excluded_socialization_categories` and
-- `excluded_content_ids` to `[]` with a header note explaining that the
-- SocializationExclusion entity did not exist. It does now, so this rewrite
-- replaces those two literals with real reads, and adds recorded experiences
-- to `recent_history` so category recency comes from what the household did
-- rather than from what the plan happened to show.
--
-- Still empty, and why (unchanged from 20260728000100):
--   * events         - no Event table exists.
--   * training_state - no TrainingGoal / TrainingSession tables exist.
create or replace function public.write_path_generation_context(
  actor_id uuid,
  target_pet_id uuid,
  capacity_override public.capacity_mode default null,
  at_instant timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
    -- No Event entity in this slice (see header).
    'events', '[]'::jsonb,
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
    -- No TrainingGoal entity in this slice (see header).
    'training_state', '[]'::jsonb,
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
  );

  return context;
end;
$$;

-- ---------------------------------------------------------------------------
-- SECURITY DEFINER lockdown
-- ---------------------------------------------------------------------------

-- Every write_path_* function trusts its actor_id argument, so only the edge
-- function's service role may call it.
revoke execute on function public.write_path_record_socialization(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_edit_socialization_record(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_remove_socialization_record(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_set_socialization_exclusion(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_clear_socialization_exclusion(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_generation_context(uuid, uuid, public.capacity_mode, timestamptz) from public, anon, authenticated;

grant execute on function public.write_path_record_socialization(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_edit_socialization_record(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_remove_socialization_record(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_set_socialization_exclusion(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_clear_socialization_exclusion(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_generation_context(uuid, uuid, public.capacity_mode, timestamptz) to service_role;

-- These bypass RLS to resolve display names and catalogue labels, so they are
-- service-role only as well; clients read the base tables through RLS.
revoke execute on function public.socialization_authorize_pet(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.socialization_record_json(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.socialization_exclusion_json(uuid) from public, anon, authenticated;
revoke execute on function public.socialization_record_guard() from public, anon, authenticated;
revoke execute on function public.socialization_exclusion_guard() from public, anon, authenticated;

grant execute on function public.socialization_authorize_pet(uuid, uuid) to service_role;
grant execute on function public.socialization_record_json(uuid, boolean) to service_role;
grant execute on function public.socialization_exclusion_json(uuid) to service_role;

-- `is_socialization_category` is a pure vocabulary predicate over a public
-- content list, and CHECK constraints on these tables evaluate it as the
-- inserting role, so it stays broadly executable.
grant execute on function public.is_socialization_category(text) to public;
