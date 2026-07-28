-- Socialization passport tests (F09, E06, DM 10 §12.4).
--
-- Covers the invariants this slice owns:
--   * a record is OWNER-REPORTED and non-diagnostic -- the response vocabulary
--     is closed, and no score, count, or rating is stored or derivable;
--   * an ACTIVE exclusion is a HARD eligibility constraint that reaches the
--     engine through write_path_generation_context, and is REVERSIBLE without
--     losing the decision or the past records (US-068);
--   * DM §18.10 household/pet consistency, §18.6 archived pets and closed
--     households, §18.11 published content only;
--   * cross-household isolation under RLS, and the SECURITY DEFINER lockdown;
--   * category recency reaches the generation context from real records, which
--     is what lets the breadth rule rotate (US-067, catalogue §9).
--
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_socialization;
create table test_socialization.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create table test_socialization.state (key text primary key, value text);

grant usage on schema test_socialization to authenticated;
grant select, insert, update on test_socialization.results, test_socialization.state to authenticated;
grant usage, select on all sequences in schema test_socialization to authenticated;

create or replace function test_socialization.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_socialization.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_socialization.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin perform test_socialization.record(p_name, coalesce(p_condition, false), p_detail); end;
$$;

create or replace function test_socialization.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_socialization.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_socialization.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

