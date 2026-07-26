-- Remaining Slice A write-path commands.
-- Each command owns its authorization, validation, mutation, disposition/audit
-- records, and command_log success envelope in one transaction.

create or replace function public.write_path_set_routine_preferences(
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
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));

  select * into existing
  from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;

  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'set_routine_preferences' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  if nullif(trim(payload_input->>'household_id'), '') is null then
    raise exception 'household_id is required' using errcode = '22023';
  end if;
  if not (payload_input ? 'routine_windows') or jsonb_typeof(payload_input->'routine_windows') <> 'object' then
    raise exception 'routine_windows must be an object' using errcode = '22023';
  end if;

  select * into target_household
  from public.households
  where id = (payload_input->>'household_id')::uuid and status = 'active';

  if not found or not exists (
    select 1
    from public.household_memberships
    where household_id = target_household.id and user_id = actor_id and status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  insert into public.household_preferences (
    household_id, routine_windows, meal_template_ref, default_capacity_mode,
    created_by, updated_by, updated_at
  )
  values (
    target_household.id,
    payload_input->'routine_windows',
    nullif(payload_input->>'meal_template_ref', ''),
    target_household.default_capacity_mode,
    actor_id,
    actor_id,
    recorded_at_input
  )
  on conflict (household_id) do update
  set routine_windows = excluded.routine_windows,
      meal_template_ref = excluded.meal_template_ref,
      updated_at = recorded_at_input,
      updated_by = actor_id;

  response := jsonb_build_object(
    'household_preferences',
    jsonb_build_object(
      'household_id', target_household.id,
      'routine_windows', payload_input->'routine_windows',
      'meal_template_ref', nullif(payload_input->>'meal_template_ref', '')
    )
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  )
  values (
    actor_id, idempotency_key, 'set_routine_preferences', payload_hash_input, request_body_input,
    response, 'succeeded', recorded_at_input, effective_at_input, now()
  );

  return response;
end;
$$;

create or replace function public.write_path_create_task(
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
  definition_id uuid;
  schedule_id uuid;
  occurrence_id uuid;
  due_date date;
  policy public.time_policy;
  assignment_value text;
  assignment_kind_value public.assignment_kind;
  assignment_user_id_value uuid;
  recurrence_value jsonb;
  occurrence_key_value text;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));

  select * into existing
  from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;

  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'create_task' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  if nullif(trim(payload_input->>'pet_id'), '') is null then
    raise exception 'pet_id is required' using errcode = '22023';
  end if;
  if nullif(trim(payload_input->>'title'), '') is null then
    raise exception 'title is required' using errcode = '22023';
  end if;
  if coalesce(payload_input->>'local_due_date', '') !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'local_due_date must be YYYY-MM-DD' using errcode = '22023';
  end if;
  if nullif(payload_input->>'time_policy', '') is null then
    raise exception 'time_policy is required' using errcode = '22023';
  end if;
  if nullif(payload_input->>'assignment', '') is null then
    raise exception 'assignment is required' using errcode = '22023';
  end if;

  select * into target_pet
  from public.pets
  where id = (payload_input->>'pet_id')::uuid and status = 'active' and deleted_at is null;

  if not found then
    raise exception 'active pet not found' using errcode = '22023';
  end if;
  if not exists (
    select 1
    from public.households h
    join public.household_memberships hm on hm.household_id = h.id
    where h.id = target_pet.household_id
      and h.status = 'active'
      and hm.user_id = actor_id
      and hm.status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  due_date := (payload_input->>'local_due_date')::date;
  policy := (payload_input->>'time_policy')::public.time_policy;
  assignment_value := payload_input->>'assignment';

  if policy = 'exact_time' then
    if coalesce(payload_input->>'exact_time', '') !~ '^([01]\d|2[0-3]):[0-5]\d$'
       or payload_input ? 'window_ref' then
      raise exception 'exact_time policy requires HH:MM exact_time and no window_ref' using errcode = '22023';
    end if;
  elsif policy = 'window' then
    if coalesce(payload_input->>'window_ref', '') not in ('morning', 'midday', 'afternoon', 'evening', 'sleep')
       or payload_input ? 'exact_time' then
      raise exception 'window policy requires a valid window_ref and no exact_time' using errcode = '22023';
    end if;
  elsif payload_input ? 'exact_time' or payload_input ? 'window_ref' then
    raise exception 'anytime policy does not accept exact_time or window_ref' using errcode = '22023';
  end if;

  if assignment_value in ('unassigned', 'anyone') then
    assignment_kind_value := assignment_value::public.assignment_kind;
    assignment_user_id_value := null;
  elsif assignment_value ~ '^member:[0-9a-fA-F-]{36}$' then
    assignment_kind_value := 'member';
    assignment_user_id_value := substring(assignment_value from 8)::uuid;
    if not exists (
      select 1 from public.household_memberships
      where household_id = target_pet.household_id
        and user_id = assignment_user_id_value
        and status = 'active'
    ) then
      raise exception 'assigned member must be active in the pet household' using errcode = '22023';
    end if;
  else
    raise exception 'assignment must be unassigned, anyone, or member:<user_uuid>' using errcode = '22023';
  end if;

  definition_id := coalesce(nullif(payload_input->>'task_definition_id', '')::uuid, gen_random_uuid());
  schedule_id := coalesce(nullif(payload_input->>'schedule_id', '')::uuid, gen_random_uuid());
  occurrence_id := coalesce(nullif(payload_input->>'occurrence_id', '')::uuid, gen_random_uuid());

  recurrence_value := jsonb_build_object(
    'type', 'once',
    'anchor_date', due_date,
    'time_policy', policy
  );
  if policy = 'exact_time' then
    recurrence_value := recurrence_value || jsonb_build_object('exact_time', payload_input->>'exact_time');
  elsif policy = 'window' then
    recurrence_value := recurrence_value || jsonb_build_object('window_ref', payload_input->>'window_ref');
  end if;

  occurrence_key_value := schedule_id::text || ':' || due_date::text;

  insert into public.task_definitions (
    id, provenance, household_id, title, category, default_obligation_class,
    default_effort, default_time_policy, created_by, updated_by
  )
  values (
    definition_id, 'user', target_pet.household_id, trim(payload_input->>'title'),
    'routine', 'scheduled', 'short', policy, actor_id, actor_id
  );

  insert into public.task_schedules (
    id, household_id, pet_id, task_definition_id, recurrence, assignment_kind,
    assignment_user_id, origin, obligation_class, active_range_start_date,
    active_range_until, created_by, updated_by
  )
  values (
    schedule_id, target_pet.household_id, target_pet.id, definition_id,
    recurrence_value, assignment_kind_value, assignment_user_id_value,
    'user_created', 'scheduled', due_date, due_date, actor_id, actor_id
  );

  insert into public.task_occurrences (
    id, occurrence_key, household_id, pet_id, schedule_id, local_due_date,
    original_local_due_date, time_policy, due_time, window_ref, assignment_kind,
    assignment_user_id, state, obligation_class, origin, created_by, updated_by
  )
  values (
    occurrence_id, occurrence_key_value, target_pet.household_id, target_pet.id,
    schedule_id, due_date, due_date, policy,
    case when policy = 'exact_time' then (payload_input->>'exact_time')::time else null end,
    case when policy = 'window' then payload_input->>'window_ref' else null end,
    assignment_kind_value, assignment_user_id_value, 'pending', 'scheduled',
    'user_created', actor_id, actor_id
  );

  response := jsonb_build_object(
    'task_definition', jsonb_build_object(
      'id', definition_id, 'provenance', 'user', 'household_id', target_pet.household_id,
      'title', trim(payload_input->>'title')
    ),
    'task_schedule', jsonb_build_object(
      'id', schedule_id, 'recurrence', recurrence_value, 'assignment', assignment_value,
      'obligation_class', 'scheduled'
    ),
    'task_occurrence', jsonb_build_object(
      'id', occurrence_id, 'occurrence_key', occurrence_key_value,
      'original_local_due_date', due_date, 'local_due_date', due_date,
      'state', 'pending', 'time_policy', policy
    )
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  )
  values (
    actor_id, idempotency_key, 'create_task', payload_hash_input, request_body_input,
    response, 'succeeded', recorded_at_input, effective_at_input, now()
  );

  return response;
end;
$$;

create or replace function public.write_path_complete_occurrence(
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
  current_completion public.dispositions%rowtype;
  disposition_id uuid := gen_random_uuid();
  effective_value timestamptz := coalesce(effective_at_input, recorded_at_input);
  new_superseded boolean := false;
  effective_completion_id uuid;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));

  select * into existing
  from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;

  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'complete_occurrence' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  if nullif(trim(payload_input->>'occurrence_id'), '') is null then
    raise exception 'occurrence_id is required' using errcode = '22023';
  end if;
  if effective_value > recorded_at_input + interval '5 minutes'
     or effective_value < recorded_at_input - interval '7 days' then
    raise exception 'effective_at must be between recorded_at - 7 days and recorded_at + 5 minutes' using errcode = '22023';
  end if;

  select * into target_occurrence
  from public.task_occurrences
  where id = (payload_input->>'occurrence_id')::uuid
    and deleted_at is null
  for update;

  if not found or not exists (
    select 1
    from public.households h
    join public.household_memberships hm on hm.household_id = h.id
    where h.id = target_occurrence.household_id
      and h.status = 'active'
      and hm.user_id = actor_id
      and hm.status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;
  if target_occurrence.state not in ('pending', 'completed') then
    raise exception 'only a pending or completed occurrence can be completed' using errcode = '22023';
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
  )
  values (
    disposition_id, target_occurrence.household_id, target_occurrence.id, 'complete',
    actor_id, recorded_at_input, effective_value, nullif(payload_input->>'note', ''),
    idempotency_key, new_superseded
  );

  update public.task_occurrences
  set state = 'completed',
      revision = revision + 1,
      updated_at = recorded_at_input,
      updated_by = actor_id
  where id = target_occurrence.id;

  if effective_value < recorded_at_input then
    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at, reason
    )
    values (
      target_occurrence.household_id,
      actor_id,
      jsonb_build_object('type', 'task_occurrence', 'id', target_occurrence.id),
      'completion.backdated',
      jsonb_build_object(
        'disposition_id', disposition_id,
        'recorded_at', recorded_at_input,
        'effective_at', effective_value,
        'superseded', new_superseded
      ),
      recorded_at_input,
      nullif(payload_input->>'note', '')
    );
  end if;

  response := jsonb_build_object(
    'occurrence', jsonb_build_object(
      'id', target_occurrence.id, 'state', 'completed',
      'effective_completion_id', effective_completion_id
    ),
    'disposition', jsonb_build_object(
      'id', disposition_id, 'action', 'complete', 'actor_user_id', actor_id,
      'recorded_at', recorded_at_input, 'effective_at', effective_value,
      'superseded', new_superseded
    )
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  )
  values (
    actor_id, idempotency_key, 'complete_occurrence', payload_hash_input, request_body_input,
    response, 'succeeded', recorded_at_input, effective_value, now()
  );

  return response;
