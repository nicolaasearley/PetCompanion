-- Slice B daily coordination foundation:
-- strict supported recurrence, occurrence presentation overrides, deterministic
-- DST resolution, notification candidates, and derived plan-item maintenance.

alter table public.task_definitions
  add column revision integer not null default 1 check (revision > 0);

create or replace function public.recurrence_rule_is_valid(rule jsonb)
returns boolean
language sql
immutable
as $$
  select
    jsonb_typeof(rule) = 'object'
    and rule ? 'type'
    and rule->>'type' in (
      'once', 'daily', 'weekdays', 'every_n_days', 'weekly',
      'monthly_safe', 'interval_after_completion'
    )
    and rule ? 'anchor_date'
    and (rule->>'anchor_date') ~ '^\d{4}-\d{2}-\d{2}$'
    and (
      not (rule ? 'until')
      or (
        (rule->>'until') ~ '^\d{4}-\d{2}-\d{2}$'
        and (rule->>'until')::date >= (rule->>'anchor_date')::date
      )
    )
    and (
      not (rule ? 'count')
      or (
        jsonb_typeof(rule->'count') = 'number'
        and (rule->>'count')::integer > 0
      )
    )
    and rule ? 'time_policy'
    and rule->>'time_policy' in ('exact_time', 'window', 'anytime')
    and (
      (
        rule->>'time_policy' = 'exact_time'
        and rule ? 'exact_time'
        and (rule->>'exact_time') ~ '^([01]\d|2[0-3]):[0-5]\d$'
        and not (rule ? 'window_ref')
      )
      or (
        rule->>'time_policy' = 'window'
        and rule ? 'window_ref'
        and rule->>'window_ref' in ('morning', 'midday', 'afternoon', 'evening', 'sleep')
        and not (rule ? 'exact_time')
      )
      or (
        rule->>'time_policy' = 'anytime'
        and not (rule ? 'exact_time')
        and not (rule ? 'window_ref')
      )
    )
    and (
      (
        rule->>'type' in ('once', 'daily', 'weekly')
        and not (rule ? 'interval')
        and not (rule ? 'weekdays')
        and not (rule ? 'day_of_month')
      )
      or (
        rule->>'type' = 'weekdays'
        and rule ? 'weekdays'
        and jsonb_typeof(rule->'weekdays') = 'array'
        and jsonb_array_length(rule->'weekdays') between 1 and 7
        and not exists (
          select 1 from jsonb_array_elements_text(rule->'weekdays') d(value)
          where lower(d.value) not in (
            '1','2','3','4','5','6','7',
            'mon','monday','tue','tuesday','wed','wednesday',
            'thu','thursday','fri','friday','sat','saturday','sun','sunday'
          )
        )
        and not (rule ? 'interval')
        and not (rule ? 'day_of_month')
      )
      or (
        rule->>'type' in ('every_n_days', 'interval_after_completion')
        and rule ? 'interval'
        and jsonb_typeof(rule->'interval') = 'number'
        and (rule->>'interval')::integer > 0
        and not (rule ? 'weekdays')
        and not (rule ? 'day_of_month')
      )
      or (
        rule->>'type' = 'monthly_safe'
        and rule ? 'day_of_month'
        and jsonb_typeof(rule->'day_of_month') = 'number'
        and (rule->>'day_of_month')::integer between 1 and 31
        and not (rule ? 'interval')
        and not (rule ? 'weekdays')
      )
    );
$$;

alter table public.task_occurrences
  add column title_override text,
  add constraint task_occurrences_title_override_present
    check (title_override is null or char_length(trim(title_override)) > 0);

create type public.notification_candidate_class as enum ('task_due', 'task_snooze');
create type public.notification_candidate_state as enum (
  'scheduled', 'sent', 'cancelled', 'suppressed', 'failed'
);

create table public.notification_candidates (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null references auth.users(id),
  household_id uuid not null references public.households(id) on delete cascade,
  occurrence_id uuid not null references public.task_occurrences(id) on delete cascade,
  class public.notification_candidate_class not null,
  source_ref jsonb not null,
  scheduled_for timestamptz not null,
  dedupe_key text not null unique,
  state public.notification_candidate_state not null default 'scheduled',
  resolved_at timestamptz,
  resolution_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint notification_candidates_source_object check (jsonb_typeof(source_ref) = 'object'),
  constraint notification_candidates_resolution_shape check (
    (state = 'scheduled' and resolved_at is null)
    or (state <> 'scheduled' and resolved_at is not null)
  )
);