create or replace function test_socialization.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_socialization.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_socialization.val(p_key text)
returns text language sql stable as $$
  select value from test_socialization.state where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures: two independent households, plus an archived pet and an outsider.
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('44440000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'soc-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('44440000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'soc-partner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('44440000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'soc-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.user_profiles(id, display_name) values
  ('44440000-0000-4000-8000-000000000001', 'Nic'),
  ('44440000-0000-4000-8000-000000000002', 'Sarah'),
  ('44440000-0000-4000-8000-000000000003', 'Outsider');

insert into public.households (id, name, time_zone, created_by, updated_by) values
  ('55550000-0000-4000-8000-000000000001', 'Maple House', 'America/Toronto',
   '44440000-0000-4000-8000-000000000001', '44440000-0000-4000-8000-000000000001'),
  ('55550000-0000-4000-8000-000000000002', 'Elsewhere House', 'Europe/Stockholm',
   '44440000-0000-4000-8000-000000000003', '44440000-0000-4000-8000-000000000003');

insert into public.household_memberships (
  household_id, user_id, role, status, joined_at, created_by, updated_by
) values
  ('55550000-0000-4000-8000-000000000001', '44440000-0000-4000-8000-000000000001',
   'owner', 'active', now(), '44440000-0000-4000-8000-000000000001', '44440000-0000-4000-8000-000000000001'),
  ('55550000-0000-4000-8000-000000000001', '44440000-0000-4000-8000-000000000002',
   'caregiver', 'active', now(), '44440000-0000-4000-8000-000000000001', '44440000-0000-4000-8000-000000000001'),
  ('55550000-0000-4000-8000-000000000002', '44440000-0000-4000-8000-000000000003',
   'owner', 'active', now(), '44440000-0000-4000-8000-000000000003', '44440000-0000-4000-8000-000000000003');

insert into public.pets (
  id, household_id, name, birth_date_kind, birth_date, status, created_by, updated_by
) values
  ('66660000-0000-4000-8000-000000000001', '55550000-0000-4000-8000-000000000001',
   'Maple', 'exact', current_date - 80, 'active',
   '44440000-0000-4000-8000-000000000001', '44440000-0000-4000-8000-000000000001'),
  ('66660000-0000-4000-8000-000000000002', '55550000-0000-4000-8000-000000000001',
   'Willow', 'exact', current_date - 200, 'archived',
   '44440000-0000-4000-8000-000000000001', '44440000-0000-4000-8000-000000000001'),
  ('66660000-0000-4000-8000-000000000003', '55550000-0000-4000-8000-000000000002',
   'Birch', 'exact', current_date - 90, 'active',
   '44440000-0000-4000-8000-000000000003', '44440000-0000-4000-8000-000000000003');

insert into public.household_preferences (household_id, created_by, updated_by) values
  ('55550000-0000-4000-8000-000000000001', '44440000-0000-4000-8000-000000000001',
   '44440000-0000-4000-8000-000000000001'),
  ('55550000-0000-4000-8000-000000000002', '44440000-0000-4000-8000-000000000003',
   '44440000-0000-4000-8000-000000000003');

-- ---------------------------------------------------------------------------
-- 1. Recording an experience (US-067, TR-08).
-- ---------------------------------------------------------------------------

select test_socialization.put(
  'record_1',
  public.write_path_record_socialization(
    '44440000-0000-4000-8000-000000000001', 'soc-record-1', 'hash-record-1',
    '{"command":"record_socialization"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', '66660000-0000-4000-8000-000000000001',
      'record_id', '77770000-0000-4000-8000-000000000001',
      'experience_content_id', 'soc.sounds.vacuum_low',
      'context', 'Two rooms away with the door open',
      'response', 'curious',
      'note', 'Went back to chewing after ten seconds'
    )
  )::text
);

select test_socialization.assert_true(
  'recording an experience stores the owner-reported response and the catalogue reference',
  (test_socialization.val('record_1')::jsonb -> 'record' ->> 'response') = 'curious'
  and (test_socialization.val('record_1')::jsonb -> 'record' -> 'experience_ref' ->> 'content_id')
      = 'soc.sounds.vacuum_low'
  and (test_socialization.val('record_1')::jsonb -> 'record' ->> 'created_by_name') = 'Nic'
  and (select category = 'Sounds'
        and household_id = '55550000-0000-4000-8000-000000000001'
        and effective_date = (now() at time zone 'America/Toronto')::date
       from public.socialization_records
       where id = '77770000-0000-4000-8000-000000000001')
);

select test_socialization.assert_true(
  'the category comes from the catalogue, never from the client',
  (select category = 'Sounds' from public.socialization_records
   where id = (public.write_path_record_socialization(
     '44440000-0000-4000-8000-000000000001', 'soc-record-mislabel', 'hash-mislabel',
     '{}'::jsonb, now(), null,
     jsonb_build_object(
       'pet_id', '66660000-0000-4000-8000-000000000001',
       'experience_content_id', 'soc.sounds.doorbell',
       'category', 'Transportation',
       'response', 'relaxed'
     )
   ) -> 'record' ->> 'id')::uuid)
);

select test_socialization.assert_true(
  'recording is audited with the category and vocabulary term but never the caregiver''s note',
  (select count(*) = 1 and bool_and(
            summary ->> 'category' = 'Sounds'
            and summary ->> 'response' = 'curious'
            and position('chewing' in summary::text) = 0)
   from public.audit_events
   where entity_ref ->> 'id' = '77770000-0000-4000-8000-000000000001'
     and action = 'socialization.recorded')
);

select test_socialization.assert_true(
  'a custom experience is recorded against a category with no catalogue reference',
  (select custom_label = 'Neighbour''s wheelie bin'
        and category = 'Household objects'
        and experience_content_id is null
   from public.socialization_records
   where id = (public.write_path_record_socialization(
     '44440000-0000-4000-8000-000000000002', 'soc-record-custom', 'hash-custom',
     '{}'::jsonb, now(), null,
     jsonb_build_object(
       'pet_id', '66660000-0000-4000-8000-000000000001',
       'custom_label', 'Neighbour''s wheelie bin',
       'category', 'Household objects',
       'response', 'hesitant'
     )
   ) -> 'record' ->> 'id')::uuid)
);

-- ---------------------------------------------------------------------------
-- 2. The response vocabulary is closed and non-diagnostic (catalogue §8).
-- ---------------------------------------------------------------------------

select test_socialization.expect_sqlstate(
  'a response outside the owner-reported vocabulary is rejected, so nothing can read as a diagnosis',
  $s$select public.write_path_record_socialization(
    '44440000-0000-4000-8000-000000000001', 'soc-record-bad-response', 'hash-bad-response',
    '{}'::jsonb, now(), null,
    '{"pet_id":"66660000-0000-4000-8000-000000000001",
      "experience_content_id":"soc.people.child_distance","response":"reactive"}'
  )$s$,
  '22023'
);

select test_socialization.assert_true(
  'the stored vocabulary is exactly the five catalogue §8 terms',
  (select array_agg(enumlabel::text order by enumsortorder)
   from pg_enum where enumtypid = 'public.socialization_response'::regtype)
  = array['relaxed', 'curious', 'neutral', 'hesitant', 'fearful']
);

select test_socialization.assert_true(
  'no score, rating, count, or streak column exists on either table (F09 exclusion)',
  (select count(*) = 0
   from information_schema.columns
   where table_schema = 'public'
     and table_name in ('socialization_records', 'socialization_exclusions')
     and (column_name ~* 'score|rating|streak|level|percent|progress'
          or column_name in ('count', 'total')))
);

select test_socialization.expect_sqlstate(
  'a custom experience must still name one of the eight F09 categories',
  $s$select public.write_path_record_socialization(
    '44440000-0000-4000-8000-000000000001', 'soc-record-bad-category', 'hash-bad-category',
    '{}'::jsonb, now(), null,
    '{"pet_id":"66660000-0000-4000-8000-000000000001",
      "custom_label":"Hot air balloon","category":"Weather","response":"curious"}'
  )$s$,
  '22023'
);

