create extension if not exists pgcrypto;

create type public.user_status as enum ('active', 'deletion_pending', 'deleted');
create type public.household_status as enum ('active', 'closed');
create type public.capacity_mode as enum ('normal', 'busy', 'essentials_only', 'custom');
create type public.household_role as enum ('owner', 'caregiver', 'limited_caregiver', 'professional_readonly');
create type public.membership_status as enum ('active', 'removed', 'left');
create type public.invitation_status as enum ('pending', 'accepted', 'declined', 'revoked', 'expired');
create type public.pet_species as enum ('dog');
create type public.pet_sex as enum ('female', 'male', 'unknown');
create type public.birth_date_kind as enum ('exact', 'estimated');
create type public.pet_status as enum ('active', 'archived');
create type public.task_definition_provenance as enum ('user', 'system');
create type public.task_category as enum ('health', 'feeding', 'routine', 'training', 'socialization', 'grooming', 'event', 'preparation', 'life', 'household');
create type public.obligation_class as enum ('required', 'scheduled', 'recommended', 'informational');
create type public.time_policy as enum ('exact_time', 'window', 'anytime');
create type public.assignment_kind as enum ('unassigned', 'member', 'anyone');
create type public.schedule_origin as enum ('user_created', 'recurring_schedule', 'health_schedule', 'calendar_event', 'training_program', 'development_rule', 'socialization_rule', 'system_preparation_rule');
create type public.schedule_status as enum ('active', 'paused', 'archived', 'superseded');
create type public.occurrence_state as enum ('pending', 'completed', 'skipped', 'rescheduled', 'cancelled', 'expired');
create type public.disposition_action as enum ('complete', 'undo_complete', 'skip', 'undo_skip', 'snooze', 'reschedule', 'cancel', 'dismiss_required');
create type public.skip_reason as enum ('not_relevant_today', 'already_did_this', 'too_busy', 'pet_not_feeling_well', 'do_not_suggest_for_now');
create type public.plan_status as enum ('open', 'closed');
create type public.plan_item_kind as enum ('obligation', 'recommendation', 'informational', 'upcoming_preview');
create type public.priority_tier as enum ('P0', 'P1', 'P2', 'P3', 'P4', 'P5');
create type public.plan_section as enum ('needs_attention', 'today', 'recommended', 'coming_up', 'completed');
create type public.plan_item_display_state as enum ('planned', 'completed', 'skipped', 'snoozed', 'rescheduled', 'cancelled', 'expired');
create type public.content_publication_status as enum ('draft', 'review', 'published', 'retired');
create type public.content_review_status as enum ('pending_professional_review', 'professionally_reviewed');
create type public.command_status as enum ('succeeded', 'failed');

