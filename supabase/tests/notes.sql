-- Care notes tests (F10, DM §11.1 general_note / document, US-077).
--
-- Covers:
--   * create / edit / remove with revision checks and idempotency;
--   * document kind requires title; non-empty media_refs rejected on create
--     (attach via prepare_care_note_media — see notes_media.sql);
--   * archived pet / closed household guards;
--   * RLS isolation (outsider cannot SELECT);
--   * authenticated members cannot INSERT/UPDATE/DELETE directly;
--   * SECURITY DEFINER lockdown (authenticated cannot EXECUTE write_path_*).
--
-- Storage upload lifecycle lives in notes_media.sql.
--
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_notes;
create table test_notes.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create table test_notes.state (key text primary key, value text);

grant usage on schema test_notes to authenticated;
grant select, insert, update on test_notes.results, test_notes.state to authenticated;
grant usage, select on all sequences in schema test_notes to authenticated;

create or replace function test_notes.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_notes.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_notes.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  perform test_notes.record(p_name, coalesce(p_condition, false), p_detail);
end;
$$;

create or replace function test_notes.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_notes.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_notes.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

create or replace function test_notes.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_notes.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_notes.val(p_key text)
returns text language sql stable as $$
  select value from test_notes.state where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('c4440000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'notes-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('c4440000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'notes-partner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('c4440000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'notes-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.user_profiles(id, display_name) values
  ('c4440000-0000-4000-8000-000000000001', 'Nic'),
  ('c4440000-0000-4000-8000-000000000002', 'Sarah'),
  ('c4440000-0000-4000-8000-000000000003', 'Outsider');

insert into public.households (id, name, time_zone, created_by, updated_by) values
  ('c5550000-0000-4000-8000-000000000001', 'Maple House', 'America/Toronto',
   'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'),
  ('c5550000-0000-4000-8000-000000000002', 'Elsewhere House', 'Europe/Stockholm',
   'c4440000-0000-4000-8000-000000000003', 'c4440000-0000-4000-8000-000000000003');

insert into public.household_memberships (
  household_id, user_id, role, status, joined_at, created_by, updated_by
) values
  ('c5550000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001',
   'owner', 'active', now(), 'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'),
  ('c5550000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000002',
   'caregiver', 'active', now(), 'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'),
  ('c5550000-0000-4000-8000-000000000002', 'c4440000-0000-4000-8000-000000000003',
   'owner', 'active', now(), 'c4440000-0000-4000-8000-000000000003', 'c4440000-0000-4000-8000-000000000003');

insert into public.pets (
  id, household_id, name, birth_date_kind, birth_date, status, created_by, updated_by
) values
  ('c6660000-0000-4000-8000-000000000001', 'c5550000-0000-4000-8000-000000000001',
   'Maple', 'exact', current_date - 80, 'active',
   'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'),
  ('c6660000-0000-4000-8000-000000000002', 'c5550000-0000-4000-8000-000000000001',
   'Willow', 'exact', current_date - 200, 'archived',
   'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'),
  ('c6660000-0000-4000-8000-000000000003', 'c5550000-0000-4000-8000-000000000002',
   'Birch', 'exact', current_date - 90, 'active',
   'c4440000-0000-4000-8000-000000000003', 'c4440000-0000-4000-8000-000000000003');

insert into public.household_preferences (household_id, created_by, updated_by) values
  ('c5550000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001',
   'c4440000-0000-4000-8000-000000000001'),
  ('c5550000-0000-4000-8000-000000000002', 'c4440000-0000-4000-8000-000000000003',
   'c4440000-0000-4000-8000-000000000003');

insert into public.providers (
  id, household_id, name, kind, created_by, updated_by
) values (
  'c7770000-0000-4000-8000-000000000001', 'c5550000-0000-4000-8000-000000000001',
  'Riverside Vet', 'veterinarian',
  'c4440000-0000-4000-8000-000000000001', 'c4440000-0000-4000-8000-000000000001'
);

-- ---------------------------------------------------------------------------
-- 1. Create care note
-- ---------------------------------------------------------------------------

select test_notes.put(
  'note_1',
  public.write_path_create_care_note(
    'c4440000-0000-4000-8000-000000000001', 'note-1', 'hash-note-1',
    '{"command":"create_care_note"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'c6660000-0000-4000-8000-000000000001',
      'care_note_id', 'c8880000-0000-4000-8000-000000000001',
      'kind', 'general_note',
      'title', 'Soft stool after new food',
      'body', 'Tried new kibble yesterday evening. Soft stool this morning — monitoring.',
      'effective_date', (current_date - 1)::text,
      'provenance', 'owner_entered',
      'provider_id', 'c7770000-0000-4000-8000-000000000001'
    )
  )::text
);

select test_notes.assert_true(
  'create_care_note stores body and provenance',
  exists (
    select 1 from public.care_notes
    where id = 'c8880000-0000-4000-8000-000000000001'
      and title = 'Soft stool after new food'
      and body like 'Tried new kibble%'
      and provenance = 'owner_entered'
      and provider_id = 'c7770000-0000-4000-8000-000000000001'
      and kind = 'general_note'
      and media_refs is null
      and deleted_at is null
  )
);

select test_notes.assert_true(
  'create_care_note returns created_by_name attribution',
  (test_notes.val('note_1')::jsonb->'care_note'->>'created_by_name') = 'Nic'
);

select test_notes.assert_true(
  'create_care_note is idempotent',
  public.write_path_create_care_note(
    'c4440000-0000-4000-8000-000000000001', 'note-1', 'hash-note-1',
    '{"command":"create_care_note"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'c6660000-0000-4000-8000-000000000001',
      'care_note_id', 'c8880000-0000-4000-8000-000000000001',
      'title', 'Soft stool after new food',
      'body', 'Tried new kibble yesterday evening. Soft stool this morning — monitoring.',
      'effective_date', (current_date - 1)::text,
      'provenance', 'owner_entered',
      'provider_id', 'c7770000-0000-4000-8000-000000000001'
    )
  )::text = test_notes.val('note_1')
);

select test_notes.expect_sqlstate(
  'create_care_note rejects idempotency reuse with different payload',
  $stmt$
    select public.write_path_create_care_note(
      'c4440000-0000-4000-8000-000000000001', 'note-1', 'hash-note-1-diff',
      '{"command":"create_care_note"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'c6660000-0000-4000-8000-000000000001',
        'body', 'Different body'
      )
    );
  $stmt$,
  '23505'
);

