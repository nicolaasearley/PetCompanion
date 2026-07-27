-- Slice B idempotent coordination write commands.

create or replace function public.write_path_create_recurring_task(
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
  created_schedule_id uuid;
  first_occurrence_id uuid;
  recurrence_value jsonb;
  assignment_value text;
  assignment_kind_value public.assignment_kind;
  assignment_user_id_value uuid;
  category_value public.task_category;
  obligation_value public.obligation_class;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'create_recurring_task' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target_pet from public.pets
  where id = (payload_input->>'pet_id')::uuid
    and status = 'active' and deleted_at is null;
  if not found or not exists (
    select 1 from public.households h
    join public.household_memberships hm on hm.household_id = h.id
    where h.id = target_pet.household_id and h.status = 'active'
      and hm.user_id = actor_id and hm.status = 'active'
  ) then
    raise exception 'active pet and household membership required' using errcode = '42501';
  end if;
  if nullif(trim(payload_input->>'title'), '') is null
     or not public.recurrence_rule_is_valid(payload_input->'recurrence') then
    raise exception 'title and a supported recurrence rule are required' using errcode = '22023';
  end if;
  if payload_input ? 'reminder_config'
     and jsonb_typeof(payload_input->'reminder_config') <> 'object' then
    raise exception 'reminder_config must be an object' using errcode = '22023';
  end if;

  assignment_value := payload_input->>'assignment';
  if assignment_value in ('unassigned', 'anyone') then
    assignment_kind_value := assignment_value::public.assignment_kind;
  elsif assignment_value ~ '^member:[0-9a-fA-F-]{36}$' then
    assignment_kind_value := 'member';
    assignment_user_id_value := substring(assignment_value from 8)::uuid;
    if not exists (
      select 1 from public.household_memberships
      where household_id = target_pet.household_id
        and user_id = assignment_user_id_value and status = 'active'
    ) then
      raise exception 'assigned member must be active in the pet household' using errcode = '22023';
    end if;
  else
    raise exception 'assignment is invalid' using errcode = '22023';
  end if;

  recurrence_value := payload_input->'recurrence';
  definition_id := coalesce(nullif(payload_input->>'task_definition_id', '')::uuid, gen_random_uuid());
  created_schedule_id := coalesce(nullif(payload_input->>'schedule_id', '')::uuid, gen_random_uuid());
  category_value := coalesce(nullif(payload_input->>'category', '')::public.task_category, 'routine');
  obligation_value := coalesce(
    nullif(payload_input->>'obligation_class', '')::public.obligation_class, 'scheduled'
  );
  if obligation_value not in ('required', 'scheduled') then
    raise exception 'obligation_class must be required or scheduled' using errcode = '22023';
  end if;

  insert into public.task_definitions (
    id, provenance, household_id, title, category, default_obligation_class,
    default_effort, default_time_policy, created_by, updated_by
  ) values (
    definition_id, 'user', target_pet.household_id, trim(payload_input->>'title'),
    category_value, obligation_value, 'short',
    (recurrence_value->>'time_policy')::public.time_policy, actor_id, actor_id
  );

  insert into public.task_schedules (
    id, household_id, pet_id, task_definition_id, recurrence,
    assignment_kind, assignment_user_id, origin, obligation_class,
    reminder_config, active_range_start_date, active_range_until,
    created_by, updated_by
  ) values (
    created_schedule_id, target_pet.household_id, target_pet.id, definition_id,
    recurrence_value, assignment_kind_value, assignment_user_id_value,
    'user_created', obligation_value, payload_input->'reminder_config',
    (recurrence_value->>'anchor_date')::date,
    nullif(recurrence_value->>'until', '')::date,
    actor_id, actor_id
  );

  if recurrence_value->>'type' = 'interval_after_completion' then
    first_occurrence_id := gen_random_uuid();
    insert into public.task_occurrences (
      id, occurrence_key, household_id, pet_id, schedule_id, local_due_date,
      original_local_due_date, time_policy, due_time, window_ref,
      assignment_kind, assignment_user_id, state, obligation_class, origin,
      origin_ref, created_by, updated_by
    ) values (
      first_occurrence_id, created_schedule_id::text || ':ordinal:1',
      target_pet.household_id, target_pet.id, created_schedule_id,
      (recurrence_value->>'anchor_date')::date,
      (recurrence_value->>'anchor_date')::date,
      (recurrence_value->>'time_policy')::public.time_policy,
      case when recurrence_value->>'time_policy' = 'exact_time'
        then (recurrence_value->>'exact_time')::time end,
      case when recurrence_value->>'time_policy' = 'window'
        then recurrence_value->>'window_ref' end,
      assignment_kind_value, assignment_user_id_value, 'pending',
      obligation_value, 'user_created',
      jsonb_build_object('interval_ordinal', 1), actor_id, actor_id
    );
  else
    perform public.write_path_materialize_occurrences(
      actor_id, target_pet.id, (recurrence_value->>'anchor_date')::date, 14
    );
  end if;

  response := jsonb_build_object(
    'task_definition', jsonb_build_object(
      'id', definition_id, 'revision', 1, 'title', trim(payload_input->>'title')
    ),
    'task_schedule', (
      select to_jsonb(s) from public.task_schedules s where s.id = created_schedule_id
    ),
    'occurrences', coalesce((
      select jsonb_agg(to_jsonb(o) order by o.local_due_date, o.occurrence_key)
      from public.task_occurrences o where o.schedule_id = created_schedule_id
    ), '[]'::jsonb)
  );
  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'create_recurring_task', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );
  return response;