create or replace function public.is_active_household_member(target_household_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return exists (
    select 1
    from public.household_memberships hm
    where hm.household_id = target_household_id
      and hm.user_id = auth.uid()
      and hm.status = 'active'
  );
end;
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.deny_audit_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'audit_events are append-only';
end;
$$;

create or replace function public.deny_closed_plan_mutation()
returns trigger
language plpgsql
as $$
begin
  if old.status = 'closed' then
    raise exception 'closed plans are immutable';
  end if;
  return coalesce(new, old);
end;
$$;

create or replace function public.deny_closed_plan_item_mutation()
returns trigger
language plpgsql
as $$
begin
  if exists (select 1 from public.plans p where p.id = coalesce(new.plan_id, old.plan_id) and p.status = 'closed') then
    raise exception 'items on closed plans are immutable';
  end if;
  return coalesce(new, old);
end;
$$;

create or replace function public.recurrence_rule_is_valid(rule jsonb)
returns boolean
language sql
immutable
as $$
  select
    jsonb_typeof(rule) = 'object'
    and rule ? 'type'
    and rule->>'type' in ('once', 'daily', 'weekdays', 'every_n_days', 'weekly', 'monthly_safe', 'interval_after_completion')
    and rule ? 'anchor_date'
    and (rule->>'anchor_date') ~ '^\d{4}-\d{2}-\d{2}$'
    and (not (rule ? 'interval') or jsonb_typeof(rule->'interval') = 'number')
    and (not (rule ? 'count') or jsonb_typeof(rule->'count') = 'number')
    and (not (rule ? 'until') or (rule->>'until') ~ '^\d{4}-\d{2}-\d{2}$')
    and (not (rule ? 'weekdays') or (
      jsonb_typeof(rule->'weekdays') = 'array'
      and jsonb_array_length(rule->'weekdays') between 1 and 7
    ))
    and (not (rule ? 'day_of_month') or ((rule->>'day_of_month')::int between 1 and 31))
    and rule ? 'time_policy'
    and rule->>'time_policy' in ('exact_time', 'window', 'anytime')
    and (
      (rule->>'time_policy' = 'exact_time' and rule ? 'exact_time' and (rule->>'exact_time') ~ '^\d{2}:\d{2}$' and not (rule ? 'window_ref'))
      or (rule->>'time_policy' = 'window' and rule ? 'window_ref' and rule->>'window_ref' in ('morning', 'midday', 'afternoon', 'evening', 'sleep') and not (rule ? 'exact_time'))
      or (rule->>'time_policy' = 'anytime' and not (rule ? 'exact_time') and not (rule ? 'window_ref'))
    )
    and (
      (rule->>'type' in ('daily', 'weekly', 'once') and not (rule ? 'interval') and not (rule ? 'weekdays') and not (rule ? 'day_of_month'))
      or (rule->>'type' = 'weekdays' and rule ? 'weekdays' and not (rule ? 'interval') and not (rule ? 'day_of_month'))
      or (rule->>'type' in ('every_n_days', 'interval_after_completion') and rule ? 'interval' and (rule->>'interval')::int > 0 and not (rule ? 'weekdays') and not (rule ? 'day_of_month'))
      or (rule->>'type' = 'monthly_safe' and rule ? 'day_of_month' and not (rule ? 'interval') and not (rule ? 'weekdays'))
    );
$$;

create table public.user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  auth_provider_ref text,
  display_name text not null check (char_length(trim(display_name)) > 0),
  status public.user_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) > 0),
  time_zone text not null check (char_length(trim(time_zone)) > 0),
  status public.household_status not null default 'active',
  default_capacity_mode public.capacity_mode not null default 'normal',
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id)
);

create table public.household_memberships (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  role public.household_role not null,
  status public.membership_status not null default 'active',
  joined_at timestamptz not null default now(),
  ended_at timestamptz,
  ended_by uuid references auth.users(id),
  invitation_id uuid,
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  constraint household_memberships_end_consistency check (
    (status = 'active' and ended_at is null and ended_by is null)
    or (status <> 'active' and ended_at is not null)
  )
);

create unique index household_memberships_one_active_per_user_household
  on public.household_memberships (user_id, household_id)
  where status = 'active';

create table public.household_invitations (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  token_hash text not null,
  role_granted public.household_role not null default 'caregiver',
  expires_at timestamptz not null,
  status public.invitation_status not null default 'pending',
  accepted_by uuid references auth.users(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  constraint household_invitations_role_mvp check (role_granted = 'caregiver'),
  constraint household_invitations_resolution_shape check (
    (status = 'pending' and accepted_by is null and resolved_at is null)
    or (status <> 'pending' and resolved_at is not null)
  )
);

create unique index household_invitations_token_hash_unique on public.household_invitations (token_hash);
create unique index household_invitations_accepted_once on public.household_invitations (id) where status = 'accepted';

alter table public.household_memberships
  add constraint household_memberships_invitation_id_fkey
  foreign key (invitation_id) references public.household_invitations(id);

create table public.pets (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  species public.pet_species not null default 'dog',
  breed_text text,
  sex public.pet_sex,
  birth_date_kind public.birth_date_kind not null,
  birth_date date,
  estimated_age_weeks integer,
  estimated_as_of_date date,
  homecoming_date date,
  stage_override text,
  profile_photo_media_id uuid,
  food_notes text,
  allergy_notes text,
  microchip_ref text,
  notes text,
  primary_provider_id uuid,
  status public.pet_status not null default 'active',
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id),
  constraint pets_birth_shape check (
    (
      birth_date_kind = 'exact'
      and birth_date is not null
      and estimated_age_weeks is null
      and estimated_as_of_date is null
    )
    or (
      birth_date_kind = 'estimated'
      and birth_date is null
      and estimated_age_weeks is not null
      and estimated_age_weeks >= 0
      and estimated_as_of_date is not null
    )
  ),
  constraint pets_homecoming_after_birth check (
    birth_date_kind <> 'exact' or homecoming_date is null or birth_date is null or homecoming_date >= birth_date
  ),
  constraint pets_deleted_shape check ((deleted_at is null and deleted_by is null) or deleted_at is not null)
);

