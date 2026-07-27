-- WP-4 generation lifecycle tests. Entire suite rolls back.
\set ON_ERROR_STOP on
begin;

create schema test_generation;
create table test_generation.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);

create or replace function test_generation.record(p_name text, p_passed boolean, p_detail text default null)
returns void
language plpgsql
as $$
begin
  insert into test_generation.results(name, passed, detail) values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %', case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_generation.assert_true(p_name text, p_condition boolean, p_detail text default null)
returns void
language plpgsql
as $$
begin
  perform test_generation.record(p_name, coalesce(p_condition, false), p_detail);
end;
$$;

create or replace function test_generation.expect_sqlstate(p_name text, p_statement text, p_sqlstate text)
returns void
language plpgsql
as $$
begin
  begin
    execute p_statement;
    perform test_generation.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_generation.record(
      p_name,
      sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
)
values (
  'b1000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'generation@test.local', 'x', now(), now(), now(),
  '{}', '{}', false, false
);

insert into public.households (
  id, name, time_zone, status, default_capacity_mode, created_by, updated_by
)
values (
  'b2000000-0000-4000-8000-000000000001', 'Generation Household',
  'America/Toronto', 'active', 'normal',
  'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001'
);

insert into public.household_memberships (
  id, household_id, user_id, role, status, joined_at, created_by, updated_by
)
values (
  'b3000000-0000-4000-8000-000000000001', 'b2000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000001', 'owner', 'active', now(),
  'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001'
);

insert into public.household_preferences (
  household_id, routine_windows, created_by, updated_by
)
values (
  'b2000000-0000-4000-8000-000000000001',
  '{"morning":{"start":"07:00","end":"09:00"}}',
  'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001'
);

insert into public.pets (
  id, household_id, name, species, birth_date_kind, birth_date, homecoming_date,
  status, created_by, updated_by
)
values (
  'b4000000-0000-4000-8000-000000000001', 'b2000000-0000-4000-8000-000000000001',
  'Leap Pup', 'dog', 'exact', '2023-12-01', '2024-02-29', 'active',
  'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001'
);

insert into public.pet_preferences (pet_id, household_id, created_by, updated_by)
values (
  'b4000000-0000-4000-8000-000000000001', 'b2000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001'
);

insert into public.task_definitions (
  id, provenance, household_id, title, category, default_obligation_class,
  default_effort, default_time_policy, created_by, updated_by
)
values
  ('b5000000-0000-4000-8000-000000000001', 'user', 'b2000000-0000-4000-8000-000000000001',
   'Daily care', 'routine', 'scheduled', 'short', 'anytime',
   'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001'),
  ('b5000000-0000-4000-8000-000000000002', 'user', 'b2000000-0000-4000-8000-000000000001',
   'Weekly care', 'routine', 'scheduled', 'short', 'anytime',
   'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001'),
  ('b5000000-0000-4000-8000-000000000003', 'user', 'b2000000-0000-4000-8000-000000000001',
   'Month end care', 'routine', 'scheduled', 'short', 'anytime',
   'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001'),
  ('b5000000-0000-4000-8000-000000000004', 'user', 'b2000000-0000-4000-8000-000000000001',
   'Non-leap month end care', 'routine', 'scheduled', 'short', 'anytime',
   'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001');

insert into public.task_schedules (
  id, household_id, pet_id, task_definition_id, recurrence, assignment_kind,
  origin, obligation_class, active_range_start_date, active_range_until,
  created_by, updated_by
)
values
  ('b6000000-0000-4000-8000-000000000001', 'b2000000-0000-4000-8000-000000000001',
   'b4000000-0000-4000-8000-000000000001', 'b5000000-0000-4000-8000-000000000001',
   '{"type":"daily","anchor_date":"2024-02-26","time_policy":"anytime"}',
   'anyone', 'recurring_schedule', 'scheduled', '2024-02-26', '2024-03-10',
   'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001'),
  ('b6000000-0000-4000-8000-000000000002', 'b2000000-0000-4000-8000-000000000001',
   'b4000000-0000-4000-8000-000000000001', 'b5000000-0000-4000-8000-000000000002',
   '{"type":"weekly","anchor_date":"2024-02-26","time_policy":"anytime"}',
   'anyone', 'recurring_schedule', 'scheduled', '2024-02-26', '2024-03-31',
   'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001'),
  ('b6000000-0000-4000-8000-000000000003', 'b2000000-0000-4000-8000-000000000001',
   'b4000000-0000-4000-8000-000000000001', 'b5000000-0000-4000-8000-000000000003',
   '{"type":"monthly_safe","anchor_date":"2024-01-31","day_of_month":31,"time_policy":"anytime"}',
   'anyone', 'recurring_schedule', 'scheduled', '2024-01-31', '2024-04-30',
   'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001'),
  ('b6000000-0000-4000-8000-000000000004', 'b2000000-0000-4000-8000-000000000001',
   'b4000000-0000-4000-8000-000000000001', 'b5000000-0000-4000-8000-000000000004',
   '{"type":"monthly_safe","anchor_date":"2023-01-31","day_of_month":31,"time_policy":"anytime"}',
   'anyone', 'recurring_schedule', 'scheduled', '2023-01-31', '2023-02-28',
   'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001');