end;
$$;

create or replace function public.write_path_edit_occurrence(
  actor_id uuid, idempotency_key text, payload_hash_input text,
  request_body_input jsonb, recorded_at_input timestamptz,
  effective_at_input timestamptz, payload_input jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.command_log%rowtype;
  target_occurrence public.task_occurrences%rowtype;
  target_schedule public.task_schedules%rowtype;
  target_definition public.task_definitions%rowtype;
  assignment_value text;
  assignment_kind_value public.assignment_kind;
  assignment_user_id_value uuid;
  policy public.time_policy;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'edit_occurrence' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target_occurrence from public.task_occurrences
  where id = (payload_input->>'occurrence_id')::uuid and deleted_at is null for update;
  if not found or not exists (
    select 1 from public.household_memberships
    where household_id = target_occurrence.household_id
      and user_id = actor_id and status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;
  if target_occurrence.revision <> (payload_input->>'expected_revision')::integer then
    raise exception 'occurrence revision conflict' using errcode = '40001';
  end if;
  if target_occurrence.state not in ('pending', 'skipped') then
    raise exception 'only an active occurrence can be edited' using errcode = '22023';
  end if;

  select * into target_schedule from public.task_schedules where id = target_occurrence.schedule_id;
  select * into target_definition from public.task_definitions where id = target_schedule.task_definition_id;
  if target_schedule.origin = 'health_schedule' then
    raise exception 'health schedules must be edited through their owning record' using errcode = '22023';
  end if;
  if payload_input ? 'title' then
    if target_schedule.recurrence->>'type' <> 'once' or target_definition.provenance <> 'user' then
      raise exception 'rename a recurring task with this-and-future edit' using errcode = '22023';
    end if;
    update public.task_definitions
    set title = trim(payload_input->>'title'), revision = revision + 1,
        updated_at = recorded_at_input, updated_by = actor_id
    where id = target_definition.id;
  end if;

  assignment_kind_value := target_occurrence.assignment_kind;
  assignment_user_id_value := target_occurrence.assignment_user_id;
  if payload_input ? 'assignment' then
    assignment_value := payload_input->>'assignment';
    if assignment_value in ('unassigned', 'anyone') then
      assignment_kind_value := assignment_value::public.assignment_kind;
      assignment_user_id_value := null;
    elsif assignment_value ~ '^member:[0-9a-fA-F-]{36}$' then
      assignment_kind_value := 'member';
      assignment_user_id_value := substring(assignment_value from 8)::uuid;
      if not exists (
        select 1 from public.household_memberships
        where household_id = target_occurrence.household_id
          and user_id = assignment_user_id_value and status = 'active'
      ) then
        raise exception 'assigned member must be active in the household' using errcode = '22023';
      end if;
    else
      raise exception 'assignment is invalid' using errcode = '22023';
    end if;
  end if;

  policy := coalesce(nullif(payload_input->>'time_policy', '')::public.time_policy, target_occurrence.time_policy);
  update public.task_occurrences
  set time_policy = policy,
      due_time = case
        when policy = 'exact_time' then coalesce(nullif(payload_input->>'exact_time', '')::time, target_occurrence.due_time)
        else null
      end,
      window_ref = case
        when policy = 'window' then coalesce(nullif(payload_input->>'window_ref', ''), target_occurrence.window_ref)
        else null
      end,
      assignment_kind = assignment_kind_value,
      assignment_user_id = assignment_user_id_value,
      revision = revision + 1,
      updated_at = recorded_at_input,
      updated_by = actor_id
  where id = target_occurrence.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at, reason
  ) values (
    target_occurrence.household_id, actor_id,
    jsonb_build_object('type', 'task_occurrence', 'id', target_occurrence.id),
    'occurrence.edited',
    jsonb_build_object(
      'previous_revision', target_occurrence.revision,
      'new_revision', target_occurrence.revision + 1,
      'title_changed', payload_input ? 'title',
      'time_changed', payload_input ? 'time_policy',
      'assignment_changed', payload_input ? 'assignment'
    ),
    recorded_at_input, nullif(payload_input->>'note', '')
  );
  response := jsonb_build_object(
    'occurrence', (select to_jsonb(o) from public.task_occurrences o where o.id = target_occurrence.id),
    'task_definition', (select to_jsonb(td) from public.task_definitions td where td.id = target_definition.id)
  );
  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'edit_occurrence', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );
  return response;
