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
  | "record_weight"
  | "edit_weight"
  | "remove_weight"
  | "create_provider"
  | "edit_provider"
  | "remove_provider"
  | "create_medication_schedule"
  | "edit_medication_schedule"
  | "archive_medication_schedule"
  | "complete_medication_occurrence"
  | "record_vaccination"
  | "edit_vaccination"
  | "remove_vaccination"
  | "record_grooming"
  | "edit_grooming"
  | "remove_grooming"
  | "create_care_note"
  | "edit_care_note"
  | "remove_care_note"
  | "prepare_care_note_media"
  | "complete_care_note_media"
  | "fail_care_note_media"
  | "remove_care_note_media"
  | "start_training_goal"
  | "pause_training_goal"
  | "resume_training_goal"
  | "retire_training_goal"
  | "update_training_progress"
  | "log_training_session"
  | "create_milestone"
  | "edit_milestone"
  | "remove_milestone"
  | "prepare_milestone_media"
  | "complete_milestone_media"
  | "fail_milestone_media"
  | "remove_milestone_media"
  | "create_event"
  | "edit_event"
  | "cancel_event"
  | "archive_event"
  | "register_device_token"
  | "unregister_device_token";

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
// Care: weight + providers + medications (F10, DM §11.2–§11.4).
// Dose text is stored verbatim — never computed or normalized (docs/13).
// ---------------------------------------------------------------------------

/** Original unit preserved; conversions are display-time only (US-075). */
export type WeightUnit = "kg" | "lb";

export type ProviderKind = "veterinarian" | "groomer" | "trainer" | "other";

export type MedicationProvenance = "owner_entered" | "professional_instruction";

/** CA-08 / US-075. Value+unit stored exactly as entered. */
export interface RecordWeightPayload {
  pet_id: string;
  measurement_id?: string;
  /** Decimal string or number; server stores original precision. */
  value: string | number;
  unit: WeightUnit;
  /** Household-local date; defaults to today; may not be in the future. */
  effective_date?: string;
  note?: string;
}

export interface EditWeightPayload {
  measurement_id: string;
  expected_revision: number;
  value?: string | number;
  unit?: WeightUnit;
  effective_date?: string;
  note?: string | null;
}

export interface RemoveWeightPayload {
  measurement_id: string;
}

/** CA-09. Household-owned care contact. */
export interface CreateProviderPayload {
  household_id: string;
  provider_id?: string;
  name: string;
  kind: ProviderKind;
  phone?: string;
  address?: string;
  notes?: string;
}

export interface EditProviderPayload {
  provider_id: string;
  expected_revision: number;
  name?: string;
  kind?: ProviderKind;
  phone?: string | null;
  address?: string | null;
  notes?: string | null;
}

export interface RemoveProviderPayload {
  provider_id: string;
}

/**
 * Supported recurrence only (DM §8.6). Unsupported clinical patterns must be
 * rejected — never approximated. Dose/name fields are free text as entered.
 */
export interface CreateMedicationSchedulePayload {
  pet_id: string;
  medication_schedule_id?: string;
  /** As entered — never normalized. */
  medication_name: string;
  /** As entered — never computed, converted, or suggested. */
  dose_text?: string;
  instructions_text?: string;
  provenance?: MedicationProvenance;
  provider_id?: string;
  /** Must pass recurrence_rule_is_valid. */
  recurrence: Record<string, unknown>;
}

export interface EditMedicationSchedulePayload {
  medication_schedule_id: string;
  expected_revision: number;
  medication_name?: string;
  dose_text?: string | null;
  instructions_text?: string | null;
  provenance?: MedicationProvenance;
  provider_id?: string | null;
  recurrence?: Record<string, unknown>;
}

export interface ArchiveMedicationSchedulePayload {
  medication_schedule_id: string;
  expected_revision: number;
}

/**
 * Completing a medication occurrence. When another caregiver completed
 * recently, the server requires `acknowledged_recent_completion: true`
 * (docs/12 §22.3). Never suggests doubling or skipping.
 */
export interface CompleteMedicationOccurrencePayload {
  occurrence_id: string;
  note?: string;
  /** Required when a recent partner completion exists. */
  acknowledged_recent_completion?: boolean;
}

// ---------------------------------------------------------------------------
// Care: vaccinations — history only (F10, DM §11.1, US-070).
// next_due_date is an owner/vet-entered fact for display; never computed.
// ---------------------------------------------------------------------------

export type VaccinationProvenance = "owner_entered" | "professional_instruction";

/** US-070. Name, date given, optional next due as entered, provenance. */
export interface RecordVaccinationPayload {
  pet_id: string;
  vaccination_id?: string;
  /** As entered from documents or vet — never normalized. */
  vaccine_name: string;
  /** Household-local date given; defaults to today; may not be in the future. */
  effective_date?: string;
  /** Optional owner/vet-entered fact only. Never computed by PetCompanion. */
  next_due_date?: string;
  provenance?: VaccinationProvenance;
  provider_id?: string;
  note?: string;
}

export interface EditVaccinationPayload {
  vaccination_id: string;
  expected_revision: number;
  vaccine_name?: string;
  effective_date?: string;
  next_due_date?: string | null;
  provenance?: VaccinationProvenance;
  provider_id?: string | null;
  note?: string | null;
}

export interface RemoveVaccinationPayload {
  vaccination_id: string;
}

// ---------------------------------------------------------------------------
// Care: grooming — history only (F10, DM §11.1).
// next_due_date is an owner-entered fact for display; never computed.
// ---------------------------------------------------------------------------

export type GroomingActivityType =
  | "brushing"
  | "nails"
  | "bath"
  | "teeth"
  | "ears"
  | "other";

