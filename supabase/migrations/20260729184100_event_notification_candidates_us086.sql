-- Event notification candidates (US-086).
--
-- Extends notification_candidates so Events can own reminder rows the same way
-- task occurrences do. write_path create/edit/cancel/archive refresh candidates:
-- reschedule cancels stale scheduled rows and inserts ones for the new start;
-- cancel/archive leave only cancelled candidates.
--
-- Does not implement APNs delivery — only candidate lifecycle hygiene.

-- ---------------------------------------------------------------------------
-- Schema: allow event-linked candidates alongside occurrence-linked ones
-- ---------------------------------------------------------------------------

alter type public.notification_candidate_class add value if not exists 'event_reminder';

alter table public.notification_candidates
  alter column occurrence_id drop not null;

alter table public.notification_candidates
  add column if not exists event_id uuid references public.events(id) on delete cascade;

alter table public.notification_candidates
  drop constraint if exists notification_candidates_source_xor;

alter table public.notification_candidates
  add constraint notification_candidates_source_xor check (
    (occurrence_id is not null and event_id is null)
    or (occurrence_id is null and event_id is not null)
  );

create index if not exists notification_candidates_event
  on public.notification_candidates (event_id, state)
  where event_id is not null;

comment on column public.notification_candidates.event_id is
  'Set for event_reminder candidates (US-086). Mutually exclusive with occurrence_id.';

comment on column public.events.reminder_config is
  'Lead times object, e.g. {"lead_minutes":[60,1440]}. write_path create/edit refresh event_reminder notification_candidates (US-086); APNs delivery is a later slice.';

-- ---------------------------------------------------------------------------
-- refresh_event_notification_candidates
-- Mirrors refresh_occurrence_notification_candidates for Event rows.
-- ---------------------------------------------------------------------------

