-- Assert plan tables are published for multi-device Realtime reconciliation.
begin;

do $$
declare
  missing text[];
begin
  select coalesce(array_agg(t order by t), '{}')
  into missing
  from unnest(array['dispositions', 'task_occurrences', 'plans']) as t
  where not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = t
  );

  if array_length(missing, 1) is not null then
    raise exception '[FAIL] missing from supabase_realtime publication: %', missing;
  end if;

  raise notice '[PASS] dispositions, task_occurrences, plans are in supabase_realtime';
end $$;

do $$
declare
  bad text[];
begin
  select coalesce(array_agg(c.relname order by c.relname), '{}')
  into bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname in ('dispositions', 'task_occurrences', 'plans')
    and c.relreplident <> 'f'; -- FULL

  if array_length(bad, 1) is not null then
    raise exception '[FAIL] replica identity is not FULL for: %', bad;
  end if;

  raise notice '[PASS] dispositions, task_occurrences, plans use REPLICA IDENTITY FULL';
end $$;

rollback;