end;
$$;

create or replace function public.write_path_cancel_occurrence(
  actor_id uuid, idempotency_key text, payload_hash_input text,
  request_body_input jsonb, recorded_at_input timestamptz,
  effective_at_input timestamptz, payload_input jsonb
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
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'cancel_occurrence' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target_occurrence from public.task_occurrences
  where id = (payload_input->>'occurrence_id')::uuid and deleted_at is null for update;
  if not found or not exists (
    select 1 from public.household_memberships
    where household_id = target_occurrence.household_id
      and user_id = actor_id and status = 'active'
  ) then raise exception 'active household membership required' using errcode = '42501'; end if;
  if target_occurrence.revision <> (payload_input->>'expected_revision')::integer then
    raise exception 'occurrence revision conflict' using errcode = '40001';
  end if;
  if target_occurrence.state not in ('pending', 'skipped') then
    raise exception 'only an active occurrence can be cancelled' using errcode = '22023';
  end if;
  if target_occurrence.obligation_class = 'required'
     and coalesce((payload_input->>'confirm_required')::boolean, false) is not true then
    raise exception 'required occurrence cancellation needs confirmation' using errcode = 'PC001';
  end if;

  insert into public.dispositions (
    id, household_id, occurrence_id, action, actor_user_id, recorded_at,
    effective_at, note, client_idempotency_key
  ) values (
    disposition_id, target_occurrence.household_id, target_occurrence.id,
    'cancel', actor_id, recorded_at_input,
    coalesce(effective_at_input, recorded_at_input),
    nullif(payload_input->>'note', ''), idempotency_key
  );
  update public.task_occurrences
  set state = 'cancelled', revision = revision + 1,
      updated_at = recorded_at_input, updated_by = actor_id
  where id = target_occurrence.id;
  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at, reason
  ) values (
    target_occurrence.household_id, actor_id,
    jsonb_build_object('type', 'task_occurrence', 'id', target_occurrence.id),
    'occurrence.cancelled',
    jsonb_build_object('previous_revision', target_occurrence.revision),
    recorded_at_input, nullif(payload_input->>'note', '')
  );

  response := jsonb_build_object(
    'occurrence', (select to_jsonb(o) from public.task_occurrences o where o.id = target_occurrence.id),
    'disposition', (select to_jsonb(d) from public.dispositions d where d.id = disposition_id)
  );
  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'cancel_occurrence', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );
  return response;
