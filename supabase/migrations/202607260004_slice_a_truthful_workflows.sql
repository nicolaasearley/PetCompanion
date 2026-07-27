-- Slice A truthfulness pass:
-- unknown birth dates, routine schedule materialization, durable household
-- capacity, recommendation promotion, and timezone-aware lazy day close.

alter type public.birth_date_kind add value if not exists 'unknown';

alter table public.pets drop constraint pets_birth_shape;
alter table public.pets
  add constraint pets_birth_shape check (
    (
      birth_date_kind::text = 'exact'
      and birth_date is not null
      and estimated_age_weeks is null
      and estimated_as_of_date is null
    )
    or (
      birth_date_kind::text = 'estimated'
      and birth_date is null
      and estimated_age_weeks is not null
      and estimated_age_weeks >= 0
      and estimated_as_of_date is not null
    )
    or (
      birth_date_kind::text = 'unknown'
      and birth_date is null
      and estimated_age_weeks is null
      and estimated_as_of_date is null
    )
  );

create or replace function public.write_path_rebuild_routine_schedules(
  actor_id uuid,
  target_household_id uuid,
  routine_input jsonb,
  recorded_at_input timestamptz
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  target_household public.households%rowtype;
  target_pet public.pets%rowtype;
  target_date date;
  start_date date;
  meals_per_day integer;
  meal_definition_id uuid;
  potty_definition_id uuid;
  sleep_definition_id uuid;
  slot text;
  created_count integer := 0;
  schedule_id uuid;
  recurrence_value jsonb;
begin
  if jsonb_typeof(routine_input) <> 'object' then
    raise exception 'routine_windows must be an object' using errcode = '22023';
  end if;

  select * into target_household
  from public.households
  where id = target_household_id and status = 'active';

  if not found or not exists (
    select 1 from public.household_memberships
    where household_id = target_household_id
      and user_id = actor_id
      and status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  target_date := public.household_current_local_date(target_household_id, recorded_at_input);
  meals_per_day := greatest(2, least(3, coalesce((routine_input->>'meals_per_day')::integer, 3)));

  select id into meal_definition_id
  from public.task_definitions
  where provenance = 'system'
    and content_id = case when meals_per_day = 2
      then 'routine.meals_adolescent'
      else 'routine.meals_young_puppy'
    end
  order by content_version desc
  limit 1;

  select id into potty_definition_id
  from public.task_definitions
  where provenance = 'system' and content_id = 'routine.potty_young'
  order by content_version desc
  limit 1;

  select id into sleep_definition_id
  from public.task_definitions
  where provenance = 'system' and content_id = 'routine.sleep'
  order by content_version desc
  limit 1;

  if meal_definition_id is null or potty_definition_id is null or sleep_definition_id is null then
    raise exception 'routine content catalogue is incomplete' using errcode = '22023';
  end if;

  -- Supersede only schedules owned by this onboarding/settings workflow.
  update public.task_schedules
  set status = 'archived',
      revision = revision + 1,
      updated_at = recorded_at_input,
      updated_by = actor_id
  where household_id = target_household_id
    and status = 'active'
    and origin = 'recurring_schedule'
    and origin_ref->>'routine_managed' = 'true';

  update public.task_occurrences o
  set state = 'cancelled',
      revision = o.revision + 1,
      updated_at = recorded_at_input,
      updated_by = actor_id
  from public.task_schedules s
  where s.id = o.schedule_id
    and s.household_id = target_household_id
    and s.status = 'archived'
    and s.origin_ref->>'routine_managed' = 'true'
    and o.local_due_date >= target_date
    and o.state = 'pending';

  for target_pet in
    select * from public.pets
    where household_id = target_household_id
      and status = 'active'
      and deleted_at is null
  loop
    start_date := greatest(target_date, coalesce(target_pet.homecoming_date, target_date));

    foreach slot in array (
      case when meals_per_day = 2
        then array['morning', 'evening']
        else array['morning', 'midday', 'evening']
      end
    )
    loop
      schedule_id := gen_random_uuid();
      recurrence_value := jsonb_build_object(
        'type', 'daily',
        'anchor_date', start_date,
        'time_policy', 'window',
        'window_ref', slot
      );
      insert into public.task_schedules (
        id, household_id, pet_id, task_definition_id, recurrence,
        assignment_kind, origin, origin_ref, obligation_class,
        active_range_start_date, created_by, updated_by
      )
      values (
        schedule_id, target_household_id, target_pet.id, meal_definition_id,
        recurrence_value, 'anyone', 'recurring_schedule',
        jsonb_build_object('routine_managed', true, 'routine_kind', 'meal', 'slot', slot),
        'scheduled', start_date, actor_id, actor_id
      );
      created_count := created_count + 1;
    end loop;

    foreach slot in array array['morning', 'sleep']
    loop
      schedule_id := gen_random_uuid();
      recurrence_value := jsonb_build_object(
        'type', 'daily',
        'anchor_date', start_date,
        'time_policy', 'window',
        'window_ref', slot
      );
      insert into public.task_schedules (
        id, household_id, pet_id, task_definition_id, recurrence,
        assignment_kind, origin, origin_ref, obligation_class,
        active_range_start_date, created_by, updated_by
      )
      values (
        schedule_id, target_household_id, target_pet.id, potty_definition_id,
        recurrence_value, 'anyone', 'recurring_schedule',
        jsonb_build_object('routine_managed', true, 'routine_kind', 'potty', 'slot', slot),
        'scheduled', start_date, actor_id, actor_id
      );
      created_count := created_count + 1;
    end loop;

    schedule_id := gen_random_uuid();
    recurrence_value := jsonb_build_object(
      'type', 'daily',
      'anchor_date', start_date,
      'time_policy', 'window',
      'window_ref', 'evening'
    );
    insert into public.task_schedules (
      id, household_id, pet_id, task_definition_id, recurrence,
      assignment_kind, origin, origin_ref, obligation_class,
      active_range_start_date, created_by, updated_by
    )
    values (
      schedule_id, target_household_id, target_pet.id, sleep_definition_id,
      recurrence_value, 'anyone', 'recurring_schedule',
      jsonb_build_object('routine_managed', true, 'routine_kind', 'sleep', 'slot', 'evening'),
      'scheduled', start_date, actor_id, actor_id
    );
    created_count := created_count + 1;
  end loop;

  return created_count;
end;
$$;

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
  schedule_count integer;
  meal_ref text;
  normalized_routines jsonb;
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

  if nullif(trim(payload_input->>'household_id'), '') is null
     or not (payload_input ? 'routine_windows')
     or jsonb_typeof(payload_input->'routine_windows') <> 'object' then
    raise exception 'household_id and object routine_windows are required' using errcode = '22023';
  end if;

  select * into target_household
  from public.households
  where id = (payload_input->>'household_id')::uuid and status = 'active';

  if not found or not exists (
    select 1 from public.household_memberships
    where household_id = target_household.id
      and user_id = actor_id
      and status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  meal_ref := coalesce(
    nullif(payload_input->>'meal_template_ref', ''),
    coalesce(payload_input->'routine_windows'->>'meals_per_day', '3') || '_meals'
  );
  normalized_routines := jsonb_build_object(
    'meals_per_day', coalesce((payload_input->'routine_windows'->>'meals_per_day')::integer, 3)
  );
  for response in
    select jsonb_build_object(
      'key', band,
      'value', jsonb_build_object(
        'start', coalesce(
          payload_input->'routine_windows'->band->>'start',
          lpad(payload_input->'routine_windows'->band->>'start_hour', 2, '0') || ':00'
        ),
        'end', coalesce(
          payload_input->'routine_windows'->band->>'end',
          lpad(payload_input->'routine_windows'->band->>'end_hour', 2, '0') || ':00'
        )
      )
    )
    from unnest(array['morning', 'midday', 'afternoon', 'evening', 'sleep']) band
    where jsonb_typeof(payload_input->'routine_windows'->band) = 'object'
  loop
    normalized_routines := normalized_routines
      || jsonb_build_object(response->>'key', response->'value');
  end loop;

  insert into public.household_preferences (
    household_id, routine_windows, meal_template_ref, default_capacity_mode,
    created_by, updated_by, updated_at
  )
  values (
    target_household.id, normalized_routines, meal_ref,
    target_household.default_capacity_mode, actor_id, actor_id, recorded_at_input
  )
  on conflict (household_id) do update
  set routine_windows = excluded.routine_windows,
      meal_template_ref = excluded.meal_template_ref,
      updated_at = recorded_at_input,
      updated_by = actor_id;

  schedule_count := public.write_path_rebuild_routine_schedules(
    actor_id, target_household.id, normalized_routines, recorded_at_input
  );

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  )
  values (
    target_household.id, actor_id,
    jsonb_build_object('type', 'household_preferences', 'id', target_household.id),
    'routine_preferences.updated',
    jsonb_build_object('routine_schedules_created', schedule_count, 'meal_template_ref', meal_ref),
    recorded_at_input
  );

  response := jsonb_build_object(
    'household_preferences', jsonb_build_object(
      'household_id', target_household.id,
      'routine_windows', normalized_routines,
      'meal_template_ref', meal_ref
    ),
    'routine_schedules_created', schedule_count
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  )
  values (
    actor_id, idempotency_key, 'set_routine_preferences', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );
  return response;
end;
$$;

create or replace function public.write_path_set_default_capacity(
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
  target_household_id uuid;
  capacity_value public.capacity_mode;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'set_default_capacity' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  target_household_id := (payload_input->>'household_id')::uuid;
  capacity_value := (payload_input->>'default_capacity_mode')::public.capacity_mode;
  if not exists (
    select 1 from public.households h
    join public.household_memberships hm on hm.household_id = h.id
    where h.id = target_household_id and h.status = 'active'
      and hm.user_id = actor_id and hm.status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  update public.households
  set default_capacity_mode = capacity_value,
      updated_at = recorded_at_input,
      updated_by = actor_id
  where id = target_household_id;
  update public.household_preferences
  set default_capacity_mode = capacity_value,
      updated_at = recorded_at_input,
      updated_by = actor_id
  where household_preferences.household_id = target_household_id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_household_id, actor_id, jsonb_build_object('type', 'household', 'id', target_household_id),
    'capacity.default_changed', jsonb_build_object('default_capacity_mode', capacity_value),
    recorded_at_input
  );
  insert into public.analytics_events (
    household_id, actor_user_id, event_name, occurred_at, metadata
  ) values (
    target_household_id, actor_id, 'capacity_mode_changed', recorded_at_input,
    jsonb_build_object('scope', 'household_default', 'capacity_mode', capacity_value)
  );

  response := jsonb_build_object(
    'household_id', target_household_id, 'default_capacity_mode', capacity_value
  );
  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'set_default_capacity', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );
  return response;
end;
$$;

create or replace function public.write_path_accept_recommendation(
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
  target_item public.plan_items%rowtype;
  target_plan public.plans%rowtype;
  definition_id uuid := gen_random_uuid();
  schedule_id uuid := gen_random_uuid();
  promoted_occurrence_id uuid := gen_random_uuid();
  disposition_id uuid;
  policy public.time_policy;
  recurrence_value jsonb;
  complete_value boolean := coalesce((payload_input->>'complete')::boolean, true);
  pinned_value boolean := coalesce((payload_input->>'pinned')::boolean, false);
  effective_value timestamptz := coalesce(effective_at_input, recorded_at_input);
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'accept_recommendation' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target_item
  from public.plan_items
  where id = (payload_input->>'plan_item_id')::uuid
  for update;
  if not found or target_item.kind <> 'recommendation'
     or target_item.display_state <> 'planned' then
    raise exception 'planned recommendation not found' using errcode = '22023';
  end if;

  select * into target_plan from public.plans
  where id = target_item.plan_id for update;
  if target_plan.status <> 'open' or not exists (
    select 1 from public.household_memberships
    where household_id = target_plan.household_id
      and user_id = actor_id and status = 'active'
  ) then
    raise exception 'active household membership and open plan required' using errcode = '42501';
  end if;

  if effective_value > recorded_at_input + interval '5 minutes'
     or effective_value < recorded_at_input - interval '7 days' then
    raise exception 'effective_at must be between recorded_at - 7 days and recorded_at + 5 minutes' using errcode = '22023';
  end if;

  policy := case
    when target_item.due_time is not null then 'exact_time'::public.time_policy
    when target_item.time_window is not null and target_item.time_window <> 'anytime'
      then 'window'::public.time_policy
    else 'anytime'::public.time_policy
  end;
  recurrence_value := jsonb_build_object(
    'type', 'once', 'anchor_date', target_plan.local_date, 'time_policy', policy
  );
  if policy = 'exact_time' then
    recurrence_value := recurrence_value || jsonb_build_object(
      'exact_time', to_char(target_item.due_time, 'HH24:MI')
    );
  elsif policy = 'window' then
    recurrence_value := recurrence_value || jsonb_build_object(
      'window_ref', target_item.time_window
    );
  end if;

  insert into public.task_definitions (
    id, provenance, household_id, title, category, default_obligation_class,
    default_effort, default_time_policy, metadata, created_by, updated_by
  ) values (
    definition_id, 'user', target_plan.household_id, target_item.title,
    target_item.category, 'scheduled', coalesce(target_item.effort_band, 'short'),
    policy, jsonb_strip_nulls(jsonb_build_object(
      'promoted_from_plan_item_id', target_item.id,
      'content_ref', target_item.content_ref,
      'recommendation_rule_ref', target_item.recommendation_rule_ref
    )), actor_id, actor_id
  );

  insert into public.task_schedules (
    id, household_id, pet_id, task_definition_id, recurrence, assignment_kind,
    origin, origin_ref, obligation_class, active_range_start_date,
    active_range_until, created_by, updated_by
  ) values (
    schedule_id, target_plan.household_id, target_plan.pet_id, definition_id,
    recurrence_value, 'anyone', coalesce(target_item.origin, 'development_rule'),
    jsonb_build_object('promoted_from_plan_item_id', target_item.id),
    'scheduled', target_plan.local_date, target_plan.local_date, actor_id, actor_id
  );

  insert into public.task_occurrences (
    id, occurrence_key, household_id, pet_id, schedule_id, local_due_date,
    original_local_due_date, time_policy, due_time, window_ref, assignment_kind,
    state, obligation_class, origin, origin_ref, created_by, updated_by
  ) values (
    promoted_occurrence_id, schedule_id::text || ':' || target_plan.local_date::text,
    target_plan.household_id, target_plan.pet_id, schedule_id,
    target_plan.local_date, target_plan.local_date, policy,
    case when policy = 'exact_time' then target_item.due_time end,
    case when policy = 'window' then target_item.time_window end,
    'anyone', (case when complete_value then 'completed' else 'pending' end)::public.occurrence_state,
    'scheduled', coalesce(target_item.origin, 'development_rule'),
    jsonb_build_object('promoted_from_plan_item_id', target_item.id),
    actor_id, actor_id
  );

  if complete_value then
    disposition_id := gen_random_uuid();
    insert into public.dispositions (
      id, household_id, occurrence_id, action, actor_user_id, recorded_at,
      effective_at, note, client_idempotency_key
    ) values (
      disposition_id, target_plan.household_id, promoted_occurrence_id, 'complete',
      actor_id, recorded_at_input, effective_value,
      nullif(payload_input->>'note', ''), idempotency_key
    );
  end if;

  update public.plan_items
  set kind = 'obligation',
      occurrence_id = promoted_occurrence_id,
      recommendation_rule_ref = null,
      obligation_class = 'scheduled',
      section = (case when complete_value then 'completed' else 'today' end)::public.plan_section,
      pinned = pinned_value,
      display_state = (case when complete_value then 'completed' else 'planned' end)::public.plan_item_display_state,
      completion = case when complete_value then jsonb_strip_nulls(jsonb_build_object(
        'completed_at', effective_value,
        'completed_by_user_id', actor_id,
        'completed_by_name', (
          select display_name from public.user_profiles where id = actor_id
        )
      )) else null end,
      updated_at = now()
  where id = target_item.id;

  update public.plans
  set recommendations_frozen_at = coalesce(recommendations_frozen_at, recorded_at_input),
      updated_at = now(),
      updated_by = actor_id
  where id = target_plan.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_plan.household_id, actor_id,
    jsonb_build_object('type', 'plan_item', 'id', target_item.id),
    'recommendation.accepted',
    jsonb_build_object(
      'occurrence_id', promoted_occurrence_id, 'completed', complete_value, 'pinned', pinned_value
    ),
    recorded_at_input
  );

  response := jsonb_build_object(
    'plan_item', jsonb_build_object(
      'id', target_item.id, 'kind', 'obligation',
      'occurrence_id', promoted_occurrence_id,
      'display_state', case when complete_value then 'completed' else 'planned' end,
      'pinned', pinned_value
    ),
    'task_occurrence', jsonb_build_object(
      'id', promoted_occurrence_id, 'schedule_id', schedule_id,
      'state', case when complete_value then 'completed' else 'pending' end,
      'local_due_date', target_plan.local_date
    ),
    'disposition_id', disposition_id
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'accept_recommendation', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_value, now()
  );
  return response;
end;
$$;

create or replace function public.close_elapsed_plans(at_instant timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  expired_count integer;
  closed_count integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('close-elapsed-plans', 0));

  update public.plan_items pi
  set display_state = 'expired', updated_at = now()
  from public.plans p
  where p.id = pi.plan_id
    and p.status = 'open'
    and p.local_date < (at_instant at time zone p.time_zone_snapshot)::date
    and pi.kind = 'recommendation'
    and pi.display_state = 'planned';
  get diagnostics expired_count = row_count;

  update public.plans p
  set status = 'closed', updated_at = now()
  where p.status = 'open'
    and p.local_date < (at_instant at time zone p.time_zone_snapshot)::date;
  get diagnostics closed_count = row_count;

  return jsonb_build_object(
    'plans_closed', closed_count,
    'recommendations_expired', expired_count,
    'evaluated_at', at_instant
  );
end;
$$;

revoke execute on function public.write_path_rebuild_routine_schedules(uuid, uuid, jsonb, timestamptz) from public, anon, authenticated;
revoke execute on function public.write_path_set_default_capacity(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_accept_recommendation(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.close_elapsed_plans(timestamptz) from public, anon, authenticated;

grant execute on function public.write_path_rebuild_routine_schedules(uuid, uuid, jsonb, timestamptz) to service_role;
grant execute on function public.write_path_set_default_capacity(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_accept_recommendation(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.close_elapsed_plans(timestamptz) to service_role;
