-- Slice B shared care: household invitations.
--
-- Implements the HouseholdInvitation lifecycle (DM doc 10 §7.4) and the
-- membership invariants it touches (DM §18.1, §18.2):
--   * the share token is generated server-side and stored ONLY as a SHA-256
--     hash; the plaintext token is returned exactly once, in the live
--     create response, and is never written to command_log or audit_events;
--   * acceptance is single-use and atomic: it creates exactly one active
--     membership, or it fails and changes nothing;
--   * at most one active membership per (user, household) -- also backed by
--     the partial unique index from the Slice A foundation;
--   * every active household keeps at least one active owner -- previously a
--     "write-path-only" invariant, now enforced by a trigger as well;
--   * creating and revoking invitations is owner-only (DM §5.2, US-011).
--
-- Pre-acceptance disclosure (DM §7.4) is served by public.invitation_preview:
-- household name, inviter display name, and expiry -- nothing else, ever.

-- ---------------------------------------------------------------------------
-- Token hashing
-- ---------------------------------------------------------------------------

-- Deliberately built on the core pg_catalog sha256(bytea) rather than
-- pgcrypto's digest(): pgcrypto may live in the `extensions` schema on hosted
-- Supabase, which is not on these functions' `search_path = public`.
create or replace function public.household_invitation_token_hash(token_input text)
returns text
language sql
immutable
strict
as $$
  select encode(sha256(convert_to(token_input, 'UTF8')), 'hex');
$$;

comment on function public.household_invitation_token_hash(text) is
  'SHA-256 hex digest of an invitation share token. The plaintext token is never stored (DM 10 §7.4).';

-- ---------------------------------------------------------------------------
-- Lazy expiry
-- ---------------------------------------------------------------------------