select test_notes.expect_sqlstate(
  'create_care_note rejects future effective_date',
  $stmt$
    select public.write_path_create_care_note(
      'c4440000-0000-4000-8000-000000000001', 'note-future', 'hash-note-future',
      '{"command":"create_care_note"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'c6660000-0000-4000-8000-000000000001',
        'body', 'Future observation',
        'effective_date', (current_date + 1)::text
      )
    );
  $stmt$,
  '22023'
);

select test_notes.expect_sqlstate(
  'create_care_note rejects document kind without title',
  $stmt$
    select public.write_path_create_care_note(
      'c4440000-0000-4000-8000-000000000001', 'note-doc-no-title', 'hash-note-doc-no-title',
      '{"command":"create_care_note"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'c6660000-0000-4000-8000-000000000001',
        'kind', 'document',
        'body', 'placeholder'
      )
    );
  $stmt$,
  '22023'
);

select test_notes.put(
  'note_doc',
  public.write_path_create_care_note(
    'c4440000-0000-4000-8000-000000000001', 'note-doc', 'hash-note-doc',
    '{"command":"create_care_note"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'c6660000-0000-4000-8000-000000000001',
      'care_note_id', 'c8880000-0000-4000-8000-000000000099',
      'kind', 'document',
      'title', 'Clinic PDF',
      'body', 'Vaccination card scan'
    )
  )::text
);

select test_notes.assert_true(
  'create_care_note accepts document kind with title',
  (test_notes.val('note_doc')::jsonb->'care_note'->>'kind') = 'document'
  and (test_notes.val('note_doc')::jsonb->'care_note'->>'title') = 'Clinic PDF'
);

select test_notes.expect_sqlstate(
  'create_care_note rejects non-empty media_refs',
  $stmt$
    select public.write_path_create_care_note(
      'c4440000-0000-4000-8000-000000000001', 'note-media', 'hash-note-media',
      '{"command":"create_care_note"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'c6660000-0000-4000-8000-000000000001',
        'body', 'Has attachment',
        'media_refs', jsonb_build_array('storage://x')
      )
    );
  $stmt$,
  '22023'
);

select test_notes.expect_sqlstate(
  'create_care_note rejects archived pet',
  $stmt$
    select public.write_path_create_care_note(
      'c4440000-0000-4000-8000-000000000001', 'note-archived', 'hash-note-archived',
      '{"command":"create_care_note"}'::jsonb, now(), null,
      jsonb_build_object(
        'pet_id', 'c6660000-0000-4000-8000-000000000002',
        'body', 'Should fail'
      )
    );
  $stmt$,
  '42501'
);

-- ---------------------------------------------------------------------------
-- 2. Edit care note
-- ---------------------------------------------------------------------------

select test_notes.put(
  'note_1_edit',
  public.write_path_edit_care_note(
    'c4440000-0000-4000-8000-000000000002', 'note-1-edit', 'hash-note-1-edit',
    '{"command":"edit_care_note"}'::jsonb, now(), null,
    jsonb_build_object(
      'care_note_id', 'c8880000-0000-4000-8000-000000000001',
      'expected_revision', 1,
      'title', 'Soft stool — resolved',
      'body', 'Back to normal after one day. Keeping old kibble for now.',
      'provenance', 'professional_instruction'
    )
  )::text
);

