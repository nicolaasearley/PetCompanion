-- Event notification candidates (US-086).
--
-- Covers:
--   * create with reminder_config schedules event_reminder candidates;
--   * reschedule cancels stale scheduled rows and creates new ones;
--   * cancel clears scheduled candidates (none remain scheduled);
--   * archive clears scheduled candidates;
--   * verify_due cancels when the event is no longer confirmed.
--
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_event_notify;
create table test_event_notify.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create table test_event_notify.state (key text primary key, value text);

create or replace function test_event_notify.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_event_notify.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_event_notify.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  perform test_event_notify.record(p_name, coalesce(p_condition, false), p_detail);
end;
$$;

create or replace function test_event_notify.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_event_notify.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_event_notify.val(p_key text)
returns text language sql stable as $$
  select value from test_event_notify.state where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (2 active members → 2 recipients per lead)
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('f4440000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'evt-notify-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('f4440000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'evt-notify-partner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.user_profiles(id, display_name) values
  ('f4440000-0000-4000-8000-000000000001', 'Nic'),
  ('f4440000-0000-4000-8000-000000000002', 'Sarah');

insert into public.households (id, name, time_zone, created_by, updated_by) values
  ('f5550000-0000-4000-8000-000000000001', 'Notify House', 'America/Toronto',
   'f4440000-0000-4000-8000-000000000001', 'f4440000-0000-4000-8000-000000000001');

insert into public.household_memberships (
  id, household_id, user_id, role, status, created_by, updated_by
) values
  ('f6660000-0000-4000-8000-000000000001', 'f5550000-0000-4000-8000-000000000001',
   'f4440000-0000-4000-8000-000000000001', 'owner', 'active',
   'f4440000-0000-4000-8000-000000000001', 'f4440000-0000-4000-8000-000000000001'),
  ('f6660000-0000-4000-8000-000000000002', 'f5550000-0000-4000-8000-000000000001',
   'f4440000-0000-4000-8000-000000000002', 'caregiver', 'active',
   'f4440000-0000-4000-8000-000000000001', 'f4440000-0000-4000-8000-000000000001');

insert into public.household_preferences (household_id, default_capacity_mode, created_by, updated_by)
values (
  'f5550000-0000-4000-8000-000000000001', 'normal',
  'f4440000-0000-4000-8000-000000000001', 'f4440000-0000-4000-8000-000000000001'
);

insert into public.pets (
  id, household_id, name, species, birth_date_kind, birth_date, created_by, updated_by
) values (
  'f7770000-0000-4000-8000-000000000001', 'f5550000-0000-4000-8000-000000000001',
  'Maple', 'dog', 'exact', '2026-04-01',
  'f4440000-0000-4000-8000-000000000001', 'f4440000-0000-4000-8000-000000000001'
);

insert into public.pet_preferences (pet_id, household_id, created_by, updated_by)
values (
  'f7770000-0000-4000-8000-000000000001',
  'f5550000-0000-4000-8000-000000000001',
  'f4440000-0000-4000-8000-000000000001',
  'f4440000-0000-4000-8000-000000000001'
);

select test_event_notify.put('owner', 'f4440000-0000-4000-8000-000000000001');
select test_event_notify.put('household', 'f5550000-0000-4000-8000-000000000001');
select test_event_notify.put('pet', 'f7770000-0000-4000-8000-000000000001');
select test_event_notify.put(
  'start_date',
  (date '2026-11-10')::text
);
select test_event_notify.put(
  'reschedule_date',
  (date '2026-11-12')::text
);

-- ---------------------------------------------------------------------------
-- Create schedules candidates (2 leads × 2 members = 4)
-- ---------------------------------------------------------------------------

select test_event_notify.put('create_resp', public.write_path_create_event(
  test_event_notify.val('owner')::uuid,
  'evt-notify-create',
  'hash-evt-notify-create',
  '{}'::jsonb,
  '2026-11-01 12:00:00+00'::timestamptz,
  '2026-11-01 12:00:00+00'::timestamptz,
  jsonb_build_object(
    'event_id', 'f8880000-0000-4000-8000-000000000001',
    'household_id', test_event_notify.val('household'),
    'pet_id', test_event_notify.val('pet'),
    'kind', 'vet_appointment',
    'title', 'Vaccines',
    'start_date', test_event_notify.val('start_date'),
    'all_day', false,
    'start_time', '14:00',
    'reminder_config', jsonb_build_object('lead_minutes', jsonb_build_array(60, 1440))
  )
)::text);

select test_event_notify.assert_true(
  'create_event schedules notification candidates',
  (test_event_notify.val('create_resp')::jsonb->>'notification_candidates_scheduled')::integer = 4
  and (
    select count(*) from public.notification_candidates
    where event_id = 'f8880000-0000-4000-8000-000000000001'
      and class = 'event_reminder'
      and state = 'scheduled'
  ) = 4
);

select test_event_notify.assert_true(
  'create candidates use event start minus lead minutes',
  (
    select count(*) from public.notification_candidates nc
    where nc.event_id = 'f8880000-0000-4000-8000-000000000001'
      and nc.state = 'scheduled'
      and nc.scheduled_for = public.resolve_household_wall_time(
        test_event_notify.val('start_date')::date,
        time '14:00',
        'America/Toronto'
      ) - interval '60 minutes'
  ) = 2
  and (
    select count(*) from public.notification_candidates nc
    where nc.event_id = 'f8880000-0000-4000-8000-000000000001'
      and nc.state = 'scheduled'
      and nc.scheduled_for = public.resolve_household_wall_time(
        test_event_notify.val('start_date')::date,
        time '14:00',
        'America/Toronto'
      ) - interval '1440 minutes'
  ) = 2
);

-- ---------------------------------------------------------------------------
-- Reschedule updates candidates (US-086)
-- ---------------------------------------------------------------------------

select test_event_notify.put('edit_resp', public.write_path_edit_event(
  test_event_notify.val('owner')::uuid,
  'evt-notify-reschedule',
  'hash-evt-notify-reschedule',
  '{}'::jsonb,
  '2026-11-01 12:05:00+00'::timestamptz,
  '2026-11-01 12:05:00+00'::timestamptz,
  jsonb_build_object(
    'event_id', 'f8880000-0000-4000-8000-000000000001',
    'expected_revision', 1,
    'start_date', test_event_notify.val('reschedule_date'),
    'start_time', '10:00',
    'all_day', false
  )
)::text);

select test_event_notify.assert_true(
  'reschedule schedules new candidates and returns count',
  (test_event_notify.val('edit_resp')::jsonb->>'notification_candidates_scheduled')::integer = 4
  and (
    select count(*) from public.notification_candidates
    where event_id = 'f8880000-0000-4000-8000-000000000001'
      and class = 'event_reminder'
      and state = 'scheduled'
  ) = 4
);

select test_event_notify.assert_true(
  'reschedule cancels prior scheduled candidates',
  (
    select count(*) from public.notification_candidates
    where event_id = 'f8880000-0000-4000-8000-000000000001'
      and state = 'cancelled'
      and resolution_reason = 'candidate_replaced'
  ) = 4
);

select test_event_notify.assert_true(
  'reschedule candidates use the new start instant',
  (
    select count(*) from public.notification_candidates nc
    where nc.event_id = 'f8880000-0000-4000-8000-000000000001'
      and nc.state = 'scheduled'
      and nc.scheduled_for = public.resolve_household_wall_time(
        test_event_notify.val('reschedule_date')::date,
        time '10:00',
        'America/Toronto'
      ) - interval '60 minutes'
  ) = 2
  and (
    select count(*) = 0 from public.notification_candidates nc
    where nc.event_id = 'f8880000-0000-4000-8000-000000000001'
      and nc.state = 'scheduled'
      and nc.scheduled_for = public.resolve_household_wall_time(
        test_event_notify.val('start_date')::date,
        time '14:00',
        'America/Toronto'
      ) - interval '60 minutes'
  )
);

-- ---------------------------------------------------------------------------
-- Cancel clears scheduled candidates
-- ---------------------------------------------------------------------------

select test_event_notify.put('cancel_resp', public.write_path_cancel_event(
  test_event_notify.val('owner')::uuid,
  'evt-notify-cancel',
  'hash-evt-notify-cancel',
  '{}'::jsonb,
  '2026-11-01 12:10:00+00'::timestamptz,
  '2026-11-01 12:10:00+00'::timestamptz,
  jsonb_build_object(
    'event_id', 'f8880000-0000-4000-8000-000000000001',
    'expected_revision', 2
  )
)::text);

select test_event_notify.assert_true(
  'cancel_event clears scheduled candidates',
  (test_event_notify.val('cancel_resp')::jsonb->>'notification_candidates_scheduled')::integer = 0
  and (
    select count(*) from public.notification_candidates
    where event_id = 'f8880000-0000-4000-8000-000000000001'
      and state = 'scheduled'
  ) = 0
  and (
    select count(*) from public.notification_candidates
    where event_id = 'f8880000-0000-4000-8000-000000000001'
      and state = 'cancelled'
      and resolution_reason = 'event_cancelled'
  ) = 4
);

-- Restore via edit (cancelled → confirmed) and re-schedule
select public.write_path_edit_event(
  test_event_notify.val('owner')::uuid,
  'evt-notify-restore',
  'hash-evt-notify-restore',
  '{}'::jsonb,
  '2026-11-01 12:15:00+00'::timestamptz,
  '2026-11-01 12:15:00+00'::timestamptz,
  jsonb_build_object(
    'event_id', 'f8880000-0000-4000-8000-000000000001',
    'expected_revision', 3,
    'start_date', test_event_notify.val('reschedule_date'),
    'start_time', '10:00',
    'all_day', false
  )
);

select test_event_notify.assert_true(
  'edit of cancelled event restores candidates',
  (
    select count(*) from public.notification_candidates
    where event_id = 'f8880000-0000-4000-8000-000000000001'
      and state = 'scheduled'
  ) = 4
  and (
    select status = 'confirmed' from public.events
    where id = 'f8880000-0000-4000-8000-000000000001'
  )
);

-- ---------------------------------------------------------------------------
-- Archive clears scheduled candidates
-- ---------------------------------------------------------------------------

select test_event_notify.put('archive_resp', public.write_path_archive_event(
  test_event_notify.val('owner')::uuid,
  'evt-notify-archive',
  'hash-evt-notify-archive',
  '{}'::jsonb,
  '2026-11-01 12:20:00+00'::timestamptz,
  '2026-11-01 12:20:00+00'::timestamptz,
  jsonb_build_object(
    'event_id', 'f8880000-0000-4000-8000-000000000001',
    'expected_revision', 4
  )
)::text);

select test_event_notify.assert_true(
  'archive_event clears scheduled candidates',
  (test_event_notify.val('archive_resp')::jsonb->>'notification_candidates_scheduled')::integer = 0
  and (
    select count(*) from public.notification_candidates
    where event_id = 'f8880000-0000-4000-8000-000000000001'
      and state = 'scheduled'
  ) = 0
  and (
    select count(*) from public.notification_candidates
    where event_id = 'f8880000-0000-4000-8000-000000000001'
      and state = 'cancelled'
      and resolution_reason = 'event_archived'
  ) >= 4
);

-- ---------------------------------------------------------------------------
-- verify_due cancels event_reminder when event is cancelled (pre-seeded)
-- ---------------------------------------------------------------------------

select public.write_path_create_event(
  test_event_notify.val('owner')::uuid,
  'evt-notify-verify',
  'hash-evt-notify-verify',
  '{}'::jsonb,
  '2026-11-01 12:25:00+00'::timestamptz,
  '2026-11-01 12:25:00+00'::timestamptz,
  jsonb_build_object(
    'event_id', 'f8880000-0000-4000-8000-000000000002',
    'household_id', test_event_notify.val('household'),
    'kind', 'class',
    'title', 'Puppy class',
    'start_date', '2026-11-05',
    'all_day', false,
    'start_time', '09:00',
    'reminder_config', jsonb_build_object('lead_minutes', jsonb_build_array(0))
  )
);

-- Force candidates due in the past, then cancel the event without going through
-- refresh (direct status flip) so verify must catch the stale row.
update public.notification_candidates
set scheduled_for = '2026-11-01 12:00:00+00'::timestamptz
where event_id = 'f8880000-0000-4000-8000-000000000002'
  and state = 'scheduled';

update public.events
set status = 'cancelled'
where id = 'f8880000-0000-4000-8000-000000000002';

select test_event_notify.put(
  'verify_resp',
  public.verify_due_notification_candidates(
    '2026-11-01 13:00:00+00'::timestamptz,
    50
  )::text
);

select test_event_notify.assert_true(
  'verify_due cancels event_reminder for cancelled events',
  (test_event_notify.val('verify_resp')::jsonb->>'cancelled_count')::integer >= 2
  and (
    select count(*) from public.notification_candidates
    where event_id = 'f8880000-0000-4000-8000-000000000002'
      and state = 'scheduled'
  ) = 0
  and (
    select count(*) from public.notification_candidates
    where event_id = 'f8880000-0000-4000-8000-000000000002'
      and state = 'cancelled'
      and resolution_reason = 'event_cancelled'
  ) >= 2
);

-- ---------------------------------------------------------------------------
-- No reminder_config → no candidates
-- ---------------------------------------------------------------------------

select test_event_notify.put('no_reminder_resp', public.write_path_create_event(
  test_event_notify.val('owner')::uuid,
  'evt-notify-none',
  'hash-evt-notify-none',
  '{}'::jsonb,
  '2026-11-01 12:30:00+00'::timestamptz,
  '2026-11-01 12:30:00+00'::timestamptz,
  jsonb_build_object(
    'event_id', 'f8880000-0000-4000-8000-000000000003',
    'household_id', test_event_notify.val('household'),
    'kind', 'other',
    'title', 'Quiet meetup',
    'start_date', '2026-11-20',
    'all_day', true
  )
)::text);

select test_event_notify.assert_true(
  'create without reminder_config schedules zero candidates',
  (test_event_notify.val('no_reminder_resp')::jsonb->>'notification_candidates_scheduled')::integer = 0
  and (
    select count(*) from public.notification_candidates
    where event_id = 'f8880000-0000-4000-8000-000000000003'
  ) = 0
);

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

do $$
declare
  failed integer;
begin
  select count(*) into failed from test_event_notify.results where not passed;
  if failed > 0 then
    raise exception '% event notification assertion(s) failed', failed;
  end if;
  raise notice 'Event notification candidates suite: all assertions passed';
end;
$$;

rollback;