select test_socialization.expect_sqlstate(
  'a record must identify either a catalogue experience or a custom label, never both',
  $s$select public.write_path_record_socialization(
    '44440000-0000-4000-8000-000000000001', 'soc-record-both', 'hash-both',
    '{}'::jsonb, now(), null,
    '{"pet_id":"66660000-0000-4000-8000-000000000001",
      "experience_content_id":"soc.surfaces.grass","custom_label":"Grass","response":"relaxed"}'
  )$s$,
  '22023'
);

select test_socialization.expect_sqlstate(
  'an experience cannot be recorded before it happens',
  $s$select public.write_path_record_socialization(
    '44440000-0000-4000-8000-000000000001', 'soc-record-future', 'hash-future',
    '{}'::jsonb, now(), null,
    format('{"pet_id":"66660000-0000-4000-8000-000000000001",
             "experience_content_id":"soc.surfaces.grass","response":"relaxed",
             "effective_date":"%s"}', (current_date + 3)::text)::jsonb
  )$s$,
  '22023'
);

-- ---------------------------------------------------------------------------
-- 3. Authorization and tenancy (DM §18.10, F01).
-- ---------------------------------------------------------------------------

select test_socialization.expect_sqlstate(
  'a member of another household cannot record against this pet, and learns nothing about it',
  $s$select public.write_path_record_socialization(
    '44440000-0000-4000-8000-000000000003', 'soc-record-cross', 'hash-cross',
    '{}'::jsonb, now(), null,
    '{"pet_id":"66660000-0000-4000-8000-000000000001",
      "experience_content_id":"soc.surfaces.grass","response":"relaxed"}'
  )$s$,
  '42501'
);

select test_socialization.expect_sqlstate(
  'DM §18.6: an archived pet accrues no new records',
  $s$select public.write_path_record_socialization(
    '44440000-0000-4000-8000-000000000001', 'soc-record-archived', 'hash-archived',
    '{}'::jsonb, now(), null,
    '{"pet_id":"66660000-0000-4000-8000-000000000002",
      "experience_content_id":"soc.surfaces.grass","response":"relaxed"}'
  )$s$,
  '42501'
);

select test_socialization.expect_sqlstate(
  'DM §18.10: a record cannot name a pet from another household',
  $s$insert into public.socialization_records (
    household_id, pet_id, custom_label, category, effective_date, response,
    created_by, updated_by
  ) values (
    '55550000-0000-4000-8000-000000000001', '66660000-0000-4000-8000-000000000003',
    'Smuggled', 'Surfaces', current_date, 'relaxed',
    '44440000-0000-4000-8000-000000000001', '44440000-0000-4000-8000-000000000001'
  )$s$,
  '23503'
);

select test_socialization.expect_sqlstate(
  'DM §18.11: a record cannot reference unpublished catalogue content',
  $s$insert into public.socialization_records (
    household_id, pet_id, experience_content_id, experience_content_version,
    category, effective_date, response, created_by, updated_by
  ) values (
    '55550000-0000-4000-8000-000000000001', '66660000-0000-4000-8000-000000000001',
    'soc.surfaces.grass', 99, 'Surfaces', current_date, 'relaxed',
    '44440000-0000-4000-8000-000000000001', '44440000-0000-4000-8000-000000000001'
  )$s$,
  '23503'
);

select test_socialization.expect_sqlstate(
  'a catalogue experience cannot be filed under the wrong category',
  $s$insert into public.socialization_records (
    household_id, pet_id, experience_content_id, experience_content_version,
    category, effective_date, response, created_by, updated_by
  ) values (
    '55550000-0000-4000-8000-000000000001', '66660000-0000-4000-8000-000000000001',
    'soc.surfaces.grass', 1, 'Animals', current_date, 'relaxed',
    '44440000-0000-4000-8000-000000000001', '44440000-0000-4000-8000-000000000001'
  )$s$,
  '22023'
);

