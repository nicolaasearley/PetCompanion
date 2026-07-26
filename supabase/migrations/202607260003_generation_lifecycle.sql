-- WP-4: recurrence materialization, generation context/persistence, and day close.

alter table public.plan_items
  add column title text,
  add column due_time time,
  add column content_ref jsonb,
  add column origin public.schedule_origin,
  add column completion jsonb;

alter table public.plan_items
  add constraint plan_items_title_present check (title is null or char_length(trim(title)) > 0),
  add constraint plan_items_additional_json_shapes check (
    (content_ref is null or jsonb_typeof(content_ref) = 'object')
    and (completion is null or jsonb_typeof(completion) = 'object')
  );

create or replace function public.household_current_local_date(
  target_household_id uuid,
  at_instant timestamptz default now()
)
returns date
language sql
stable
security definer
set search_path = public
as $$
  select (at_instant at time zone h.time_zone)::date
  from public.households h
  where h.id = target_household_id;
$$;

create or replace function public.write_path_materialize_occurrences(
  actor_id uuid,
  target_pet_id uuid,
  window_start date,
  window_days integer default 14
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  inserted_count integer;
begin
  if window_days < 1 or window_days > 366 then
    raise exception 'window_days must be between 1 and 366' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.pets p
    join public.households h on h.id = p.household_id and h.status = 'active'
    join public.household_memberships hm
      on hm.household_id = h.id and hm.user_id = actor_id and hm.status = 'active'
    where p.id = target_pet_id and p.status = 'active' and p.deleted_at is null
  ) then
    raise exception 'active pet and household membership required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('materialize:' || target_pet_id::text || ':' || window_start::text, 0)
  );

  with recursive schedule_source as (
    select
      s.*,
      (s.recurrence->>'anchor_date')::date as anchor_date,
      least(
        window_start + (window_days - 1),
        coalesce((s.recurrence->>'until')::date, 'infinity'::date),
        coalesce(s.active_range_until, 'infinity'::date)
      ) as generation_end
    from public.task_schedules s
    join public.pets p on p.id = s.pet_id
    join public.households h on h.id = s.household_id
    where s.pet_id = target_pet_id
      and s.status = 'active'
      and s.deleted_at is null
      and p.status = 'active'
      and p.deleted_at is null
      and h.status = 'active'
      and s.recurrence->>'type' <> 'interval_after_completion'
  ),
  calendar_days as (
    select s.*, candidate_date::date
    from schedule_source s
    cross join lateral generate_series(
      s.anchor_date,
      s.generation_end,
      interval '1 day'
    ) candidate_date
    where s.generation_end >= s.anchor_date
  ),
  eligible as (
    select
      c.*,
      row_number() over (partition by c.id order by c.candidate_date) as occurrence_ordinal
    from calendar_days c
    where c.candidate_date >= c.anchor_date
      and c.candidate_date >= c.active_range_start_date
      and (
        (c.recurrence->>'type' = 'once' and c.candidate_date = c.anchor_date)
        or c.recurrence->>'type' = 'daily'
        or (
          c.recurrence->>'type' = 'weekdays'
          and exists (
            select 1
            from jsonb_array_elements_text(c.recurrence->'weekdays') weekday(value)
            where lower(weekday.value) in (
              extract(isodow from c.candidate_date)::integer::text,
              lower(to_char(c.candidate_date, 'FMDay')),
              lower(to_char(c.candidate_date, 'Dy'))
            )
          )
        )
        or (
          c.recurrence->>'type' = 'every_n_days'
          and (c.candidate_date - c.anchor_date) % (c.recurrence->>'interval')::integer = 0
        )
        or (
          c.recurrence->>'type' = 'weekly'
          and (c.candidate_date - c.anchor_date) % 7 = 0
        )
        or (
          c.recurrence->>'type' = 'monthly_safe'
          and c.candidate_date = (
            date_trunc('month', c.candidate_date)::date
            + least(
              (c.recurrence->>'day_of_month')::integer,
              extract(day from (date_trunc('month', c.candidate_date) + interval '1 month - 1 day'))::integer
            ) - 1
          )
        )
      )
  ),
  inserted as (
    insert into public.task_occurrences (
      occurrence_key, household_id, pet_id, schedule_id, local_due_date,
      original_local_due_date, time_policy, due_time, window_ref,
      assignment_kind, assignment_user_id, state, obligation_class, origin,
      origin_ref, created_by, updated_by
    )
    select
      e.id::text || ':' || e.candidate_date::text,
      e.household_id,
      e.pet_id,
      e.id,
      e.candidate_date,
      e.candidate_date,
      (e.recurrence->>'time_policy')::public.time_policy,
      case when e.recurrence->>'time_policy' = 'exact_time'
        then (e.recurrence->>'exact_time')::time end,
      case when e.recurrence->>'time_policy' = 'window'
        then e.recurrence->>'window_ref' end,
      e.assignment_kind,
      e.assignment_user_id,
      'pending',
      e.obligation_class,
      e.origin,
      e.origin_ref,
      actor_id,
      actor_id
    from eligible e
    where e.candidate_date >= window_start
      and (
        not (e.recurrence ? 'count')
        or e.occurrence_ordinal <= (e.recurrence->>'count')::integer
      )
    on conflict (occurrence_key) do nothing
    returning 1
  )
  select count(*) into inserted_count from inserted;

  return inserted_count;