create table public.household_preferences (
  household_id uuid primary key references public.households(id) on delete cascade,
  routine_windows jsonb not null default '{}'::jsonb,
  meal_template_ref text,
  potty_template_ref text,
  default_capacity_mode public.capacity_mode not null default 'normal',
  locale text not null default 'en-US',
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  constraint household_preferences_windows_object check (jsonb_typeof(routine_windows) = 'object')
);

create table public.user_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  morning_summary_opt_in boolean not null default true,
  allowed_delivery_window jsonb not null default '{"start":"08:00","end":"20:00"}'::jsonb,
  notification_class_settings jsonb not null default '{}'::jsonb,
  quiet_hours jsonb not null default '{}'::jsonb,
  lock_screen_detail_level text not null default 'discreet' check (lock_screen_detail_level in ('discreet', 'detailed')),
  completion_update_opt_in boolean not null default false,
  display_units jsonb not null default '{"weight":"kg"}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint user_preferences_json_shapes check (
    jsonb_typeof(allowed_delivery_window) = 'object'
    and jsonb_typeof(notification_class_settings) = 'object'
    and jsonb_typeof(quiet_hours) = 'object'
    and jsonb_typeof(display_units) = 'object'
  )
);

create table public.pet_preferences (
  pet_id uuid primary key references public.pets(id) on delete cascade,
  household_id uuid not null references public.households(id) on delete cascade,
  paused_recommendation_categories public.task_category[] not null default '{}',
  suggestion_frequency_adjustments jsonb not null default '{}'::jsonb,
  training_days_per_week_target integer check (training_days_per_week_target between 0 and 7),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  constraint pet_preferences_adjustments_object check (jsonb_typeof(suggestion_frequency_adjustments) = 'object')
);

create table public.content_versions (
  content_id text not null,
  version integer not null check (version > 0),
  content_type text not null check (content_type in ('development_stage', 'task_definition', 'recommendation_rule', 'training_skill', 'socialization_experience')),
  publication_status public.content_publication_status not null default 'published',
  review_status public.content_review_status not null default 'pending_professional_review',
  source_category text not null default 'product_seed',
  author text not null,
  authored_on date not null,
  reviewer_name text,
  reviewed_on date,
  effective_from date not null,
  retired_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (content_id, version),
  constraint content_versions_review_metadata check (
    (review_status = 'pending_professional_review' and reviewer_name is null and reviewed_on is null)
    or (review_status = 'professionally_reviewed' and reviewer_name is not null and reviewed_on is not null)
  ),
  constraint content_versions_retired_status check (retired_at is null or publication_status = 'retired')
);

create table public.development_stages (
  content_id text not null,
  version integer not null,
  stage_key text not null,
  name text not null,
  position integer not null check (position > 0),
  approximate_band text not null,
  focus_areas text[] not null,
  description text,
  next_stage_preview text,
  entry_guidance jsonb not null default '{}'::jsonb,
  review_status public.content_review_status not null default 'pending_professional_review',
  effective_from date not null,
  retired_at timestamptz,
  primary key (content_id, version),
  unique (stage_key, version),
  foreign key (content_id, version) references public.content_versions(content_id, version),
  constraint development_stages_content_id check (content_id = 'stage.' || stage_key),
  constraint development_stages_json_shapes check (jsonb_typeof(entry_guidance) = 'object')
);

create table public.task_definitions (
  id uuid primary key default gen_random_uuid(),
  provenance public.task_definition_provenance not null,
  household_id uuid references public.households(id) on delete cascade,
  content_id text,
  content_version integer,
  title text not null check (char_length(trim(title)) > 0),
  category public.task_category not null,
  default_obligation_class public.obligation_class not null,
  instructions_content_ref jsonb,
  default_effort text not null check (default_effort in ('tiny', 'short', 'moderate', 'extended')),
  default_time_policy public.time_policy not null default 'anytime',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id),
  foreign key (content_id, content_version) references public.content_versions(content_id, version),
  constraint task_definitions_provenance_shape check (
    (provenance = 'system' and household_id is null and content_id is not null and content_version is not null and created_by is null and updated_by is null)
    or (provenance = 'user' and household_id is not null and content_id is null and content_version is null and created_by is not null and updated_by is not null)
  ),
  constraint task_definitions_json_shapes check (
    (instructions_content_ref is null or jsonb_typeof(instructions_content_ref) = 'object')
    and jsonb_typeof(metadata) = 'object'
  )
);