-- ---------------------------------------------------------------------------
-- 4. Editing and removing (US-067; DM §13 optimistic concurrency).
-- ---------------------------------------------------------------------------

select test_socialization.put(
  'edited',
  public.write_path_edit_socialization_record(
    '44440000-0000-4000-8000-000000000002', 'soc-edit-1', 'hash-edit-1',
    '{}'::jsonb, now(), null,
    jsonb_build_object(
      'record_id', '77770000-0000-4000-8000-000000000001',
      'expected_revision', 1,
      'response', 'relaxed',
      'note', 'Slept through it the second time'
    )
  )::text
);

select test_socialization.assert_true(
  'a co-caregiver can correct the owner-reported response, and the revision advances',
  (test_socialization.val('edited')::jsonb -> 'record' ->> 'response') = 'relaxed'
  and (test_socialization.val('edited')::jsonb -> 'record' ->> 'revision')::integer = 2
  and (select updated_by = '44440000-0000-4000-8000-000000000002'
       from public.socialization_records where id = '77770000-0000-4000-8000-000000000001')
);

select test_socialization.expect_sqlstate(
  'a stale edit is rejected rather than silently overwriting a co-caregiver (US-055)',
  $s$select public.write_path_edit_socialization_record(
    '44440000-0000-4000-8000-000000000001', 'soc-edit-stale', 'hash-edit-stale',
    '{}'::jsonb, now(), null,
    '{"record_id":"77770000-0000-4000-8000-000000000001","expected_revision":1,"response":"neutral"}'
  )$s$,
  '40001'
);

select test_socialization.expect_sqlstate(
  'an outsider cannot edit a record they cannot see',
  $s$select public.write_path_edit_socialization_record(
    '44440000-0000-4000-8000-000000000003', 'soc-edit-outsider', 'hash-edit-outsider',
    '{}'::jsonb, now(), null,
    '{"record_id":"77770000-0000-4000-8000-000000000001","expected_revision":2,"response":"neutral"}'
  )$s$,
  '42501'
);

select test_socialization.put(
  'removed',
  public.write_path_remove_socialization_record(
    '44440000-0000-4000-8000-000000000001', 'soc-remove-1', 'hash-remove-1',
    '{}'::jsonb, now(), null,
    jsonb_build_object('record_id', (
      select id::text from public.socialization_records
      where pet_id = '66660000-0000-4000-8000-000000000001' and category = 'Household objects'
    ))
  )::text
);

select test_socialization.assert_true(
  'removal is a recoverable tombstone, not a delete',
  (test_socialization.val('removed')::jsonb -> 'record' ->> 'removed_at') is not null
  and (select count(*) = 1 from public.socialization_records
       where pet_id = '66660000-0000-4000-8000-000000000001'
         and category = 'Household objects'
         and deleted_at is not null
         and deleted_by = '44440000-0000-4000-8000-000000000001')
);

-- ---------------------------------------------------------------------------
-- 5. Exclusions are hard, reversible, and reach the engine (US-068).
-- ---------------------------------------------------------------------------

select test_socialization.put(
  'exclusion_category',
  public.write_path_set_socialization_exclusion(
    '44440000-0000-4000-8000-000000000001', 'soc-exclude-1', 'hash-exclude-1',
    '{}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', '66660000-0000-4000-8000-000000000001',
      'exclusion_id', '88880000-0000-4000-8000-000000000001',
      'category', 'Animals',
      'reason', 'unsuitable',
      'note', 'Waiting on vet guidance'
    )
  )::text
);

select test_socialization.put(
  'exclusion_experience',
  public.write_path_set_socialization_exclusion(
    '44440000-0000-4000-8000-000000000002', 'soc-exclude-2', 'hash-exclude-2',
    '{}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', '66660000-0000-4000-8000-000000000001',
      'experience_content_id', 'soc.surfaces.gravel',
      'reason', 'unavailable'
    )
  )::text
);