end;
$$;

create or replace function public.write_path_undo_completion(
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
  cleared_completion_id uuid;
  disposition_id uuid := gen_random_uuid();
  effective_value timestamptz := coalesce(effective_at_input, recorded_at_input);
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));

  select * into existing
  from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;

  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'undo_completion' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;
  if nullif(trim(payload_input->>'occurrence_id'), '') is null then
    raise exception 'occurrence_id is required' using errcode = '22023';
  end if;
  if effective_value > recorded_at_input + interval '5 minutes'
     or effective_value < recorded_at_input - interval '7 days' then
    raise exception 'effective_at must be between recorded_at - 7 days and recorded_at + 5 minutes' using errcode = '22023';
  end if;

  select * into target_occurrence
  from public.task_occurrences
  where id = (payload_input->>'occurrence_id')::uuid and deleted_at is null
  for update;

  if not found or not exists (
    select 1
    from public.households h
    join public.household_memberships hm on hm.household_id = h.id
    where h.id = target_occurrence.household_id
      and h.status = 'active'
      and hm.user_id = actor_id
      and hm.status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  update public.dispositions
  set superseded = true
  where occurrence_id = target_occurrence.id
    and action = 'complete'
    and superseded = false
  returning id into cleared_completion_id;

  insert into public.dispositions (
    id, household_id, occurrence_id, action, actor_user_id, recorded_at,
    effective_at, note, client_idempotency_key
  )
  values (
    disposition_id, target_occurrence.household_id, target_occurrence.id,
    'undo_complete', actor_id, recorded_at_input, effective_value,
    nullif(payload_input->>'note', ''), idempotency_key
  );

  update public.task_occurrences
  set state = 'pending',
      revision = revision + 1,
      updated_at = recorded_at_input,
      updated_by = actor_id
  where id = target_occurrence.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at, reason
  )
  values (
    target_occurrence.household_id,
    actor_id,
    jsonb_build_object('type', 'task_occurrence', 'id', target_occurrence.id),
    'completion.undone',
    jsonb_build_object(
      'undo_disposition_id', disposition_id,
      'cleared_completion_id', cleared_completion_id,
      'state_before', target_occurrence.state,
      'state_after', 'pending'
    ),
    recorded_at_input,
    nullif(payload_input->>'note', '')
  );

  response := jsonb_build_object(
    'occurrence', jsonb_build_object(
      'id', target_occurrence.id, 'state', 'pending',
      'effective_completion_id', null
    ),
    'disposition', jsonb_build_object(
      'id', disposition_id, 'action', 'undo_complete',
      'actor_user_id', actor_id, 'recorded_at', recorded_at_input,
      'effective_at', effective_value
    ),
    'cleared_completion_id', cleared_completion_id
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  )
  values (
    actor_id, idempotency_key, 'undo_completion', payload_hash_input, request_body_input,
    response, 'succeeded', recorded_at_input, effective_value, now()
  );

  return response;
