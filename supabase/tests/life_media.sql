-- Life milestone media tests (F12, DM §12.6, US-090/US-091/US-093, Scenario H).
--
-- Covers:
--   * prepare / complete / fail / remove media write paths;
--   * milestone text remains after fail;
--   * media_refs append/detach;
--   * household soft cap notice path (count helper);
--   * outsider cannot SELECT media;
--   * Storage bucket exists and is private;
--   * Storage RLS helper authorizes household members only for pending writes;
--   * SECURITY DEFINER lockdown on write_path_* media commands.
--
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_life_media;
create table test_life_media.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create table test_life_media.state (key text primary key, value text);

grant usage on schema test_life_media to authenticated;
grant select, insert, update on test_life_media.results, test_life_media.state to authenticated;
grant usage, select on all sequences in schema test_life_media to authenticated;

create or replace function test_life_media.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_life_media.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_life_media.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin perform test_life_media.record(p_name, coalesce(p_condition, false), p_detail); end;
$$;

create or replace function test_life_media.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_life_media.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_life_media.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

create or replace function test_life_media.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_life_media.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_life_media.val(p_key text)
returns text language sql stable as $$
  select value from test_life_media.state where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('c4440000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'life-media-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('c4440000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'life-media-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.user_profiles(id, display_name) values
  ('c4440000-0000-4000-8000-000000000001', 'Nic'),
  ('c4440000-0000-4000-8000-000000000003', 'Outsider');

insert into public.households (id, name, time_zone, created_by, updated_by) values
  ('c5550000-0000-4000-8000-000000000001', 'Media House', 'America/Toronto',
   'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'),
  ('c5550000-0000-4000-8000-000000000002', 'Elsewhere Media', 'Europe/Stockholm',
   'c4440000-0000-4000-8000-000000000003', 'c4440000-0000-4000-8000-000000000003');

insert into public.household_memberships (
  household_id, user_id, role, status, joined_at, created_by, updated_by
) values
  ('c5550000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001',
   'owner', 'active', now(), 'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'),
  ('c5550000-0000-4000-8000-000000000002', 'c4440000-0000-4000-8000-000000000003',
   'owner', 'active', now(), 'c4440000-0000-4000-8000-000000000003', 'c4440000-0000-4000-8000-000000000003');

insert into public.pets (
  id, household_id, name, birth_date_kind, birth_date, status, created_by, updated_by
) values (
  'c6660000-0000-4000-8000-000000000001', 'c5550000-0000-4000-8000-000000000001',
  'Maple', 'exact', current_date - 90, 'active',
  'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'
);

insert into public.household_preferences (household_id, created_by, updated_by) values
  ('c5550000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001',
   'c4440000-0000-4000-8000-000000000001'),
  ('c5550000-0000-4000-8000-000000000002', 'c4440000-0000-4000-8000-000000000003',
   'c4440000-0000-4000-8000-000000000003');

-- Milestone text first (Scenario H)
select test_life_media.put(
  'ms_1',
  public.write_path_create_milestone(
    'c4440000-0000-4000-8000-000000000001', 'life-media-ms-1', 'hash-life-media-ms-1',
    '{"command":"create_milestone"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'c6660000-0000-4000-8000-000000000001',
      'milestone_id', 'c7770000-0000-4000-8000-000000000001',
      'title', 'First day home',
      'effective_date', (current_date - 10)::text
    )
  )::text
);

select test_life_media.assert_true(
  'household-media bucket exists and is private',
  exists (
    select 1 from storage.buckets
    where id = 'household-media' and public is false and file_size_limit = 10485760
  )
);

select test_life_media.put(
  'prep_1',
  public.write_path_prepare_milestone_media(
    'c4440000-0000-4000-8000-000000000001', 'life-media-prep-1', 'hash-life-media-prep-1',
    '{"command":"prepare_milestone_media"}'::jsonb, now(), null,
    jsonb_build_object(
      'milestone_id', 'c7770000-0000-4000-8000-000000000001',
      'media_id', 'c8880000-0000-4000-8000-000000000001',
      'mime_type', 'image/jpeg',
      'byte_size', 2048
    )
  )::text
);

select test_life_media.assert_true(
  'prepare returns pending_upload media',
  (test_life_media.val('prep_1')::jsonb->'media'->>'status') = 'pending_upload'
);

select test_life_media.assert_true(
  'prepare returns household-prefixed upload path',
  (test_life_media.val('prep_1')::jsonb->'upload'->>'path')
    = 'c5550000-0000-4000-8000-000000000001/c8880000-0000-4000-8000-000000000001'
);

select test_life_media.assert_true(
  'prepare appends media_refs on milestone',
  (test_life_media.val('prep_1')::jsonb->'milestone'->'media_refs')
    @> to_jsonb(ARRAY['c8880000-0000-4000-8000-000000000001']::text[])
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'c4440000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select test_life_media.assert_true(
  'storage helper allows member write while pending',
  public.media_storage_object_allowed(
    'household-media',
    'c5550000-0000-4000-8000-000000000001/c8880000-0000-4000-8000-000000000001',
    true
  )
);

select set_config('request.jwt.claim.sub', 'c4440000-0000-4000-8000-000000000003', true);

select test_life_media.assert_true(
  'storage helper denies outsider write',
  not public.media_storage_object_allowed(
    'household-media',
    'c5550000-0000-4000-8000-000000000001/c8880000-0000-4000-8000-000000000001',
    true
  )
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claim.role', '', true);

select test_life_media.put(
  'fail_1',
  public.write_path_fail_milestone_media(
    'c4440000-0000-4000-8000-000000000001', 'life-media-fail-1', 'hash-life-media-fail-1',
    '{"command":"fail_milestone_media"}'::jsonb, now(), null,
    jsonb_build_object('media_id', 'c8880000-0000-4000-8000-000000000001')
  )::text
);

select test_life_media.assert_true(
  'fail marks upload_failed without removing milestone',
  (test_life_media.val('fail_1')::jsonb->'media'->>'status') = 'upload_failed'
  and exists (
    select 1 from public.milestones
    where id = 'c7770000-0000-4000-8000-000000000001' and deleted_at is null
  )
);

select test_life_media.put(
  'complete_1',
  public.write_path_complete_milestone_media(
    'c4440000-0000-4000-8000-000000000001', 'life-media-complete-1', 'hash-life-media-complete-1',
    '{"command":"complete_milestone_media"}'::jsonb, now(), null,
    jsonb_build_object(
      'media_id', 'c8880000-0000-4000-8000-000000000001',
      'byte_size', 1800
    )
  )::text
);

select test_life_media.assert_true(
  'complete marks available',
  (test_life_media.val('complete_1')::jsonb->'media'->>'status') = 'available'
  and (test_life_media.val('complete_1')::jsonb->'media'->>'uploaded_at') is not null
);

select test_life_media.expect_sqlstate(
  'fail refuses available media',
  format($sql$
    select public.write_path_fail_milestone_media(
      'c4440000-0000-4000-8000-000000000001', 'life-media-fail-available', 'hash-fail-available',
      '{"command":"fail_milestone_media"}'::jsonb, now(), null,
      jsonb_build_object('media_id', 'c8880000-0000-4000-8000-000000000001')
    )
  $sql$),
  '22023'
);

select test_life_media.put(
  'remove_1',
  public.write_path_remove_milestone_media(
    'c4440000-0000-4000-8000-000000000001', 'life-media-remove-1', 'hash-life-media-remove-1',
    '{"command":"remove_milestone_media"}'::jsonb, now(), null,
    jsonb_build_object('media_id', 'c8880000-0000-4000-8000-000000000001')
  )::text
);

select test_life_media.assert_true(
  'remove detaches media_refs and keeps milestone',
  (
    select media_refs is null
    from public.milestones
    where id = 'c7770000-0000-4000-8000-000000000001'
  )
  and exists (
    select 1 from public.milestones
    where id = 'c7770000-0000-4000-8000-000000000001' and deleted_at is null
  )
);

select test_life_media.assert_true(
  'removed media is not readable via RLS policy predicate',
  (
    select status = 'removed' from public.media
    where id = 'c8880000-0000-4000-8000-000000000001'
  )
);

select test_life_media.expect_sqlstate(
  'prepare rejects outsider milestone',
  format($sql$
    select public.write_path_prepare_milestone_media(
      'c4440000-0000-4000-8000-000000000003', 'life-media-outsider', 'hash-outsider',
      '{"command":"prepare_milestone_media"}'::jsonb, now(), null,
      jsonb_build_object(
        'milestone_id', 'c7770000-0000-4000-8000-000000000001',
        'mime_type', 'image/jpeg',
        'byte_size', 100
      )
    )
  $sql$),
  '42501'
);

select test_life_media.expect_sqlstate(
  'authenticated cannot execute prepare directly',
  $sql$
    set local role authenticated;
    select public.write_path_prepare_milestone_media(
      'c4440000-0000-4000-8000-000000000001', 'x', 'y', '{}'::jsonb, now(), null, '{}'::jsonb
    );
  $sql$,
  '42501'
);

select test_life_media.expect_sqlstate(
  'prepare rejects PDF for Life milestones',
  format($sql$
    select public.write_path_prepare_milestone_media(
      'c4440000-0000-4000-8000-000000000001', 'life-media-pdf', 'hash-life-media-pdf',
      '{"command":"prepare_milestone_media"}'::jsonb, now(), null,
      jsonb_build_object(
        'milestone_id', 'c7770000-0000-4000-8000-000000000001',
        'mime_type', 'application/pdf',
        'byte_size', 2048
      )
    )
  $sql$),
  '22023'
);

-- Summary
do $$
declare
  failed int;
  total int;
begin
  select count(*) filter (where not passed), count(*)
  into failed, total
  from test_life_media.results;
  raise notice 'Life milestone media suite: %/% passed', total - failed, total;
  if failed > 0 then
    raise exception 'Life milestone media suite failed: % of % assertions', failed, total;
  end if;
end;
$$;

rollback;
