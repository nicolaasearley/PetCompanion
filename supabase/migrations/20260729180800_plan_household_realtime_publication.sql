-- Multi-device plan reconciliation foundation: publish the tables the iOS
-- client already reads for Daily Plan / occurrence dispositions so Supabase
-- Realtime can deliver household-scoped change events. RLS still gates which
-- rows each caregiver receives; the client filter is defense-in-depth.

-- FULL replica identity so UPDATE/DELETE filters on household_id see the
-- column (DEFAULT only carries the primary key).
alter table public.dispositions replica identity full;
alter table public.task_occurrences replica identity full;
alter table public.plans replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.dispositions;
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.task_occurrences;
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.plans;
exception
  when duplicate_object then null;
end $$;
