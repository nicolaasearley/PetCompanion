export type WritePathCommand =
  | "create_household"
  | "create_pet"
  | "set_routine_preferences"
  | "set_default_capacity"
  | "create_task"
  | "create_recurring_task"
  | "edit_occurrence"
  | "cancel_occurrence"
  | "snooze_occurrence"
  | "reschedule_occurrence"
  | "undo_skip"
  | "edit_schedule_future"
  | "archive_schedule"
  | "accept_recommendation"
  | "complete_occurrence"
  | "undo_completion"
  | "skip_item";

export interface CommandEnvelope<TPayload = unknown> {
  command: WritePathCommand;
  payload: TPayload;
  client_idempotency_key: string;
  recorded_at: string;
  effective_at?: string;
}

export interface CreateHouseholdPayload {
  id?: string;
  name: string;
  time_zone: string;
  default_capacity_mode?: "normal" | "busy" | "essentials_only" | "custom";
}

export interface CreatePetPayload {
  id?: string;
  household_id: string;
  name: string;
  species?: "dog";
  breed_text?: string;
  sex?: "female" | "male" | "unknown";
  birth_date_kind: "exact" | "estimated" | "unknown";
  birth_date?: string;
  estimated_age_weeks?: number;
  estimated_as_of_date?: string;
  homecoming_date?: string;
  stage_override?: string;
  food_notes?: string;
  allergy_notes?: string;
  microchip_ref?: string;
  notes?: string;
}

export interface SetRoutinePreferencesPayload {
  household_id: string;
  routine_windows: Record<string, unknown>;
  meal_template_ref?: string | null;
}

export interface SetDefaultCapacityPayload {
  household_id: string;
  default_capacity_mode: "normal" | "busy" | "essentials_only" | "custom";
}

export type TaskAssignment = "unassigned" | "anyone" | `member:${string}`;

export interface CreateTaskPayload {
  pet_id: string;
  title: string;
  local_due_date: string;
  time_policy: "anytime" | "window" | "exact_time";
  window_ref?: "morning" | "midday" | "afternoon" | "evening" | "sleep";
  exact_time?: string;
  assignment: TaskAssignment;
  task_definition_id?: string;
  schedule_id?: string;
  occurrence_id?: string;
}

export type RecurrenceType =
  | "once"
  | "daily"
  | "weekdays"
  | "every_n_days"
  | "weekly"
  | "monthly_safe"
  | "interval_after_completion";

export interface RecurrenceRulePayload {
  type: RecurrenceType;
  anchor_date: string;
  interval?: number;
  weekdays?: Array<number | string>;
  day_of_month?: number;
  count?: number;
  until?: string;
  time_policy: "anytime" | "window" | "exact_time";
  window_ref?: "morning" | "midday" | "afternoon" | "evening" | "sleep";
  exact_time?: string;
}

export interface CreateRecurringTaskPayload {
  pet_id: string;
  title: string;
  recurrence: RecurrenceRulePayload;
  assignment: TaskAssignment;
  category?: string;
  obligation_class?: "required" | "scheduled";
  reminder_config?: Record<string, unknown>;
  task_definition_id?: string;
  schedule_id?: string;
}

export interface EditOccurrencePayload {
  occurrence_id: string;
  expected_revision: number;
  title?: string;
  time_policy?: "anytime" | "window" | "exact_time";
  window_ref?: "morning" | "midday" | "afternoon" | "evening" | "sleep";
  exact_time?: string;
  assignment?: TaskAssignment;
  note?: string;
}

export interface CancelOccurrencePayload {
  occurrence_id: string;
  expected_revision: number;
  confirm_required?: boolean;
  note?: string;
}

export interface SnoozeOccurrencePayload {
  occurrence_id: string;
  snooze_until: string;
  note?: string;
}

export interface RescheduleOccurrencePayload {
  occurrence_id: string;
  expected_revision: number;
  local_due_date: string;
  time_policy?: "anytime" | "window" | "exact_time";
  window_ref?: "morning" | "midday" | "afternoon" | "evening" | "sleep";
  exact_time?: string;
  note?: string;
}

export interface UndoSkipPayload {
  occurrence_id: string;
  note?: string;
}

export interface EditScheduleFuturePayload {
  schedule_id: string;
  expected_revision: number;
  split_date: string;
  recurrence: RecurrenceRulePayload;
  title?: string;
  assignment?: TaskAssignment;
  reminder_config?: Record<string, unknown> | null;
  successor_schedule_id?: string;
  successor_task_definition_id?: string;
  note?: string;
}

export interface ArchiveSchedulePayload {
  schedule_id: string;
  expected_revision: number;
  confirm_required?: boolean;
  note?: string;
}

export interface AcceptRecommendationPayload {
  plan_item_id: string;
  complete?: boolean;
  pinned?: boolean;
  note?: string;
}

export interface CompleteOccurrencePayload {
  occurrence_id: string;
  note?: string;
}

export interface UndoCompletionPayload {
  occurrence_id: string;
  note?: string;
}

export type SkipReason =
  | "not_relevant_today"
  | "already_did_this"
  | "too_busy"
  | "pet_not_feeling_well"
  | "do_not_suggest_for_now";

export interface SkipItemPayload {
  occurrence_id: string;
  skip_reason?: SkipReason;
  confirm_required?: boolean;
  note?: string;
}

export interface CommandSuccess<T = unknown> {
  ok: true;
  command: WritePathCommand;
  idempotent_replay: boolean;
  result: T;
}

export interface CommandFailure {
  ok: false;
  command?: WritePathCommand;
  code: string;
  message: string;
  idempotent_replay?: boolean;
}