/** Owner-entered grooming history. Optional next due is display-only. */
export interface RecordGroomingPayload {
  pet_id: string;
  grooming_id?: string;
  activity_type: GroomingActivityType;
  /** Household-local date done; defaults to today; may not be in the future. */
  effective_date?: string;
  /** Optional owner-entered fact only. Never computed by PetCompanion. */
  next_due_date?: string;
  note?: string;
}

export interface EditGroomingPayload {
  grooming_id: string;
  expected_revision: number;
  activity_type?: GroomingActivityType;
  effective_date?: string;
  next_due_date?: string | null;
  note?: string | null;
}

export interface RemoveGroomingPayload {
  grooming_id: string;
}

// ---------------------------------------------------------------------------
// Care: notes — general observations + document refs (F10, DM §11.1, US-077).
// Attachments use household-media via prepare/complete/fail/remove (Scenario H).
// media_refs on create/edit are rejected; attach after the text save.
// ---------------------------------------------------------------------------

export type CareNoteKind = "general_note" | "document";
export type CareNoteProvenance = "owner_entered" | "professional_instruction";

/** US-077. Owner/professional observation text. Document kind requires title. */
export interface CreateCareNotePayload {
  pet_id: string;
  care_note_id?: string;
  /** general_note (default) or document (title required). */
  kind?: CareNoteKind;
  title?: string;
  body: string;
  /** Household-local date; defaults to today; may not be in the future. */
  effective_date?: string;
  provenance?: CareNoteProvenance;
  provider_id?: string;
  /** Rejected when non-empty — use prepare_care_note_media. */
  media_refs?: unknown[];
}

export interface EditCareNotePayload {
  care_note_id: string;
  expected_revision: number;
  title?: string | null;
  body?: string;
  effective_date?: string;
  provenance?: CareNoteProvenance;
  provider_id?: string | null;
  /** Rejected when non-empty — use prepare_care_note_media. */
  media_refs?: unknown[] | null;
}

export interface RemoveCareNotePayload {
  care_note_id: string;
}

/** Prepare a pending media row + Storage path after the care note text exists. */
export interface PrepareCareNoteMediaPayload {
  care_note_id: string;
  media_id?: string;
  /** Images or PDF paperwork; Life milestones stay image-only. */
  mime_type:
    | "image/jpeg"
    | "image/png"
    | "image/heic"
    | "image/webp"
    | "application/pdf";
  /** Declared size; must be 1..10_485_760. */
  byte_size: number;
  /** Client-extracted capture time when available (ISO-8601). */
  capture_time?: string;
}

export interface CompleteCareNoteMediaPayload {
  media_id: string;
  byte_size?: number;
}

export interface FailCareNoteMediaPayload {
  media_id: string;
}

export interface RemoveCareNoteMediaPayload {
  media_id: string;
}

// ---------------------------------------------------------------------------
// Life milestones (F12, DM §12.5) + household-private media (DM §12.6).
// ---------------------------------------------------------------------------

/** LF-03 / US-090. Text saves independently of photos. */
export interface CreateMilestonePayload {
  pet_id: string;
  milestone_id?: string;
  title: string;
  /** Household-local date; defaults to today; may not be in the future. */
  effective_date?: string;
  note?: string;
}

export interface EditMilestonePayload {
  milestone_id: string;
  expected_revision: number;
  title?: string;
  effective_date?: string;
  note?: string | null;
}

export interface RemoveMilestonePayload {
  milestone_id: string;
}

/** Prepare a pending media row + Storage path after the milestone text exists. */
export interface PrepareMilestoneMediaPayload {
  milestone_id: string;
  media_id?: string;
  mime_type: "image/jpeg" | "image/png" | "image/heic" | "image/webp";
  /** Declared size; must be 1..10_485_760. */
  byte_size: number;
  /** Client-extracted capture time when available (ISO-8601). */
  capture_time?: string;
}

export interface CompleteMilestoneMediaPayload {
  media_id: string;
  /** Optional final byte size after client resize/re-encode. */
  byte_size?: number;
}

export interface FailMilestoneMediaPayload {
  media_id: string;
}

export interface RemoveMilestoneMediaPayload {
  media_id: string;
}

// ---------------------------------------------------------------------------
// Events / appointments (F11, DM §11.5).
// ---------------------------------------------------------------------------

export type EventKind = "vet_appointment" | "class" | "grooming_visit" | "other";

export interface CreateEventPayload {
  household_id: string;
  event_id?: string;
  pet_id?: string | null;
  kind: EventKind;
  title: string;
  start_date: string;
  all_day?: boolean;
  start_time?: string;
  end_time?: string;
  location_text?: string;
  provider_id?: string | null;
  notes?: string;
  reminder_config?: Record<string, unknown> | null;
}

export interface EditEventPayload {
  event_id: string;
  expected_revision: number;
  pet_id?: string | null;
  kind?: EventKind;
  title?: string;
  start_date?: string;
  all_day?: boolean;
  start_time?: string | null;
  end_time?: string | null;
  location_text?: string | null;
  provider_id?: string | null;
  notes?: string | null;
  reminder_config?: Record<string, unknown> | null;
}

export interface CancelEventPayload {
  event_id: string;
  expected_revision: number;
}

export interface ArchiveEventPayload {
  event_id: string;
  expected_revision: number;
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

/** APNs device token registration (remote push foundation). */
export interface RegisterDeviceTokenPayload {
  token: string;
  environment: "sandbox" | "production";
  platform?: "ios";
  app_build?: string;
  device_name?: string;
  token_id?: string;
}

export interface UnregisterDeviceTokenPayload {
  token: string;
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
