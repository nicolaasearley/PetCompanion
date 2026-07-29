-- Catalogue content for rule.event_prep_vet (docs/15 §5 / §9).
--
-- The recommendation rule was already seeded; the selected task definition was
-- missing. Engine also keeps a fallback row so generation works before this
-- migration lands. No write_path_generation_context change: events already
-- match EventInput (events foundation).

insert into public.content_versions (
  content_id, version, content_type, publication_status, review_status,
  source_category, author, authored_on, effective_from
)
values (
  'prep.gather_records_questions', 1, 'task_definition', 'published',
  'pending_professional_review', 'product_seed', 'PetCompanion product seed',
  '2026-07-26', '2026-07-26'
)
on conflict (content_id, version) do nothing;

insert into public.task_definitions (
  provenance, content_id, content_version, title, category,
  default_obligation_class, instructions_content_ref, default_effort,
  default_time_policy, metadata
)
select
  'system',
  'prep.gather_records_questions',
  1,
  'Gather records and questions',
  'preparation',
  'recommended',
  '{"content_id":"prep.gather_records_questions","version":1}'::jsonb,
  'short',
  'anytime',
  '{"event_prep_kind":"vet_appointment"}'::jsonb
where not exists (
  select 1 from public.task_definitions
  where content_id = 'prep.gather_records_questions' and content_version = 1
);
