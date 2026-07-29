-- Events client write lockdown.
--
-- RLS alone is not enough for UPDATE/DELETE: with only a SELECT policy,
-- Postgres silently affects 0 rows (no error). Clients must not hold
-- INSERT/UPDATE/DELETE privileges — mutations go through write_path_*.

revoke insert, update, delete on public.events from anon, authenticated;
grant select on public.events to authenticated;
grant all on public.events to service_role;
