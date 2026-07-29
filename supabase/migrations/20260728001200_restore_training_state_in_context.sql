-- Restore training state to the generation context.
--
-- Two migrations in this batch each re-issued write_path_generation_context:
-- 20260728001000 added real training_state and practice history, and
-- 20260728001100 (socialization) replaced the whole function from a base that
-- still hardcoded 'training_state' to '[]'. Because it sorts later it applied
-- second and silently reverted the training work, re-starving
-- rule.active_skill_practice, rule.alone_time and rule.start_next_skill.
--
-- Git merged both cleanly and every suite passed in isolation: the two edits
-- live in different files and only collide when both are applied in order
-- against a fresh database. This migration composes both contributions.

CREATE OR REPLACE FUNCTION public.write_path_generation_context(actor_id uuid, target_pet_id uuid, capacity_override capacity_mode DEFAULT NULL::capacity_mode, at_instant timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    'training_state', public.training_state_for_pet(target_pet.id, target_household.time_zone),
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
      || public.training_practice_history_for_pet(target_pet.id, target_date - 30)
  );

  return context;
end;
$function$

;
