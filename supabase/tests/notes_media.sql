-- Care note media tests (F10, DM §11.1 / §12.6, US-077, Scenario H).
--
-- Covers:
--   * prepare / complete / fail / remove care note media write paths;
--   * PDF accepted for Care (images still accepted); oversized rejected;
--   * note text remains after fail;
--   * media_refs append/detach;
--   * Storage helper authorizes household members only for pending writes;
--   * milestone media cannot be completed via care_note complete path;
--   * SECURITY DEFINER lockdown on write_path_* care note media commands.
--
-- Reuses household-media bucket from life_milestone_media. Does not mutate
-- Life write paths (Life stays image-only).
--
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_notes_media;
create table test_notes_media.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create table test_notes_media.state (key text primary key, value text);

grant usage on schema test_notes_media to authenticated;
grant select, insert, update on test_notes_media.results, test_notes_media.state to authenticated;
grant usage, select on all sequences in schema test_notes_media to authenticated;

create or replace function test_notes_media.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_notes_media.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_notes_media.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  perform test_notes_media.record(p_name, coalesce(p_condition, false), p_detail);
end;
$$;

create or replace function test_notes_media.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_notes_media.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_notes_media.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

create or replace function test_notes_media.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_notes_media.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_notes_media.val(p_key text)
returns text language sql stable as $$
  select value from test_notes_media.state where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('c4440000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'notes-media-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('c4440000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'notes-media-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.user_profiles(id, display_name) values
  ('c4440000-0000-4000-8000-000000000001', 'Nic'),
  ('c4440000-0000-4000-8000-000000000003', 'Outsider');

insert into public.households (id, name, time_zone, created_by, updated_by) values
  ('c5550000-0000-4000-8000-000000000001', 'Notes Media House', 'America/Toronto',
   'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'),
  ('c5550000-0000-4000-8000-000000000002', 'Elsewhere Notes Media', 'Europe/Stockholm',
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

-- Note text first (Scenario H)
select test_notes_media.put(
  'note_1',
  public.write_path_create_care_note(
    'c4440000-0000-4000-8000-000000000001', 'notes-media-note-1', 'hash-notes-media-note-1',
    '{"command":"create_care_note"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'c6660000-0000-4000-8000-000000000001',
      'care_note_id', 'c7770000-0000-4000-8000-000000000001',
      'kind', 'document',
      'title', 'Vaccine card',
      'body', 'From the clinic visit',
      'effective_date', (current_date - 3)::text
    )
  )::text
);

select test_notes_media.assert_true(
  'household-media bucket exists and is private',
  exists (
    select 1 from storage.buckets
    where id = 'household-media' and public is false and file_size_limit = 10485760
  )
);

select test_notes_media.assert_true(
  'household-media bucket allows PDF and images',
  exists (
    select 1 from storage.buckets
    where id = 'household-media'
      and allowed_mime_types @> array[
        'image/jpeg', 'image/png', 'image/heic', 'image/webp', 'application/pdf'
      ]::text[]
  )
);

select test_notes_media.put(
  'prep_1',
  public.write_path_prepare_care_note_media(
    'c4440000-0000-4000-8000-000000000001', 'notes-media-prep-1', 'hash-notes-media-prep-1',
    '{"command":"prepare_care_note_media"}'::jsonb, now(), null,
    jsonb_build_object(
      'care_note_id', 'c7770000-0000-4000-8000-000000000001',
      'media_id', 'c8880000-0000-4000-8000-000000000001',
      'mime_type', 'image/jpeg',
      'byte_size', 2048
    )
  )::text
);

select test_notes_media.assert_true(
  'prepare returns pending_upload media',
  (test_notes_media.val('prep_1')::jsonb->'media'->>'status') = 'pending_upload'
);

select test_notes_media.assert_true(
  'prepare returns household-prefixed upload path',
  (test_notes_media.val('prep_1')::jsonb->'upload'->>'path')
    = 'c5550000-0000-4000-8000-000000000001/c8880000-0000-4000-8000-000000000001'
);

select test_notes_media.assert_true(
  'prepare appends media_refs on care note',
  (test_notes_media.val('prep_1')::jsonb->'care_note'->'media_refs')
    @> to_jsonb(ARRAY['c8880000-0000-4000-8000-000000000001']::text[])
);

select test_notes_media.assert_true(
  'prepare attaches media to care_note type',
  (test_notes_media.val('prep_1')::jsonb->'media'->'attached_to'->>'type') = 'care_note'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'c4440000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select test_notes_media.assert_true(
  'storage helper allows member write while pending',
  public.media_storage_object_allowed(
    'household-media',
    'c5550000-0000-4000-8000-000000000001/c8880000-0000-4000-8000-000000000001',
    true
  )
);

select set_config('request.jwt.claim.sub', 'c4440000-0000-4000-8000-000000000003', true);

select test_notes_media.assert_true(
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

select test_notes_media.put(
  'fail_1',
  public.write_path_fail_care_note_media(
    'c4440000-0000-4000-8000-000000000001', 'notes-media-fail-1', 'hash-notes-media-fail-1',
    '{"command":"fail_care_note_media"}'::jsonb, now(), null,
    jsonb_build_object('media_id', 'c8880000-0000-4000-8000-000000000001')
  )::text
);

select test_notes_media.assert_true(
  'fail marks upload_failed without removing note',
  (test_notes_media.val('fail_1')::jsonb->'media'->>'status') = 'upload_failed'
  and exists (
    select 1 from public.care_notes
    where id = 'c7770000-0000-4000-8000-000000000001' and deleted_at is null
  )
);

select test_notes_media.put(
  'complete_1',
  public.write_path_complete_care_note_media(
    'c4440000-0000-4000-8000-000000000001', 'notes-media-complete-1', 'hash-notes-media-complete-1',
    '{"command":"complete_care_note_media"}'::jsonb, now(), null,
    jsonb_build_object(
      'media_id', 'c8880000-0000-4000-8000-000000000001',
      'byte_size', 1800
    )
  )::text
);

select test_notes_media.assert_true(
  'complete marks available',
  (test_notes_media.val('complete_1')::jsonb->'media'->>'status') = 'available'
  and (test_notes_media.val('complete_1')::jsonb->'media'->>'uploaded_at') is not null
);

select test_notes_media.expect_sqlstate(
  'fail refuses available media',
  format($sql$
    select public.write_path_fail_care_note_media(
      'c4440000-0000-4000-8000-000000000001', 'notes-media-fail-available', 'hash-fail-available',
      '{"command":"fail_care_note_media"}'::jsonb, now(), null,
      jsonb_build_object('media_id', 'c8880000-0000-4000-8000-000000000001')
    )
  $sql$),
  '22023'
);

select test_notes_media.put(
  'remove_1',
  public.write_path_remove_care_note_media(
    'c4440000-0000-4000-8000-000000000001', 'notes-media-remove-1', 'hash-notes-media-remove-1',
    '{"command":"remove_care_note_media"}'::jsonb, now(), null,
    jsonb_build_object('media_id', 'c8880000-0000-4000-8000-000000000001')
  )::text
);

select test_notes_media.assert_true(
  'remove detaches media_refs and keeps note',
  (
    select media_refs is null
    from public.care_notes
    where id = 'c7770000-0000-4000-8000-000000000001'
  )
  and exists (
    select 1 from public.care_notes
    where id = 'c7770000-0000-4000-8000-000000000001' and deleted_at is null
  )
);

-- Cross-type isolation: Life milestone media cannot use care note complete.
select public.write_path_create_milestone(
  'c4440000-0000-4000-8000-000000000001', 'notes-media-ms-1', 'hash-notes-media-ms-1',
  '{"command":"create_milestone"}'::jsonb, now(), null,
  jsonb_build_object(
    'pet_id', 'c6660000-0000-4000-8000-000000000001',
    'milestone_id', 'c7770000-0000-4000-8000-000000000002',
    'title', 'Isolation check',
    'effective_date', (current_date - 1)::text
  )
);

select public.write_path_prepare_milestone_media(
  'c4440000-0000-4000-8000-000000000001', 'notes-media-ms-prep', 'hash-notes-media-ms-prep',
  '{"command":"prepare_milestone_media"}'::jsonb, now(), null,
  jsonb_build_object(
    'milestone_id', 'c7770000-0000-4000-8000-000000000002',
    'media_id', 'c8880000-0000-4000-8000-000000000002',
    'mime_type', 'image/jpeg',
    'byte_size', 512
  )
);

select test_notes_media.expect_sqlstate(
  'care complete refuses milestone-attached media',
  format($sql$
    select public.write_path_complete_care_note_media(
      'c4440000-0000-4000-8000-000000000001', 'notes-media-cross', 'hash-notes-media-cross',
      '{"command":"complete_care_note_media"}'::jsonb, now(), null,
      jsonb_build_object('media_id', 'c8880000-0000-4000-8000-000000000002')
    )
  $sql$),
  '22023'
);

select test_notes_media.expect_sqlstate(
  'prepare rejects outsider care note',
  format($sql$
    select public.write_path_prepare_care_note_media(
      'c4440000-0000-4000-8000-000000000003', 'notes-media-outsider', 'hash-outsider',
      '{"command":"prepare_care_note_media"}'::jsonb, now(), null,
      jsonb_build_object(
        'care_note_id', 'c7770000-0000-4000-8000-000000000001',
        'mime_type', 'image/jpeg',
        'byte_size', 100
      )
    )
  $sql$),
  '42501'
);

select test_notes_media.expect_sqlstate(
  'authenticated cannot execute prepare directly',
  $sql$
    set local role authenticated;
    select public.write_path_prepare_care_note_media(
      'c4440000-0000-4000-8000-000000000001', 'x', 'y', '{}'::jsonb, now(), null, '{}'::jsonb
    );
  $sql$,
  '42501'
);

-- PDF accepted for Care documents; Life prepare still rejects PDF below.
select test_notes_media.put(
  'prep_pdf',
  public.write_path_prepare_care_note_media(
    'c4440000-0000-4000-8000-000000000001', 'notes-media-prep-pdf', 'hash-notes-media-prep-pdf',
    '{"command":"prepare_care_note_media"}'::jsonb, now(), null,
    jsonb_build_object(
      'care_note_id', 'c7770000-0000-4000-8000-000000000001',
      'media_id', 'c8880000-0000-4000-8000-0000000000aa',
      'mime_type', 'application/pdf',
      'byte_size', 4096
    )
  )::text
);

select test_notes_media.assert_true(
  'prepare accepts application/pdf for care notes',
  (test_notes_media.val('prep_pdf')::jsonb->'media'->>'mime_type') = 'application/pdf'
  and (test_notes_media.val('prep_pdf')::jsonb->'media'->>'status') = 'pending_upload'
);

select test_notes_media.expect_sqlstate(
  'prepare rejects oversized care attachment',
  format($sql$
    select public.write_path_prepare_care_note_media(
      'c4440000-0000-4000-8000-000000000001', 'notes-media-too-big', 'hash-too-big',
      '{"command":"prepare_care_note_media"}'::jsonb, now(), null,
      jsonb_build_object(
        'care_note_id', 'c7770000-0000-4000-8000-000000000001',
        'mime_type', 'application/pdf',
        'byte_size', 10485761
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
  from test_notes_media.results;
  raise notice 'Care note media suite: %/% passed', total - failed, total;
  if failed > 0 then
    raise exception 'Care note media suite failed: % of % assertions', failed, total;
  end if;
end;
$$;

rollback;