end;
$$;

create or replace function public.write_path_snooze_occurrence(
  actor_id uuid, idempotency_key text, payload_hash_input text,
  request_body_input jsonb, recorded_at_input timestamptz,
  effective_at_input timestamptz, payload_input jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.command_log%rowtype;
  target_occurrence public.task_occurrences%rowtype;
  target_household public.households%rowtype;
  disposition_id uuid := gen_random_uuid();
  snooze_value timestamptz;
  candidate_count integer;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'snooze_occurrence' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;
  select * into target_occurrence from public.task_occurrences
  where id = (payload_input->>'occurrence_id')::uuid and deleted_at is null for update;
  if not found or target_occurrence.state <> 'pending' or not exists (
    select 1 from public.household_memberships
    where household_id = target_occurrence.household_id
      and user_id = actor_id and status = 'active'
  ) then raise exception 'active pending occurrence and membership required' using errcode = '42501'; end if;
  select * into target_household from public.households where id = target_occurrence.household_id;
  snooze_value := (payload_input->>'snooze_until')::timestamptz;
  if snooze_value <= recorded_at_input
     or (snooze_value at time zone target_household.time_zone)::date
        <> (recorded_at_input at time zone target_household.time_zone)::date
     or target_occurrence.local_due_date
        <> (recorded_at_input at time zone target_household.time_zone)::date then
    raise exception 'snooze_until must be later today in the household time zone' using errcode = '22023';
  end if;

  insert into public.dispositions (
    id, household_id, occurrence_id, action, actor_user_id, recorded_at,
    effective_at, note, snooze_until, client_idempotency_key
  ) values (
    disposition_id, target_occurrence.household_id, target_occurrence.id,
    'snooze', actor_id, recorded_at_input, recorded_at_input,
    nullif(payload_input->>'note', ''), snooze_value, idempotency_key
  );
  update public.plan_items pi
  set display_state = 'snoozed', updated_at = now()
  from public.plans p
  where pi.plan_id = p.id and p.status = 'open'
    and pi.occurrence_id = target_occurrence.id;
  candidate_count := public.refresh_occurrence_notification_candidates(
    target_occurrence.id, snooze_value
  );
  response := jsonb_build_object(
    'occurrence', to_jsonb(target_occurrence),
    'disposition', (select to_jsonb(d) from public.dispositions d where d.id = disposition_id),
    'notification_candidates_scheduled', candidate_count
  );
  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'snooze_occurrence', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );
  return response;
end;
$$;