select public.write_path_materialize_occurrences(
  'b1000000-0000-4000-8000-000000000001',
  'b4000000-0000-4000-8000-000000000001',
  '2023-02-25', 4
);
select test_generation.assert_true(
  'monthly_safe clamps day 31 to February 28 in a non-leap year',
  exists (
    select 1 from public.task_occurrences
    where occurrence_key = 'b6000000-0000-4000-8000-000000000004:2023-02-28'
      and original_local_due_date = '2023-02-28'
  )
);

select public.write_path_materialize_occurrences(
  'b1000000-0000-4000-8000-000000000001',
  'b4000000-0000-4000-8000-000000000001',
  '2024-02-26', 14
);
select test_generation.assert_true(
  'daily and weekly schedules materialize the expected dates',
  (select count(*) = 14 from public.task_occurrences where schedule_id = 'b6000000-0000-4000-8000-000000000001')
  and (select count(*) = 2 from public.task_occurrences where schedule_id = 'b6000000-0000-4000-8000-000000000002')
);
select test_generation.assert_true(
  'monthly_safe produces February 29 in a leap year with a deterministic key',
  exists (
    select 1 from public.task_occurrences
    where occurrence_key = 'b6000000-0000-4000-8000-000000000003:2024-02-29'
      and original_local_due_date = '2024-02-29'
  )
);

select public.write_path_materialize_occurrences(
  'b1000000-0000-4000-8000-000000000001',
  'b4000000-0000-4000-8000-000000000001',
  '2024-02-26', 14
);
select test_generation.assert_true(
  'materialization replay is idempotent',
  (select count(*) = 14 from public.task_occurrences where schedule_id = 'b6000000-0000-4000-8000-000000000001')
  and (select count(*) = 2 from public.task_occurrences where schedule_id = 'b6000000-0000-4000-8000-000000000002')
  and (select count(*) = 1 from public.task_occurrences where occurrence_key = 'b6000000-0000-4000-8000-000000000003:2024-02-29')
);

select test_generation.assert_true(
  'household local date observes the household time zone across a UTC boundary',
  public.household_current_local_date(
    'b2000000-0000-4000-8000-000000000001',
    '2024-03-01 02:30:00+00'
  ) = '2024-02-29'
);

insert into public.content_versions (
  content_id, version, content_type, publication_status, review_status,
  source_category, author, authored_on, effective_from
)
values (
  'rule.test', 1, 'recommendation_rule', 'published',
  'pending_professional_review', 'test', 'test suite', '2024-01-01', '2024-01-01'
)
on conflict (content_id, version) do nothing;

insert into public.recommendation_rules (
  content_id, version, name, description, category, eligibility, cooldown_days,
  effort_band, default_time_window, default_priority, explanation_template,
  review_status, effective_from
)
values (
  'rule.test', 1, 'Test rule', 'Test-only recommendation', 'training', '{}', 0,
  'tiny', 'anytime', 'P3', 'A useful test.',
  'pending_professional_review', '2024-01-01'
)
on conflict (content_id, version) do nothing;