create unique index task_definitions_system_content_unique on public.task_definitions (content_id, content_version) where provenance = 'system';

create table public.recommendation_rules (
  content_id text not null,
  version integer not null,
  name text not null,
  description text not null,
  category public.task_category not null,
  eligibility jsonb not null,
  cooldown_days integer not null default 0 check (cooldown_days >= 0),
  frequency_cap jsonb,
  effort_band text not null check (effort_band in ('tiny', 'short', 'moderate', 'extended')),
  default_time_window text check (default_time_window in ('morning', 'midday', 'afternoon', 'evening', 'sleep', 'anytime')),
  default_priority public.priority_tier not null default 'P3',
  explanation_template text not null,
  review_status public.content_review_status not null default 'pending_professional_review',
  effective_from date not null,
  retired_at timestamptz,
  primary key (content_id, version),
  foreign key (content_id, version) references public.content_versions(content_id, version),
  constraint recommendation_rules_content_id check (content_id like 'rule.%'),
  constraint recommendation_rules_json_shapes check (
    jsonb_typeof(eligibility) = 'object'
    and (frequency_cap is null or jsonb_typeof(frequency_cap) = 'object')
  )
);

create table public.training_skills (
  content_id text not null,
  version integer not null,
  skill_group text not null,
  title text not null,
  promise text,
  steps jsonb not null,
  prerequisite_skill_refs text[] not null default '{}',
  stage_guidance text not null,
  effort_band text not null check (effort_band in ('tiny', 'short', 'moderate', 'extended')),
  recommended_frequency text not null,
  common_mistakes text[] not null,
  watch_for text,
  going_well text,
  safety_notes text,
  media_refs jsonb,
  review_status public.content_review_status not null default 'pending_professional_review',
  effective_from date not null,
  retired_at timestamptz,
  primary key (content_id, version),
  foreign key (content_id, version) references public.content_versions(content_id, version),
  constraint training_skills_content_id check (content_id like 'skill.%'),
  constraint training_skills_json_shapes check (
    jsonb_typeof(steps) = 'array'
    and (media_refs is null or jsonb_typeof(media_refs) = 'array')
  )
);

create table public.socialization_catalog (
  content_id text not null,
  version integer not null,
  category text not null,
  experience_key text not null,
  label text not null,
  caution_text text not null,
  response_vocabulary text[] not null,
  review_status public.content_review_status not null default 'pending_professional_review',
  effective_from date not null,
  retired_at timestamptz,
  primary key (content_id, version),
  foreign key (content_id, version) references public.content_versions(content_id, version),
  constraint socialization_catalog_content_id check (content_id like 'soc.%')
);

create table public.task_schedules (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  task_definition_id uuid not null references public.task_definitions(id),
  recurrence jsonb not null check (public.recurrence_rule_is_valid(recurrence)),
  assignment_kind public.assignment_kind not null default 'unassigned',
  assignment_user_id uuid references auth.users(id),
  origin public.schedule_origin not null,
  origin_ref jsonb,
  obligation_class public.obligation_class not null,
  reminder_config jsonb,
  active_range_start_date date not null,
  active_range_until date,
  status public.schedule_status not null default 'active',
  supersedes_schedule_id uuid references public.task_schedules(id),
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id),
  constraint task_schedules_range check (active_range_until is null or active_range_until >= active_range_start_date),
  constraint task_schedules_assignment_shape check (
    (assignment_kind = 'member' and assignment_user_id is not null)
    or (assignment_kind <> 'member' and assignment_user_id is null)
  ),
  constraint task_schedules_json_shapes check (
    (origin_ref is null or jsonb_typeof(origin_ref) = 'object')
    and (reminder_config is null or jsonb_typeof(reminder_config) = 'object')
  )
);