create or replace function public.write_path_reschedule_occurrence(
  actor_id uuid, idempotency_key text, payload_hash_input text,
  request_body_input jsonb, recorded_at_input timestamptz,
  effective_at_input timestamptz, payload_input jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.command_log%rowtype;
  target_occurrence public.task_occurrences%rowtype;
  target_schedule public.task_schedules%rowtype;
  disposition_id uuid := gen_random_uuid();
  new_date date;
  policy public.time_policy;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'reschedule_occurrence' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;
  select * into target_occurrence from public.task_occurrences
  where id = (payload_input->>'occurrence_id')::uuid and deleted_at is null for update;
  if not found or target_occurrence.state <> 'pending' or not exists (
    select 1 from public.household_memberships
    where household_id = target_occurrence.household_id
      and user_id = actor_id and status = 'active'
  ) then raise exception 'active pending occurrence and membership required' using errcode = '42501'; end if;
  if target_occurrence.revision <> (payload_input->>'expected_revision')::integer then
    raise exception 'occurrence revision conflict' using errcode = '40001';
  end if;
  select * into target_schedule from public.task_schedules where id = target_occurrence.schedule_id;
  if target_schedule.origin = 'health_schedule' then
    raise exception 'health schedules must be rescheduled through their owning record' using errcode = '22023';
  end if;
  new_date := (payload_input->>'local_due_date')::date;
  if target_schedule.recurrence->>'type' <> 'once' and (
    new_date < target_schedule.active_range_start_date
    or (target_schedule.active_range_until is not null and new_date > target_schedule.active_range_until)
  ) then
    raise exception 'rescheduled date must remain in the schedule active range' using errcode = '22023';
  end if;
  if target_schedule.recurrence->>'type' = 'once' then
    update public.task_schedules
    set active_range_start_date = least(active_range_start_date, new_date),
        active_range_until = greatest(active_range_until, new_date),
        revision = revision + 1, updated_at = recorded_at_input, updated_by = actor_id
    where id = target_schedule.id;
  end if;
  policy := coalesce(nullif(payload_input->>'time_policy', '')::public.time_policy, target_occurrence.time_policy);

  insert into public.dispositions (
    id, household_id, occurrence_id, action, actor_user_id, recorded_at,
    effective_at, note, reschedule_to, client_idempotency_key
  ) values (
    disposition_id, target_occurrence.household_id, target_occurrence.id,
    'reschedule', actor_id, recorded_at_input, recorded_at_input,
    nullif(payload_input->>'note', ''), new_date, idempotency_key
  );
  update public.task_occurrences
  set local_due_date = new_date,
      time_policy = policy,
      due_time = case when policy = 'exact_time'
        then coalesce(nullif(payload_input->>'exact_time', '')::time, target_occurrence.due_time) end,
      window_ref = case when policy = 'window'
        then coalesce(nullif(payload_input->>'window_ref', ''), target_occurrence.window_ref) end,
      revision = revision + 1, updated_at = recorded_at_input, updated_by = actor_id
  where id = target_occurrence.id;
  update public.plan_items pi
  set display_state = 'rescheduled', updated_at = now()
  from public.plans p
  where pi.plan_id = p.id and p.status = 'open'
    and pi.occurrence_id = target_occurrence.id
    and p.local_date <> new_date;
  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at, reason
  ) values (
    target_occurrence.household_id, actor_id,
    jsonb_build_object('type', 'task_occurrence', 'id', target_occurrence.id),
    'occurrence.rescheduled',
    jsonb_build_object(
      'from_date', target_occurrence.local_due_date, 'to_date', new_date,
      'previous_revision', target_occurrence.revision,
      'new_revision', target_occurrence.revision + 1
    ), recorded_at_input, nullif(payload_input->>'note', '')
  );
  response := jsonb_build_object(
    'occurrence', (select to_jsonb(o) from public.task_occurrences o where o.id = target_occurrence.id),
    'disposition', (select to_jsonb(d) from public.dispositions d where d.id = disposition_id)
  );
  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'reschedule_occurrence', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );
  return response;
end;
$$;

create or replace function public.write_path_undo_skip(
  actor_id uuid, idempotency_key text, payload_hash_input text,
  request_body_input jsonb, recorded_at_input timestamptz,
  effective_at_input timestamptz, payload_input jsonb
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
  cleared_skip_ids jsonb;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'undo_skip' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;
  select * into target_occurrence from public.task_occurrences
  where id = (payload_input->>'occurrence_id')::uuid and deleted_at is null for update;
  if not found or not exists (
    select 1 from public.household_memberships
    where household_id = target_occurrence.household_id
      and user_id = actor_id and status = 'active'
  ) then raise exception 'active household membership required' using errcode = '42501'; end if;
  if target_occurrence.state <> 'skipped' then
    raise exception 'only a skipped occurrence can be restored' using errcode = '22023';
  end if;
  with cleared as (
    update public.dispositions set superseded = true
    where occurrence_id = target_occurrence.id and action = 'skip' and not superseded
    returning id
  )
  select coalesce(jsonb_agg(id), '[]'::jsonb) into cleared_skip_ids from cleared;
  insert into public.dispositions (
    id, household_id, occurrence_id, action, actor_user_id, recorded_at,
    effective_at, note, client_idempotency_key
  ) values (
    disposition_id, target_occurrence.household_id, target_occurrence.id,
    'undo_skip', actor_id, recorded_at_input,
    coalesce(effective_at_input, recorded_at_input),
    nullif(payload_input->>'note', ''), idempotency_key
  );
  update public.task_occurrences
  set state = 'pending', revision = revision + 1,
      updated_at = recorded_at_input, updated_by = actor_id
  where id = target_occurrence.id;
  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at, reason
  ) values (
    target_occurrence.household_id, actor_id,
    jsonb_build_object('type', 'task_occurrence', 'id', target_occurrence.id),
    'skip.undone', jsonb_build_object('cleared_skip_ids', cleared_skip_ids),
    recorded_at_input, nullif(payload_input->>'note', '')
  );
  response := jsonb_build_object(
    'occurrence', (select to_jsonb(o) from public.task_occurrences o where o.id = target_occurrence.id),
    'disposition', (select to_jsonb(d) from public.dispositions d where d.id = disposition_id),
    'cleared_skip_ids', cleared_skip_ids
  );
  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'undo_skip', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );
  return response;