select test_socialization.assert_true(
  'both exclusion scopes are active and attributed',
  (test_socialization.val('exclusion_category')::jsonb -> 'exclusion' ->> 'active')::boolean
  and (test_socialization.val('exclusion_category')::jsonb -> 'exclusion' ->> 'reason') = 'unsuitable'
  and (test_socialization.val('exclusion_experience')::jsonb -> 'exclusion' ->> 'set_by')
      = '44440000-0000-4000-8000-000000000002'
);

select test_socialization.assert_true(
  're-marking an already-excluded category updates the live decision instead of stacking rows',
  (select count(*) = 1 from public.socialization_exclusions
   where pet_id = '66660000-0000-4000-8000-000000000001'
     and category = 'Animals' and cleared_at is null)
  and (public.write_path_set_socialization_exclusion(
        '44440000-0000-4000-8000-000000000001', 'soc-exclude-again', 'hash-exclude-again',
        '{}'::jsonb, now(), null,
        jsonb_build_object(
          'pet_id', '66660000-0000-4000-8000-000000000001',
          'category', 'Animals', 'reason', 'paused'
        )
      ) -> 'exclusion' ->> 'id') = '88880000-0000-4000-8000-000000000001'
  and (select count(*) = 1 from public.socialization_exclusions
       where pet_id = '66660000-0000-4000-8000-000000000001'
         and category = 'Animals' and cleared_at is null)
);

select test_socialization.expect_sqlstate(
  'an exclusion targets a category or an experience, never both',
  $s$select public.write_path_set_socialization_exclusion(
    '44440000-0000-4000-8000-000000000001', 'soc-exclude-both', 'hash-exclude-both',
    '{}'::jsonb, now(), null,
    '{"pet_id":"66660000-0000-4000-8000-000000000001","category":"Sounds",
      "experience_content_id":"soc.sounds.doorbell","reason":"paused"}'
  )$s$,
  '22023'
);

select test_socialization.expect_sqlstate(
  'an exclusion reason outside the model vocabulary is rejected',
  $s$select public.write_path_set_socialization_exclusion(
    '44440000-0000-4000-8000-000000000001', 'soc-exclude-reason', 'hash-exclude-reason',
    '{}'::jsonb, now(), null,
    '{"pet_id":"66660000-0000-4000-8000-000000000001","category":"Sounds","reason":"forbidden"}'
  )$s$,
  '22023'
);

-- The whole point of the entity: the engine must see it.
select test_socialization.put(
  'context_excluded',
  public.write_path_generation_context(
    '44440000-0000-4000-8000-000000000001', '66660000-0000-4000-8000-000000000001'
  )::text
);

select test_socialization.assert_true(
  'an active exclusion reaches the generation context as a hard constraint',
  test_socialization.val('context_excluded')::jsonb
    -> 'household' -> 'excluded_socialization_categories' = '["Animals"]'::jsonb
  and test_socialization.val('context_excluded')::jsonb
    -> 'household' -> 'excluded_content_ids' = '["soc.surfaces.gravel"]'::jsonb
);

select test_socialization.assert_true(
  'US-067: recorded experiences feed category recency, so breadth can rotate',
  (select count(*) = 2 from jsonb_array_elements(
     test_socialization.val('context_excluded')::jsonb -> 'recent_history') entry
   where entry ->> 'socialization_category' = 'Sounds'
     and entry ->> 'outcome' = 'completed')
  -- the removed record is gone from history, the custom one having been the
  -- only "Household objects" entry
  and (select count(*) = 0 from jsonb_array_elements(
         test_socialization.val('context_excluded')::jsonb -> 'recent_history') entry
       where entry ->> 'socialization_category' = 'Household objects')
);

select test_socialization.put(
  'cleared',
  public.write_path_clear_socialization_exclusion(
    '44440000-0000-4000-8000-000000000002', 'soc-clear-1', 'hash-clear-1',
    '{}'::jsonb, now(), null,
    jsonb_build_object('exclusion_id', '88880000-0000-4000-8000-000000000001')
  )::text
);

select test_socialization.assert_true(
  'US-068: clearing is reversal, not deletion -- the decision, its author, and past records survive',
  (test_socialization.val('cleared')::jsonb -> 'exclusion' ->> 'active')::boolean is false
  and (select cleared_by = '44440000-0000-4000-8000-000000000002'
        and reason = 'paused'
        and set_by = '44440000-0000-4000-8000-000000000001'
       from public.socialization_exclusions where id = '88880000-0000-4000-8000-000000000001')
  and (select count(*) = 2 from public.socialization_records
       where pet_id = '66660000-0000-4000-8000-000000000001' and deleted_at is null)
);