end;
$$;

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
      'excluded_socialization_categories', '[]'::jsonb,
      'excluded_content_ids', '[]'::jsonb,
      'paused_content_ids', '[]'::jsonb,
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
    'training_state', '[]'::jsonb,
    'recent_history', coalesce((
      select jsonb_agg(history.row order by history.row->>'local_date' desc)
      from (
        select jsonb_strip_nulls(jsonb_build_object(
          'local_date', p.local_date,
          'content_id', pi.content_ref->>'content_id',
          'rule_content_id', pi.recommendation_rule_ref->>'content_id',
          'category', pi.category,
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
          'content_id', td.content_id,
          'category', td.category,
          'outcome', case d.action
            when 'complete' then 'completed'
            when 'skip' then 'skipped'
            when 'dismiss_required' then 'dismissed'
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
      ) history
    ), '[]'::jsonb)
  );

  return context;
end;
$$;

create or replace function public.write_path_persist_plan(
  actor_id uuid,
  plan_input jsonb,
  items_input jsonb,
  diagnostics_input jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target_pet public.pets%rowtype;
  saved_plan_id uuid;
  existing_plan public.plans%rowtype;
  item jsonb;
begin
  if jsonb_typeof(plan_input) <> 'object' or jsonb_typeof(items_input) <> 'array' then
    raise exception 'plan_input must be an object and items_input an array' using errcode = '22023';
  end if;

  select p.* into target_pet
  from public.pets p
  join public.households h on h.id = p.household_id and h.status = 'active'
  join public.household_memberships hm
    on hm.household_id = h.id and hm.user_id = actor_id and hm.status = 'active'
  where p.id = (plan_input->>'pet_id')::uuid and p.status = 'active' and p.deleted_at is null;

  if not found or target_pet.household_id <> (plan_input->>'household_id')::uuid then
    raise exception 'active pet and household membership required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('plan:' || target_pet.id::text || ':' || (plan_input->>'local_date'), 0)
  );

  select * into existing_plan
  from public.plans
  where pet_id = target_pet.id and local_date = (plan_input->>'local_date')::date
  for update;

  if found and existing_plan.status = 'closed' then
    raise exception 'closed plans are immutable' using errcode = '55000';
  end if;

  insert into public.plans (
    household_id, pet_id, local_date, time_zone_snapshot, stage_snapshot,
    capacity_mode_applied, plan_version, catalogue_version_set, input_digest,
    status, generated_at, created_by, updated_by
  )
  values (
    target_pet.household_id,
    target_pet.id,
    (plan_input->>'local_date')::date,
    plan_input->>'time_zone_snapshot',
    plan_input->'stage_snapshot',
    (plan_input->>'capacity_mode_applied')::public.capacity_mode,
    1,
    plan_input->'catalogue_version_set',
    plan_input->>'input_digest',
    'open',
    (plan_input->>'generated_at')::timestamptz,
    actor_id,
    actor_id
  )
  on conflict (pet_id, local_date) do update set
    time_zone_snapshot = excluded.time_zone_snapshot,
    stage_snapshot = excluded.stage_snapshot,
    capacity_mode_applied = excluded.capacity_mode_applied,
    plan_version = public.plans.plan_version + 1,
    catalogue_version_set = excluded.catalogue_version_set,
    input_digest = excluded.input_digest,
    generated_at = excluded.generated_at,
    updated_by = actor_id
  returning id into saved_plan_id;

  for item in select value from jsonb_array_elements(items_input)
  loop
    if nullif(item->>'item_key', '') is null or nullif(trim(item->>'title'), '') is null then
      raise exception 'each plan item requires item_key and title' using errcode = '22023';
    end if;

    if existing_plan.recommendations_frozen_at is not null
       and item->>'kind' = 'recommendation' then
      continue;
    end if;

    if nullif(item->'content_ref', 'null'::jsonb) is not null and not exists (
      select 1
      from public.content_versions cv
      where cv.content_id = item->'content_ref'->>'content_id'
        and cv.version = (item->'content_ref'->>'version')::integer
        and cv.publication_status = 'published'
    ) then
      raise exception 'plan item references unpublished content' using errcode = '22023';
    end if;

    if nullif(item->'recommendation_rule_ref', 'null'::jsonb) is not null and not exists (
      select 1
      from public.recommendation_rules rr
      join public.content_versions cv using (content_id, version)
      where rr.content_id = item->'recommendation_rule_ref'->>'content_id'
        and rr.version = (item->'recommendation_rule_ref'->>'version')::integer
        and cv.publication_status = 'published'
    ) then
      raise exception 'plan item references unpublished recommendation rule' using errcode = '22023';
    end if;

    insert into public.plan_items (
      plan_id, item_key, kind, occurrence_id, recommendation_rule_ref,
      content_ref, title, category, obligation_class, priority_tier, section,
      time_window, due_time, effort_band, explanation_text, score_components,
      pinned, display_state, origin, completion
    )
    values (
      saved_plan_id,
      item->>'item_key',
      (item->>'kind')::public.plan_item_kind,
      nullif(item->>'occurrence_id', '')::uuid,
      nullif(item->'recommendation_rule_ref', 'null'::jsonb),
      nullif(item->'content_ref', 'null'::jsonb),
      item->>'title',
      (item->>'category')::public.task_category,
      (item->>'obligation_class')::public.obligation_class,
      (item->>'priority_tier')::public.priority_tier,
      (item->>'section')::public.plan_section,
      nullif(item->>'time_window', ''),
      nullif(item->>'due_time', '')::time,
      nullif(item->>'effort_band', ''),
      nullif(item->>'explanation_text', ''),
      nullif(item->'score_components', 'null'::jsonb),
      coalesce((item->>'pinned')::boolean, false),
      (item->>'display_state')::public.plan_item_display_state,
      nullif(item->>'origin', '')::public.schedule_origin,
      nullif(item->'completion', 'null'::jsonb)
    )
    on conflict (plan_id, item_key) do update set
      kind = excluded.kind,
      occurrence_id = excluded.occurrence_id,
      recommendation_rule_ref = excluded.recommendation_rule_ref,
      content_ref = excluded.content_ref,
      title = excluded.title,
      category = excluded.category,
      obligation_class = excluded.obligation_class,
      priority_tier = excluded.priority_tier,
      section = excluded.section,
      time_window = excluded.time_window,
      due_time = excluded.due_time,
      effort_band = excluded.effort_band,
      explanation_text = excluded.explanation_text,
      score_components = excluded.score_components,
      display_state = excluded.display_state,
      origin = excluded.origin,
      completion = excluded.completion,
      updated_at = now();
  end loop;

  delete from public.plan_items pi
  where pi.plan_id = saved_plan_id
    and (existing_plan.recommendations_frozen_at is null or pi.kind <> 'recommendation')
    and not exists (
      select 1 from jsonb_array_elements(items_input) incoming
      where incoming->>'item_key' = pi.item_key
    );

  insert into public.analytics_events (
    household_id, actor_user_id, event_name, occurred_at, metadata
  )
  values (
    target_pet.household_id, actor_id, 'plan_generated',
    (plan_input->>'generated_at')::timestamptz,
    jsonb_build_object(
      'local_date', plan_input->>'local_date',
      'diagnostics', diagnostics_input
    )
  );

  return jsonb_build_object(
    'plan', (select to_jsonb(p) from public.plans p where p.id = saved_plan_id),
    'items', coalesce((
      select jsonb_agg(to_jsonb(pi) order by pi.section, pi.priority_tier, pi.due_time nulls last, pi.title, pi.item_key)
      from public.plan_items pi
      where pi.plan_id = saved_plan_id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.freeze_plan_recommendations_on_disposition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.plans p
  set recommendations_frozen_at = coalesce(p.recommendations_frozen_at, new.recorded_at),
      updated_at = now()
  where p.status = 'open'
    and p.recommendations_frozen_at is null
    and exists (
      select 1
      from public.plan_items pi
      where pi.plan_id = p.id and pi.occurrence_id = new.occurrence_id
    );
  return new;
end;
$$;

create trigger dispositions_freeze_plan_recommendations
after insert on public.dispositions
for each row execute function public.freeze_plan_recommendations_on_disposition();

create or replace function public.close_plans_for_date(target_date date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  expired_count integer;
  closed_count integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('close-plans:' || target_date::text, 0));

  update public.plan_items pi
  set display_state = 'expired', updated_at = now()
  from public.plans p
  where p.id = pi.plan_id
    and p.local_date = target_date
    and p.status = 'open'
    and pi.kind = 'recommendation'
    and pi.display_state = 'planned';
  get diagnostics expired_count = row_count;

  update public.plans
  set status = 'closed', updated_at = now()
  where local_date = target_date and status = 'open';
  get diagnostics closed_count = row_count;

  return jsonb_build_object(
    'local_date', target_date,
    'plans_closed', closed_count,
    'recommendations_expired', expired_count
  );
end;
$$;

revoke execute on function public.household_current_local_date(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.write_path_materialize_occurrences(uuid, uuid, date, integer) from public, anon, authenticated;
revoke execute on function public.write_path_generation_context(uuid, uuid, public.capacity_mode, timestamptz) from public, anon, authenticated;
revoke execute on function public.write_path_persist_plan(uuid, jsonb, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.freeze_plan_recommendations_on_disposition() from public, anon, authenticated;
revoke execute on function public.close_plans_for_date(date) from public, anon, authenticated;

grant execute on function public.household_current_local_date(uuid, timestamptz) to service_role;
grant execute on function public.write_path_materialize_occurrences(uuid, uuid, date, integer) to service_role;
grant execute on function public.write_path_generation_context(uuid, uuid, public.capacity_mode, timestamptz) to service_role;
grant execute on function public.write_path_persist_plan(uuid, jsonb, jsonb, jsonb) to service_role;
grant execute on function public.close_plans_for_date(date) to service_role;