end;
$$;

create or replace function public.write_path_edit_schedule_future(
  actor_id uuid, idempotency_key text, payload_hash_input text,
  request_body_input jsonb, recorded_at_input timestamptz,
  effective_at_input timestamptz, payload_input jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.command_log%rowtype;
  target_schedule public.task_schedules%rowtype;
  target_definition public.task_definitions%rowtype;
  successor_schedule_id uuid;
  successor_definition_id uuid;
  recurrence_value jsonb;
  split_date_value date;
  assignment_value text;
  assignment_kind_value public.assignment_kind;
  assignment_user_id_value uuid;
  cancelled_count integer;
  cancelled_occurrences jsonb;
  first_occurrence_id uuid;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'edit_schedule_future' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;
  select * into target_schedule from public.task_schedules
  where id = (payload_input->>'schedule_id')::uuid and deleted_at is null for update;
  if not found or not exists (
    select 1 from public.household_memberships
    where household_id = target_schedule.household_id
      and user_id = actor_id and status = 'active'
  ) then raise exception 'active household membership required' using errcode = '42501'; end if;
  if target_schedule.revision <> (payload_input->>'expected_revision')::integer then
    raise exception 'schedule revision conflict' using errcode = '40001';
  end if;
  if target_schedule.status <> 'active' or target_schedule.origin = 'health_schedule' then
    raise exception 'only an active non-health schedule can be split' using errcode = '22023';
  end if;
  select * into target_definition from public.task_definitions
  where id = target_schedule.task_definition_id;
  if target_definition.provenance <> 'user' then
    raise exception 'system-managed schedules must be changed through their owning settings' using errcode = '22023';
  end if;
  recurrence_value := payload_input->'recurrence';
  if not public.recurrence_rule_is_valid(recurrence_value) then
    raise exception 'unsupported recurrence rule' using errcode = '22023';
  end if;
  split_date_value := (payload_input->>'split_date')::date;
  if (recurrence_value->>'anchor_date')::date <> split_date_value
     or split_date_value < target_schedule.active_range_start_date then
    raise exception 'successor recurrence must anchor on a valid split date' using errcode = '22023';
  end if;

  assignment_kind_value := target_schedule.assignment_kind;
  assignment_user_id_value := target_schedule.assignment_user_id;
  if payload_input ? 'assignment' then
    assignment_value := payload_input->>'assignment';
    if assignment_value in ('unassigned', 'anyone') then
      assignment_kind_value := assignment_value::public.assignment_kind;
      assignment_user_id_value := null;
    elsif assignment_value ~ '^member:[0-9a-fA-F-]{36}$' then
      assignment_kind_value := 'member';
      assignment_user_id_value := substring(assignment_value from 8)::uuid;
      if not exists (
        select 1 from public.household_memberships
        where household_id = target_schedule.household_id
          and user_id = assignment_user_id_value and status = 'active'
      ) then
        raise exception 'assigned member must be active in the household' using errcode = '22023';
      end if;
    else raise exception 'assignment is invalid' using errcode = '22023';
    end if;
  end if;

  successor_schedule_id := coalesce(
    nullif(payload_input->>'successor_schedule_id', '')::uuid, gen_random_uuid()
  );
  successor_definition_id := target_definition.id;
  if payload_input ? 'title' then
    successor_definition_id := coalesce(
      nullif(payload_input->>'successor_task_definition_id', '')::uuid, gen_random_uuid()
    );
    insert into public.task_definitions (
      id, provenance, household_id, title, category, default_obligation_class,
      instructions_content_ref, default_effort, default_time_policy, metadata,
      created_by, updated_by
    ) values (
      successor_definition_id, 'user', target_definition.household_id,
      trim(payload_input->>'title'), target_definition.category,
      target_definition.default_obligation_class, target_definition.instructions_content_ref,
      target_definition.default_effort,
      (recurrence_value->>'time_policy')::public.time_policy,
      target_definition.metadata, actor_id, actor_id
    );
  end if;

  update public.task_schedules
  set status = 'superseded',
      active_range_until = split_date_value - 1,
      revision = revision + 1,
      updated_at = recorded_at_input,
      updated_by = actor_id
  where id = target_schedule.id;
  with changed as (
    update public.task_occurrences
    set state = 'cancelled', revision = revision + 1,
        updated_at = recorded_at_input, updated_by = actor_id
    where schedule_id = target_schedule.id
      and local_due_date >= split_date_value and state in ('pending', 'skipped')
    returning *
  )
  select count(*), coalesce(
    jsonb_agg(to_jsonb(changed) order by local_due_date, occurrence_key),
    '[]'::jsonb
  )
  into cancelled_count, cancelled_occurrences
  from changed;

  insert into public.task_schedules (
    id, household_id, pet_id, task_definition_id, recurrence,
    assignment_kind, assignment_user_id, origin, origin_ref, obligation_class,
    reminder_config, active_range_start_date, active_range_until,
    supersedes_schedule_id, created_by, updated_by
  ) values (
    successor_schedule_id, target_schedule.household_id, target_schedule.pet_id,
    successor_definition_id, recurrence_value, assignment_kind_value,
    assignment_user_id_value, target_schedule.origin, target_schedule.origin_ref,
    target_schedule.obligation_class,
    case when payload_input ? 'reminder_config' then payload_input->'reminder_config'
      else target_schedule.reminder_config end,
    split_date_value, nullif(recurrence_value->>'until', '')::date,
    target_schedule.id, actor_id, actor_id
  );

  if recurrence_value->>'type' = 'interval_after_completion' then
    first_occurrence_id := gen_random_uuid();
    insert into public.task_occurrences (
      id, occurrence_key, household_id, pet_id, schedule_id, local_due_date,
      original_local_due_date, time_policy, due_time, window_ref,
      assignment_kind, assignment_user_id, state, obligation_class, origin,
      origin_ref, created_by, updated_by
    ) values (
      first_occurrence_id, successor_schedule_id::text || ':ordinal:1',
      target_schedule.household_id, target_schedule.pet_id, successor_schedule_id,
      split_date_value, split_date_value,
      (recurrence_value->>'time_policy')::public.time_policy,
      case when recurrence_value->>'time_policy' = 'exact_time'
        then (recurrence_value->>'exact_time')::time end,
      case when recurrence_value->>'time_policy' = 'window'
        then recurrence_value->>'window_ref' end,
      assignment_kind_value, assignment_user_id_value, 'pending',
      target_schedule.obligation_class, target_schedule.origin,
      coalesce(target_schedule.origin_ref, '{}'::jsonb)
        || jsonb_build_object('interval_ordinal', 1),
      actor_id, actor_id
    );
  else
    perform public.write_path_materialize_occurrences(
      actor_id, target_schedule.pet_id, split_date_value, 14
    );
  end if;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at, reason
  ) values (
    target_schedule.household_id, actor_id,
    jsonb_build_object('type', 'task_schedule', 'id', target_schedule.id),
    'schedule.split',
    jsonb_build_object(
      'previous_revision', target_schedule.revision,
      'successor_schedule_id', successor_schedule_id,
      'split_date', split_date_value,
      'future_occurrences_cancelled', cancelled_count
    ), recorded_at_input, nullif(payload_input->>'note', '')
  );
  response := jsonb_build_object(
    'superseded_schedule', (
      select to_jsonb(s) from public.task_schedules s where s.id = target_schedule.id
    ),
    'successor_schedule', (
      select to_jsonb(s) from public.task_schedules s where s.id = successor_schedule_id
    ),
    'task_definition', (
      select to_jsonb(td) from public.task_definitions td where td.id = successor_definition_id
    ),
    'future_occurrences_cancelled', cancelled_count,
    'cancelled_occurrences', cancelled_occurrences,
    'occurrences', coalesce((
      select jsonb_agg(to_jsonb(o) order by o.local_due_date, o.occurrence_key)
      from public.task_occurrences o where o.schedule_id = successor_schedule_id
    ), '[]'::jsonb)
  );
  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'edit_schedule_future', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );
  return response;