select public.write_path_persist_plan(
  'b1000000-0000-4000-8000-000000000001',
  '{
    "household_id":"b2000000-0000-4000-8000-000000000001",
    "pet_id":"b4000000-0000-4000-8000-000000000001",
    "local_date":"2024-02-29",
    "time_zone_snapshot":"America/Toronto",
    "stage_snapshot":{"stage_key":"foundations","content_id":null,"version":null},
    "capacity_mode_applied":"normal",
    "catalogue_version_set":[],
    "input_digest":"digest-1",
    "generated_at":"2024-02-29T13:00:00Z"
  }',
  '[
    {
      "item_key":"occ:b6000000-0000-4000-8000-000000000003:2024-02-29",
      "kind":"informational",
      "occurrence_id":null,
      "recommendation_rule_ref":null,
      "content_ref":null,
      "title":"Month end care",
      "category":"routine",
      "obligation_class":"informational",
      "priority_tier":"P2",
      "section":"today",
      "time_window":null,
      "due_time":null,
      "effort_band":"short",
      "explanation_text":null,
      "score_components":null,
      "pinned":false,
      "display_state":"planned",
      "origin":"recurring_schedule",
      "completion":null
    },
    {
      "item_key":"rec:test",
      "kind":"recommendation",
      "occurrence_id":null,
      "recommendation_rule_ref":{"content_id":"rule.test","version":1},
      "content_ref":null,
      "title":"Try a tiny activity",
      "category":"training",
      "obligation_class":"recommended",
      "priority_tier":"P3",
      "section":"recommended",
      "time_window":"anytime",
      "due_time":null,
      "effort_band":"tiny",
      "explanation_text":"A useful test.",
      "score_components":null,
      "pinned":false,
      "display_state":"planned",
      "origin":"development_rule",
      "completion":null
    }
  ]',
  '{"selected_recommendation_count":1}'
);

select public.write_path_persist_plan(
  'b1000000-0000-4000-8000-000000000001',
  '{
    "household_id":"b2000000-0000-4000-8000-000000000001",
    "pet_id":"b4000000-0000-4000-8000-000000000001",
    "local_date":"2024-02-29",
    "time_zone_snapshot":"America/Toronto",
    "stage_snapshot":{"stage_key":"foundations","content_id":null,"version":null},
    "capacity_mode_applied":"normal",
    "catalogue_version_set":[],
    "input_digest":"digest-2",
    "generated_at":"2024-02-29T13:01:00Z"
  }',
  jsonb_build_array(
    jsonb_build_object(
      'item_key', 'occ:b6000000-0000-4000-8000-000000000003:2024-02-29',
      'kind', 'obligation',
      'occurrence_id', (select id from public.task_occurrences where occurrence_key = 'b6000000-0000-4000-8000-000000000003:2024-02-29'),
      'recommendation_rule_ref', null,
      'content_ref', null,
      'title', 'Month end care (stable key)',
      'category', 'routine',
      'obligation_class', 'scheduled',
      'priority_tier', 'P2',
      'section', 'today',
      'time_window', null,
      'due_time', null,
      'effort_band', 'short',
      'explanation_text', null,
      'score_components', null,
      'pinned', false,
      'display_state', 'planned',
      'origin', 'recurring_schedule',
      'completion', null
    ),
    jsonb_build_object(
      'item_key', 'rec:test',
      'kind', 'recommendation',
      'occurrence_id', null,
      'recommendation_rule_ref', jsonb_build_object('content_id', 'rule.test', 'version', 1),
      'content_ref', null,
      'title', 'Try a tiny activity',
      'category', 'training',
      'obligation_class', 'recommended',
      'priority_tier', 'P3',
      'section', 'recommended',
      'time_window', 'anytime',
      'due_time', null,
      'effort_band', 'tiny',
      'explanation_text', 'A useful test.',
      'score_components', null,
      'pinned', false,
      'display_state', 'planned',
      'origin', 'development_rule',
      'completion', null
    )
  ),
  '{"selected_recommendation_count":1}'
);

select test_generation.assert_true(
  'plan persistence bumps version and upserts stable item keys without duplicates',
  (select plan_version = 2 from public.plans where pet_id = 'b4000000-0000-4000-8000-000000000001' and local_date = '2024-02-29')
  and (select count(*) = 2 from public.plan_items pi join public.plans p on p.id = pi.plan_id
       where p.pet_id = 'b4000000-0000-4000-8000-000000000001' and p.local_date = '2024-02-29')
  and (select title = 'Month end care (stable key)' from public.plan_items pi join public.plans p on p.id = pi.plan_id
       where p.pet_id = 'b4000000-0000-4000-8000-000000000001' and p.local_date = '2024-02-29'
         and pi.item_key = 'occ:b6000000-0000-4000-8000-000000000003:2024-02-29')
);