create or replace function public.refresh_event_notification_candidates(
  target_event_id uuid
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  target_event public.events%rowtype;
  target_household public.households%rowtype;
  member_row record;
  lead_minutes integer;
  start_instant timestamptz;
  lead_source jsonb;
  candidate_count integer := 0;
  resolution text;
begin
  select * into target_event
  from public.events where id = target_event_id;
  if not found then
    return 0;
  end if;

  if target_event.deleted_at is not null then
    resolution := 'event_archived';
  elsif target_event.status = 'cancelled' then
    resolution := 'event_cancelled';
  else
    resolution := 'candidate_replaced';
  end if;

  update public.notification_candidates
  set state = 'cancelled',
      resolved_at = now(),
      resolution_reason = resolution,
      updated_at = now()
  where event_id = target_event.id
    and state = 'scheduled';

  if target_event.deleted_at is not null
     or target_event.status <> 'confirmed' then
    return 0;
  end if;

  select * into target_household
  from public.households
  where id = target_event.household_id and status = 'active';
  if not found then
    return 0;
  end if;

  if target_event.reminder_config is null then
    return 0;
  end if;

  lead_source := target_event.reminder_config->'lead_minutes';
  if lead_source is null
     or jsonb_typeof(lead_source) <> 'array'
     or jsonb_array_length(lead_source) = 0 then
    return 0;
  end if;

  if target_event.all_day or target_event.start_time is null then
    start_instant := public.resolve_household_wall_time(
      target_event.start_date,
      time '00:00',
      target_household.time_zone
    );
  else
    start_instant := public.resolve_household_wall_time(
      target_event.start_date,
      target_event.start_time,
      target_household.time_zone
    );
  end if;

  if start_instant is null then
    return 0;
  end if;

  for lead_minutes in
    select coalesce(value::integer, 0)
    from jsonb_array_elements_text(lead_source)
  loop
    if lead_minutes < 0 or lead_minutes > 10080 then
      raise exception 'reminder lead minutes must be between 0 and 10080'
        using errcode = '22023';
    end if;

    for member_row in
      select user_id
      from public.household_memberships
      where household_id = target_event.household_id
        and status = 'active'
    loop
      insert into public.notification_candidates (
        recipient_user_id, household_id, occurrence_id, event_id, class,
        source_ref, scheduled_for, dedupe_key
      ) values (
        member_row.user_id,
        target_event.household_id,
        null,
        target_event.id,
        'event_reminder',
        jsonb_build_object(
          'type', 'event',
          'id', target_event.id,
          'lead_minutes', lead_minutes
        ),
        start_instant - make_interval(mins => lead_minutes),
        'event_reminder:' || target_event.id::text || ':' ||
          member_row.user_id::text || ':' || lead_minutes::text || ':' ||
          extract(epoch from start_instant)::bigint::text
      )
      on conflict (dedupe_key) do update set
        state = 'scheduled',
        resolved_at = null,
        resolution_reason = null,
        scheduled_for = excluded.scheduled_for,
        source_ref = excluded.source_ref,
        event_id = excluded.event_id,
        occurrence_id = null,
        updated_at = now();
      candidate_count := candidate_count + 1;
    end loop;
  end loop;

  return candidate_count;
end;
$$;

revoke execute on function public.refresh_event_notification_candidates(uuid)
  from public, anon, authenticated;
grant execute on function public.refresh_event_notification_candidates(uuid)
  to service_role;

comment on function public.refresh_event_notification_candidates(uuid) is
  'Cancel scheduled event_reminder candidates and recreate for a confirmed event (US-086).';

-- ---------------------------------------------------------------------------
-- verify_due_notification_candidates — branch for event_reminder rows
-- ---------------------------------------------------------------------------

create or replace function public.verify_due_notification_candidates(
  at_instant timestamptz default now(),
  batch_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  due_count integer := 0;
  cancelled_count integer := 0;
  eligible_count integer := 0;
  candidate_row public.notification_candidates%rowtype;
  occurrence_row public.task_occurrences%rowtype;
  event_row public.events%rowtype;
  household_row public.households%rowtype;
  member_ok boolean;
  cancel_reason text;
  run_id uuid;
begin
  if batch_limit is null or batch_limit < 1 or batch_limit > 500 then
    batch_limit := 100;
  end if;

  for candidate_row in
    select *
    from public.notification_candidates
    where state = 'scheduled'
      and scheduled_for <= at_instant
    order by scheduled_for
    limit batch_limit
    for update skip locked
  loop
    due_count := due_count + 1;
    cancel_reason := null;

    if candidate_row.event_id is not null then
      select * into event_row
      from public.events where id = candidate_row.event_id;
      if not found then
        cancel_reason := 'event_missing';
      elsif event_row.deleted_at is not null then
        cancel_reason := 'event_archived';
      elsif event_row.status <> 'confirmed' then
        cancel_reason := 'event_' || event_row.status::text;
      else
        select * into household_row
        from public.households
        where id = candidate_row.household_id and status = 'active';
        if not found then
          cancel_reason := 'household_inactive';
        else
          select exists(
            select 1
            from public.household_memberships m
            where m.household_id = candidate_row.household_id
              and m.user_id = candidate_row.recipient_user_id
              and m.status = 'active'
          ) into member_ok;
          if not member_ok then
            cancel_reason := 'recipient_not_active_member';
          end if;
        end if;
      end if;
    else
      select * into occurrence_row
      from public.task_occurrences where id = candidate_row.occurrence_id;
      if not found then
        cancel_reason := 'occurrence_missing';
      elsif occurrence_row.state <> 'pending' then
        cancel_reason := 'occurrence_' || occurrence_row.state::text;
      else
        select * into household_row
        from public.households
        where id = candidate_row.household_id and status = 'active';
        if not found then
          cancel_reason := 'household_inactive';
        else
          select exists(
            select 1
            from public.household_memberships m
            where m.household_id = candidate_row.household_id
              and m.user_id = candidate_row.recipient_user_id
              and m.status = 'active'
          ) into member_ok;
          if not member_ok then
            cancel_reason := 'recipient_not_active_member';
          end if;
        end if;
      end if;
    end if;

    if cancel_reason is not null then
      update public.notification_candidates
      set state = 'cancelled',
          resolved_at = at_instant,
          resolution_reason = cancel_reason,
          updated_at = now()
      where id = candidate_row.id and state = 'scheduled';
      cancelled_count := cancelled_count + 1;
    else
      eligible_count := eligible_count + 1;
    end if;
  end loop;

  insert into public.notification_dispatch_runs (
    mode, outcome, due_count, verified_count, cancelled_count, eligible_count,
    detail, started_at, finished_at
  ) values (
    'verify_only',
    'ok',
    due_count,
    due_count,
    cancelled_count,
    eligible_count,
    jsonb_build_object('at_instant', at_instant),
    at_instant,
    now()
  )
  returning id into run_id;

  return jsonb_build_object(
    'run_id', run_id,
    'due_count', due_count,
    'cancelled_count', cancelled_count,
    'eligible_count', eligible_count
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- claim_due_notification_candidates — expose event_id for senders
-- ---------------------------------------------------------------------------

create or replace function public.claim_due_notification_candidates(
  at_instant timestamptz default now(),
  batch_limit integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  verify_result jsonb;
  eligible jsonb := '[]'::jsonb;
begin
  verify_result := public.verify_due_notification_candidates(at_instant, batch_limit);

  select coalesce(jsonb_agg(row_to_json(q)::jsonb order by q.scheduled_for), '[]'::jsonb)
  into eligible
  from (
    select
      nc.id as candidate_id,
      nc.recipient_user_id,
      nc.household_id,
      nc.occurrence_id,
      nc.event_id,
      nc.class,
      nc.source_ref,
      nc.scheduled_for,
      nc.dedupe_key,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', d.id,
          'token', d.token,
          'environment', d.environment,
          'platform', d.platform
        ) order by d.last_registered_at desc)
        from public.device_push_tokens d
        where d.user_id = nc.recipient_user_id
          and d.revoked_at is null
      ), '[]'::jsonb) as device_tokens
    from public.notification_candidates nc
    where nc.state = 'scheduled'
      and nc.scheduled_for <= at_instant
    order by nc.scheduled_for
    limit batch_limit
  ) q;

  return jsonb_build_object(
    'verify', verify_result,
    'candidates', eligible,
    'apns_required', true
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_create_event — schedule candidates after insert
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
  candidate_count integer := 0;
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

  candidate_count := public.refresh_event_notification_candidates(event_id);

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
      'pet_id', pet_id_value,
      'notification_candidates_scheduled', candidate_count
    ),
    recorded_at_input
  );

  response := jsonb_build_object(
    'event', public.event_json(event_id),
    'notification_candidates_scheduled', candidate_count
  );

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
-- write_path_edit_event — refresh after reschedule / reminder change
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
  candidate_count integer := 0;
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

  candidate_count := public.refresh_event_notification_candidates(target.id);

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
      'pet_id', pet_id_value,
      'notification_candidates_scheduled', candidate_count
    ),
    recorded_at_input
  );

  response := jsonb_build_object(
    'event', public.event_json(target.id),
    'notification_candidates_scheduled', candidate_count
  );

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
-- write_path_cancel_event — clear scheduled candidates
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
  candidate_count integer := 0;
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
    candidate_count := public.refresh_event_notification_candidates(target.id);
    response := jsonb_build_object(
      'event', public.event_json(target.id),
      'notification_candidates_scheduled', candidate_count
    );
  else
    update public.events
    set status = 'cancelled',
        revision = target.revision + 1,
        updated_by = actor_id
    where id = target.id;

    candidate_count := public.refresh_event_notification_candidates(target.id);

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target.household_id, actor_id,
      jsonb_build_object('type', 'event', 'id', target.id),
      'event.cancelled',
      jsonb_build_object(
        'title', target.title,
        'start_date', target.start_date,
        'notification_candidates_scheduled', candidate_count
      ),
      recorded_at_input
    );

    response := jsonb_build_object(
      'event', public.event_json(target.id),
      'notification_candidates_scheduled', candidate_count
    );
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
-- write_path_archive_event — clear scheduled candidates on soft delete
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
  candidate_count integer := 0;
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

  candidate_count := public.refresh_event_notification_candidates(target.id);

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target.household_id, actor_id,
    jsonb_build_object('type', 'event', 'id', target.id),
    'event.archived',
    jsonb_build_object(
      'title', target.title,
      'start_date', target.start_date,
      'notification_candidates_scheduled', candidate_count
    ),
    recorded_at_input
  );

  response := jsonb_build_object(
    'event', public.event_json(target.id, true),
    'notification_candidates_scheduled', candidate_count
  );

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