create table public.task_occurrences (
  id uuid primary key default gen_random_uuid(),
  occurrence_key text not null unique,
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  schedule_id uuid references public.task_schedules(id),
  local_due_date date not null,
  original_local_due_date date not null,
  time_policy public.time_policy not null,
  due_time time,
  window_ref text check (window_ref in ('morning', 'midday', 'afternoon', 'evening', 'sleep')),
  assignment_kind public.assignment_kind not null default 'unassigned',
  assignment_user_id uuid references auth.users(id),
  state public.occurrence_state not null default 'pending',
  obligation_class public.obligation_class not null,
  origin public.schedule_origin not null,
  origin_ref jsonb,
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id),
  constraint task_occurrences_time_shape check (
    (time_policy = 'exact_time' and due_time is not null and window_ref is null)
    or (time_policy = 'window' and due_time is null and window_ref is not null)
    or (time_policy = 'anytime' and due_time is null and window_ref is null)
  ),
  constraint task_occurrences_assignment_shape check (
    (assignment_kind = 'member' and assignment_user_id is not null)
    or (assignment_kind <> 'member' and assignment_user_id is null)
  ),
  constraint task_occurrences_schedule_required_for_calendar_key check (schedule_id is not null),
  constraint task_occurrences_json_shapes check ((origin_ref is null or jsonb_typeof(origin_ref) = 'object'))
);

create table public.dispositions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  occurrence_id uuid not null references public.task_occurrences(id) on delete cascade,
  action public.disposition_action not null,
  actor_user_id uuid not null references auth.users(id),
  recorded_at timestamptz not null,
  effective_at timestamptz not null,
  note text,
  skip_reason public.skip_reason,
  snooze_until timestamptz,
  reschedule_to date,
  media_refs jsonb,
  client_idempotency_key text not null,
  superseded boolean not null default false,
  device_metadata jsonb not null default '{}'::jsonb,
  sync_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint dispositions_action_shape check (
    (action = 'skip' and (snooze_until is null and reschedule_to is null))
    or (action = 'snooze' and snooze_until is not null and reschedule_to is null and skip_reason is null)
    or (action = 'reschedule' and reschedule_to is not null and snooze_until is null and skip_reason is null)
    or (action not in ('skip', 'snooze', 'reschedule') and skip_reason is null and snooze_until is null and reschedule_to is null)
  ),
  constraint dispositions_effective_not_future check (effective_at <= recorded_at + interval '5 minutes'),
  constraint dispositions_json_shapes check (
    (media_refs is null or jsonb_typeof(media_refs) = 'array')
    and jsonb_typeof(device_metadata) = 'object'
    and jsonb_typeof(sync_metadata) = 'object'
  )
);

create unique index dispositions_client_idempotency_per_actor on public.dispositions (actor_user_id, client_idempotency_key);
create unique index dispositions_one_effective_completion on public.dispositions (occurrence_id) where action = 'complete' and superseded = false;

create table public.plans (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  local_date date not null,
  time_zone_snapshot text not null,
  stage_snapshot jsonb not null,
  capacity_mode_applied public.capacity_mode not null,
  plan_version integer not null default 1 check (plan_version > 0),
  catalogue_version_set jsonb not null,
  input_digest text not null,
  recommendations_frozen_at timestamptz,
  status public.plan_status not null default 'open',
  generated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint plans_snapshot_shapes check (
    jsonb_typeof(stage_snapshot) = 'object'
    and jsonb_typeof(catalogue_version_set) = 'array'
  )
);

create unique index plans_one_per_pet_day on public.plans (pet_id, local_date);

create table public.plan_items (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.plans(id) on delete cascade,
  item_key text not null,
  kind public.plan_item_kind not null,
  occurrence_id uuid references public.task_occurrences(id),
  recommendation_rule_ref jsonb,
  category public.task_category not null,
  obligation_class public.obligation_class not null,
  priority_tier public.priority_tier not null,
  section public.plan_section not null,
  time_window text check (time_window in ('morning', 'midday', 'afternoon', 'evening', 'sleep', 'anytime')),
  effort_band text check (effort_band in ('tiny', 'short', 'moderate', 'extended')),
  explanation_text text,
  score_components jsonb,
  pinned boolean not null default false,
  display_state public.plan_item_display_state not null default 'planned',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint plan_items_kind_shape check (
    (kind = 'obligation' and occurrence_id is not null and recommendation_rule_ref is null)
    or (kind = 'recommendation' and occurrence_id is null and recommendation_rule_ref is not null)
    or (kind in ('informational', 'upcoming_preview'))
  ),
  constraint plan_items_json_shapes check (
    (recommendation_rule_ref is null or jsonb_typeof(recommendation_rule_ref) = 'object')
    and (score_components is null or jsonb_typeof(score_components) = 'object')
  )
);

create unique index plan_items_stable_key_per_plan on public.plan_items (plan_id, item_key);

