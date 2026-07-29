-- Remote push foundation: device token registration + candidate consumer
-- groundwork (docs/06 §9, docs/10 device registrations, Slice D APNs path).
--
-- This migration does NOT require APNs .p8 keys in the repo. It:
--   1. stores per-user iOS device tokens (owner-only RLS; mutations via write-path);
--   2. records notification_dispatch_runs for processor audits;
--   3. provides verify_due_notification_candidates (cancels stale due rows);
--   4. provides claim_due_notification_candidates for a future APNs sender.
--
-- Candidates that remain valid stay `scheduled` until a configured sender marks
-- them sent/failed. Running verify without APNs is therefore safe and useful.

-- ---------------------------------------------------------------------------
-- Vocabularies
-- ---------------------------------------------------------------------------

create type public.device_push_platform as enum ('ios');
create type public.device_push_environment as enum ('sandbox', 'production');
create type public.notification_dispatch_mode as enum (
  'verify_only',
  'claim_for_send',
  'apns_send'
);
create type public.notification_dispatch_outcome as enum (
  'ok',
  'partial',
  'skipped_apns_not_configured',
  'failed'
);

-- ---------------------------------------------------------------------------
-- device_push_tokens (user-owned; DM §4 / §7)
-- ---------------------------------------------------------------------------

create table public.device_push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token text not null,
  platform public.device_push_platform not null default 'ios',
  environment public.device_push_environment not null,
  app_build text,
  device_name text,
  last_registered_at timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint device_push_tokens_token_shape check (
    token ~ '^[0-9a-fA-F]{32,200}$'
  ),
  constraint device_push_tokens_revoked_shape check (
    revoked_at is null or revoked_at >= created_at
  )
);

comment on table public.device_push_tokens is
  'APNs device tokens owned by a single auth user. Mutations go through write_path_* only.';

create unique index device_push_tokens_active_token_unique
  on public.device_push_tokens (token)
  where revoked_at is null;

create index device_push_tokens_user_active
  on public.device_push_tokens (user_id, last_registered_at desc)
  where revoked_at is null;

create trigger device_push_tokens_set_updated_at
before update on public.device_push_tokens
for each row execute function public.set_updated_at();

alter table public.device_push_tokens enable row level security;

create policy "device push tokens owner read"
  on public.device_push_tokens for select
  using (user_id = auth.uid());

-- No INSERT/UPDATE/DELETE policies for authenticated — write-path only.
grant select on public.device_push_tokens to authenticated;
grant all on public.device_push_tokens to service_role;

-- ---------------------------------------------------------------------------
-- notification_dispatch_runs (service audit of candidate consumer)
-- ---------------------------------------------------------------------------

create table public.notification_dispatch_runs (
  id uuid primary key default gen_random_uuid(),
  mode public.notification_dispatch_mode not null,
  outcome public.notification_dispatch_outcome not null,
  due_count integer not null default 0 check (due_count >= 0),
  verified_count integer not null default 0 check (verified_count >= 0),
  cancelled_count integer not null default 0 check (cancelled_count >= 0),
  eligible_count integer not null default 0 check (eligible_count >= 0),
  sent_count integer not null default 0 check (sent_count >= 0),
  failed_count integer not null default 0 check (failed_count >= 0),
  detail jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  finished_at timestamptz not null default now(),
  constraint notification_dispatch_runs_detail_object check (
    jsonb_typeof(detail) = 'object'
  )
);

comment on table public.notification_dispatch_runs is
  'Audit rows for process-notification-candidates / verify_due_notification_candidates.';

alter table public.notification_dispatch_runs enable row level security;
-- No authenticated policies — service_role / SECURITY DEFINER only.
grant all on public.notification_dispatch_runs to service_role;

-- ---------------------------------------------------------------------------
-- JSON helper
-- ---------------------------------------------------------------------------

create or replace function public.device_push_token_json(target_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', t.id,
    'token', t.token,
    'platform', t.platform,
    'environment', t.environment,
    'app_build', t.app_build,
    'device_name', t.device_name,
    'last_registered_at', t.last_registered_at,
    'revoked_at', t.revoked_at
  )
  from public.device_push_tokens t
  where t.id = target_id;
$$;

