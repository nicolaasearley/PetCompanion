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
  | "skip_item"
  | "create_invitation"
  | "revoke_invitation"
  | "accept_invitation"
  | "decline_invitation"
  | "record_socialization"
  | "edit_socialization_record"
  | "remove_socialization_record"
  | "set_socialization_exclusion"
  | "clear_socialization_exclusion"
  | "start_training_goal"
  | "pause_training_goal"
  | "resume_training_goal"
  | "retire_training_goal"
  | "update_training_progress"
  | "log_training_session";

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

/** ST-05. Owner-only; the share token is generated server-side. */
export interface CreateInvitationPayload {
  household_id: string;
  /** Client-supplied identity so a retry cannot create a second invitation. */
  invitation_id?: string;
  /** 1–336 hours; defaults to 168 (7 days). */
  expires_in_hours?: number;
  /** `caregiver` is the only role grantable in MVP (DM 10 §7.4). */
  role_granted?: "caregiver";
}

/**
 * The plaintext `token` appears ONLY here, in the live create response. It is
 * not stored in `command_log`, so an idempotent replay returns the same
 * invitation with `token` absent and `token_returned_once` set.
 */
export interface CreateInvitationResult {
  invitation: {
    id: string;
    household_id: string;
    household_name: string;
    created_by: string;
    role_granted: "caregiver";
    status: "pending";
    expires_at: string;
  };
  token_returned_once: true;
  token?: string;
}

/** ST-04/ST-05. Owner-only. */
export interface RevokeInvitationPayload {
  invitation_id: string;
}

/** ON-05. The token is the invitation's only credential. */
export interface AcceptInvitationPayload {
  token: string;
}

/** ON-05. Declining exposes nothing about the household (US-012). */
export interface DeclineInvitationPayload {
  token: string;
}

/**
 * F09 socialization passport.
 *
 * The response vocabulary is closed and OWNER-REPORTED (catalogue §8). It is
 * never a behavioural assessment: "hesitant" and "fearful" mean more distance
 * and a softer version next time, not more repetitions, and the product must
 * never render them as a finding about the puppy.
 */
export type SocializationResponse = "relaxed" | "curious" | "neutral" | "hesitant" | "fearful";

/** The eight F09 categories (core features §14, catalogue §8). */
export type SocializationCategory =
  | "People"
  | "Animals"
  | "Sounds"
  | "Surfaces"
  | "Environments"
  | "Handling"
  | "Transportation"
  | "Household objects";

/** DM 10 §12.4. Every reason is reversible. */
export type SocializationExclusionReason = "unavailable" | "unsuitable" | "paused";

/**
 * TR-08. Exactly one of `experience_content_id` (a catalogue experience) or
 * `custom_label` (F09 "Add a custom experience"). For a catalogue experience
 * the server takes the category from the catalogue and ignores any supplied
 * `category`; a custom experience must name one itself.
 */
export interface RecordSocializationPayload {
  pet_id: string;
  /** Client-supplied identity so a retry cannot create a second record. */
  record_id?: string;
  experience_content_id?: string;
  custom_label?: string;
  category?: SocializationCategory;
  /** Household-local date; defaults to today and may not be in the future. */
  effective_date?: string;
  context?: string;
  response: SocializationResponse;
  note?: string;
  media_refs?: unknown[];
}

/**
 * Corrects the observation, not its identity: an edit cannot re-point a record
 * at a different experience or category, because that rewrites history rather
 * than fixing it. Remove and re-record instead.
 */
export interface EditSocializationRecordPayload {
  record_id: string;
  /** Optimistic concurrency (DM §13); a stale write is rejected, not merged. */
  expected_revision: number;
  effective_date?: string;
  context?: string | null;
  response?: SocializationResponse;
  note?: string | null;
  media_refs?: unknown[] | null;
}

/** A recoverable tombstone, never a hard delete (DM §13). */
export interface RemoveSocializationRecordPayload {
  record_id: string;
}