end;
$$;

create or replace function public.write_path_archive_schedule(
  actor_id uuid, idempotency_key text, payload_hash_input text,
  request_body_input jsonb, recorded_at_input timestamptz,
  effective_at_input timestamptz, payload_input jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.command_log%rowtype;
  target_schedule public.task_schedules%rowtype;
  cancelled_count integer;
  cancelled_occurrences jsonb;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'archive_schedule' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;
  select * into target_schedule from public.task_schedules
  where id = (payload_input->>'schedule_id')::uuid and deleted_at is null for update;
  if not found or not exists (
    select 1 from public.household_memberships
    where household_id = target_schedule.household_id
      and user_id = actor_id and status = 'active'
  ) then raise exception 'active household membership required' using errcode = '42501'; end if;
  if target_schedule.revision <> (payload_input->>'expected_revision')::integer then
    raise exception 'schedule revision conflict' using errcode = '40001';
  end if;
  if target_schedule.status <> 'active' or target_schedule.origin = 'health_schedule' then
    raise exception 'only an active non-health schedule can be archived here' using errcode = '22023';
  end if;
  if target_schedule.obligation_class = 'required'
     and coalesce((payload_input->>'confirm_required')::boolean, false) is not true then
    raise exception 'required schedule archival needs confirmation' using errcode = 'PC001';
  end if;
  update public.task_schedules
  set status = 'archived', revision = revision + 1,
      updated_at = recorded_at_input, updated_by = actor_id
  where id = target_schedule.id;
  with changed as (
    update public.task_occurrences
    set state = 'cancelled', revision = revision + 1,
        updated_at = recorded_at_input, updated_by = actor_id
    where schedule_id = target_schedule.id and state in ('pending', 'skipped')
    returning *
  )
  select count(*), coalesce(
    jsonb_agg(to_jsonb(changed) order by local_due_date, occurrence_key),
    '[]'::jsonb
  )
  into cancelled_count, cancelled_occurrences
  from changed;
  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at, reason
  ) values (
    target_schedule.household_id, actor_id,
    jsonb_build_object('type', 'task_schedule', 'id', target_schedule.id),
    'schedule.archived',
    jsonb_build_object(
      'previous_revision', target_schedule.revision,
      'future_occurrences_cancelled', cancelled_count
    ), recorded_at_input, nullif(payload_input->>'note', '')
  );
  response := jsonb_build_object(
    'task_schedule', (
      select to_jsonb(s) from public.task_schedules s where s.id = target_schedule.id
    ),
    'occurrences_cancelled', cancelled_count,
    'occurrences', cancelled_occurrences
  );
  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'archive_schedule', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );
  return response;
end;
$$;

-- SECURITY DEFINER lockdown: only the authenticated Edge write path may supply actor_id.
revoke execute on function public.write_path_create_recurring_task(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_edit_occurrence(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_cancel_occurrence(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_snooze_occurrence(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_reschedule_occurrence(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_undo_skip(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_edit_schedule_future(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_archive_schedule(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;

grant execute on function public.write_path_create_recurring_task(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_edit_occurrence(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_cancel_occurrence(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_snooze_occurrence(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_reschedule_occurrence(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_undo_skip(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_edit_schedule_future(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_archive_schedule(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