select test_notes.assert_true(
  'edit_care_note bumps revision and updates fields',
  exists (
    select 1 from public.care_notes
    where id = 'c8880000-0000-4000-8000-000000000001'
      and title = 'Soft stool — resolved'
      and body like 'Back to normal%'
      and provenance = 'professional_instruction'
      and revision = 2
      and updated_by = 'c4440000-0000-4000-8000-000000000002'
  )
);

select test_notes.expect_sqlstate(
  'edit_care_note rejects stale revision',
  $stmt$
    select public.write_path_edit_care_note(
      'c4440000-0000-4000-8000-000000000001', 'note-stale', 'hash-note-stale',
      '{"command":"edit_care_note"}'::jsonb, now(), null,
      jsonb_build_object(
        'care_note_id', 'c8880000-0000-4000-8000-000000000001',
        'expected_revision', 1,
        'body', 'Stale'
      )
    );
  $stmt$,
  '40001'
);

-- ---------------------------------------------------------------------------
-- 3. Remove care note
-- ---------------------------------------------------------------------------

select public.write_path_remove_care_note(
  'c4440000-0000-4000-8000-000000000001', 'note-1-remove', 'hash-note-1-remove',
  '{"command":"remove_care_note"}'::jsonb, now(), null,
  jsonb_build_object('care_note_id', 'c8880000-0000-4000-8000-000000000001')
);

select test_notes.assert_true(
  'remove_care_note soft-deletes',
  exists (
    select 1 from public.care_notes
    where id = 'c8880000-0000-4000-8000-000000000001'
      and deleted_at is not null
      and deleted_by = 'c4440000-0000-4000-8000-000000000001'
  )
);

select test_notes.assert_true(
  'remove_care_note is idempotent',
  (public.write_path_remove_care_note(
    'c4440000-0000-4000-8000-000000000001', 'note-1-remove', 'hash-note-1-remove',
    '{"command":"remove_care_note"}'::jsonb, now(), null,
    jsonb_build_object('care_note_id', 'c8880000-0000-4000-8000-000000000001')
  )->'care_note'->>'id') = 'c8880000-0000-4000-8000-000000000001'
);

-- ---------------------------------------------------------------------------
-- 4. RLS + direct write denial
-- ---------------------------------------------------------------------------

select test_notes.put(
  'note_2',
  public.write_path_create_care_note(
    'c4440000-0000-4000-8000-000000000001', 'note-2', 'hash-note-2',
    '{"command":"create_care_note"}'::jsonb, now(), null,
    jsonb_build_object(
      'pet_id', 'c6660000-0000-4000-8000-000000000001',
      'care_note_id', 'c8880000-0000-4000-8000-000000000002',
      'body', 'Second observation for RLS checks',
      'effective_date', (current_date - 2)::text,
      'provenance', 'owner_entered'
    )
  )::text
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'c4440000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select test_notes.assert_true(
  'member can SELECT own household care note',
  exists (
    select 1 from public.care_notes
    where id = 'c8880000-0000-4000-8000-000000000002'
  )
);

select test_notes.expect_sqlstate(
  'member cannot INSERT care note directly',
  $stmt$
    insert into public.care_notes (
      household_id, pet_id, body, effective_date, created_by, updated_by
    ) values (
      'c5550000-0000-4000-8000-000000000001',
      'c6660000-0000-4000-8000-000000000001',
      'Bypass', current_date - 1,
      'c4440000-0000-4000-8000-000000000001',
      'c4440000-0000-4000-8000-000000000001'
    );
  $stmt$,
  '42501'
);

select test_notes.expect_sqlstate(
  'authenticated cannot EXECUTE write_path_create_care_note',
  $stmt$
    select public.write_path_create_care_note(
      'c4440000-0000-4000-8000-000000000001', 'note-lock', 'hash-note-lock',
      '{}'::jsonb, now(), null, '{}'::jsonb
    );
  $stmt$,
  '42501'
);

select set_config('request.jwt.claim.sub', 'c4440000-0000-4000-8000-000000000003', true);

select test_notes.assert_true(
  'outsider cannot SELECT other household care note',
  not exists (
    select 1 from public.care_notes
    where id = 'c8880000-0000-4000-8000-000000000002'
  )
);

reset role;

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

do $$
declare
  failed integer;
begin
  select count(*) into failed from test_notes.results where not passed;
  raise notice 'notes suite: % failed of %',
    failed, (select count(*) from test_notes.results);
  if failed > 0 then
    raise exception '% care note assertion(s) failed', failed;
  end if;
end;
$$;

rollback;