create index notification_candidates_due
  on public.notification_candidates (scheduled_for)
  where state = 'scheduled';
create index notification_candidates_occurrence
  on public.notification_candidates (occurrence_id, state);

create trigger notification_candidates_set_updated_at
before update on public.notification_candidates
for each row execute function public.set_updated_at();

alter table public.notification_candidates enable row level security;
create policy "notification candidates recipient read"
  on public.notification_candidates for select
  using (
    recipient_user_id = auth.uid()
    and public.is_active_household_member(household_id)
  );
grant select on public.notification_candidates to authenticated;
grant all on public.notification_candidates to service_role;

create or replace function public.resolve_household_wall_time(
  target_date date,
  target_time time,
  target_time_zone text
)
returns timestamptz
language sql
stable
strict
as $$
  with requested as (
    select target_date + target_time as wall,
           (target_date + target_time) at time zone target_time_zone as approximate
  )
  select instant
  from requested
  cross join lateral generate_series(
    requested.approximate - interval '3 hours',
    requested.approximate + interval '3 hours',
    interval '1 minute'
  ) instant
  where (instant at time zone target_time_zone)::date = target_date
    and (instant at time zone target_time_zone) >= requested.wall
  order by instant
  limit 1;
$$;

create or replace function public.refresh_occurrence_notification_candidates(
  target_occurrence_id uuid,
  snooze_instant timestamptz default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  target_occurrence public.task_occurrences%rowtype;
  target_schedule public.task_schedules%rowtype;
  target_household public.households%rowtype;
  member_row record;
  lead_minutes integer;
  due_instant timestamptz;
  candidate_count integer := 0;
begin
  select * into target_occurrence
  from public.task_occurrences where id = target_occurrence_id;
  if not found then return 0; end if;

  update public.notification_candidates
  set state = 'cancelled',
      resolved_at = now(),
      resolution_reason = case
        when target_occurrence.state = 'completed' then 'occurrence_completed'
        when target_occurrence.state = 'skipped' then 'occurrence_skipped'
        when target_occurrence.state = 'cancelled' then 'occurrence_cancelled'
        when target_occurrence.state = 'rescheduled' then 'occurrence_rescheduled'
        else 'candidate_replaced'
      end
  where occurrence_id = target_occurrence.id and state = 'scheduled';

  if target_occurrence.state <> 'pending' then return 0; end if;

  select * into target_schedule
  from public.task_schedules where id = target_occurrence.schedule_id;
  select * into target_household
  from public.households where id = target_occurrence.household_id and status = 'active';
  if not found or target_schedule.status not in ('active', 'paused') then return 0; end if;

  if snooze_instant is not null then
    for member_row in
      select user_id from public.household_memberships
      where household_id = target_occurrence.household_id and status = 'active'
    loop
      insert into public.notification_candidates (
        recipient_user_id, household_id, occurrence_id, class, source_ref,
        scheduled_for, dedupe_key
      ) values (
        member_row.user_id, target_occurrence.household_id, target_occurrence.id,
        'task_snooze',
        jsonb_build_object('type', 'occurrence', 'id', target_occurrence.id),
        snooze_instant,
        'task_snooze:' || target_occurrence.id::text || ':' ||
          member_row.user_id::text || ':' || extract(epoch from snooze_instant)::bigint::text
      )
      on conflict (dedupe_key) do update set
        state = 'scheduled', resolved_at = null, resolution_reason = null,
        scheduled_for = excluded.scheduled_for, updated_at = now();
      candidate_count := candidate_count + 1;
    end loop;
    return candidate_count;
  end if;

  if target_occurrence.time_policy <> 'exact_time' or target_occurrence.due_time is null then
    return 0;
  end if;

  due_instant := public.resolve_household_wall_time(
    target_occurrence.local_due_date,
    target_occurrence.due_time,
    target_household.time_zone
  );

  for lead_minutes in
    select coalesce(value::integer, 0)
    from jsonb_array_elements_text(
      coalesce(target_schedule.reminder_config->'lead_minutes', '[0]'::jsonb)
    )
  loop
    if lead_minutes < 0 or lead_minutes > 10080 then
      raise exception 'reminder lead minutes must be between 0 and 10080'
        using errcode = '22023';
    end if;
    for member_row in
      select user_id from public.household_memberships
      where household_id = target_occurrence.household_id and status = 'active'
    loop
      insert into public.notification_candidates (
        recipient_user_id, household_id, occurrence_id, class, source_ref,
        scheduled_for, dedupe_key
      ) values (
        member_row.user_id, target_occurrence.household_id, target_occurrence.id,
        'task_due',
        jsonb_build_object(
          'type', 'occurrence', 'id', target_occurrence.id,
          'lead_minutes', lead_minutes
        ),
        due_instant - make_interval(mins => lead_minutes),
        'task_due:' || target_occurrence.id::text || ':' ||
          member_row.user_id::text || ':' || lead_minutes::text || ':' ||
          extract(epoch from due_instant)::bigint::text
      )
      on conflict (dedupe_key) do update set
        state = 'scheduled', resolved_at = null, resolution_reason = null,
        scheduled_for = excluded.scheduled_for, updated_at = now();
      candidate_count := candidate_count + 1;
    end loop;
  end loop;
  return candidate_count;
end;
$$;

create or replace function public.maintain_occurrence_derivatives()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.refresh_occurrence_notification_candidates(new.id, null);

  if tg_op = 'UPDATE' then
    update public.plan_items pi
    set title = coalesce(new.title_override, td.title),
        time_window = case
          when new.time_policy = 'window' then new.window_ref
          when new.time_policy = 'anytime' then 'anytime'
          else null
        end,
        due_time = new.due_time,
        display_state = case new.state
          when 'pending' then 'planned'::public.plan_item_display_state
          when 'completed' then 'completed'::public.plan_item_display_state
          when 'skipped' then 'skipped'::public.plan_item_display_state
          when 'rescheduled' then 'rescheduled'::public.plan_item_display_state
          when 'cancelled' then 'cancelled'::public.plan_item_display_state
          when 'expired' then 'expired'::public.plan_item_display_state
        end,
        section = case
          when new.state = 'completed' then 'completed'::public.plan_section
          when new.local_due_date > p.local_date then 'coming_up'::public.plan_section
          else pi.section
        end,
        completion = case when new.state = 'completed' then (
          select jsonb_strip_nulls(jsonb_build_object(
            'completed_at', d.effective_at,
            'completed_by_user_id', d.actor_user_id,
            'completed_by_name', up.display_name
          ))
          from public.dispositions d
          left join public.user_profiles up on up.id = d.actor_user_id
          where d.occurrence_id = new.id
            and d.action = 'complete'
            and not d.superseded
          order by d.effective_at
          limit 1
        ) else null end,
        updated_at = now()
    from public.plans p, public.task_schedules s, public.task_definitions td
    where pi.occurrence_id = new.id
      and p.id = pi.plan_id
      and p.status = 'open'
      and s.id = new.schedule_id
      and td.id = s.task_definition_id;
  end if;
  return new;
end;
$$;

create trigger task_occurrences_maintain_derivatives
after insert or update on public.task_occurrences
for each row execute function public.maintain_occurrence_derivatives();

create or replace function public.refresh_interval_after_completion(
  target_occurrence_id uuid,
  actor_id uuid,
  undoing boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  current_occurrence public.task_occurrences%rowtype;
  target_schedule public.task_schedules%rowtype;
  target_household public.households%rowtype;
  effective_completion public.dispositions%rowtype;
  current_ordinal integer;
  next_ordinal integer;
  next_due_date date;
  next_occurrence_id uuid;
begin
  select * into current_occurrence
  from public.task_occurrences where id = target_occurrence_id;
  if not found then return null; end if;
  select * into target_schedule
  from public.task_schedules
  where id = current_occurrence.schedule_id
    and recurrence->>'type' = 'interval_after_completion';
  if not found then return null; end if;

  current_ordinal := coalesce(
    (current_occurrence.origin_ref->>'interval_ordinal')::integer, 1
  );
  next_ordinal := current_ordinal + 1;

  if undoing then
    update public.task_occurrences
    set state = 'cancelled', revision = revision + 1,
        updated_at = now(), updated_by = actor_id
    where schedule_id = target_schedule.id
      and occurrence_key = target_schedule.id::text || ':ordinal:' || next_ordinal::text
      and state = 'pending';
    return null;
  end if;

  if target_schedule.recurrence ? 'count'
     and next_ordinal > (target_schedule.recurrence->>'count')::integer then
    return null;
  end if;

  select * into effective_completion
  from public.dispositions
  where occurrence_id = current_occurrence.id
    and action = 'complete'
    and not superseded
  order by effective_at
  limit 1;
  if not found then return null; end if;

  select * into target_household from public.households
  where id = current_occurrence.household_id;
  next_due_date := (effective_completion.effective_at at time zone target_household.time_zone)::date
    + (target_schedule.recurrence->>'interval')::integer;

  if target_schedule.recurrence ? 'until'
     and next_due_date > (target_schedule.recurrence->>'until')::date then
    return null;
  end if;

  select id into next_occurrence_id
  from public.task_occurrences
  where schedule_id = target_schedule.id
    and occurrence_key = target_schedule.id::text || ':ordinal:' || next_ordinal::text
  for update;

  if found then
    update public.task_occurrences
    set local_due_date = next_due_date,
        original_local_due_date = next_due_date,
        time_policy = (target_schedule.recurrence->>'time_policy')::public.time_policy,
        due_time = case when target_schedule.recurrence->>'time_policy' = 'exact_time'
          then (target_schedule.recurrence->>'exact_time')::time end,
        window_ref = case when target_schedule.recurrence->>'time_policy' = 'window'
          then target_schedule.recurrence->>'window_ref' end,
        state = 'pending',
        revision = revision + 1,
        updated_at = now(),
        updated_by = actor_id
    where id = next_occurrence_id;
  else
    next_occurrence_id := gen_random_uuid();
    insert into public.task_occurrences (
      id, occurrence_key, household_id, pet_id, schedule_id, local_due_date,
      original_local_due_date, time_policy, due_time, window_ref,
      assignment_kind, assignment_user_id, state, obligation_class, origin,
      origin_ref, created_by, updated_by
    ) values (
      next_occurrence_id,
      target_schedule.id::text || ':ordinal:' || next_ordinal::text,
      target_schedule.household_id, target_schedule.pet_id, target_schedule.id,
      next_due_date, next_due_date,
      (target_schedule.recurrence->>'time_policy')::public.time_policy,
      case when target_schedule.recurrence->>'time_policy' = 'exact_time'
        then (target_schedule.recurrence->>'exact_time')::time end,
      case when target_schedule.recurrence->>'time_policy' = 'window'
        then target_schedule.recurrence->>'window_ref' end,
      target_schedule.assignment_kind, target_schedule.assignment_user_id,
      'pending', target_schedule.obligation_class, target_schedule.origin,
      coalesce(target_schedule.origin_ref, '{}'::jsonb)
        || jsonb_build_object('interval_ordinal', next_ordinal),
      actor_id, actor_id
    );
  end if;
  return next_occurrence_id;
end;
$$;

create or replace function public.maintain_interval_schedule_from_disposition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.action = 'complete' and not new.superseded then
    perform public.refresh_interval_after_completion(new.occurrence_id, new.actor_user_id, false);
  elsif new.action = 'undo_complete' then
    perform public.refresh_interval_after_completion(new.occurrence_id, new.actor_user_id, true);
  end if;
  return new;
end;
$$;

create trigger dispositions_maintain_interval_schedule
after insert on public.dispositions
for each row execute function public.maintain_interval_schedule_from_disposition();

revoke execute on function public.resolve_household_wall_time(date, time, text) from public, anon, authenticated;
revoke execute on function public.refresh_occurrence_notification_candidates(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.maintain_occurrence_derivatives() from public, anon, authenticated;
revoke execute on function public.refresh_interval_after_completion(uuid, uuid, boolean) from public, anon, authenticated;
revoke execute on function public.maintain_interval_schedule_from_disposition() from public, anon, authenticated;

grant execute on function public.resolve_household_wall_time(date, time, text) to service_role;
grant execute on function public.refresh_occurrence_notification_candidates(uuid, timestamptz) to service_role;
grant execute on function public.refresh_interval_after_completion(uuid, uuid, boolean) to service_role;

-- Existing exact-time pending occurrences gain candidates on migration.
do $$
declare occurrence_row record;
begin
  for occurrence_row in
    select id from public.task_occurrences
    where state = 'pending' and time_policy = 'exact_time'
  loop
    perform public.refresh_occurrence_notification_candidates(occurrence_row.id, null);
  end loop;
end;
$$;