/**
 * US-068. Exactly one of `category` or `experience_content_id`. An active
 * exclusion is a HARD eligibility constraint: the engine drops the whole
 * category (or that one experience) rather than substituting a near-duplicate.
 * Re-marking an already-excluded scope updates the live decision.
 */
export interface SetSocializationExclusionPayload {
  pet_id: string;
  exclusion_id?: string;
  category?: SocializationCategory;
  experience_content_id?: string;
  reason: SocializationExclusionReason;
  note?: string;
}

/** US-068 "The choice can be reversed" -- clearing keeps the row and its author. */
export interface ClearSocializationExclusionPayload {
  exclusion_id: string;
}
// ---------------------------------------------------------------------------
// Training goals and sessions (F08, epic E06)
// ---------------------------------------------------------------------------

/**
 * The seven owner-reported states of F08, minus `paused`: pausing is a goal
 * status change (`pause_training_goal`), not a judgement about learning, so
 * the two can never disagree and pausing never erases reported progress.
 */
export type TrainingProgressState =
  | "not_started"
  | "introduced"
  | "practicing"
  | "reliable_in_familiar_setting"
  | "generalizing"
  | "maintained";

export type TrainingGoalStatus = "active" | "paused" | "retired";

/**
 * Every command after `start_training_goal` addresses an existing goal, either
 * by id or by the (pet, skill) pair the lesson screen already has in hand.
 */
export type TrainingGoalRef =
  | { goal_id: string; pet_id?: string; skill_ref?: string }
  | { goal_id?: string; pet_id: string; skill_ref: string };

/** TR-03. Idempotent: starting the same skill twice returns the same goal. */
export interface StartTrainingGoalPayload {
  pet_id: string;
  /** A published catalogue skill content id (`skill.*`). */
  skill_ref: string;
}

/** Optimistic concurrency is optional; supplying it turns a lost update into
 * an explicit conflict rather than a silent overwrite. */
export type PauseTrainingGoalPayload = TrainingGoalRef & { expected_revision?: number };
export type ResumeTrainingGoalPayload = TrainingGoalRef & { expected_revision?: number };
export type RetireTrainingGoalPayload = TrainingGoalRef & { expected_revision?: number };

/** TR-05. Owner-reported, never inferred (US-065, engine §19.2). */
export type UpdateTrainingProgressPayload = TrainingGoalRef & {
  progress_state: TrainingProgressState;
  expected_revision?: number;
};

/** TR-04. `progress_state_after` is a separate, deliberate control: without it
 * a session records practice and nothing else (US-063). */
export type LogTrainingSessionPayload = TrainingGoalRef & {
  /** Defaults to the household's local today; back-datable up to 30 days. */
  effective_date?: string;
  effective_time?: string;
  duration_minutes?: number;
  outcome_note?: string;
  progress_state_after?: TrainingProgressState;
  media_refs?: unknown[];
};

export interface TrainingGoalResult {
  goal: {
    id: string;
    household_id: string;
    pet_id: string;
    skill_ref: string;
    status: TrainingGoalStatus;
    progress_state: TrainingProgressState;
    started_at: string;
    started_by?: string;
    paused_at?: string;
    resumed_at?: string;
    retired_at?: string;
    progress_state_updated_at?: string;
    progress_state_updated_by?: string;
    revision: number;
    last_session_on?: string;
    session_count: number;
  };
}

export type LogTrainingSessionResult = TrainingGoalResult & {
  session: {
    id: string;
    goal_id: string;
    pet_id: string;
    skill_ref: string;
    /** The catalogue version the caregiver actually followed (DM §12.3). */
    skill_version: number;
    effective_date: string;
    effective_time?: string;
    duration_minutes?: number;
    outcome_note?: string;
    progress_state_after?: TrainingProgressState;
    actor_user_id: string;
    recorded_at: string;
  };
};

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