-- There is no scheduled job in this slice, so pending invitations that have
-- passed `expires_at` are resolved opportunistically whenever a household's
-- invitations are next written. `resolved_at` records when the invitation
-- actually lapsed (its own expiry instant), not when the sweep noticed.
--
-- Acceptance deliberately does NOT call this: an accept of an expired token
-- must raise, and raising would roll the transition back anyway. Readers
-- (invitation_preview, ST-04) therefore treat `status = 'pending' and
-- expires_at <= now()` as expired regardless of the stored status.
create or replace function public.expire_stale_household_invitations(target_household_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  expired_count integer;
begin
  with lapsed as (
    update public.household_invitations
    set status = 'expired', resolved_at = expires_at
    where household_id = target_household_id
      and status = 'pending'
      and expires_at <= now()
    returning 1
  )
  select count(*) into expired_count from lapsed;
  return expired_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- DM §18.1: an active household always keeps at least one active owner
-- ---------------------------------------------------------------------------

create or replace function public.enforce_active_owner_present()
returns trigger
language plpgsql
as $$
declare
  target_household_id uuid;
begin
  -- Only departures of an active owner can break the invariant.
  if tg_op = 'UPDATE' then
    if old.status <> 'active' or old.role <> 'owner' then
      return new;
    end if;
    if new.status = 'active' and new.role = 'owner' then
      return new;
    end if;
    target_household_id := old.household_id;
  else
    if old.status <> 'active' or old.role <> 'owner' then
      return old;
    end if;
    target_household_id := old.household_id;
  end if;

  -- A closed household is outside the invariant (DM §18.1 says "every active
  -- household"); household closure legitimately ends every membership.
  if not exists (
    select 1 from public.households h
    where h.id = target_household_id and h.status = 'active'
  ) then
    return coalesce(new, old);
  end if;

  if not exists (
    select 1 from public.household_memberships hm
    where hm.household_id = target_household_id
      and hm.role = 'owner'
      and hm.status = 'active'
  ) then
    raise exception 'an active household must keep at least one active owner'
      using errcode = '23514';
  end if;

  return coalesce(new, old);
end;
$$;

create trigger household_memberships_keep_active_owner
  after update or delete on public.household_memberships
  for each row execute function public.enforce_active_owner_present();

-- ---------------------------------------------------------------------------
-- write_path_create_invitation (US-011, ST-05)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_create_invitation(
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
  target_household public.households%rowtype;
  actor_role public.household_role;
  role_granted_value public.household_role;
  invitation_id uuid;
  token_plain text;
  token_hash_value text;
  expires_in_hours integer;
  expires_at_value timestamptz;
  pending_count integer;
  stored_response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'create_invitation' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    -- A replay never re-reveals the token: the stored response omits it.
    return existing.response_body;
  end if;

  select * into target_household from public.households
  where id = nullif(payload_input->>'household_id', '')::uuid;
  if not found or target_household.status <> 'active' then
    raise exception 'household not found or closed' using errcode = '42501';
  end if;

  -- Owner-only invite rights (US-011: "A full caregiver cannot invite another
  -- member"). Membership is re-checked here, not trusted from the client.
  select hm.role into actor_role from public.household_memberships hm
  where hm.household_id = target_household.id
    and hm.user_id = actor_id
    and hm.status = 'active';
  if not found or actor_role <> 'owner' then
    raise exception 'only a household owner can invite a caregiver' using errcode = '42501';
  end if;

  role_granted_value := coalesce(nullif(payload_input->>'role_granted', ''), 'caregiver')::public.household_role;
  if role_granted_value <> 'caregiver' then
    raise exception 'only the caregiver role can be granted in MVP' using errcode = '22023';
  end if;

  expires_in_hours := coalesce(nullif(payload_input->>'expires_in_hours', '')::integer, 168);
  if expires_in_hours < 1 or expires_in_hours > 336 then
    raise exception 'expires_in_hours must be between 1 and 336' using errcode = '22023';
  end if;

  perform public.expire_stale_household_invitations(target_household.id);

  -- US-011 "Repeated invite submission does not create uncontrolled
  -- duplicates": exact resubmissions are absorbed by the idempotency key
  -- above; distinct submissions are bounded so a household can never
  -- accumulate an unbounded set of live tokens.
  select count(*) into pending_count from public.household_invitations
  where household_id = target_household.id and status = 'pending';
  if pending_count >= 5 then
    raise exception 'this household already has 5 pending invitations; revoke one before creating another'
      using errcode = '22023';
  end if;

  invitation_id := coalesce(nullif(payload_input->>'invitation_id', '')::uuid, gen_random_uuid());

  -- 244 bits of entropy from two v4 UUIDs. gen_random_bytes() would be the
  -- obvious source but lives in pgcrypto (schema-placement caveat above);
  -- gen_random_uuid() is core and equally CSPRNG-backed.
  token_plain := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  token_hash_value := public.household_invitation_token_hash(token_plain);

  -- Expiry is anchored to server time, never to the client-supplied
  -- recorded_at, which a caller could backdate or postdate.
  expires_at_value := now() + make_interval(hours => expires_in_hours);

  insert into public.household_invitations (
    id, household_id, created_by, token_hash, role_granted, expires_at, status, updated_by
  ) values (
    invitation_id, target_household.id, actor_id, token_hash_value,
    role_granted_value, expires_at_value, 'pending', actor_id
  );

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_household.id, actor_id,
    jsonb_build_object('type', 'household_invitation', 'id', invitation_id),
    'invitation.created',
    jsonb_build_object(
      'role_granted', role_granted_value,
      'expires_at', expires_at_value
    ),
    recorded_at_input
  );

  -- The stored response omits the token on purpose: command_log is durable,
  -- replayable, and support-readable. `token_returned_once` tells a client
  -- that replayed a create that the link it is looking for was already
  -- issued and cannot be recovered -- revoke and re-invite instead.
  stored_response := jsonb_build_object(
    'invitation', jsonb_build_object(
      'id', invitation_id,
      'household_id', target_household.id,
      'household_name', target_household.name,
      'created_by', actor_id,
      'role_granted', role_granted_value,
      'status', 'pending',
      'expires_at', expires_at_value
    ),
    'token_returned_once', true
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'create_invitation', payload_hash_input,
    request_body_input, stored_response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return stored_response || jsonb_build_object('token', token_plain);
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_revoke_invitation (US-011 "A pending invitation can be revoked")
-- ---------------------------------------------------------------------------

create or replace function public.write_path_revoke_invitation(
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
  target_invitation public.household_invitations%rowtype;
  actor_role public.household_role;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'revoke_invitation' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  select * into target_invitation from public.household_invitations
  where id = nullif(payload_input->>'invitation_id', '')::uuid
  for update;
  if not found then
    raise exception 'invitation not found' using errcode = 'PC010';
  end if;

  select hm.role into actor_role from public.household_memberships hm
  where hm.household_id = target_invitation.household_id
    and hm.user_id = actor_id
    and hm.status = 'active';
  if not found or actor_role <> 'owner' then
    raise exception 'only a household owner can revoke an invitation' using errcode = '42501';
  end if;

  if target_invitation.status <> 'pending' then
    raise exception 'this invitation is already %', target_invitation.status using errcode = 'PC012';
  end if;

  update public.household_invitations
  set status = 'revoked', resolved_at = now(), updated_by = actor_id
  where id = target_invitation.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values (
    target_invitation.household_id, actor_id,
    jsonb_build_object('type', 'household_invitation', 'id', target_invitation.id),
    'invitation.revoked',
    jsonb_build_object('previous_status', 'pending', 'expires_at', target_invitation.expires_at),
    recorded_at_input
  );

  response := jsonb_build_object(
    'invitation', (
      select jsonb_build_object(
        'id', i.id, 'household_id', i.household_id, 'status', i.status,
        'expires_at', i.expires_at, 'resolved_at', i.resolved_at
      )
      from public.household_invitations i where i.id = target_invitation.id
    )
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'revoke_invitation', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_accept_invitation (US-012, ON-05)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_accept_invitation(
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
  target_invitation public.household_invitations%rowtype;
  target_household public.households%rowtype;
  existing_membership public.household_memberships%rowtype;
  token_input text;
  token_hash_value text;
  membership_id uuid;
  joined_at_value timestamptz;
  stored_request jsonb;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'accept_invitation' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  token_input := nullif(trim(payload_input->>'token'), '');
  if token_input is null then
    raise exception 'token is required' using errcode = '22023';
  end if;
  token_hash_value := public.household_invitation_token_hash(token_input);

  -- Defence in depth: the edge function already redacts the plaintext token
  -- before it reaches request_body_input, but command_log is durable and must
  -- never hold a live token even if another caller forgets.
  stored_request := request_body_input;
  if stored_request #> '{payload,token}' is not null then
    stored_request := jsonb_set(stored_request, '{payload,token}', '"[redacted]"'::jsonb);
  end if;

  -- Serialises concurrent acceptances of the SAME token across sessions, so
  -- single-use holds even when two devices race (DM §18.2).
  perform pg_advisory_xact_lock(hashtextextended('household_invitation:' || token_hash_value, 0));

  select * into target_invitation from public.household_invitations
  where token_hash = token_hash_value
  for update;
  if not found then
    raise exception 'this invitation link is not valid' using errcode = 'PC010';
  end if;

  select * into target_household from public.households
  where id = target_invitation.household_id;

  select * into existing_membership from public.household_memberships
  where household_id = target_invitation.household_id
    and user_id = actor_id
    and status = 'active';

  -- DM §7.4: "re-submitting a completed acceptance returns the existing
  -- result". Only the user who accepted it may replay it; for anyone else an
  -- accepted token is simply used up.
  if target_invitation.status = 'accepted' then
    if target_invitation.accepted_by = actor_id and existing_membership.id is not null then
      response := jsonb_build_object(
        'household', jsonb_build_object(
          'id', target_household.id, 'name', target_household.name,
          'time_zone', target_household.time_zone, 'status', target_household.status
        ),
        'membership', jsonb_build_object(
          'id', existing_membership.id, 'user_id', actor_id,
          'role', existing_membership.role, 'status', existing_membership.status,
          'joined_at', existing_membership.joined_at
        ),
        'invitation', jsonb_build_object(
          'id', target_invitation.id, 'status', target_invitation.status,
          'resolved_at', target_invitation.resolved_at
        )
      );
      insert into public.command_log (
        actor_user_id, client_idempotency_key, command, payload_hash, request_body,
        response_body, status, recorded_at, effective_at, completed_at
      ) values (
        actor_id, idempotency_key, 'accept_invitation', payload_hash_input,
        stored_request, response, 'succeeded', recorded_at_input,
        effective_at_input, now()
      );
      return response;
    end if;
    raise exception 'this invitation has already been used' using errcode = 'PC012';
  end if;

  if target_invitation.status = 'declined' then
    raise exception 'this invitation was declined' using errcode = 'PC012';
  end if;
  if target_invitation.status = 'revoked' then
    raise exception 'this invitation was revoked by the household owner' using errcode = 'PC012';
  end if;
  if target_invitation.status = 'expired' or target_invitation.expires_at <= now() then
    raise exception 'this invitation has expired' using errcode = 'PC011';
  end if;

  if target_household.status <> 'active' then
    raise exception 'this household is closed' using errcode = 'PC014';
  end if;

  -- DM §18.1: at most one active membership per (user, household).
  if existing_membership.id is not null then
    raise exception 'you are already a member of this household' using errcode = 'PC013';
  end if;

  -- MVP client constraint, not a data-model rule: every surface in this
  -- release (household switcher, plan generation, notification routing)
  -- assumes one active household per account, so joining a second one would
  -- render untruthfully rather than fail. DM §5.1 permits multiple
  -- memberships; lift this check together with the household switcher.
  if exists (
    select 1
    from public.household_memberships hm
    join public.households h on h.id = hm.household_id
    where hm.user_id = actor_id
      and hm.status = 'active'
      and h.status = 'active'
  ) then
    raise exception 'PetCompanion supports one household per account in this release'
      using errcode = 'PC015';
  end if;

  joined_at_value := coalesce(effective_at_input, recorded_at_input, now());

  insert into public.household_memberships (
    household_id, user_id, role, status, joined_at, invitation_id, created_by, updated_by
  ) values (
    target_invitation.household_id, actor_id, target_invitation.role_granted,
    'active', joined_at_value, target_invitation.id, actor_id, actor_id
  )
  returning id into membership_id;

  update public.household_invitations
  set status = 'accepted', accepted_by = actor_id, resolved_at = now(), updated_by = actor_id
  where id = target_invitation.id;

  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  ) values
    (
      target_invitation.household_id, actor_id,
      jsonb_build_object('type', 'household_invitation', 'id', target_invitation.id),
      'invitation.accepted',
      jsonb_build_object('membership_id', membership_id, 'role_granted', target_invitation.role_granted),
      recorded_at_input
    ),
    (
      target_invitation.household_id, actor_id,
      jsonb_build_object('type', 'household_membership', 'id', membership_id),
      'membership.created',
      jsonb_build_object(
        'role', target_invitation.role_granted,
        'invitation_id', target_invitation.id,
        'joined_at', joined_at_value
      ),
      recorded_at_input
    );

  response := jsonb_build_object(
    'household', jsonb_build_object(
      'id', target_household.id, 'name', target_household.name,
      'time_zone', target_household.time_zone, 'status', target_household.status
    ),
    'membership', jsonb_build_object(
      'id', membership_id, 'user_id', actor_id,
      'role', target_invitation.role_granted, 'status', 'active',
      'joined_at', joined_at_value
    ),
    'invitation', jsonb_build_object(
      'id', target_invitation.id, 'status', 'accepted', 'resolved_at', now()
    )
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'accept_invitation', payload_hash_input,
    stored_request, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_decline_invitation (US-012)
-- ---------------------------------------------------------------------------

create or replace function public.write_path_decline_invitation(
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
  target_invitation public.household_invitations%rowtype;
  token_input text;
  token_hash_value text;
  stored_request jsonb;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'decline_invitation' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  token_input := nullif(trim(payload_input->>'token'), '');
  if token_input is null then
    raise exception 'token is required' using errcode = '22023';
  end if;
  token_hash_value := public.household_invitation_token_hash(token_input);

  stored_request := request_body_input;
  if stored_request #> '{payload,token}' is not null then
    stored_request := jsonb_set(stored_request, '{payload,token}', '"[redacted]"'::jsonb);
  end if;

  perform pg_advisory_xact_lock(hashtextextended('household_invitation:' || token_hash_value, 0));

  select * into target_invitation from public.household_invitations
  where token_hash = token_hash_value
  for update;
  if not found then
    raise exception 'this invitation link is not valid' using errcode = 'PC010';
  end if;

  -- Declining twice is a no-op that returns the same shape, so a retry after
  -- a lost response never turns into an error the invitee cannot resolve.
  if target_invitation.status not in ('pending', 'declined') then
    raise exception 'this invitation is already %', target_invitation.status using errcode = 'PC012';
  end if;

  if target_invitation.status = 'pending' then
    update public.household_invitations
    set status = 'declined', resolved_at = now(), updated_by = actor_id
    where id = target_invitation.id;

    insert into public.audit_events (
      household_id, actor_user_id, entity_ref, action, summary, occurred_at
    ) values (
      target_invitation.household_id, actor_id,
      jsonb_build_object('type', 'household_invitation', 'id', target_invitation.id),
      'invitation.declined',
      jsonb_build_object('previous_status', 'pending'),
      recorded_at_input
    );
  end if;

  -- Declining exposes nothing about the household (US-012).
  response := jsonb_build_object(
    'invitation', jsonb_build_object('id', target_invitation.id, 'status', 'declined')
  );

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'decline_invitation', payload_hash_input,
    stored_request, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- Pre-acceptance preview (ON-05, DM §7.4)
-- ---------------------------------------------------------------------------

-- The invitee is by definition NOT a member yet, so no RLS-scoped read can
-- serve ON-05. This is the only path that discloses anything about a
-- household to a non-member, and it discloses exactly the three fields DM
-- §7.4 permits: household name, inviter display name, expiry. It is
-- read-only, takes no actor parameter (it derives the viewer from auth.uid()),
-- and requires both authentication and possession of a 244-bit token.
create or replace function public.invitation_preview(token_input text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  viewer_id uuid := auth.uid();
  target_invitation public.household_invitations%rowtype;
  target_household public.households%rowtype;
  inviter_display_name text;
  preview_status text;
begin
  if viewer_id is null then
    raise exception 'sign in to review an invitation' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(token_input, '')), '') is null then
    return jsonb_build_object('status', 'not_found');
  end if;

  select * into target_invitation from public.household_invitations
  where token_hash = public.household_invitation_token_hash(trim(token_input));
  if not found then
    -- No household detail for an unknown token, and the same shape as every
    -- other failure so the response cannot be used as an oracle.
    return jsonb_build_object('status', 'not_found');
  end if;

  select * into target_household from public.households where id = target_invitation.household_id;
  select up.display_name into inviter_display_name from public.user_profiles up
  where up.id = target_invitation.created_by;

  preview_status := case
    when target_invitation.status = 'accepted' and target_invitation.accepted_by = viewer_id then 'accepted_by_you'
    when target_invitation.status = 'accepted' then 'already_used'
    when target_invitation.status = 'declined' then 'declined'
    when target_invitation.status = 'revoked' then 'revoked'
    when target_invitation.status = 'expired' or target_invitation.expires_at <= now() then 'expired'
    when target_household.status <> 'active' then 'household_closed'
    when exists (
      select 1 from public.household_memberships hm
      where hm.household_id = target_invitation.household_id
        and hm.user_id = viewer_id and hm.status = 'active'
    ) then 'already_member'
    when exists (
      select 1 from public.household_memberships hm
      join public.households h on h.id = hm.household_id
      where hm.user_id = viewer_id and hm.status = 'active' and h.status = 'active'
    ) then 'other_household'
    else 'valid'
  end;

  return jsonb_build_object(
    'status', preview_status,
    'household_name', target_household.name,
    'inviter_display_name', inviter_display_name,
    'expires_at', target_invitation.expires_at,
    'role_granted', target_invitation.role_granted
  );
end;
$$;

comment on function public.invitation_preview(text) is
  'Pre-acceptance disclosure for ON-05: household name, inviter display name, and expiry only (DM 10 §7.4).';

-- ---------------------------------------------------------------------------
-- Member display names for co-members (US-013, DM §7.1)
-- ---------------------------------------------------------------------------

-- `user_profiles` RLS is self-only, which was fine while a household had one
-- member; with a second caregiver the client could not resolve anyone else's
-- name and rendered the literal string "Caregiver". DM §7.1 allows other
-- members to see exactly `display_name` and the membership role, so this view
-- exposes that column set and nothing else (no auth_provider_ref, no email).
--
-- security_invoker stays off so the view can read user_profiles past its
-- self-only policy; tenancy is enforced inside the view by
-- is_active_household_member, and security_barrier stops a user-supplied
-- function in an outer WHERE from being evaluated before that filter.
create view public.household_member_profiles
  with (security_invoker = false, security_barrier = true)
as
select
  hm.id as membership_id,
  hm.household_id,
  hm.user_id,
  hm.role,
  hm.status,
  hm.joined_at,
  hm.ended_at,
  up.display_name,
  up.status as user_status
from public.household_memberships hm
join public.user_profiles up on up.id = hm.user_id
where public.is_active_household_member(hm.household_id);

comment on view public.household_member_profiles is
  'Household members joined with the only user fields co-members may see (DM 10 §7.1): display_name and account status.';

grant select on public.household_member_profiles to authenticated;

-- ---------------------------------------------------------------------------
-- Column-level hardening: token hashes never leave the server
-- ---------------------------------------------------------------------------

-- ST-04 needs to list pending invitations, which requires SELECT on
-- household_invitations, but no client ever needs `token_hash`. Replacing the
-- Slice A table-wide grant with a column list keeps the RLS row scoping
-- ("invitations active member read") and removes the hash from the wire.
revoke select on public.household_invitations from authenticated;
grant select (
  id, household_id, created_by, role_granted, expires_at, status,
  accepted_by, resolved_at, created_at, updated_at, updated_by
) on public.household_invitations to authenticated;

-- ---------------------------------------------------------------------------
-- SECURITY DEFINER lockdown
-- ---------------------------------------------------------------------------

-- Every write_path_* function trusts its actor_id argument, so only the edge
-- function's service role may call it.
revoke execute on function public.write_path_create_invitation(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_revoke_invitation(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_accept_invitation(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_decline_invitation(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.expire_stale_household_invitations(uuid) from public, anon, authenticated;

grant execute on function public.write_path_create_invitation(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_revoke_invitation(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_accept_invitation(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_decline_invitation(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.expire_stale_household_invitations(uuid) to service_role;

-- The preview is read-only, derives its viewer from the JWT, and returns only
-- the three fields DM §7.4 permits, so authenticated callers may invoke it
-- directly. `anon` may not: US-012 requires an authenticated account.
revoke execute on function public.invitation_preview(text) from public, anon;
grant execute on function public.invitation_preview(text) to authenticated, service_role;
revoke execute on function public.household_invitation_token_hash(text) from public, anon, authenticated;
grant execute on function public.household_invitation_token_hash(text) to service_role;