revoke execute on function public.device_push_token_json(uuid) from public, anon, authenticated;
grant execute on function public.device_push_token_json(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- write_path_register_device_token
-- ---------------------------------------------------------------------------

create or replace function public.write_path_register_device_token(
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
  token_value text;
  environment_value public.device_push_environment;
  platform_value public.device_push_platform;
  token_id uuid;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'register_device_token' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  token_value := lower(nullif(trim(payload_input->>'token'), ''));
  if token_value is null or token_value !~ '^[0-9a-f]{32,200}$' then
    raise exception 'token must be a hex APNs device token' using errcode = '22023';
  end if;

  begin
    environment_value := (payload_input->>'environment')::public.device_push_environment;
  exception when invalid_text_representation then
    raise exception 'environment must be sandbox or production' using errcode = '22023';
  end;
  if environment_value is null then
    raise exception 'environment is required' using errcode = '22023';
  end if;

  begin
    platform_value := coalesce(
      nullif(payload_input->>'platform', '')::public.device_push_platform,
      'ios'::public.device_push_platform
    );
  exception when invalid_text_representation then
    raise exception 'platform must be ios in MVP' using errcode = '22023';
  end;
  if platform_value is distinct from 'ios'::public.device_push_platform then
    raise exception 'platform must be ios in MVP' using errcode = '22023';
  end if;

  -- Re-activate a previously revoked row for the same token, or insert.
  select id into token_id
  from public.device_push_tokens
  where token = token_value
  order by created_at desc
  limit 1;

  if token_id is not null then
    update public.device_push_tokens
    set user_id = actor_id,
        platform = platform_value,
        environment = environment_value,
        app_build = nullif(trim(payload_input->>'app_build'), ''),
        device_name = nullif(trim(payload_input->>'device_name'), ''),
        last_registered_at = coalesce(recorded_at_input, now()),
        revoked_at = null,
        updated_at = now()
    where id = token_id;
  else
    token_id := coalesce(nullif(payload_input->>'token_id', '')::uuid, gen_random_uuid());
    insert into public.device_push_tokens (
      id, user_id, token, platform, environment, app_build, device_name,
      last_registered_at
    ) values (
      token_id, actor_id, token_value, platform_value, environment_value,
      nullif(trim(payload_input->>'app_build'), ''),
      nullif(trim(payload_input->>'device_name'), ''),
      coalesce(recorded_at_input, now())
    );
  end if;

  -- Optional household audit (token registration is user-owned; users may
  -- register before joining a household).
  insert into public.audit_events (
    household_id, actor_user_id, entity_ref, action, summary, occurred_at
  )
  select
    m.household_id, actor_id,
    jsonb_build_object('type', 'device_push_token', 'id', token_id),
    'notifications.device_token_registered',
    jsonb_build_object(
      'platform', platform_value,
      'environment', environment_value
    ),
    recorded_at_input
  from public.household_memberships m
  where m.user_id = actor_id and m.status = 'active'
  order by m.joined_at
  limit 1;

  response := jsonb_build_object('device_token', public.device_push_token_json(token_id));

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'register_device_token', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

-- ---------------------------------------------------------------------------
-- write_path_unregister_device_token
-- ---------------------------------------------------------------------------

create or replace function public.write_path_unregister_device_token(
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
  token_value text;
  token_row public.device_push_tokens%rowtype;
  response jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(actor_id::text || ':' || idempotency_key, 0));
  select * into existing from public.command_log
  where actor_user_id = actor_id and client_idempotency_key = idempotency_key;
  if found then
    if existing.payload_hash <> payload_hash_input or existing.command <> 'unregister_device_token' then
      raise exception 'idempotency key reused with different command or payload' using errcode = '23505';
    end if;
    return existing.response_body;
  end if;

  token_value := lower(nullif(trim(payload_input->>'token'), ''));
  if token_value is null then
    raise exception 'token is required' using errcode = '22023';
  end if;

  select * into token_row
  from public.device_push_tokens
  where user_id = actor_id
    and token = token_value
    and revoked_at is null
  order by last_registered_at desc
  limit 1;

  if not found then
    response := jsonb_build_object('revoked', false, 'reason', 'not_found');
  else
    update public.device_push_tokens
    set revoked_at = coalesce(recorded_at_input, now()),
        updated_at = now()
    where id = token_row.id;

    response := jsonb_build_object(
      'revoked', true,
      'device_token', public.device_push_token_json(token_row.id)
    );
  end if;

  insert into public.command_log (
    actor_user_id, client_idempotency_key, command, payload_hash, request_body,
    response_body, status, recorded_at, effective_at, completed_at
  ) values (
    actor_id, idempotency_key, 'unregister_device_token', payload_hash_input,
    request_body_input, response, 'succeeded', recorded_at_input,
    effective_at_input, now()
  );

  return response;
end;
$$;

revoke execute on function public.write_path_register_device_token(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke execute on function public.write_path_unregister_device_token(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
grant execute on function public.write_path_register_device_token(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.write_path_unregister_device_token(uuid, text, text, jsonb, timestamptz, timestamptz, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- verify_due_notification_candidates
-- Cancels due candidates that fail the pre-delivery checklist. Leaves valid
-- scheduled rows untouched so a later APNs-configured sender can deliver them.
-- ---------------------------------------------------------------------------

create or replace function public.verify_due_notification_candidates(
  at_instant timestamptz default now(),
  batch_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  due_count integer := 0;
  cancelled_count integer := 0;
  eligible_count integer := 0;
  candidate_row public.notification_candidates%rowtype;
  occurrence_row public.task_occurrences%rowtype;
  household_row public.households%rowtype;
  member_ok boolean;
  cancel_reason text;
  run_id uuid;
begin
  if batch_limit is null or batch_limit < 1 or batch_limit > 500 then
    batch_limit := 100;
  end if;

  for candidate_row in
    select *
    from public.notification_candidates
    where state = 'scheduled'
      and scheduled_for <= at_instant
    order by scheduled_for
    limit batch_limit
    for update skip locked
  loop
    due_count := due_count + 1;
    cancel_reason := null;

    select * into occurrence_row
    from public.task_occurrences where id = candidate_row.occurrence_id;
    if not found then
      cancel_reason := 'occurrence_missing';
    elsif occurrence_row.state <> 'pending' then
      cancel_reason := 'occurrence_' || occurrence_row.state::text;
    else
      select * into household_row
      from public.households
      where id = candidate_row.household_id and status = 'active';
      if not found then
        cancel_reason := 'household_inactive';
      else
        select exists(
          select 1
          from public.household_memberships m
          where m.household_id = candidate_row.household_id
            and m.user_id = candidate_row.recipient_user_id
            and m.status = 'active'
        ) into member_ok;
        if not member_ok then
          cancel_reason := 'recipient_not_active_member';
        end if;
      end if;
    end if;

    if cancel_reason is not null then
      update public.notification_candidates
      set state = 'cancelled',
          resolved_at = at_instant,
          resolution_reason = cancel_reason,
          updated_at = now()
      where id = candidate_row.id and state = 'scheduled';
      cancelled_count := cancelled_count + 1;
    else
      eligible_count := eligible_count + 1;
    end if;
  end loop;

  insert into public.notification_dispatch_runs (
    mode, outcome, due_count, verified_count, cancelled_count, eligible_count,
    detail, started_at, finished_at
  ) values (
    'verify_only',
    'ok',
    due_count,
    due_count,
    cancelled_count,
    eligible_count,
    jsonb_build_object('at_instant', at_instant),
    at_instant,
    now()
  )
  returning id into run_id;

  return jsonb_build_object(
    'run_id', run_id,
    'due_count', due_count,
    'cancelled_count', cancelled_count,
    'eligible_count', eligible_count
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- claim_due_notification_candidates
-- Returns eligible due candidates + active device tokens for a sender.
-- Does not mark candidates sent — the Edge Function does that after APNs ACK.
-- ---------------------------------------------------------------------------

create or replace function public.claim_due_notification_candidates(
  at_instant timestamptz default now(),
  batch_limit integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  verify_result jsonb;
  eligible jsonb := '[]'::jsonb;
begin
  verify_result := public.verify_due_notification_candidates(at_instant, batch_limit);

  select coalesce(jsonb_agg(row_to_json(q)::jsonb order by q.scheduled_for), '[]'::jsonb)
  into eligible
  from (
    select
      nc.id as candidate_id,
      nc.recipient_user_id,
      nc.household_id,
      nc.occurrence_id,
      nc.class,
      nc.source_ref,
      nc.scheduled_for,
      nc.dedupe_key,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', d.id,
          'token', d.token,
          'environment', d.environment,
          'platform', d.platform
        ) order by d.last_registered_at desc)
        from public.device_push_tokens d
        where d.user_id = nc.recipient_user_id
          and d.revoked_at is null
      ), '[]'::jsonb) as device_tokens
    from public.notification_candidates nc
    where nc.state = 'scheduled'
      and nc.scheduled_for <= at_instant
    order by nc.scheduled_for
    limit batch_limit
  ) q;

  return jsonb_build_object(
    'verify', verify_result,
    'candidates', eligible,
    'apns_required', true
  );
end;
$$;

revoke execute on function public.verify_due_notification_candidates(timestamptz, integer) from public, anon, authenticated;
revoke execute on function public.claim_due_notification_candidates(timestamptz, integer) from public, anon, authenticated;
grant execute on function public.verify_due_notification_candidates(timestamptz, integer) to service_role;
grant execute on function public.claim_due_notification_candidates(timestamptz, integer) to service_role;

-- Periodic stale-candidate cleanup (no APNs required). Idempotent and cheap.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'verify-due-notification-candidates') then
    perform cron.unschedule('verify-due-notification-candidates');
  end if;

  perform cron.schedule(
    'verify-due-notification-candidates',
    '*/5 * * * *',
    $job$select public.verify_due_notification_candidates(now(), 100)$job$
  );
end;
$$;