select test_socialization.assert_true(
  'a cleared category is eligible again, while the untouched experience exclusion still binds',
  (select ctx -> 'household' -> 'excluded_socialization_categories' = '[]'::jsonb
        and ctx -> 'household' -> 'excluded_content_ids' = '["soc.surfaces.gravel"]'::jsonb
   from (select public.write_path_generation_context(
           '44440000-0000-4000-8000-000000000001', '66660000-0000-4000-8000-000000000001'
         ) as ctx) c)
);

-- ---------------------------------------------------------------------------
-- 6. Idempotency (DM §18.3).
-- ---------------------------------------------------------------------------

select test_socialization.assert_true(
  'replaying a record command returns the original result without creating a second row',
  (public.write_path_record_socialization(
     '44440000-0000-4000-8000-000000000001', 'soc-record-1', 'hash-record-1',
     '{}'::jsonb, now(), null,
     jsonb_build_object(
       'pet_id', '66660000-0000-4000-8000-000000000001',
       'experience_content_id', 'soc.sounds.vacuum_low',
       'response', 'curious'
     )
   ) -> 'record' ->> 'id') = '77770000-0000-4000-8000-000000000001'
  and (select count(*) = 1 from public.socialization_records
       where id = '77770000-0000-4000-8000-000000000001')
);

select test_socialization.expect_sqlstate(
  'reusing an idempotency key with a different payload is a conflict',
  $s$select public.write_path_record_socialization(
    '44440000-0000-4000-8000-000000000001', 'soc-record-1', 'hash-record-DIFFERENT',
    '{}'::jsonb, now(), null,
    '{"pet_id":"66660000-0000-4000-8000-000000000001",
      "experience_content_id":"soc.sounds.vacuum_low","response":"curious"}'
  )$s$,
  '23505'
);

-- ---------------------------------------------------------------------------
-- 7. RLS and the SECURITY DEFINER lockdown.
-- ---------------------------------------------------------------------------

do $$
declare mine integer; theirs integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims',
    '{"sub":"44440000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  select count(*) into mine from public.socialization_records
  where pet_id = '66660000-0000-4000-8000-000000000001';
  reset role;
  perform test_socialization.assert_true(
    'an active member reads their household''s records',
    mine >= 2, format('rows visible=%s', mine)
  );

  set local role authenticated;
  perform set_config('request.jwt.claims',
    '{"sub":"44440000-0000-4000-8000-000000000003","role":"authenticated"}', true);
  select count(*) into theirs from public.socialization_records;
  select count(*) into mine from public.socialization_exclusions;
  reset role;
  perform test_socialization.assert_true(
    'a member of another household sees no records and no exclusions',
    theirs = 0 and mine = 0, format('records=%s exclusions=%s', theirs, mine)
  );
end;
$$;
reset role;

select test_socialization.expect_sqlstate(
  'the socialization write-path functions are not callable by authenticated clients',
  $s$do $inner$
    begin
      set local role authenticated;
      perform public.write_path_record_socialization(
        '44440000-0000-4000-8000-000000000003', 'soc-direct', 'hash-direct',
        '{}'::jsonb, now(), null, '{"pet_id":"66660000-0000-4000-8000-000000000001"}'::jsonb
      );
    end;
  $inner$$s$,
  '42501'
);
reset role;

select test_socialization.expect_sqlstate(
  'clients cannot write records directly, bypassing the command log and its audit',
  $s$do $inner$
    begin
      set local role authenticated;
      perform set_config('request.jwt.claims',
        '{"sub":"44440000-0000-4000-8000-000000000001","role":"authenticated"}', true);
      insert into public.socialization_records (
        household_id, pet_id, custom_label, category, effective_date, response,
        created_by, updated_by
      ) values (
        '55550000-0000-4000-8000-000000000001', '66660000-0000-4000-8000-000000000001',
        'Direct write', 'Surfaces', current_date, 'relaxed',
        '44440000-0000-4000-8000-000000000001', '44440000-0000-4000-8000-000000000001'
      );
    end;
  $inner$$s$,
  '42501'
);
reset role;

do $$
declare failed_count integer;
begin
  select count(*) into failed_count from test_socialization.results where not passed;
  if failed_count > 0 then
    raise exception '% socialization assertion(s) failed', failed_count;
  end if;
end;
$$;
rollback;