select test_generation.assert_true(
  'generation context crosses the household-local homecoming boundary',
  (public.write_path_generation_context(
    'b1000000-0000-4000-8000-000000000001',
    'b4000000-0000-4000-8000-000000000001',
    null,
    '2024-02-29 04:30:00+00'
  ) ->> 'local_date') = '2024-02-28'
  and (public.write_path_generation_context(
    'b1000000-0000-4000-8000-000000000001',
    'b4000000-0000-4000-8000-000000000001',
    null,
    '2024-02-29 04:30:00+00'
  ) #>> '{pet,expected_homecoming_date}') = '2024-02-29'
  and (public.write_path_generation_context(
    'b1000000-0000-4000-8000-000000000001',
    'b4000000-0000-4000-8000-000000000001',
    null,
    '2024-02-29 05:30:00+00'
  ) ->> 'local_date') = '2024-02-29'
);

-- The close call has side effects, so it must be sequenced BEFORE the state
-- reads: Postgres does not guarantee left-to-right AND evaluation, and putting
-- the call inside the conjunction made the reads observe pre-close state.
do $$
declare
  close_result jsonb;
begin
  close_result := public.close_plans_for_date('2024-02-29');
  perform test_generation.record(
    'day close expires planned recommendations and closes the plan',
    (close_result->>'plans_closed')::integer = 1
    and (select status = 'closed' from public.plans where pet_id = 'b4000000-0000-4000-8000-000000000001' and local_date = '2024-02-29')
    and (select display_state = 'expired' from public.plan_items pi join public.plans p on p.id = pi.plan_id
         where p.pet_id = 'b4000000-0000-4000-8000-000000000001' and p.local_date = '2024-02-29'
           and pi.item_key = 'rec:test')
  );
end $$;

-- Timezone-aware automatic close only closes plans whose own local day elapsed.
insert into public.plans (
  id, household_id, pet_id, local_date, time_zone_snapshot, stage_snapshot,
  capacity_mode_applied, catalogue_version_set, input_digest, status,
  created_by, updated_by
) values (
  'b8000000-0000-4000-8000-000000000002',
  'b2000000-0000-4000-8000-000000000001',
  'b4000000-0000-4000-8000-000000000001',
  '2024-03-01', 'America/Toronto', '{"stage_key":"foundations"}',
  'normal', '[]', 'digest-current-day', 'open',
  'b1000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000001'
);
do $$
declare
  close_result jsonb;
begin
  close_result := public.close_elapsed_plans('2024-03-02 04:30:00+00');
  perform test_generation.record(
    'elapsed close respects each plan timezone local date',
    (close_result->>'plans_closed')::integer = 0
    and (select status = 'open' from public.plans where id = 'b8000000-0000-4000-8000-000000000002')
  );
  close_result := public.close_elapsed_plans('2024-03-02 05:30:00+00');
  perform test_generation.record(
    'elapsed close runs after local midnight',
    (close_result->>'plans_closed')::integer = 1
    and (select status = 'closed' from public.plans where id = 'b8000000-0000-4000-8000-000000000002')
  );
end $$;

select test_generation.expect_sqlstate(
  'closed plans refuse regeneration',
  $sql$select public.write_path_persist_plan(
    'b1000000-0000-4000-8000-000000000001',
    '{
      "household_id":"b2000000-0000-4000-8000-000000000001",
      "pet_id":"b4000000-0000-4000-8000-000000000001",
      "local_date":"2024-02-29",
      "time_zone_snapshot":"America/Toronto",
      "stage_snapshot":{"stage_key":"foundations"},
      "capacity_mode_applied":"normal",
      "catalogue_version_set":[],
      "input_digest":"closed",
      "generated_at":"2024-02-29T13:02:00Z"
    }',
    '[]',
    '{}'
  )$sql$,
  '55000'
);

do $$
declare
  failed_count integer;
begin
  select count(*) into failed_count from test_generation.results where not passed;
  if failed_count > 0 then
    raise exception '% generation lifecycle assertion(s) failed', failed_count;
  end if;
end;
$$;

rollback;
