-- Restore a plan item's section when its occurrence leaves the completed state.
--
-- maintain_occurrence_derivatives moved an item into the Completed section on
-- completion but fell through to `else pi.section` for every other state, so the
-- section was sticky: undoing a completion reverted display_state and left the
-- item collapsed under Completed instead of returning it to Today. Skipping it
-- afterwards produced a skipped item sitting in Completed.
--
-- The section is now recomputed from the occurrence on every state change, using
-- the same placement rules as the engine's obligationItem (docs/12 §6):
-- completed, else future, else overdue-required-pending, else today.

create or replace function public.maintain_occurrence_derivatives()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform public.refresh_occurrence_notification_candidates(new.id, null);

  if tg_op = 'UPDATE' then
    update public.plan_items pi
    set title = coalesce(new.title_override, td.title),
        time_window = case
          when new.time_policy = 'window' then new.window_ref
          when new.time_policy = 'anytime' then 'anytime'
          else null
        end,
        due_time = new.due_time,
        display_state = case new.state
          when 'pending' then 'planned'::public.plan_item_display_state
          when 'completed' then 'completed'::public.plan_item_display_state
          when 'skipped' then 'skipped'::public.plan_item_display_state
          when 'rescheduled' then 'rescheduled'::public.plan_item_display_state
          when 'cancelled' then 'cancelled'::public.plan_item_display_state
          when 'expired' then 'expired'::public.plan_item_display_state
        end,
        section = case
          when new.state = 'completed' then 'completed'::public.plan_section
          when new.local_due_date > p.local_date then 'coming_up'::public.plan_section
          when new.local_due_date < p.local_date
            and new.state = 'pending'
            and s.obligation_class = 'required' then 'needs_attention'::public.plan_section
          else 'today'::public.plan_section
        end,
        completion = case when new.state = 'completed' then (
          select jsonb_strip_nulls(jsonb_build_object(
            'completed_at', d.effective_at,
            'completed_by_user_id', d.actor_user_id,
            'completed_by_name', up.display_name
          ))
          from public.dispositions d
          left join public.user_profiles up on up.id = d.actor_user_id
          where d.occurrence_id = new.id
            and d.action = 'complete'
            and not d.superseded
          order by d.effective_at
          limit 1
        ) else null end,
        updated_at = now()
    from public.plans p, public.task_schedules s, public.task_definitions td
    where pi.occurrence_id = new.id
      and p.id = pi.plan_id
      and p.status = 'open'
      and s.id = new.schedule_id
      and td.id = s.task_definition_id;
  end if;
  return new;
end;
$function$;

-- Repair items already stranded by the previous behaviour. Limited to open
-- plans; closed plans are immutable by design and keep their recorded history.
update public.plan_items pi
set section = case
      when o.state = 'completed' then 'completed'::public.plan_section
      when o.local_due_date > p.local_date then 'coming_up'::public.plan_section
      when o.local_due_date < p.local_date
        and o.state = 'pending'
        and s.obligation_class = 'required' then 'needs_attention'::public.plan_section
      else 'today'::public.plan_section
    end,
    updated_at = now()
from public.task_occurrences o, public.task_schedules s, public.plans p
where pi.occurrence_id = o.id
  and s.id = o.schedule_id
  and p.id = pi.plan_id
  and p.status = 'open'
  and pi.section = 'completed'
  and o.state <> 'completed';