create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  actor_user_id uuid references auth.users(id),
  entity_ref jsonb not null,
  action text not null check (char_length(trim(action)) > 0),
  summary jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  reason text,
  created_at timestamptz not null default now(),
  constraint audit_events_json_shapes check (jsonb_typeof(entity_ref) = 'object' and jsonb_typeof(summary) = 'object')
);

create table public.analytics_events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid references public.households(id) on delete cascade,
  actor_user_id uuid references auth.users(id),
  event_name text not null check (event_name in (
    'plan_generated', 'plan_viewed', 'plan_item_completed', 'plan_item_completion_undone',
    'plan_item_skipped', 'plan_item_skip_undone', 'onboarding_step_completed',
    'capacity_mode_changed', 'write_command_failed'
  )),
  occurred_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  constraint analytics_events_metadata_object check (jsonb_typeof(metadata) = 'object')
);

create table public.command_log (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid not null references auth.users(id),
  client_idempotency_key text not null,
  command text not null,
  payload_hash text not null,
  request_body jsonb not null,
  response_body jsonb,
  status public.command_status,
  error_code text,
  recorded_at timestamptz not null,
  effective_at timestamptz,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint command_log_json_shapes check (jsonb_typeof(request_body) = 'object' and (response_body is null or jsonb_typeof(response_body) = 'object'))
);

create unique index command_log_idempotency_per_actor on public.command_log (actor_user_id, client_idempotency_key);

