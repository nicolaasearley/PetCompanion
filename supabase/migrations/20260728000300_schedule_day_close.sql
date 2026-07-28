-- Schedule the day-close job.
--
-- close_elapsed_plans has existed since the generation-lifecycle migration but
-- nothing invoked it automatically: it ran only as a side effect of a plan
-- request. A household that does not open the app for a few days therefore left
-- plans open and recommendations unexpired, which contradicts the missed-item
-- policy in docs/12 §16 (recommendations expire at day close; they must not
-- reappear as yesterday's overdue work).
--
-- The job is timezone-agnostic. close_elapsed_plans compares each plan's own
-- time_zone_snapshot against the instant it is given, so a single schedule
-- serves every household. It runs every fifteen minutes rather than hourly
-- because not every IANA offset falls on the hour — India is +05:30, Nepal
-- +05:45, Chatham +12:45 — and an hourly job would leave those households a
-- stale plan for up to three quarters of an hour after their local midnight.
-- The function is cheap and idempotent, so the extra runs cost effectively
-- nothing.

create extension if not exists pg_cron;

do $$
begin
  -- Make the migration re-runnable: pg_cron rejects a duplicate job name.
  if exists (select 1 from cron.job where jobname = 'close-elapsed-plans') then
    perform cron.unschedule('close-elapsed-plans');
  end if;

  perform cron.schedule(
    'close-elapsed-plans',
    '*/15 * * * *',
    $job$select public.close_elapsed_plans(now())$job$
  );
end;
$$;