end;
$$;

create or replace function public.write_path_skip_item(
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
  disposition_id uuid := gen_random_uuid();
  effective_value timestamptz := coalesce(effective_at_input, recorded_at_input);
  skip_reason_value public.skip_reason;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));

  select * into existing
  from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;

  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'skip_item' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;
  if nullif(trim(payload_input->>'occurrence_id'), '') is null then
    raise exception 'occurrence_id is required' using errcode = '22023';
  end if;
  if effective_value > recorded_at_input + interval '5 minutes'
     or effective_value < recorded_at_input - interval '7 days' then
    raise exception 'effective_at must be between recorded_at - 7 days and recorded_at + 5 minutes' using errcode = '22023';
  end if;

  select * into target_occurrence
  from public.task_occurrences
  where id = (payload_input->>'occurrence_id')::uuid and deleted_at is null
  for update;

  if not found or not exists (
    select 1
    from public.households h
    join public.household_memberships hm on hm.household_id = h.id
    where h.id = target_occurrence.household_id
      and h.status = 'active'
      and hm.user_id = actor_id
      and hm.status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;
  if target_occurrence.state not in ('pending', 'skipped') then
    raise exception 'only a pending or skipped occurrence can be skipped' using errcode = '22023';
  end if;
  if target_occurrence.obligation_class = 'required'
     and coalesce((payload_input->>'confirm_required')::boolean, false) is not true then
    raise exception 'required occurrence skip requires confirm_required=true' using errcode = 'PC001';
  end if;

  skip_reason_value := nullif(payload_input->>'skip_reason', '')::public.skip_reason;

  insert into public.dispositions (
    id, household_id, occurrence_id, action, actor_user_id, recorded_at,
    effective_at, note, skip_reason, client_idempotency_key
  )
  values (
    disposition_id, target_occurrence.household_id, target_occurrence.id, 'skip',
    actor_id, recorded_at_input, effective_value, nullif(payload_input->>'note', ''),
    skip_reason_value, idempotency_key
  );

  update public.task_occurrences
  set state = 'skipped',
      revision = revision + 1,
      updated_at = recorded_at_input,
      updated_by = actor_id
  where id = target_occurrence.id;

  response := jsonb_build_object(
    'occurrence', jsonb_build_object('id', target_occurrence.id, 'state', 'skipped'),
    'disposition', jsonb_build_object(
      'id', disposition_id, 'action', 'skip', 'actor_user_id', actor_id,
      'recorded_at', recorded_at_input, 'effective_at', effective_value,
      'skip_reason', skip_reason_value
    )
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  )
  values (
    actor_id, idempotency_key, 'skip_item', payload_hash_input, request_body_input,
    response, 'succeeded', recorded_at_input, effective_value, now()
  );

  return response;
end;
$$;

-- SECURITY DEFINER RPC lockdown. The edge function derives actor_id from the
-- verified JWT; clients must never be able to spoof it by calling RPC directly.
revoke execute on function public.write_path_set_routine_preferences(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_create_task(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_complete_occurrence(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_undo_completion(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_skip_item(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;

grant execute on function public.write_path_set_routine_preferences(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_create_task(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_complete_occurrence(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_undo_completion(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_skip_item(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