create or replace function public.write_path_create_household(
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
  household_id uuid;
  membership_id uuid;
  response jsonb;
begin
  select * into existing
  from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;

  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'create_household' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  if nullif(trim(payload_input->>'name'), '') is null then
    raise exception 'household name is required' using errcode = '22023';
  end if;
  if nullif(trim(payload_input->>'time_zone'), '') is null then
    raise exception 'household time_zone is required' using errcode = '22023';
  end if;

  household_id := coalesce(nullif(payload_input->>'id', '')::uuid, gen_random_uuid());

  insert into public.households (id, name, time_zone, default_capacity_mode, created_by, updated_by)
  values (
    household_id,
    trim(payload_input->>'name'),
    trim(payload_input->>'time_zone'),
    coalesce(nullif(payload_input->>'default_capacity_mode', '')::public.capacity_mode, 'normal'),
    actor_id,
    actor_id
  );

  insert into public.household_memberships (household_id, user_id, role, status, joined_at, created_by, updated_by)
  values (household_id, actor_id, 'owner', 'active', coalesce(effective_at_input, recorded_at_input), actor_id, actor_id)
  returning id into membership_id;

  insert into public.household_preferences (household_id, default_capacity_mode, created_by, updated_by)
  values (household_id, coalesce(nullif(payload_input->>'default_capacity_mode', '')::public.capacity_mode, 'normal'), actor_id, actor_id);

  insert into public.audit_events (household_id, actor_user_id, entity_ref, action, summary, occurred_at)
  values (
    household_id,
    actor_id,
    jsonb_build_object('type', 'household', 'id', household_id),
    'household.created',
    jsonb_build_object('membership_id', membership_id, 'role', 'owner'),
    recorded_at_input
  );

  response := jsonb_build_object(
    'household', jsonb_build_object('id', household_id, 'name', trim(payload_input->>'name'), 'time_zone', trim(payload_input->>'time_zone')),
    'membership', jsonb_build_object('id', membership_id, 'role', 'owner', 'status', 'active')
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  )
  values (
    actor_id, idempotency_key, 'create_household', payload_hash_input, request_body_input,
    response, 'succeeded', recorded_at_input, effective_at_input, now()
  );

  return response;
end;
$$;

create or replace function public.write_path_create_pet(
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
  household public.households%rowtype;
  pet_id uuid;
  birth_kind public.birth_date_kind;
  pet_species_value public.pet_species;
  response jsonb;
begin
  select * into existing
  from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;

  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'create_pet' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  if nullif(trim(payload_input->>'household_id'), '') is null then
    raise exception 'household_id is required' using errcode = '22023';
  end if;
  if nullif(trim(payload_input->>'name'), '') is null then
    raise exception 'pet name is required' using errcode = '22023';
  end if;

  select * into household
  from public.households
  where id = (payload_input->>'household_id')::uuid
    and status = 'active';

  if not found then
    raise exception 'household not found or closed' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.household_memberships
    where household_id = household.id and user_id = actor_id and status = 'active'
  ) then
    raise exception 'active household membership required' using errcode = '42501';
  end if;

  birth_kind := (payload_input->>'birth_date_kind')::public.birth_date_kind;
  pet_species_value := coalesce(nullif(payload_input->>'species', '')::public.pet_species, 'dog');
  pet_id := coalesce(nullif(payload_input->>'id', '')::uuid, gen_random_uuid());

  if birth_kind = 'exact' and nullif(payload_input->>'birth_date', '')::date > current_date then
    raise exception 'future birth_date is rejected in MVP' using errcode = '22023';
  end if;

  if birth_kind = 'estimated' and nullif(payload_input->>'estimated_as_of_date', '')::date > current_date then
    raise exception 'future estimated_as_of_date is rejected in MVP' using errcode = '22023';
  end if;

  insert into public.pets (
    id, household_id, name, species, breed_text, sex, birth_date_kind, birth_date,
    estimated_age_weeks, estimated_as_of_date, homecoming_date, stage_override,
    food_notes, allergy_notes, microchip_ref, notes, status, created_by, updated_by
  )
  values (
    pet_id,
    household.id,
    trim(payload_input->>'name'),
    pet_species_value,
    nullif(payload_input->>'breed_text', ''),
    nullif(payload_input->>'sex', '')::public.pet_sex,
    birth_kind,
    nullif(payload_input->>'birth_date', '')::date,
    nullif(payload_input->>'estimated_age_weeks', '')::integer,
    nullif(payload_input->>'estimated_as_of_date', '')::date,
    nullif(payload_input->>'homecoming_date', '')::date,
    nullif(payload_input->>'stage_override', ''),
    nullif(payload_input->>'food_notes', ''),
    nullif(payload_input->>'allergy_notes', ''),
    nullif(payload_input->>'microchip_ref', ''),
    nullif(payload_input->>'notes', ''),
    'active',
    actor_id,
    actor_id
  );

  insert into public.pet_preferences (pet_id, household_id, created_by, updated_by)
  values (pet_id, household.id, actor_id, actor_id);

  insert into public.audit_events (household_id, actor_user_id, entity_ref, action, summary, occurred_at)
  values (
    household.id,
    actor_id,
    jsonb_build_object('type', 'pet', 'id', pet_id),
    'pet.created',
    jsonb_build_object('birth_date_kind', birth_kind, 'homecoming_date', payload_input->>'homecoming_date'),
    recorded_at_input
  );

  response := jsonb_build_object(
    'pet',
    jsonb_build_object(
      'id', pet_id,
      'household_id', household.id,
      'name', trim(payload_input->>'name'),
      'species', pet_species_value,
      'birth_date_kind', birth_kind,
      'status', 'active'
    )
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  )
  values (
    actor_id, idempotency_key, 'create_pet', payload_hash_input, request_body_input,
    response, 'succeeded', recorded_at_input, effective_at_input, now()
  );

  return response;
end;
$$;

create trigger user_profiles_set_updated_at before update on public.user_profiles for each row execute function public.set_updated_at();
create trigger households_set_updated_at before update on public.households for each row execute function public.set_updated_at();
create trigger household_invitations_set_updated_at before update on public.household_invitations for each row execute function public.set_updated_at();
create trigger household_memberships_set_updated_at before update on public.household_memberships for each row execute function public.set_updated_at();
create trigger pets_set_updated_at before update on public.pets for each row execute function public.set_updated_at();
create trigger household_preferences_set_updated_at before update on public.household_preferences for each row execute function public.set_updated_at();
create trigger user_preferences_set_updated_at before update on public.user_preferences for each row execute function public.set_updated_at();
create trigger pet_preferences_set_updated_at before update on public.pet_preferences for each row execute function public.set_updated_at();
create trigger task_definitions_set_updated_at before update on public.task_definitions for each row execute function public.set_updated_at();
create trigger task_schedules_set_updated_at before update on public.task_schedules for each row execute function public.set_updated_at();
create trigger task_occurrences_set_updated_at before update on public.task_occurrences for each row execute function public.set_updated_at();
create trigger plans_set_updated_at before update on public.plans for each row execute function public.set_updated_at();
create trigger plan_items_set_updated_at before update on public.plan_items for each row execute function public.set_updated_at();
create trigger audit_events_no_update before update or delete on public.audit_events for each row execute function public.deny_audit_mutation();
create trigger plans_closed_no_update before update or delete on public.plans for each row execute function public.deny_closed_plan_mutation();
create trigger plan_items_closed_plan_no_mutation before update or delete on public.plan_items for each row execute function public.deny_closed_plan_item_mutation();

alter table public.user_profiles enable row level security;
alter table public.households enable row level security;
alter table public.household_memberships enable row level security;
alter table public.household_invitations enable row level security;
alter table public.pets enable row level security;
alter table public.household_preferences enable row level security;
alter table public.user_preferences enable row level security;
alter table public.pet_preferences enable row level security;
alter table public.content_versions enable row level security;
alter table public.development_stages enable row level security;
alter table public.task_definitions enable row level security;
alter table public.recommendation_rules enable row level security;
alter table public.training_skills enable row level security;
alter table public.socialization_catalog enable row level security;
alter table public.task_schedules enable row level security;
alter table public.task_occurrences enable row level security;
alter table public.dispositions enable row level security;
alter table public.plans enable row level security;
alter table public.plan_items enable row level security;
alter table public.audit_events enable row level security;
alter table public.analytics_events enable row level security;
alter table public.command_log enable row level security;

create policy "user profiles self read" on public.user_profiles for select using (id = auth.uid());
create policy "user profiles self insert" on public.user_profiles for insert with check (id = auth.uid());
create policy "user profiles self update" on public.user_profiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy "user preferences self read" on public.user_preferences for select using (user_id = auth.uid());
create policy "user preferences self insert" on public.user_preferences for insert with check (user_id = auth.uid());
create policy "user preferences self update" on public.user_preferences for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "households active member read" on public.households for select using (public.is_active_household_member(id));
create policy "memberships active member read" on public.household_memberships for select using (public.is_active_household_member(household_id));
create policy "invitations active member read" on public.household_invitations for select using (public.is_active_household_member(household_id));
create policy "pets active member read" on public.pets for select using (public.is_active_household_member(household_id));
create policy "household preferences active member read" on public.household_preferences for select using (public.is_active_household_member(household_id));
create policy "pet preferences active member read" on public.pet_preferences for select using (public.is_active_household_member(household_id));
create policy "task definitions read" on public.task_definitions for select using (provenance = 'system' or public.is_active_household_member(household_id));
create policy "task schedules active member read" on public.task_schedules for select using (public.is_active_household_member(household_id));
create policy "task occurrences active member read" on public.task_occurrences for select using (public.is_active_household_member(household_id));
create policy "dispositions active member read" on public.dispositions for select using (public.is_active_household_member(household_id));
create policy "plans active member read" on public.plans for select using (public.is_active_household_member(household_id));
create policy "plan items active member read" on public.plan_items for select using (
  exists (select 1 from public.plans p where p.id = plan_items.plan_id and public.is_active_household_member(p.household_id))
);
create policy "audit events active member read" on public.audit_events for select using (public.is_active_household_member(household_id));
create policy "analytics events active member read" on public.analytics_events for select using (household_id is not null and public.is_active_household_member(household_id));
create policy "command log self read" on public.command_log for select using (actor_user_id = auth.uid());

create policy "content versions world read" on public.content_versions for select using (true);
create policy "development stages world read" on public.development_stages for select using (true);
create policy "recommendation rules world read" on public.recommendation_rules for select using (true);
create policy "training skills world read" on public.training_skills for select using (true);
create policy "socialization catalog world read" on public.socialization_catalog for select using (true);

-- DM 18 write-path-only invariants:
-- 1b: every active household has at least one active owner at all times.
-- 2: invitation acceptance creates exactly one membership atomically; token creation/acceptance behavior is Slice B.
-- 6: occurrence/plan/candidate creation is blocked for archived pets, archived schedules, and closed households.
-- 6: occurrence due dates are validated against schedule active ranges because the schedule recurrence and split semantics are cross-row logic.
-- 7: health_schedule TaskSchedules are mutable only through MedicationSchedule once that entity ships.
-- 8: media and attachment household consistency is deferred until media tables ship.
-- 11: PlanItem content refs point only at published ContentVersions; this needs cross-table lookup during generation.
-- 12: dismiss_required and back-dated completions produce AuditEvents transactionally with their command.
-- Pet birth_date and estimated_as_of_date not-in-future checks are enforced in write_path_create_pet because "future" is time-relative.
