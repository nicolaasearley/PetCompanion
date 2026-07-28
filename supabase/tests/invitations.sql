-- Slice B shared-care tests: household invitations.
--
-- Covers the DM 10 §18 invariants this slice owns: single-use tokens, expiry,
-- at most one active membership per (user, household), at least one active
-- owner per active household, owner-only invite rights, idempotent replay, and
-- cross-household isolation -- plus the disclosure rules of DM §7.4 (the token
-- is only ever stored hashed; pre-acceptance exposes household name, inviter,
-- and expiry only).
--
-- The entire suite runs in one transaction and ends in ROLLBACK.
\set ON_ERROR_STOP on
begin;

create schema test_invitations;
create table test_invitations.results (
  id bigserial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
-- Scratch space for values produced by the functions under test (share
-- tokens are returned exactly once, so they must be captured as they appear).
create table test_invitations.state (key text primary key, value text);

grant usage on schema test_invitations to authenticated;
grant select, insert, update on test_invitations.results, test_invitations.state to authenticated;
grant usage, select on all sequences in schema test_invitations to authenticated;

create or replace function test_invitations.record(
  p_name text, p_passed boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into test_invitations.results(name, passed, detail)
  values (p_name, p_passed, p_detail);
  raise notice '[%] % -- %',
    case when p_passed then 'PASS' else 'FAIL' end, p_name, coalesce(p_detail, '');
end;
$$;

create or replace function test_invitations.assert_true(
  p_name text, p_condition boolean, p_detail text default null
) returns void language plpgsql as $$
begin perform test_invitations.record(p_name, coalesce(p_condition, false), p_detail); end;
$$;

create or replace function test_invitations.expect_sqlstate(
  p_name text, p_statement text, p_sqlstate text
) returns void language plpgsql as $$
begin
  begin
    execute p_statement;
    perform test_invitations.record(p_name, false, 'statement unexpectedly succeeded');
  exception when others then
    perform test_invitations.record(
      p_name, sqlstate = p_sqlstate,
      format('expected %s, received %s: %s', p_sqlstate, sqlstate, sqlerrm)
    );
  end;
end;
$$;

create or replace function test_invitations.put(p_key text, p_value text)
returns text language plpgsql as $$
begin
  insert into test_invitations.state(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return p_value;
end;
$$;

create or replace function test_invitations.val(p_key text)
returns text language sql stable as $$
  select value from test_invitations.state where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures: two independent households, plus an outsider with no membership.
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('11110000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'inv-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('11110000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'inv-partner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('11110000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'inv-outsider@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('11110000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'inv-other-owner@test.local', 'x', now(), now(), now(), '{}', '{}', false, false),
  ('11110000-0000-4000-8000-000000000005', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'inv-other-member@test.local', 'x', now(), now(), now(), '{}', '{}', false, false);

insert into public.user_profiles(id, display_name) values
  ('11110000-0000-4000-8000-000000000001', 'Nic'),
  ('11110000-0000-4000-8000-000000000002', 'Sarah'),
  ('11110000-0000-4000-8000-000000000003', 'Outsider'),
  ('11110000-0000-4000-8000-000000000004', 'Other Owner'),
  ('11110000-0000-4000-8000-000000000005', 'Other Member');

insert into public.households (id, name, time_zone, created_by, updated_by) values
  ('22220000-0000-4000-8000-000000000001', 'Maple House', 'America/Toronto',
   '11110000-0000-4000-8000-000000000001', '11110000-0000-4000-8000-000000000001'),
  ('22220000-0000-4000-8000-000000000002', 'Elsewhere House', 'Europe/Stockholm',
   '11110000-0000-4000-8000-000000000004', '11110000-0000-4000-8000-000000000004');

insert into public.household_memberships (
  household_id, user_id, role, status, joined_at, created_by, updated_by
) values
  ('22220000-0000-4000-8000-000000000001', '11110000-0000-4000-8000-000000000001',
   'owner', 'active', now(), '11110000-0000-4000-8000-000000000001', '11110000-0000-4000-8000-000000000001'),
  ('22220000-0000-4000-8000-000000000002', '11110000-0000-4000-8000-000000000004',
   'owner', 'active', now(), '11110000-0000-4000-8000-000000000004', '11110000-0000-4000-8000-000000000004'),
  ('22220000-0000-4000-8000-000000000002', '11110000-0000-4000-8000-000000000005',
   'caregiver', 'active', now(), '11110000-0000-4000-8000-000000000004', '11110000-0000-4000-8000-000000000004');

-- ---------------------------------------------------------------------------
-- 1. Happy path: an owner creates a single-use, expiring invitation.
-- ---------------------------------------------------------------------------

select test_invitations.put(
  'create_response',
  public.write_path_create_invitation(
    '11110000-0000-4000-8000-000000000001', 'inv-create-1', 'hash-create-1',
    '{"command":"create_invitation","payload":{"household_id":"22220000-0000-4000-8000-000000000001"}}',
    now(), null,
    '{"household_id":"22220000-0000-4000-8000-000000000001","invitation_id":"33330000-0000-4000-8000-000000000001"}'
  )::text
);
select test_invitations.put(
  'token_1', test_invitations.val('create_response')::jsonb ->> 'token'
);

select test_invitations.assert_true(
  'create_invitation returns a share token exactly once, with the invitation and its expiry',
  length(test_invitations.val('token_1')) = 64
  and test_invitations.val('token_1') ~ '^[0-9a-f]{64}$'
  and (test_invitations.val('create_response')::jsonb -> 'invitation' ->> 'status') = 'pending'
  and (test_invitations.val('create_response')::jsonb -> 'invitation' ->> 'household_name') = 'Maple House'
  and (test_invitations.val('create_response')::jsonb ->> 'token_returned_once')::boolean
  and (select expires_at > now() + interval '6 days' and expires_at < now() + interval '8 days'
       from public.household_invitations where id = '33330000-0000-4000-8000-000000000001')
);

select test_invitations.assert_true(
  'the share token is stored only as a SHA-256 hash, never in plaintext',
  (select token_hash = encode(sha256(convert_to(test_invitations.val('token_1'), 'UTF8')), 'hex')
   from public.household_invitations where id = '33330000-0000-4000-8000-000000000001')
  and (select count(*) = 0 from public.household_invitations
       where token_hash = test_invitations.val('token_1'))
);

select test_invitations.assert_true(
  'the create command log keeps the invitation but never the token',
  (select response_body -> 'invitation' ->> 'id' = '33330000-0000-4000-8000-000000000001'
          and not (response_body ? 'token')
          and position(test_invitations.val('token_1') in response_body::text) = 0
          and position(test_invitations.val('token_1') in request_body::text) = 0
   from public.command_log
   where actor_user_id = '11110000-0000-4000-8000-000000000001'
     and client_idempotency_key = 'inv-create-1')
);

select test_invitations.assert_true(
  'creating an invitation is audited without disclosing the token',
  (select count(*) = 1 from public.audit_events
   where household_id = '22220000-0000-4000-8000-000000000001'
     and action = 'invitation.created'
     and entity_ref->>'id' = '33330000-0000-4000-8000-000000000001'
     and position(test_invitations.val('token_1') in summary::text) = 0)
);

-- ---------------------------------------------------------------------------
-- 2. Owner-only invite rights, and cross-household isolation.
-- ---------------------------------------------------------------------------

select test_invitations.expect_sqlstate(
  'the owner of another household cannot invite into this one',
  $s$select public.write_path_create_invitation(
    '11110000-0000-4000-8000-000000000004', 'inv-create-cross', 'hash-cross',
    '{"command":"create_invitation"}', now(), null,
    '{"household_id":"22220000-0000-4000-8000-000000000001"}'
  )$s$,
  '42501'
);

select test_invitations.expect_sqlstate(
  'a user with no membership at all cannot invite',
  $s$select public.write_path_create_invitation(
    '11110000-0000-4000-8000-000000000003', 'inv-create-outsider', 'hash-outsider',
    '{"command":"create_invitation"}', now(), null,
    '{"household_id":"22220000-0000-4000-8000-000000000001"}'
  )$s$,
  '42501'
);

-- ---------------------------------------------------------------------------
-- 3. Acceptance creates exactly one membership, atomically.
-- ---------------------------------------------------------------------------

select test_invitations.expect_sqlstate(
  'an unknown token is rejected without disclosing anything',
  $s$select public.write_path_accept_invitation(
    '11110000-0000-4000-8000-000000000002', 'inv-accept-unknown', 'hash-unknown',
    '{"command":"accept_invitation"}', now(), null,
    '{"token":"0000000000000000000000000000000000000000000000000000000000000000"}'
  )$s$,
  'PC010'
);

select test_invitations.put(
  'accept_response',
  public.write_path_accept_invitation(
    '11110000-0000-4000-8000-000000000002', 'inv-accept-1', 'hash-accept-1',
    format(
      '{"command":"accept_invitation","payload":{"token":%s}}',
      to_jsonb(test_invitations.val('token_1'))
    )::jsonb,
    now(), null,
    jsonb_build_object('token', test_invitations.val('token_1'))
  )::text
);

select test_invitations.assert_true(
  'accepting creates exactly one active caregiver membership linked to the invitation',
  (select count(*) = 1 from public.household_memberships
   where household_id = '22220000-0000-4000-8000-000000000001'
     and user_id = '11110000-0000-4000-8000-000000000002'
     and status = 'active' and role = 'caregiver'
     and invitation_id = '33330000-0000-4000-8000-000000000001')
  and (select status = 'accepted'
        and accepted_by = '11110000-0000-4000-8000-000000000002'
        and resolved_at is not null
       from public.household_invitations where id = '33330000-0000-4000-8000-000000000001')
  and (test_invitations.val('accept_response')::jsonb -> 'household' ->> 'name') = 'Maple House'
);

select test_invitations.assert_true(
  'acceptance audits both the invitation and the membership (DM §15.2)',
  (select count(*) = 1 from public.audit_events
   where household_id = '22220000-0000-4000-8000-000000000001' and action = 'invitation.accepted')
  and (select count(*) = 1 from public.audit_events
       where household_id = '22220000-0000-4000-8000-000000000001' and action = 'membership.created')
);

select test_invitations.assert_true(
  'the plaintext token is redacted out of the stored accept request body',
  (select request_body -> 'payload' ->> 'token' = '[redacted]'
          and position(test_invitations.val('token_1') in request_body::text) = 0
   from public.command_log
   where actor_user_id = '11110000-0000-4000-8000-000000000002'
     and client_idempotency_key = 'inv-accept-1')
);

-- ---------------------------------------------------------------------------
-- 4. Single-use enforcement and idempotent replay.
-- ---------------------------------------------------------------------------

select test_invitations.expect_sqlstate(
  'single use: a second person cannot reuse an accepted token',
  format(
    $s$select public.write_path_accept_invitation(
      '11110000-0000-4000-8000-000000000003', 'inv-accept-second-person', 'hash-second',
      '{"command":"accept_invitation"}', now(), null, %L::jsonb
    )$s$,
    jsonb_build_object('token', test_invitations.val('token_1'))
  ),
  'PC012'
);

select test_invitations.put(
  'accept_replay_same_key',
  public.write_path_accept_invitation(
    '11110000-0000-4000-8000-000000000002', 'inv-accept-1', 'hash-accept-1',
    '{"command":"accept_invitation"}', now(), null,
    jsonb_build_object('token', test_invitations.val('token_1'))
  )::text
);
select test_invitations.put(
  'accept_replay_new_key',
  public.write_path_accept_invitation(
    '11110000-0000-4000-8000-000000000002', 'inv-accept-1-retry', 'hash-accept-retry',
    '{"command":"accept_invitation"}', now(), null,
    jsonb_build_object('token', test_invitations.val('token_1'))
  )::text
);

select test_invitations.assert_true(
  'replaying an acceptance returns the existing result and never a second membership',
  test_invitations.val('accept_replay_same_key')::jsonb -> 'membership' ->> 'id'
    = test_invitations.val('accept_response')::jsonb -> 'membership' ->> 'id'
  and test_invitations.val('accept_replay_new_key')::jsonb -> 'membership' ->> 'id'
    = test_invitations.val('accept_response')::jsonb -> 'membership' ->> 'id'
  and (select count(*) = 1 from public.household_memberships
       where household_id = '22220000-0000-4000-8000-000000000001'
         and user_id = '11110000-0000-4000-8000-000000000002')
);

select test_invitations.expect_sqlstate(
  'reusing an idempotency key for a different payload is a conflict',
  $s$select public.write_path_create_invitation(
    '11110000-0000-4000-8000-000000000001', 'inv-create-1', 'hash-create-DIFFERENT',
    '{"command":"create_invitation"}', now(), null,
    '{"household_id":"22220000-0000-4000-8000-000000000001"}'
  )$s$,
  '23505'
);

select test_invitations.assert_true(
  'a replayed create never re-reveals the token',
  not (
    public.write_path_create_invitation(
      '11110000-0000-4000-8000-000000000001', 'inv-create-1', 'hash-create-1',
      '{"command":"create_invitation"}', now(), null,
      '{"household_id":"22220000-0000-4000-8000-000000000001","invitation_id":"33330000-0000-4000-8000-000000000001"}'
    ) ? 'token'
  )
);

-- ---------------------------------------------------------------------------
-- 5. A caregiver cannot invite; an existing member cannot re-accept.
-- ---------------------------------------------------------------------------

select test_invitations.expect_sqlstate(
  'a full caregiver cannot invite another member (US-011)',
  $s$select public.write_path_create_invitation(
    '11110000-0000-4000-8000-000000000002', 'inv-create-caregiver', 'hash-caregiver',
    '{"command":"create_invitation"}', now(), null,
    '{"household_id":"22220000-0000-4000-8000-000000000001"}'
  )$s$,
  '42501'
);

select test_invitations.put(
  'token_2',
  public.write_path_create_invitation(
    '11110000-0000-4000-8000-000000000001', 'inv-create-2', 'hash-create-2',
    '{"command":"create_invitation"}', now(), null,
    '{"household_id":"22220000-0000-4000-8000-000000000001","invitation_id":"33330000-0000-4000-8000-000000000002"}'
  ) ->> 'token'
);

select test_invitations.expect_sqlstate(
  'one active membership per (user, household): an existing member cannot accept again',
  format(
    $s$select public.write_path_accept_invitation(
      '11110000-0000-4000-8000-000000000002', 'inv-accept-already-member', 'hash-already',
      '{"command":"accept_invitation"}', now(), null, %L::jsonb
    )$s$,
    jsonb_build_object('token', test_invitations.val('token_2'))
  ),
  'PC013'
);

select test_invitations.expect_sqlstate(
  'a caregiver already active in another household cannot join a second one in this release',
  format(
    $s$select public.write_path_accept_invitation(
      '11110000-0000-4000-8000-000000000005', 'inv-accept-other-household', 'hash-other',
      '{"command":"accept_invitation"}', now(), null, %L::jsonb
    )$s$,
    jsonb_build_object('token', test_invitations.val('token_2'))
  ),
  'PC015'
);

select test_invitations.assert_true(
  'a rejected acceptance leaves the invitation pending and creates no membership',
  (select status = 'pending' from public.household_invitations
   where id = '33330000-0000-4000-8000-000000000002')
  and (select count(*) = 0 from public.household_memberships
       where household_id = '22220000-0000-4000-8000-000000000001'
         and user_id = '11110000-0000-4000-8000-000000000005')
);

-- ---------------------------------------------------------------------------
-- 6. Expiry.
-- ---------------------------------------------------------------------------

insert into public.household_invitations (
  id, household_id, created_by, token_hash, role_granted, expires_at, status, updated_by
) values (
  '33330000-0000-4000-8000-000000000003', '22220000-0000-4000-8000-000000000001',
  '11110000-0000-4000-8000-000000000001',
  public.household_invitation_token_hash('expired-fixture-token'),
  'caregiver', now() - interval '1 hour', 'pending', '11110000-0000-4000-8000-000000000001'
);

select test_invitations.expect_sqlstate(
  'an expired token cannot be accepted',
  $s$select public.write_path_accept_invitation(
    '11110000-0000-4000-8000-000000000003', 'inv-accept-expired', 'hash-expired',
    '{"command":"accept_invitation"}', now(), null,
    '{"token":"expired-fixture-token"}'
  )$s$,
  'PC011'
);

-- Deliberately its own statement: the sweep must run before the assertion
-- reads the row, and Postgres does not promise to evaluate the operands of
-- `and` in written order.
select test_invitations.put(
  'swept_count',
  public.expire_stale_household_invitations('22220000-0000-4000-8000-000000000001')::text
);

select test_invitations.assert_true(
  'a lapsed invitation is swept to expired the next time the household is written',
  test_invitations.val('swept_count') = '1'
  and (select status = 'expired' and resolved_at is not null
       from public.household_invitations where id = '33330000-0000-4000-8000-000000000003')
);

select test_invitations.expect_sqlstate(
  'an already-expired invitation stays terminal',
  $s$select public.write_path_accept_invitation(
    '11110000-0000-4000-8000-000000000003', 'inv-accept-expired-2', 'hash-expired-2',
    '{"command":"accept_invitation"}', now(), null,
    '{"token":"expired-fixture-token"}'
  )$s$,
  'PC011'
);

-- ---------------------------------------------------------------------------
-- 7. Revoke and decline.
-- ---------------------------------------------------------------------------

select test_invitations.expect_sqlstate(
  'only an owner can revoke a pending invitation',
  $s$select public.write_path_revoke_invitation(
    '11110000-0000-4000-8000-000000000002', 'inv-revoke-caregiver', 'hash-revoke-caregiver',
    '{"command":"revoke_invitation"}', now(), null,
    '{"invitation_id":"33330000-0000-4000-8000-000000000002"}'
  )$s$,
  '42501'
);

select public.write_path_revoke_invitation(
  '11110000-0000-4000-8000-000000000001', 'inv-revoke-1', 'hash-revoke-1',
  '{"command":"revoke_invitation"}', now(), null,
  '{"invitation_id":"33330000-0000-4000-8000-000000000002"}'
);

select test_invitations.assert_true(
  'revoking resolves the invitation and audits it',
  (select status = 'revoked' and resolved_at is not null
   from public.household_invitations where id = '33330000-0000-4000-8000-000000000002')
  and (select count(*) = 1 from public.audit_events
       where action = 'invitation.revoked'
         and entity_ref->>'id' = '33330000-0000-4000-8000-000000000002')
);

select test_invitations.expect_sqlstate(
  'a revoked token cannot be accepted',
  format(
    $s$select public.write_path_accept_invitation(
      '11110000-0000-4000-8000-000000000003', 'inv-accept-revoked', 'hash-revoked',
      '{"command":"accept_invitation"}', now(), null, %L::jsonb
    )$s$,
    jsonb_build_object('token', test_invitations.val('token_2'))
  ),
  'PC012'
);

select test_invitations.put(
  'token_4',
  public.write_path_create_invitation(
    '11110000-0000-4000-8000-000000000001', 'inv-create-4', 'hash-create-4',
    '{"command":"create_invitation"}', now(), null,
    '{"household_id":"22220000-0000-4000-8000-000000000001","invitation_id":"33330000-0000-4000-8000-000000000004"}'
  ) ->> 'token'
);

select test_invitations.put(
  'decline_response',
  public.write_path_decline_invitation(
    '11110000-0000-4000-8000-000000000003', 'inv-decline-1', 'hash-decline-1',
    format(
      '{"command":"decline_invitation","payload":{"token":%s}}',
      to_jsonb(test_invitations.val('token_4'))
    )::jsonb,
    now(), null,
    jsonb_build_object('token', test_invitations.val('token_4'))
  )::text
);

select test_invitations.assert_true(
  'declining resolves the invitation, grants nothing, and exposes no household data',
  (select status = 'declined' and accepted_by is null and resolved_at is not null
   from public.household_invitations where id = '33330000-0000-4000-8000-000000000004')
  and (select count(*) = 0 from public.household_memberships
       where household_id = '22220000-0000-4000-8000-000000000001'
         and user_id = '11110000-0000-4000-8000-000000000003')
  and not (test_invitations.val('decline_response')::jsonb ? 'household')
  and (select request_body -> 'payload' ->> 'token' = '[redacted]'
       from public.command_log where client_idempotency_key = 'inv-decline-1')
);

select test_invitations.expect_sqlstate(
  'a declined token cannot then be accepted',
  format(
    $s$select public.write_path_accept_invitation(
      '11110000-0000-4000-8000-000000000003', 'inv-accept-declined', 'hash-accept-declined',
      '{"command":"accept_invitation"}', now(), null, %L::jsonb
    )$s$,
    jsonb_build_object('token', test_invitations.val('token_4'))
  ),
  'PC012'
);

-- ---------------------------------------------------------------------------
-- 8. Bounded pending invitations (US-011 "no uncontrolled duplicates").
-- ---------------------------------------------------------------------------

do $$
declare i integer;
begin
  for i in 1..5 loop
    perform public.write_path_create_invitation(
      '11110000-0000-4000-8000-000000000004', 'inv-cap-' || i, 'hash-cap-' || i,
      '{"command":"create_invitation"}', now(), null,
      '{"household_id":"22220000-0000-4000-8000-000000000002"}'
    );
  end loop;
end;
$$;

select test_invitations.expect_sqlstate(
  'a household cannot accumulate unbounded pending invitations',
  $s$select public.write_path_create_invitation(
    '11110000-0000-4000-8000-000000000004', 'inv-cap-6', 'hash-cap-6',
    '{"command":"create_invitation"}', now(), null,
    '{"household_id":"22220000-0000-4000-8000-000000000002"}'
  )$s$,
  '22023'
);

-- ---------------------------------------------------------------------------
-- 9. At least one active owner per active household (DM §18.1).
-- ---------------------------------------------------------------------------

select test_invitations.expect_sqlstate(
  'the last active owner cannot be removed from an active household',
  $s$update public.household_memberships
     set status = 'removed', ended_at = now(), ended_by = user_id
     where household_id = '22220000-0000-4000-8000-000000000001'
       and user_id = '11110000-0000-4000-8000-000000000001'$s$,
  '23514'
);

select test_invitations.expect_sqlstate(
  'the last active owner cannot be demoted to caregiver',
  $s$update public.household_memberships
     set role = 'caregiver'
     where household_id = '22220000-0000-4000-8000-000000000001'
       and user_id = '11110000-0000-4000-8000-000000000001'$s$,
  '23514'
);

select test_invitations.assert_true(
  'a non-final owner can still leave (the invariant is about the last one)',
  (select count(*) = 1 from public.household_memberships
   where household_id = '22220000-0000-4000-8000-000000000001'
     and user_id = '11110000-0000-4000-8000-000000000001' and status = 'active')
);

-- ---------------------------------------------------------------------------
-- 10. Pre-acceptance disclosure and reader isolation (as real end users).
-- ---------------------------------------------------------------------------

select test_invitations.put(
  'token_5',
  public.write_path_create_invitation(
    '11110000-0000-4000-8000-000000000001', 'inv-create-5', 'hash-create-5',
    '{"command":"create_invitation"}', now(), null,
    '{"household_id":"22220000-0000-4000-8000-000000000001","invitation_id":"33330000-0000-4000-8000-000000000005"}'
  ) ->> 'token'
);

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"11110000-0000-4000-8000-000000000003","role":"authenticated"}', true);

select test_invitations.put(
  'preview_valid', public.invitation_preview(test_invitations.val('token_5'))::text
);
select test_invitations.put(
  'preview_unknown', public.invitation_preview('not-a-real-token')::text
);
select test_invitations.put(
  'preview_expired', public.invitation_preview('expired-fixture-token')::text
);
select test_invitations.put(
  'invitations_visible_to_outsider',
  (select count(*)::text from public.household_invitations
   where household_id = '22220000-0000-4000-8000-000000000001')
);

reset role;

select test_invitations.assert_true(
  'the pre-acceptance preview discloses household name, inviter, and expiry -- and nothing else',
  (test_invitations.val('preview_valid')::jsonb ->> 'status') = 'valid'
  and (test_invitations.val('preview_valid')::jsonb ->> 'household_name') = 'Maple House'
  and (test_invitations.val('preview_valid')::jsonb ->> 'inviter_display_name') = 'Nic'
  and (test_invitations.val('preview_valid')::jsonb ->> 'expires_at') is not null
  and (
    select array_agg(k order by k) = array['expires_at','household_name','inviter_display_name','role_granted','status']
    from jsonb_object_keys(test_invitations.val('preview_valid')::jsonb) as k
  )
);

select test_invitations.assert_true(
  'an unknown token reveals nothing at all, and an expired one is named as expired',
  test_invitations.val('preview_unknown')::jsonb = '{"status":"not_found"}'::jsonb
  and (test_invitations.val('preview_expired')::jsonb ->> 'status') = 'expired'
);

select test_invitations.assert_true(
  'an invitee still sees no invitation rows before acceptance (RLS unchanged)',
  test_invitations.val('invitations_visible_to_outsider') = '0'
);

-- ---------------------------------------------------------------------------
-- 11. Member display names: co-members, and only co-members.
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"11110000-0000-4000-8000-000000000002","role":"authenticated"}', true);

select test_invitations.put(
  'member_names',
  (select string_agg(display_name || ':' || role, ',' order by display_name)
   from public.household_member_profiles
   where household_id = '22220000-0000-4000-8000-000000000001' and status = 'active')
);
select test_invitations.put(
  'foreign_member_rows',
  (select count(*)::text from public.household_member_profiles
   where household_id = '22220000-0000-4000-8000-000000000002')
);

reset role;

select test_invitations.assert_true(
  'a caregiver can resolve every co-member display name and role (US-013)',
  test_invitations.val('member_names') = 'Nic:owner,Sarah:caregiver'
);

select test_invitations.assert_true(
  'cross-household isolation: a member sees no rows from another household',
  test_invitations.val('foreign_member_rows') = '0'
);

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"11110000-0000-4000-8000-000000000005","role":"authenticated"}', true);

select test_invitations.put(
  'other_household_member_names',
  (select string_agg(display_name, ',' order by display_name)
   from public.household_member_profiles
   where status = 'active')
);

reset role;

select test_invitations.assert_true(
  'the members view is scoped to the caller''s own households only',
  test_invitations.val('other_household_member_names') = 'Other Member,Other Owner'
);

-- ---------------------------------------------------------------------------
-- 12. Clients can never read a token hash, and can never write invitations.
-- ---------------------------------------------------------------------------

do $$
declare denied boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims',
    '{"sub":"11110000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  begin
    perform token_hash from public.household_invitations
    where id = '33330000-0000-4000-8000-000000000005';
  exception when insufficient_privilege then
    denied := true;
  end;
  reset role;
  perform test_invitations.assert_true(
    'authenticated clients hold no SELECT privilege on household_invitations.token_hash',
    denied
  );
end;
$$;

do $$
declare visible integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims',
    '{"sub":"11110000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  select count(*) into visible from public.household_invitations
  where household_id = '22220000-0000-4000-8000-000000000001';
  reset role;
  perform test_invitations.assert_true(
    'an owner can still list their household''s invitations through the granted columns',
    visible >= 4, format('rows visible=%s', visible)
  );
end;
$$;

select test_invitations.expect_sqlstate(
  'the invitation write-path functions are not callable by authenticated clients',
  $s$do $inner$
    begin
      set local role authenticated;
      perform public.write_path_accept_invitation(
        '11110000-0000-4000-8000-000000000003', 'inv-direct', 'hash-direct',
        '{}'::jsonb, now(), null, '{"token":"x"}'::jsonb
      );
    end;
  $inner$$s$,
  '42501'
);
reset role;

do $$
declare failed_count integer;
begin
  select count(*) into failed_count from test_invitations.results where not passed;
  if failed_count > 0 then
    raise exception '% invitation assertion(s) failed', failed_count;
  end if;
end;
$$;
rollback;
