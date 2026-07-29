import type {
  AcceptInvitationPayload,
  AcceptRecommendationPayload,
  ArchiveMedicationSchedulePayload,
  ArchiveSchedulePayload,
  CancelOccurrencePayload,
  ClearSocializationExclusionPayload,
  CommandEnvelope,
  CommandFailure,
  CommandSuccess,
  CompleteMedicationOccurrencePayload,
  CompleteOccurrencePayload,
  CreateHouseholdPayload,
  CreateInvitationPayload,
  CreateMedicationSchedulePayload,
  CreateMilestonePayload,
  PrepareMilestoneMediaPayload,
  CompleteMilestoneMediaPayload,
  FailMilestoneMediaPayload,
  RemoveMilestoneMediaPayload,
  CreateEventPayload,
  CreatePetPayload,
  CreateProviderPayload,
  CreateRecurringTaskPayload,
  CreateTaskPayload,
  DeclineInvitationPayload,
  EditEventPayload,
  CancelEventPayload,
  ArchiveEventPayload,
  EditMedicationSchedulePayload,
  EditMilestonePayload,
  EditOccurrencePayload,
  EditProviderPayload,
  EditScheduleFuturePayload,
  EditSocializationRecordPayload,
  CreateCareNotePayload,
  EditCareNotePayload,
  PrepareCareNoteMediaPayload,
  CompleteCareNoteMediaPayload,
  FailCareNoteMediaPayload,
  RemoveCareNoteMediaPayload,
  EditGroomingPayload,
  EditVaccinationPayload,
  EditWeightPayload,
  RecordGroomingPayload,
  RecordSocializationPayload,
  RecordVaccinationPayload,
  RecordWeightPayload,
  LogTrainingSessionPayload,
  RecurrenceRulePayload,
  RemoveCareNotePayload,
  RemoveMilestonePayload,
  RemoveProviderPayload,
  RemoveSocializationRecordPayload,
  RemoveGroomingPayload,
  RemoveVaccinationPayload,
  RemoveWeightPayload,
  RegisterDeviceTokenPayload,
  RescheduleOccurrencePayload,
  RevokeInvitationPayload,
  SetDefaultCapacityPayload,
  SetRoutinePreferencesPayload,
  SetSocializationExclusionPayload,
  SkipItemPayload,
  StartTrainingGoalPayload,
  TrainingGoalRef,
  UnregisterDeviceTokenPayload,
  UpdateTrainingProgressPayload,
  WritePathCommand,
  SnoozeOccurrencePayload,
  UndoSkipPayload,
  UndoCompletionPayload,
} from "./envelope.ts";

declare const Deno: {
  env: {
    get(name: string): string | undefined;
  };
  serve(handler: (request: Request) => Response | Promise<Response>): void;
};

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

interface AuthUser {
  id: string;
}

const implementedCommands: ReadonlySet<WritePathCommand> = new Set([
  "create_household",
  "create_pet",
  "set_routine_preferences",
  "set_default_capacity",
  "create_task",
  "create_recurring_task",
  "edit_occurrence",
  "cancel_occurrence",
  "snooze_occurrence",
  "reschedule_occurrence",
  "undo_skip",
  "edit_schedule_future",
  "archive_schedule",
  "accept_recommendation",
  "complete_occurrence",
  "undo_completion",
  "skip_item",
  "create_invitation",
  "revoke_invitation",
  "accept_invitation",
  "decline_invitation",
  "record_socialization",
  "edit_socialization_record",
  "remove_socialization_record",
  "set_socialization_exclusion",
  "clear_socialization_exclusion",
  "record_weight",
  "edit_weight",
  "remove_weight",
  "create_provider",
  "edit_provider",
  "remove_provider",
  "create_medication_schedule",
  "edit_medication_schedule",
  "archive_medication_schedule",
  "complete_medication_occurrence",
  "record_vaccination",
  "edit_vaccination",
  "remove_vaccination",
  "record_grooming",
  "edit_grooming",
  "remove_grooming",
  "create_care_note",
  "edit_care_note",
  "remove_care_note",
  "prepare_care_note_media",
  "complete_care_note_media",
  "fail_care_note_media",
  "remove_care_note_media",
  "start_training_goal",
  "pause_training_goal",
  "resume_training_goal",
  "retire_training_goal",
  "update_training_progress",
  "log_training_session",
  "create_milestone",
  "edit_milestone",
  "remove_milestone",
  "prepare_milestone_media",
  "complete_milestone_media",
  "fail_milestone_media",
  "remove_milestone_media",
  "create_event",
  "edit_event",
  "cancel_event",
  "archive_event",
  "register_device_token",
  "unregister_device_token",
]);

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return jsonResponse({ ok: false, code: "METHOD_NOT_ALLOWED", message: "Use POST." }, 405);
  }

  let envelope: CommandEnvelope;
  try {
    envelope = await request.json();
    validateEnvelope(envelope);
  } catch (error) {
    return jsonResponse(failure("BAD_REQUEST", messageOf(error)), 400);
  }

  let user: AuthUser;
  try {
    user = await authenticate(request);
  } catch (error) {
    return jsonResponse(failure("UNAUTHORIZED", messageOf(error), envelope.command), 401);
  }

  const payloadHash = await sha256Hex(stableStringify(envelope.payload));
  const replay = await findReplay(user.id, envelope.client_idempotency_key);
  if (replay) {
    if (replay.command !== envelope.command || replay.payload_hash !== payloadHash) {
      return jsonResponse(failure("IDEMPOTENCY_CONFLICT", "Idempotency key was reused with a different command or payload.", envelope.command), 409);
    }

    const body = replay.status === "succeeded"
      ? success(envelope.command, replay.response_body, true)
      : failure(replay.error_code ?? "COMMAND_FAILED", "Replayed command failed with the same stored result.", envelope.command, true);
    return jsonResponse(body, replay.status === "succeeded" ? 200 : statusForError(replay.error_code));
  }

  if (!implementedCommands.has(envelope.command)) {
    return jsonResponse(failure("UNKNOWN_COMMAND", "Unsupported command.", envelope.command), 400);
  }

  try {
    if (envelope.command === "create_household") {
      assertCreateHouseholdPayload(envelope.payload);
      const result = await rpc("write_path_create_household", {
        actor_id: user.id,
        idempotency_key: envelope.client_idempotency_key,
        payload_hash_input: payloadHash,
        request_body_input: envelope as unknown as Json,
        recorded_at_input: envelope.recorded_at,
        effective_at_input: envelope.effective_at ?? null,
        payload_input: envelope.payload as unknown as Json,
      });
      return jsonResponse(success(envelope.command, result, false), 200);
    }

    if (envelope.command === "create_pet") {
      assertCreatePetPayload(envelope.payload);
      await assertActiveMembership(user.id, envelope.payload.household_id);
    } else if (envelope.command === "set_routine_preferences") {
      assertSetRoutinePreferencesPayload(envelope.payload);
      await assertActiveMembership(user.id, envelope.payload.household_id);
    } else if (envelope.command === "set_default_capacity") {
      assertSetDefaultCapacityPayload(envelope.payload);
      await assertActiveMembership(user.id, envelope.payload.household_id);
    } else if (envelope.command === "create_task") {
      assertCreateTaskPayload(envelope.payload);
    } else if (envelope.command === "create_recurring_task") {
      assertCreateRecurringTaskPayload(envelope.payload);
    } else if (envelope.command === "edit_occurrence") {
      assertEditOccurrencePayload(envelope.payload);
    } else if (envelope.command === "cancel_occurrence") {
      assertCancelOccurrencePayload(envelope.payload);
    } else if (envelope.command === "snooze_occurrence") {
      assertSnoozeOccurrencePayload(envelope.payload);
    } else if (envelope.command === "reschedule_occurrence") {
      assertRescheduleOccurrencePayload(envelope.payload);
    } else if (envelope.command === "undo_skip") {
      assertUndoSkipPayload(envelope.payload);
    } else if (envelope.command === "edit_schedule_future") {
      assertEditScheduleFuturePayload(envelope.payload);
    } else if (envelope.command === "archive_schedule") {
      assertArchiveSchedulePayload(envelope.payload);
    } else if (envelope.command === "accept_recommendation") {
      assertAcceptRecommendationPayload(envelope.payload);
    } else if (envelope.command === "complete_occurrence") {
      assertCompleteOccurrencePayload(envelope.payload);
    } else if (envelope.command === "undo_completion") {
      assertUndoCompletionPayload(envelope.payload);
    } else if (envelope.command === "create_invitation") {
      assertCreateInvitationPayload(envelope.payload);
      await assertActiveMembership(user.id, envelope.payload.household_id);
    } else if (envelope.command === "revoke_invitation") {
      assertRevokeInvitationPayload(envelope.payload);
    } else if (envelope.command === "accept_invitation") {
      assertAcceptInvitationPayload(envelope.payload);
    } else if (envelope.command === "decline_invitation") {
      assertDeclineInvitationPayload(envelope.payload);
    } else if (envelope.command === "record_socialization") {
      assertRecordSocializationPayload(envelope.payload);
    } else if (envelope.command === "edit_socialization_record") {
      assertEditSocializationRecordPayload(envelope.payload);
    } else if (envelope.command === "remove_socialization_record") {
      assertRemoveSocializationRecordPayload(envelope.payload);
    } else if (envelope.command === "set_socialization_exclusion") {
      assertSetSocializationExclusionPayload(envelope.payload);
    } else if (envelope.command === "clear_socialization_exclusion") {
      assertClearSocializationExclusionPayload(envelope.payload);
    } else if (envelope.command === "record_weight") {
      assertRecordWeightPayload(envelope.payload);
    } else if (envelope.command === "edit_weight") {
      assertEditWeightPayload(envelope.payload);
    } else if (envelope.command === "remove_weight") {
      assertRemoveWeightPayload(envelope.payload);
    } else if (envelope.command === "create_provider") {
      assertCreateProviderPayload(envelope.payload);
      await assertActiveMembership(user.id, envelope.payload.household_id);
    } else if (envelope.command === "edit_provider") {
      assertEditProviderPayload(envelope.payload);
    } else if (envelope.command === "remove_provider") {
      assertRemoveProviderPayload(envelope.payload);
    } else if (envelope.command === "create_medication_schedule") {
      assertCreateMedicationSchedulePayload(envelope.payload);
    } else if (envelope.command === "edit_medication_schedule") {
      assertEditMedicationSchedulePayload(envelope.payload);
    } else if (envelope.command === "archive_medication_schedule") {
      assertArchiveMedicationSchedulePayload(envelope.payload);
    } else if (envelope.command === "complete_medication_occurrence") {
      assertCompleteMedicationOccurrencePayload(envelope.payload);
    } else if (envelope.command === "record_vaccination") {
      assertRecordVaccinationPayload(envelope.payload);
    } else if (envelope.command === "edit_vaccination") {
      assertEditVaccinationPayload(envelope.payload);
    } else if (envelope.command === "remove_vaccination") {
      assertRemoveVaccinationPayload(envelope.payload);
    } else if (envelope.command === "record_grooming") {
      assertRecordGroomingPayload(envelope.payload);
    } else if (envelope.command === "edit_grooming") {
      assertEditGroomingPayload(envelope.payload);
    } else if (envelope.command === "remove_grooming") {
      assertRemoveGroomingPayload(envelope.payload);
    } else if (envelope.command === "create_care_note") {
      assertCreateCareNotePayload(envelope.payload);
    } else if (envelope.command === "edit_care_note") {
      assertEditCareNotePayload(envelope.payload);
    } else if (envelope.command === "remove_care_note") {
      assertRemoveCareNotePayload(envelope.payload);
    } else if (envelope.command === "prepare_care_note_media") {
      assertPrepareCareNoteMediaPayload(envelope.payload);
    } else if (envelope.command === "complete_care_note_media") {
      assertCompleteCareNoteMediaPayload(envelope.payload);
    } else if (envelope.command === "fail_care_note_media") {
      assertFailCareNoteMediaPayload(envelope.payload);
    } else if (envelope.command === "remove_care_note_media") {
      assertRemoveCareNoteMediaPayload(envelope.payload);
    } else if (envelope.command === "start_training_goal") {
      assertStartTrainingGoalPayload(envelope.payload);
    } else if (
      envelope.command === "pause_training_goal"
      || envelope.command === "resume_training_goal"
      || envelope.command === "retire_training_goal"
    ) {
      assertTrainingGoalRefPayload(envelope.payload);
    } else if (envelope.command === "update_training_progress") {
      assertUpdateTrainingProgressPayload(envelope.payload);
    } else if (envelope.command === "log_training_session") {
      assertLogTrainingSessionPayload(envelope.payload);
    } else if (envelope.command === "create_milestone") {
      assertCreateMilestonePayload(envelope.payload);
    } else if (envelope.command === "edit_milestone") {
      assertEditMilestonePayload(envelope.payload);
    } else if (envelope.command === "remove_milestone") {
      assertRemoveMilestonePayload(envelope.payload);
    } else if (envelope.command === "prepare_milestone_media") {
      assertPrepareMilestoneMediaPayload(envelope.payload);
    } else if (envelope.command === "complete_milestone_media") {
      assertCompleteMilestoneMediaPayload(envelope.payload);
    } else if (envelope.command === "fail_milestone_media") {
      assertFailMilestoneMediaPayload(envelope.payload);
    } else if (envelope.command === "remove_milestone_media") {
      assertRemoveMilestoneMediaPayload(envelope.payload);
    } else if (envelope.command === "create_event") {
      assertCreateEventPayload(envelope.payload);
      await assertActiveMembership(user.id, envelope.payload.household_id);
    } else if (envelope.command === "edit_event") {
      assertEditEventPayload(envelope.payload);
    } else if (envelope.command === "cancel_event") {
      assertCancelEventPayload(envelope.payload);
    } else if (envelope.command === "archive_event") {
      assertArchiveEventPayload(envelope.payload);
    } else if (envelope.command === "register_device_token") {
      assertRegisterDeviceTokenPayload(envelope.payload);
    } else if (envelope.command === "unregister_device_token") {
      assertUnregisterDeviceTokenPayload(envelope.payload);
    } else {
      assertSkipItemPayload(envelope.payload);
    }

    const result = await rpc(`write_path_${envelope.command}`, {
      actor_id: user.id,
      idempotency_key: envelope.client_idempotency_key,
      payload_hash_input: payloadHash,
      request_body_input: envelopeForStorage(envelope) as unknown as Json,
      recorded_at_input: envelope.recorded_at,
      effective_at_input: envelope.effective_at ?? null,
      payload_input: envelope.payload as unknown as Json,
    });
    return jsonResponse(success(envelope.command, result, false), 200);
  } catch (error) {
    const code = codeOf(error);
    const status = statusForError(code);
    // Only deterministic failures are cached against the idempotency key. A
    // retry of a transient or unclassified failure must re-attempt the command
    // rather than replay a stored 5xx, which would strand the client's queue
    // behind an operation that can never succeed.
    if (status < 500) {
      await safeRecordFailure(user.id, envelope, payloadHash, code);
    } else {
      // Not persisted, so keep it diagnosable in the function logs. Routing
      // identifiers only — never the payload, which can carry private notes.
      console.error(
        JSON.stringify({
          event: "write_path_transient_failure",
          command: envelope.command,
          code,
          actor_user_id: user.id,
        }),
      );
    }
    return jsonResponse(failure(code, messageOf(error), envelope.command), status);
  }
});

function validateEnvelope(value: unknown): asserts value is CommandEnvelope {
  if (!isRecord(value)) throw new Error("Body must be a JSON object.");
  if (typeof value.command !== "string") throw new Error("command is required.");
  if (typeof value.client_idempotency_key !== "string" || value.client_idempotency_key.trim() === "") {
    throw new Error("client_idempotency_key is required.");
  }
  if (typeof value.recorded_at !== "string" || Number.isNaN(Date.parse(value.recorded_at))) {
    throw new Error("recorded_at must be an ISO timestamp.");
  }
  if ("effective_at" in value && value.effective_at !== undefined && (typeof value.effective_at !== "string" || Number.isNaN(Date.parse(value.effective_at)))) {
    throw new Error("effective_at must be an ISO timestamp when provided.");
  }
  if (!("payload" in value) || !isJson(value.payload)) throw new Error("payload must be JSON.");
}

function assertCreateHouseholdPayload(value: unknown): asserts value is CreateHouseholdPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  if (typeof value.name !== "string" || value.name.trim() === "") throw new Error("payload.name is required.");
  if (typeof value.time_zone !== "string" || value.time_zone.trim() === "") throw new Error("payload.time_zone is required.");
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value.time_zone }).format();
  } catch {
    throw new Error("payload.time_zone must be a valid IANA time zone.");
  }
  if ("default_capacity_mode" in value && value.default_capacity_mode !== undefined && !["normal", "busy", "essentials_only", "custom"].includes(String(value.default_capacity_mode))) {
    throw new Error("payload.default_capacity_mode is invalid.");
  }
}

function assertCreatePetPayload(value: unknown): asserts value is CreatePetPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  if (typeof value.household_id !== "string" || value.household_id.trim() === "") throw new Error("payload.household_id is required.");
  if (typeof value.name !== "string" || value.name.trim() === "") throw new Error("payload.name is required.");
  if (value.species !== undefined && value.species !== "dog") throw new Error("payload.species must be dog in MVP.");
  if (!["exact", "estimated", "unknown"].includes(String(value.birth_date_kind))) {
    throw new Error("payload.birth_date_kind must be exact, estimated, or unknown.");
  }

  if (value.birth_date_kind === "exact") {
    if (typeof value.birth_date !== "string") throw new Error("payload.birth_date is required for exact birth date.");
    if (Number.isNaN(Date.parse(`${value.birth_date}T00:00:00Z`))) throw new Error("payload.birth_date must be YYYY-MM-DD.");
    if (value.estimated_age_weeks !== undefined || value.estimated_as_of_date !== undefined) {
      throw new Error("estimated birth fields are not allowed for exact birth date.");
    }
  }

  if (value.birth_date_kind === "estimated") {
    if (typeof value.estimated_age_weeks !== "number" || !Number.isInteger(value.estimated_age_weeks) || value.estimated_age_weeks < 0) {
      throw new Error("payload.estimated_age_weeks must be a non-negative integer.");
    }
    if (typeof value.estimated_as_of_date !== "string") throw new Error("payload.estimated_as_of_date is required for estimated birth date.");
    if (isFutureDate(value.estimated_as_of_date)) throw new Error("Future estimated_as_of_date is rejected in MVP.");
    if (value.birth_date !== undefined) throw new Error("payload.birth_date is not allowed for estimated birth date.");
  }

  if (value.birth_date_kind === "unknown") {
    if (value.birth_date !== undefined || value.estimated_age_weeks !== undefined || value.estimated_as_of_date !== undefined) {
      throw new Error("birth date fields are not allowed when payload.birth_date_kind is unknown.");
    }
  }

  if (typeof value.birth_date === "string" && isFutureDate(value.birth_date)) {
    throw new Error("Future birth_date is rejected in MVP.");
  }
  if (typeof value.birth_date === "string" && typeof value.homecoming_date === "string" && value.homecoming_date < value.birth_date) {
    throw new Error("homecoming_date must be on or after birth_date.");
  }
}

function assertSetRoutinePreferencesPayload(value: unknown): asserts value is SetRoutinePreferencesPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.household_id, "payload.household_id");
  if (!isRecord(value.routine_windows)) throw new Error("payload.routine_windows must be an object.");
  if (value.meal_template_ref !== undefined && value.meal_template_ref !== null && typeof value.meal_template_ref !== "string") {
    throw new Error("payload.meal_template_ref must be a string or null.");
  }
}

function assertSetDefaultCapacityPayload(value: unknown): asserts value is SetDefaultCapacityPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.household_id, "payload.household_id");
  if (!["normal", "busy", "essentials_only", "custom"].includes(String(value.default_capacity_mode))) {
    throw new Error("payload.default_capacity_mode is invalid.");
  }
}

function assertCreateTaskPayload(value: unknown): asserts value is CreateTaskPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.pet_id, "payload.pet_id");
  assertNonEmptyString(value.title, "payload.title");
  assertLocalDate(value.local_due_date, "payload.local_due_date");

  if (!["anytime", "window", "exact_time"].includes(String(value.time_policy))) {
    throw new Error("payload.time_policy must be anytime, window, or exact_time.");
  }
  if (typeof value.assignment !== "string" || !/^(unassigned|anyone|member:[0-9a-fA-F-]{36})$/.test(value.assignment)) {
    throw new Error("payload.assignment must be unassigned, anyone, or member:<user_uuid>.");
  }

  if (value.time_policy === "exact_time") {
    if (typeof value.exact_time !== "string" || !/^([01]\d|2[0-3]):[0-5]\d$/.test(value.exact_time)) {
      throw new Error("payload.exact_time must be HH:MM for exact_time.");
    }
    if (value.window_ref !== undefined) throw new Error("payload.window_ref is not allowed for exact_time.");
  } else if (value.time_policy === "window") {
    if (!["morning", "midday", "afternoon", "evening", "sleep"].includes(String(value.window_ref))) {
      throw new Error("payload.window_ref is required and invalid for window.");
    }
    if (value.exact_time !== undefined) throw new Error("payload.exact_time is not allowed for window.");
  } else if (value.exact_time !== undefined || value.window_ref !== undefined) {
    throw new Error("anytime does not accept payload.exact_time or payload.window_ref.");
  }

  for (const field of ["task_definition_id", "schedule_id", "occurrence_id"] as const) {
    if (value[field] !== undefined) assertNonEmptyString(value[field], `payload.${field}`);
  }
}

function assertCreateRecurringTaskPayload(value: unknown): asserts value is CreateRecurringTaskPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.pet_id, "payload.pet_id");
  assertNonEmptyString(value.title, "payload.title");
  assertRecurrenceRule(value.recurrence, "payload.recurrence");
  assertAssignment(value.assignment, "payload.assignment");
  if (value.category !== undefined && !taskCategories.includes(String(value.category))) {
    throw new Error("payload.category is invalid.");
  }
  if (value.obligation_class !== undefined && !["required", "scheduled"].includes(String(value.obligation_class))) {
    throw new Error("payload.obligation_class must be required or scheduled.");
  }
  if (value.reminder_config !== undefined && !isRecord(value.reminder_config)) {
    throw new Error("payload.reminder_config must be an object.");
  }
  for (const field of ["task_definition_id", "schedule_id"] as const) {
    if (value[field] !== undefined) assertNonEmptyString(value[field], `payload.${field}`);
  }
}

function assertEditOccurrencePayload(value: unknown): asserts value is EditOccurrencePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.occurrence_id, "payload.occurrence_id");
  assertExpectedRevision(value.expected_revision);
  if (value.title !== undefined) assertNonEmptyString(value.title, "payload.title");
  if (value.assignment !== undefined) assertAssignment(value.assignment, "payload.assignment");
  if (value.time_policy !== undefined) assertTimeShape(value);
  if (value.note !== undefined && typeof value.note !== "string") throw new Error("payload.note must be a string.");
  if (value.title === undefined && value.assignment === undefined && value.time_policy === undefined) {
    throw new Error("edit_occurrence requires at least one editable field.");
  }
}

function assertCancelOccurrencePayload(value: unknown): asserts value is CancelOccurrencePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.occurrence_id, "payload.occurrence_id");
  assertExpectedRevision(value.expected_revision);
  if (value.confirm_required !== undefined && typeof value.confirm_required !== "boolean") {
    throw new Error("payload.confirm_required must be boolean.");
  }
  if (value.note !== undefined && typeof value.note !== "string") throw new Error("payload.note must be a string.");
}

function assertSnoozeOccurrencePayload(value: unknown): asserts value is SnoozeOccurrencePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.occurrence_id, "payload.occurrence_id");
  if (typeof value.snooze_until !== "string" || Number.isNaN(Date.parse(value.snooze_until))) {
    throw new Error("payload.snooze_until must be an ISO timestamp.");
  }
  if (value.note !== undefined && typeof value.note !== "string") throw new Error("payload.note must be a string.");
}

function assertRescheduleOccurrencePayload(value: unknown): asserts value is RescheduleOccurrencePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.occurrence_id, "payload.occurrence_id");
  assertExpectedRevision(value.expected_revision);
  assertLocalDate(value.local_due_date, "payload.local_due_date");
  if (value.time_policy !== undefined) assertTimeShape(value);
  if (value.note !== undefined && typeof value.note !== "string") throw new Error("payload.note must be a string.");
}

function assertUndoSkipPayload(value: unknown): asserts value is UndoSkipPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.occurrence_id, "payload.occurrence_id");
  if (value.note !== undefined && typeof value.note !== "string") throw new Error("payload.note must be a string.");
}

function assertEditScheduleFuturePayload(value: unknown): asserts value is EditScheduleFuturePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.schedule_id, "payload.schedule_id");
  assertExpectedRevision(value.expected_revision);
  assertLocalDate(value.split_date, "payload.split_date");
  assertRecurrenceRule(value.recurrence, "payload.recurrence");
  if (value.recurrence.anchor_date !== value.split_date) {
    throw new Error("payload.recurrence.anchor_date must equal payload.split_date.");
  }
  if (value.title !== undefined) assertNonEmptyString(value.title, "payload.title");
  if (value.assignment !== undefined) assertAssignment(value.assignment, "payload.assignment");
  if (value.reminder_config !== undefined && value.reminder_config !== null && !isRecord(value.reminder_config)) {
    throw new Error("payload.reminder_config must be an object or null.");
  }
  for (const field of ["successor_schedule_id", "successor_task_definition_id"] as const) {
    if (value[field] !== undefined) assertNonEmptyString(value[field], `payload.${field}`);
  }
  if (value.note !== undefined && typeof value.note !== "string") throw new Error("payload.note must be a string.");
}

function assertArchiveSchedulePayload(value: unknown): asserts value is ArchiveSchedulePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.schedule_id, "payload.schedule_id");
  assertExpectedRevision(value.expected_revision);
  if (value.confirm_required !== undefined && typeof value.confirm_required !== "boolean") {
    throw new Error("payload.confirm_required must be boolean.");
  }
  if (value.note !== undefined && typeof value.note !== "string") throw new Error("payload.note must be a string.");
}

function assertAcceptRecommendationPayload(value: unknown): asserts value is AcceptRecommendationPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.plan_item_id, "payload.plan_item_id");
  if (value.complete !== undefined && typeof value.complete !== "boolean") {
    throw new Error("payload.complete must be boolean.");
  }
  if (value.pinned !== undefined && typeof value.pinned !== "boolean") {
    throw new Error("payload.pinned must be boolean.");
  }
  if (value.note !== undefined && typeof value.note !== "string") {
    throw new Error("payload.note must be a string.");
  }
}

function assertCreateInvitationPayload(value: unknown): asserts value is CreateInvitationPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.household_id, "payload.household_id");
  if (value.invitation_id !== undefined) assertNonEmptyString(value.invitation_id, "payload.invitation_id");
  if (value.expires_in_hours !== undefined) {
    if (
      typeof value.expires_in_hours !== "number" || !Number.isInteger(value.expires_in_hours)
      || value.expires_in_hours < 1 || value.expires_in_hours > 336
    ) {
      throw new Error("payload.expires_in_hours must be a whole number of hours between 1 and 336.");
    }
  }
  if (value.role_granted !== undefined && value.role_granted !== "caregiver") {
    throw new Error("payload.role_granted must be caregiver in MVP.");
  }
}

function assertRevokeInvitationPayload(value: unknown): asserts value is RevokeInvitationPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.invitation_id, "payload.invitation_id");
}

function assertAcceptInvitationPayload(value: unknown): asserts value is AcceptInvitationPayload {
  assertInvitationTokenPayload(value);
}

function assertDeclineInvitationPayload(value: unknown): asserts value is DeclineInvitationPayload {
  assertInvitationTokenPayload(value);
}

function assertInvitationTokenPayload(value: unknown): asserts value is { token: string } {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.token, "payload.token");
  // Bound the token before it is hashed so an oversized body cannot be used
  // as a cheap CPU sink; the server issues exactly 64 hex characters.
  if (value.token.trim().length > 256) throw new Error("payload.token is not a valid invitation token.");
}

// F09 socialization passport. The response vocabulary is closed here as well
// as in the database: an unrecognized word must never reach a record, because
// the product's whole position is that a response is owner-reported, not a
// behavioural finding (catalogue §8).
const socializationResponses = ["relaxed", "curious", "neutral", "hesitant", "fearful"];
const socializationCategories = [
  "People", "Animals", "Sounds", "Surfaces",
  "Environments", "Handling", "Transportation", "Household objects",
];
const socializationExclusionReasons = ["unavailable", "unsuitable", "paused"];

function assertSocializationResponse(value: unknown, field: string): asserts value is string {
  if (typeof value !== "string" || !socializationResponses.includes(value)) {
    throw new Error(`${field} must be one of ${socializationResponses.join(", ")}.`);
  }
}

function assertSocializationMediaRefs(value: unknown, field: string): void {
  if (value === undefined || value === null) return;
  if (!Array.isArray(value)) throw new Error(`${field} must be an array.`);
}

function assertRecordSocializationPayload(value: unknown): asserts value is RecordSocializationPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.pet_id, "payload.pet_id");
  if (value.record_id !== undefined) assertNonEmptyString(value.record_id, "payload.record_id");

  const hasExperience = value.experience_content_id !== undefined;
  const hasCustom = value.custom_label !== undefined;
  if (hasExperience === hasCustom) {
    throw new Error("payload must carry exactly one of experience_content_id or custom_label.");
  }
  if (hasExperience) {
    assertNonEmptyString(value.experience_content_id, "payload.experience_content_id");
  } else {
    assertNonEmptyString(value.custom_label, "payload.custom_label");
    // The category is only client-supplied for a custom experience; for a
    // catalogue one the server takes it from the catalogue.
    if (!socializationCategories.includes(String(value.category))) {
      throw new Error("payload.category must be one of the eight socialization categories.");
    }
  }

  if (value.effective_date !== undefined) assertLocalDate(value.effective_date, "payload.effective_date");
  assertSocializationResponse(value.response, "payload.response");
  assertSocializationMediaRefs(value.media_refs, "payload.media_refs");
  for (const field of ["context", "note"] as const) {
    if (value[field] !== undefined && typeof value[field] !== "string") {
      throw new Error(`payload.${field} must be a string.`);
    }
  }
}

function assertEditSocializationRecordPayload(value: unknown): asserts value is EditSocializationRecordPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.record_id, "payload.record_id");
  assertExpectedRevision(value.expected_revision);
  if (value.effective_date !== undefined) assertLocalDate(value.effective_date, "payload.effective_date");
  if (value.response !== undefined) assertSocializationResponse(value.response, "payload.response");
  assertSocializationMediaRefs(value.media_refs, "payload.media_refs");
  for (const field of ["context", "note"] as const) {
    if (value[field] !== undefined && value[field] !== null && typeof value[field] !== "string") {
      throw new Error(`payload.${field} must be a string or null.`);
    }
  }
  // Re-pointing a record at a different experience or category is not an edit,
  // it is a rewrite of what the household observed (US-067).
  for (const field of ["experience_content_id", "custom_label", "category", "pet_id"] as const) {
    if (value[field] !== undefined) {
      throw new Error(`payload.${field} cannot be changed; remove the record and record it again.`);
    }
  }
}

function assertRemoveSocializationRecordPayload(value: unknown): asserts value is RemoveSocializationRecordPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.record_id, "payload.record_id");
}

function assertSetSocializationExclusionPayload(value: unknown): asserts value is SetSocializationExclusionPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.pet_id, "payload.pet_id");
  if (value.exclusion_id !== undefined) assertNonEmptyString(value.exclusion_id, "payload.exclusion_id");

  const hasCategory = value.category !== undefined;
  const hasExperience = value.experience_content_id !== undefined;
  if (hasCategory === hasExperience) {
    throw new Error("payload must carry exactly one of category or experience_content_id.");
  }
  if (hasCategory && !socializationCategories.includes(String(value.category))) {
    throw new Error("payload.category must be one of the eight socialization categories.");
  }
  if (hasExperience) assertNonEmptyString(value.experience_content_id, "payload.experience_content_id");

  if (!socializationExclusionReasons.includes(String(value.reason))) {
    throw new Error(`payload.reason must be one of ${socializationExclusionReasons.join(", ")}.`);
  }
  if (value.note !== undefined && typeof value.note !== "string") {
    throw new Error("payload.note must be a string.");
  }
}

function assertClearSocializationExclusionPayload(value: unknown): asserts value is ClearSocializationExclusionPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.exclusion_id, "payload.exclusion_id");
}

// ---------------------------------------------------------------------------
// Care: weight + providers (F10). No medication scheduling.
// ---------------------------------------------------------------------------

const weightUnits = ["kg", "lb"] as const;
const providerKinds = ["veterinarian", "groomer", "trainer", "other"] as const;

function assertWeightValue(value: unknown, field: string): void {
  if (typeof value === "number") {
    if (!Number.isFinite(value) || value <= 0) throw new Error(`${field} must be a positive number.`);
    return;
  }
  if (typeof value !== "string" || value.trim() === "") throw new Error(`${field} is required.`);
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) throw new Error(`${field} must be a positive number.`);
}

function assertRecordWeightPayload(value: unknown): asserts value is RecordWeightPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.pet_id, "payload.pet_id");
  if (value.measurement_id !== undefined) assertNonEmptyString(value.measurement_id, "payload.measurement_id");
  assertWeightValue(value.value, "payload.value");
  if (!weightUnits.includes(value.unit as typeof weightUnits[number])) {
    throw new Error("payload.unit must be kg or lb.");
  }
  if (value.effective_date !== undefined) assertLocalDate(value.effective_date, "payload.effective_date");
  if (value.note !== undefined && typeof value.note !== "string") {
    throw new Error("payload.note must be a string.");
  }
}

function assertEditWeightPayload(value: unknown): asserts value is EditWeightPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.measurement_id, "payload.measurement_id");
  assertExpectedRevision(value.expected_revision);
  if (value.value !== undefined) assertWeightValue(value.value, "payload.value");
  if (value.unit !== undefined && !weightUnits.includes(value.unit as typeof weightUnits[number])) {
    throw new Error("payload.unit must be kg or lb.");
  }
  if (value.effective_date !== undefined) assertLocalDate(value.effective_date, "payload.effective_date");
  if (value.note !== undefined && value.note !== null && typeof value.note !== "string") {
    throw new Error("payload.note must be a string or null.");
  }
}

function assertRemoveWeightPayload(value: unknown): asserts value is RemoveWeightPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.measurement_id, "payload.measurement_id");
}

function assertCreateProviderPayload(value: unknown): asserts value is CreateProviderPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.household_id, "payload.household_id");
  if (value.provider_id !== undefined) assertNonEmptyString(value.provider_id, "payload.provider_id");
  assertNonEmptyString(value.name, "payload.name");
  if (!providerKinds.includes(value.kind as typeof providerKinds[number])) {
    throw new Error("payload.kind must be veterinarian, groomer, trainer, or other.");
  }
  for (const field of ["phone", "address", "notes"] as const) {
    if (value[field] !== undefined && typeof value[field] !== "string") {
      throw new Error(`payload.${field} must be a string.`);
    }
  }
}

function assertEditProviderPayload(value: unknown): asserts value is EditProviderPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.provider_id, "payload.provider_id");
  assertExpectedRevision(value.expected_revision);
  if (value.name !== undefined) assertNonEmptyString(value.name, "payload.name");
  if (value.kind !== undefined && !providerKinds.includes(value.kind as typeof providerKinds[number])) {
    throw new Error("payload.kind must be veterinarian, groomer, trainer, or other.");
  }
  for (const field of ["phone", "address", "notes"] as const) {
    if (value[field] !== undefined && value[field] !== null && typeof value[field] !== "string") {
      throw new Error(`payload.${field} must be a string or null.`);
    }
  }
}

function assertRemoveProviderPayload(value: unknown): asserts value is RemoveProviderPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.provider_id, "payload.provider_id");
}

const medicationProvenances = ["owner_entered", "professional_instruction"] as const;
const recurrenceTypes = [
  "once",
  "daily",
  "weekdays",
  "every_n_days",
  "weekly",
  "monthly_safe",
  "interval_after_completion",
] as const;
const timePolicies = ["exact_time", "window", "anytime"] as const;
const windowRefs = ["morning", "midday", "afternoon", "evening", "sleep"] as const;

function assertMedicationRecurrence(value: unknown, field: string): asserts value is Record<string, unknown> {
  if (!isRecord(value)) throw new Error(`${field} must be an object.`);
  if (!recurrenceTypes.includes(value.type as typeof recurrenceTypes[number])) {
    throw new Error(`${field}.type must be a supported recurrence.`);
  }
  assertLocalDate(value.anchor_date, `${field}.anchor_date`);
  if (!timePolicies.includes(value.time_policy as typeof timePolicies[number])) {
    throw new Error(`${field}.time_policy must be exact_time, window, or anytime.`);
  }
  if (value.time_policy === "exact_time") {
    if (typeof value.exact_time !== "string" || !/^\d{2}:\d{2}$/.test(value.exact_time)) {
      throw new Error(`${field}.exact_time must be HH:MM.`);
    }
  } else if (value.time_policy === "window") {
    if (!windowRefs.includes(value.window_ref as typeof windowRefs[number])) {
      throw new Error(`${field}.window_ref is invalid.`);
    }
  }
  if (
    (value.type === "every_n_days" || value.type === "interval_after_completion")
    && (typeof value.interval !== "number" || !Number.isInteger(value.interval) || value.interval <= 0)
  ) {
    throw new Error(`${field}.interval must be a positive integer.`);
  }
}

function assertCreateMedicationSchedulePayload(
  value: unknown,
): asserts value is CreateMedicationSchedulePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.pet_id, "payload.pet_id");
  if (value.medication_schedule_id !== undefined) {
    assertNonEmptyString(value.medication_schedule_id, "payload.medication_schedule_id");
  }
  assertNonEmptyString(value.medication_name, "payload.medication_name");
  if (value.dose_text !== undefined && typeof value.dose_text !== "string") {
    throw new Error("payload.dose_text must be a string.");
  }
  if (value.instructions_text !== undefined && typeof value.instructions_text !== "string") {
    throw new Error("payload.instructions_text must be a string.");
  }
  if (
    value.provenance !== undefined
    && !medicationProvenances.includes(value.provenance as typeof medicationProvenances[number])
  ) {
    throw new Error("payload.provenance must be owner_entered or professional_instruction.");
  }
  if (value.provider_id !== undefined) assertNonEmptyString(value.provider_id, "payload.provider_id");
  assertMedicationRecurrence(value.recurrence, "payload.recurrence");
}

function assertEditMedicationSchedulePayload(
  value: unknown,
): asserts value is EditMedicationSchedulePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.medication_schedule_id, "payload.medication_schedule_id");
  assertExpectedRevision(value.expected_revision);
  if (value.medication_name !== undefined) {
    assertNonEmptyString(value.medication_name, "payload.medication_name");
  }
  if (value.dose_text !== undefined && value.dose_text !== null && typeof value.dose_text !== "string") {
    throw new Error("payload.dose_text must be a string or null.");
  }
  if (
    value.instructions_text !== undefined
    && value.instructions_text !== null
    && typeof value.instructions_text !== "string"
  ) {
    throw new Error("payload.instructions_text must be a string or null.");
  }
  if (
    value.provenance !== undefined
    && !medicationProvenances.includes(value.provenance as typeof medicationProvenances[number])
  ) {
    throw new Error("payload.provenance must be owner_entered or professional_instruction.");
  }
  if (value.provider_id !== undefined && value.provider_id !== null) {
    assertNonEmptyString(value.provider_id, "payload.provider_id");
  }
  if (value.recurrence !== undefined) {
    assertMedicationRecurrence(value.recurrence, "payload.recurrence");
  }
}

function assertArchiveMedicationSchedulePayload(
  value: unknown,
): asserts value is ArchiveMedicationSchedulePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.medication_schedule_id, "payload.medication_schedule_id");
  assertExpectedRevision(value.expected_revision);
}

function assertCompleteMedicationOccurrencePayload(
  value: unknown,
): asserts value is CompleteMedicationOccurrencePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.occurrence_id, "payload.occurrence_id");
  if (value.note !== undefined && typeof value.note !== "string") {
    throw new Error("payload.note must be a string.");
  }
  if (
    value.acknowledged_recent_completion !== undefined
    && typeof value.acknowledged_recent_completion !== "boolean"
  ) {
    throw new Error("payload.acknowledged_recent_completion must be boolean.");
  }
}

// ---------------------------------------------------------------------------
// Care vaccinations (US-070) — history only; next_due never computed.
// ---------------------------------------------------------------------------

const vaccinationProvenances = ["owner_entered", "professional_instruction"] as const;

function assertRecordVaccinationPayload(value: unknown): asserts value is RecordVaccinationPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.pet_id, "payload.pet_id");
  if (value.vaccination_id !== undefined) {
    assertNonEmptyString(value.vaccination_id, "payload.vaccination_id");
  }
  assertNonEmptyString(value.vaccine_name, "payload.vaccine_name");
  if (value.effective_date !== undefined) {
    assertLocalDate(value.effective_date, "payload.effective_date");
  }
  // Empty string = no next-due fact (iOS encodes clear/omit as "").
  if (value.next_due_date !== undefined && value.next_due_date !== "") {
    assertLocalDate(value.next_due_date, "payload.next_due_date");
  }
  if (
    value.provenance !== undefined
    && !vaccinationProvenances.includes(value.provenance as typeof vaccinationProvenances[number])
  ) {
    throw new Error("payload.provenance must be owner_entered or professional_instruction.");
  }
  if (value.provider_id !== undefined) {
    assertNonEmptyString(value.provider_id, "payload.provider_id");
  }
  if (value.note !== undefined && typeof value.note !== "string") {
    throw new Error("payload.note must be a string.");
  }
}

function assertEditVaccinationPayload(value: unknown): asserts value is EditVaccinationPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.vaccination_id, "payload.vaccination_id");
  assertExpectedRevision(value.expected_revision);
  if (value.vaccine_name !== undefined) {
    assertNonEmptyString(value.vaccine_name, "payload.vaccine_name");
  }
  if (value.effective_date !== undefined) {
    assertLocalDate(value.effective_date, "payload.effective_date");
  }
  // Empty string clears next_due (SQL nullif); null also clears.
  if (
    value.next_due_date !== undefined
    && value.next_due_date !== null
    && value.next_due_date !== ""
  ) {
    assertLocalDate(value.next_due_date, "payload.next_due_date");
  }
  if (
    value.provenance !== undefined
    && !vaccinationProvenances.includes(value.provenance as typeof vaccinationProvenances[number])
  ) {
    throw new Error("payload.provenance must be owner_entered or professional_instruction.");
  }
  if (value.provider_id !== undefined && value.provider_id !== null) {
    assertNonEmptyString(value.provider_id, "payload.provider_id");
  }
  if (value.note !== undefined && value.note !== null && typeof value.note !== "string") {
    throw new Error("payload.note must be a string or null.");
  }
}

function assertRemoveVaccinationPayload(value: unknown): asserts value is RemoveVaccinationPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.vaccination_id, "payload.vaccination_id");
}

// ---------------------------------------------------------------------------
// Care grooming (F10 / US-076) — history only; next_due never computed.
// ---------------------------------------------------------------------------

const groomingActivityTypes = [
  "brushing",
  "nails",
  "bath",
  "teeth",
  "ears",
  "other",
] as const;

function assertRecordGroomingPayload(value: unknown): asserts value is RecordGroomingPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.pet_id, "payload.pet_id");
  if (value.grooming_id !== undefined) {
    assertNonEmptyString(value.grooming_id, "payload.grooming_id");
  }
  if (!groomingActivityTypes.includes(value.activity_type as typeof groomingActivityTypes[number])) {
    throw new Error(
      "payload.activity_type must be brushing, nails, bath, teeth, ears, or other.",
    );
  }
  if (value.effective_date !== undefined) {
    assertLocalDate(value.effective_date, "payload.effective_date");
  }
  if (value.next_due_date !== undefined) {
    assertLocalDate(value.next_due_date, "payload.next_due_date");
  }
  if (value.note !== undefined && typeof value.note !== "string") {
    throw new Error("payload.note must be a string.");
  }
}

function assertEditGroomingPayload(value: unknown): asserts value is EditGroomingPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.grooming_id, "payload.grooming_id");
  assertExpectedRevision(value.expected_revision);
  if (value.activity_type !== undefined) {
    if (!groomingActivityTypes.includes(value.activity_type as typeof groomingActivityTypes[number])) {
      throw new Error(
        "payload.activity_type must be brushing, nails, bath, teeth, ears, or other.",
      );
    }
  }
  if (value.effective_date !== undefined) {
    assertLocalDate(value.effective_date, "payload.effective_date");
  }
  if (value.next_due_date !== undefined && value.next_due_date !== null) {
    assertLocalDate(value.next_due_date, "payload.next_due_date");
  }
  if (value.note !== undefined && value.note !== null && typeof value.note !== "string") {
    throw new Error("payload.note must be a string or null.");
  }
}

function assertRemoveGroomingPayload(value: unknown): asserts value is RemoveGroomingPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.grooming_id, "payload.grooming_id");
}

// ---------------------------------------------------------------------------
// Care notes (US-077) — general_note only; document/Storage deferred.
// ---------------------------------------------------------------------------

const careNoteKinds = ["general_note", "document"] as const;
const careNoteProvenances = ["owner_entered", "professional_instruction"] as const;

function assertEmptyOrAbsentMediaRefs(value: unknown, field: string): void {
  if (value === undefined || value === null) return;
  if (!Array.isArray(value)) {
    throw new Error(`${field} must be an array.`);
  }
  if (value.length > 0) {
    throw new Error("attach documents via prepare_care_note_media.");
  }
}

function assertCreateCareNotePayload(value: unknown): asserts value is CreateCareNotePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.pet_id, "payload.pet_id");
  if (value.care_note_id !== undefined) {
    assertNonEmptyString(value.care_note_id, "payload.care_note_id");
  }
  if (value.kind !== undefined) {
    if (
      typeof value.kind !== "string"
      || !careNoteKinds.includes(value.kind as typeof careNoteKinds[number])
    ) {
      throw new Error("payload.kind must be general_note or document.");
    }
  }
  assertNonEmptyString(value.body, "payload.body");
  if (typeof value.body === "string" && value.body.trim().length > 8000) {
    throw new Error("payload.body must be 8000 characters or fewer.");
  }
  if (value.title !== undefined) {
    if (typeof value.title !== "string") {
      throw new Error("payload.title must be a string.");
    }
    if (value.title.trim().length > 200) {
      throw new Error("payload.title must be 200 characters or fewer.");
    }
  }
  if (value.kind === "document") {
    if (typeof value.title !== "string" || value.title.trim().length === 0) {
      throw new Error("document notes require a title.");
    }
  }
  if (value.effective_date !== undefined) {
    assertLocalDate(value.effective_date, "payload.effective_date");
  }
  if (
    value.provenance !== undefined
    && !careNoteProvenances.includes(value.provenance as typeof careNoteProvenances[number])
  ) {
    throw new Error("payload.provenance must be owner_entered or professional_instruction.");
  }
  if (value.provider_id !== undefined) {
    assertNonEmptyString(value.provider_id, "payload.provider_id");
  }
  assertEmptyOrAbsentMediaRefs(value.media_refs, "payload.media_refs");
}

function assertEditCareNotePayload(value: unknown): asserts value is EditCareNotePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.care_note_id, "payload.care_note_id");
  assertExpectedRevision(value.expected_revision);
  if (value.body !== undefined) {
    assertNonEmptyString(value.body, "payload.body");
    if (typeof value.body === "string" && value.body.trim().length > 8000) {
      throw new Error("payload.body must be 8000 characters or fewer.");
    }
  }
  if (value.title !== undefined && value.title !== null) {
    if (typeof value.title !== "string") {
      throw new Error("payload.title must be a string or null.");
    }
    if (value.title.trim().length > 200) {
      throw new Error("payload.title must be 200 characters or fewer.");
    }
  }
  if (value.effective_date !== undefined) {
    assertLocalDate(value.effective_date, "payload.effective_date");
  }
  if (
    value.provenance !== undefined
    && !careNoteProvenances.includes(value.provenance as typeof careNoteProvenances[number])
  ) {
    throw new Error("payload.provenance must be owner_entered or professional_instruction.");
  }
  if (value.provider_id !== undefined && value.provider_id !== null) {
    assertNonEmptyString(value.provider_id, "payload.provider_id");
  }
  assertEmptyOrAbsentMediaRefs(value.media_refs, "payload.media_refs");
}

function assertRemoveCareNotePayload(value: unknown): asserts value is RemoveCareNotePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.care_note_id, "payload.care_note_id");
}

const careNoteMediaMimeTypes = [
  "image/jpeg",
  "image/png",
  "image/heic",
  "image/webp",
  "application/pdf",
] as const;

function assertPrepareCareNoteMediaPayload(
  value: unknown,
): asserts value is PrepareCareNoteMediaPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.care_note_id, "payload.care_note_id");
  if (value.media_id !== undefined) assertNonEmptyString(value.media_id, "payload.media_id");
  assertNonEmptyString(value.mime_type, "payload.mime_type");
  if (
    typeof value.mime_type === "string"
    && !careNoteMediaMimeTypes.includes(value.mime_type as typeof careNoteMediaMimeTypes[number])
  ) {
    throw new Error("payload.mime_type must be an allowed image or PDF type.");
  }
  if (typeof value.byte_size !== "number" || !Number.isInteger(value.byte_size)) {
    throw new Error("payload.byte_size must be an integer.");
  }
  if (value.byte_size <= 0 || value.byte_size > 10_485_760) {
    throw new Error("payload.byte_size must be between 1 and 10485760.");
  }
  if (value.capture_time !== undefined) {
    assertNonEmptyString(value.capture_time, "payload.capture_time");
  }
}

function assertCompleteCareNoteMediaPayload(
  value: unknown,
): asserts value is CompleteCareNoteMediaPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.media_id, "payload.media_id");
  if (value.byte_size !== undefined) {
    if (typeof value.byte_size !== "number" || !Number.isInteger(value.byte_size)) {
      throw new Error("payload.byte_size must be an integer.");
    }
    if (value.byte_size <= 0 || value.byte_size > 10_485_760) {
      throw new Error("payload.byte_size must be between 1 and 10485760.");
    }
  }
}

function assertFailCareNoteMediaPayload(
  value: unknown,
): asserts value is FailCareNoteMediaPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.media_id, "payload.media_id");
}

function assertRemoveCareNoteMediaPayload(
  value: unknown,
): asserts value is RemoveCareNoteMediaPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.media_id, "payload.media_id");
}

// ---------------------------------------------------------------------------
// Life milestones (F12) + household-private media attach (DM §12.6).
// ---------------------------------------------------------------------------

function assertCreateMilestonePayload(value: unknown): asserts value is CreateMilestonePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.pet_id, "payload.pet_id");
  if (value.milestone_id !== undefined) assertNonEmptyString(value.milestone_id, "payload.milestone_id");
  assertNonEmptyString(value.title, "payload.title");
  if (typeof value.title === "string" && value.title.trim().length > 200) {
    throw new Error("payload.title must be 200 characters or fewer.");
  }
  if (value.effective_date !== undefined) assertLocalDate(value.effective_date, "payload.effective_date");
  if (value.note !== undefined && typeof value.note !== "string") {
    throw new Error("payload.note must be a string.");
  }
  // Media attaches only via prepare_milestone_media after the text save.
  if (value.media_refs !== undefined) {
    throw new Error("payload.media_refs is not accepted on create_milestone; attach photos separately.");
  }
}

function assertEditMilestonePayload(value: unknown): asserts value is EditMilestonePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.milestone_id, "payload.milestone_id");
  assertExpectedRevision(value.expected_revision);
  if (value.title !== undefined) assertNonEmptyString(value.title, "payload.title");
  if (typeof value.title === "string" && value.title.trim().length > 200) {
    throw new Error("payload.title must be 200 characters or fewer.");
  }
  if (value.effective_date !== undefined) assertLocalDate(value.effective_date, "payload.effective_date");
  if (value.note !== undefined && value.note !== null && typeof value.note !== "string") {
    throw new Error("payload.note must be a string or null.");
  }
  if (value.media_refs !== undefined) {
    throw new Error("payload.media_refs is not accepted on edit_milestone; attach photos separately.");
  }
}

function assertRemoveMilestonePayload(value: unknown): asserts value is RemoveMilestonePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.milestone_id, "payload.milestone_id");
}

const milestoneMediaMimeTypes = ["image/jpeg", "image/png", "image/heic", "image/webp"] as const;

function assertPrepareMilestoneMediaPayload(
  value: unknown,
): asserts value is PrepareMilestoneMediaPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.milestone_id, "payload.milestone_id");
  if (value.media_id !== undefined) assertNonEmptyString(value.media_id, "payload.media_id");
  assertNonEmptyString(value.mime_type, "payload.mime_type");
  if (
    typeof value.mime_type === "string"
    && !milestoneMediaMimeTypes.includes(value.mime_type as typeof milestoneMediaMimeTypes[number])
  ) {
    throw new Error("payload.mime_type must be an allowed image type.");
  }
  if (typeof value.byte_size !== "number" || !Number.isInteger(value.byte_size)) {
    throw new Error("payload.byte_size must be an integer.");
  }
  if (value.byte_size <= 0 || value.byte_size > 10_485_760) {
    throw new Error("payload.byte_size must be between 1 and 10485760.");
  }
  if (value.capture_time !== undefined) {
    assertNonEmptyString(value.capture_time, "payload.capture_time");
  }
}

function assertCompleteMilestoneMediaPayload(
  value: unknown,
): asserts value is CompleteMilestoneMediaPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.media_id, "payload.media_id");
  if (value.byte_size !== undefined) {
    if (typeof value.byte_size !== "number" || !Number.isInteger(value.byte_size)) {
      throw new Error("payload.byte_size must be an integer.");
    }
    if (value.byte_size <= 0 || value.byte_size > 10_485_760) {
      throw new Error("payload.byte_size must be between 1 and 10485760.");
    }
  }
}

function assertFailMilestoneMediaPayload(
  value: unknown,
): asserts value is FailMilestoneMediaPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.media_id, "payload.media_id");
}

function assertRemoveMilestoneMediaPayload(
  value: unknown,
): asserts value is RemoveMilestoneMediaPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.media_id, "payload.media_id");
}

// ---------------------------------------------------------------------------
// Events / appointments (F11, DM §11.5).
// ---------------------------------------------------------------------------

const eventKinds = ["vet_appointment", "class", "grooming_visit", "other"] as const;

function assertClockTime(value: unknown, field: string): void {
  if (typeof value !== "string" || !/^\d{2}:\d{2}(:\d{2})?$/.test(value)) {
    throw new Error(`${field} must be HH:MM.`);
  }
}

function assertCreateEventPayload(value: unknown): asserts value is CreateEventPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.household_id, "payload.household_id");
  if (value.event_id !== undefined) assertNonEmptyString(value.event_id, "payload.event_id");
  if (value.pet_id !== undefined && value.pet_id !== null) {
    assertNonEmptyString(value.pet_id, "payload.pet_id");
  }
  if (!eventKinds.includes(value.kind as typeof eventKinds[number])) {
    throw new Error("payload.kind must be vet_appointment, class, grooming_visit, or other.");
  }
  assertNonEmptyString(value.title, "payload.title");
  assertLocalDate(value.start_date, "payload.start_date");
  const allDay = value.all_day === undefined ? true : value.all_day === true;
  if (value.all_day !== undefined && typeof value.all_day !== "boolean") {
    throw new Error("payload.all_day must be a boolean.");
  }
  if (!allDay) {
    assertClockTime(value.start_time, "payload.start_time");
    if (value.end_time !== undefined) assertClockTime(value.end_time, "payload.end_time");
  }
  if (value.location_text !== undefined && typeof value.location_text !== "string") {
    throw new Error("payload.location_text must be a string.");
  }
  if (value.provider_id !== undefined && value.provider_id !== null) {
    assertNonEmptyString(value.provider_id, "payload.provider_id");
  }
  if (value.notes !== undefined && typeof value.notes !== "string") {
    throw new Error("payload.notes must be a string.");
  }
  if (value.reminder_config !== undefined && value.reminder_config !== null && !isRecord(value.reminder_config)) {
    throw new Error("payload.reminder_config must be an object or null.");
  }
}

function assertEditEventPayload(value: unknown): asserts value is EditEventPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.event_id, "payload.event_id");
  assertExpectedRevision(value.expected_revision);
  if (value.pet_id !== undefined && value.pet_id !== null) {
    assertNonEmptyString(value.pet_id, "payload.pet_id");
  }
  if (value.kind !== undefined && !eventKinds.includes(value.kind as typeof eventKinds[number])) {
    throw new Error("payload.kind must be vet_appointment, class, grooming_visit, or other.");
  }
  if (value.title !== undefined) assertNonEmptyString(value.title, "payload.title");
  if (value.start_date !== undefined) assertLocalDate(value.start_date, "payload.start_date");
  if (value.all_day !== undefined && typeof value.all_day !== "boolean") {
    throw new Error("payload.all_day must be a boolean.");
  }
  if (value.start_time !== undefined && value.start_time !== null) {
    assertClockTime(value.start_time, "payload.start_time");
  }
  if (value.end_time !== undefined && value.end_time !== null) {
    assertClockTime(value.end_time, "payload.end_time");
  }
  if (value.location_text !== undefined && value.location_text !== null && typeof value.location_text !== "string") {
    throw new Error("payload.location_text must be a string or null.");
  }
  if (value.provider_id !== undefined && value.provider_id !== null) {
    assertNonEmptyString(value.provider_id, "payload.provider_id");
  }
  if (value.notes !== undefined && value.notes !== null && typeof value.notes !== "string") {
    throw new Error("payload.notes must be a string or null.");
  }
  if (value.reminder_config !== undefined && value.reminder_config !== null && !isRecord(value.reminder_config)) {
    throw new Error("payload.reminder_config must be an object or null.");
  }
}

function assertCancelEventPayload(value: unknown): asserts value is CancelEventPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.event_id, "payload.event_id");
  assertExpectedRevision(value.expected_revision);
}

function assertArchiveEventPayload(value: unknown): asserts value is ArchiveEventPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.event_id, "payload.event_id");
  assertExpectedRevision(value.expected_revision);
}

const pushEnvironments = ["sandbox", "production"] as const;

function assertRegisterDeviceTokenPayload(value: unknown): asserts value is RegisterDeviceTokenPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.token, "payload.token");
  if (!/^[0-9a-fA-F]{32,200}$/.test(value.token)) {
    throw new Error("payload.token must be a hex APNs device token.");
  }
  if (!pushEnvironments.includes(value.environment as typeof pushEnvironments[number])) {
    throw new Error("payload.environment must be sandbox or production.");
  }
  if (value.platform !== undefined && value.platform !== "ios") {
    throw new Error("payload.platform must be ios.");
  }
  if (value.app_build !== undefined && typeof value.app_build !== "string") {
    throw new Error("payload.app_build must be a string.");
  }
  if (value.device_name !== undefined && typeof value.device_name !== "string") {
    throw new Error("payload.device_name must be a string.");
  }
  if (value.token_id !== undefined) assertNonEmptyString(value.token_id, "payload.token_id");
}

function assertUnregisterDeviceTokenPayload(value: unknown): asserts value is UnregisterDeviceTokenPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.token, "payload.token");
}

// ---------------------------------------------------------------------------
// Training goals and sessions (F08, epic E06)
// ---------------------------------------------------------------------------

/**
 * `paused` is deliberately absent. F08's seventh state is a goal STATUS, and
 * accepting it here would let a client erase the substantive progress the
 * household reported (US-064). The database refuses it too.
 */
const trainingProgressStates = [
  "not_started",
  "introduced",
  "practicing",
  "reliable_in_familiar_setting",
  "generalizing",
  "maintained",
];

function assertStartTrainingGoalPayload(value: unknown): asserts value is StartTrainingGoalPayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.pet_id, "payload.pet_id");
  assertNonEmptyString(value.skill_ref, "payload.skill_ref");
  if (!/^skill\.[a-z0-9_]+$/.test(value.skill_ref)) {
    throw new Error("payload.skill_ref must be a catalogue skill id.");
  }
}

/**
 * A goal is addressed either by its id or by the (pet, skill) pair the lesson
 * screen already holds. Requiring one of the two here means the database never
 * has to guess which goal an ambiguous payload meant.
 */
function assertTrainingGoalRefPayload(value: unknown): asserts value is TrainingGoalRef {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  const hasGoalId = typeof value.goal_id === "string" && value.goal_id.trim() !== "";
  const hasPair = typeof value.pet_id === "string" && value.pet_id.trim() !== ""
    && typeof value.skill_ref === "string" && value.skill_ref.trim() !== "";
  if (!hasGoalId && !hasPair) {
    throw new Error("payload requires goal_id, or both pet_id and skill_ref.");
  }
  if (value.expected_revision !== undefined) assertExpectedRevision(value.expected_revision);
}

function assertUpdateTrainingProgressPayload(value: unknown): asserts value is UpdateTrainingProgressPayload {
  assertTrainingGoalRefPayload(value);
  const payload = value as Record<string, unknown>;
  if (payload.progress_state === "paused") {
    throw new Error("Pausing is a goal status change, not a progress state.");
  }
  if (!trainingProgressStates.includes(String(payload.progress_state))) {
    throw new Error("payload.progress_state is not one of the owner-reported states.");
  }
}

function assertLogTrainingSessionPayload(value: unknown): asserts value is LogTrainingSessionPayload {
  assertTrainingGoalRefPayload(value);
  const payload = value as Record<string, unknown>;
  if (payload.effective_date !== undefined) {
    assertLocalDate(payload.effective_date, "payload.effective_date");
    if (isFutureDate(String(payload.effective_date))) {
      throw new Error("A training session cannot be logged in the future.");
    }
  }
  if (payload.effective_time !== undefined) {
    if (typeof payload.effective_time !== "string" || !/^([01]\d|2[0-3]):[0-5]\d$/.test(payload.effective_time)) {
      throw new Error("payload.effective_time must be HH:MM.");
    }
  }
  if (payload.duration_minutes !== undefined) {
    if (
      typeof payload.duration_minutes !== "number" || !Number.isInteger(payload.duration_minutes)
      || payload.duration_minutes < 1 || payload.duration_minutes > 600
    ) {
      throw new Error("payload.duration_minutes must be a whole number of minutes between 1 and 600.");
    }
  }
  if (payload.outcome_note !== undefined && typeof payload.outcome_note !== "string") {
    throw new Error("payload.outcome_note must be a string.");
  }
  // Absent means "the household said nothing about progress", which must stay
  // distinguishable from a reconfirmation: a session never advances mastery on
  // its own (US-063).
  if (payload.progress_state_after !== undefined) {
    if (payload.progress_state_after === "paused") {
      throw new Error("Pausing is a goal status change, not a progress state.");
    }
    if (!trainingProgressStates.includes(String(payload.progress_state_after))) {
      throw new Error("payload.progress_state_after is not one of the owner-reported states.");
    }
  }
  if (payload.media_refs !== undefined && !Array.isArray(payload.media_refs)) {
    throw new Error("payload.media_refs must be an array.");
  }
}

const taskCategories = [
  "health", "feeding", "routine", "training", "socialization",
  "grooming", "event", "preparation", "life", "household",
];

function assertExpectedRevision(value: unknown): asserts value is number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1) {
    throw new Error("payload.expected_revision must be a positive integer.");
  }
}

function assertAssignment(value: unknown, field: string): asserts value is string {
  if (typeof value !== "string" || !/^(unassigned|anyone|member:[0-9a-fA-F-]{36})$/.test(value)) {
    throw new Error(`${field} must be unassigned, anyone, or member:<user_uuid>.`);
  }
}

function assertTimeShape(value: Record<string, unknown>): void {
  if (!["anytime", "window", "exact_time"].includes(String(value.time_policy))) {
    throw new Error("payload.time_policy is invalid.");
  }
  if (value.time_policy === "exact_time") {
    if (typeof value.exact_time !== "string" || !/^([01]\d|2[0-3]):[0-5]\d$/.test(value.exact_time)) {
      throw new Error("payload.exact_time must be HH:MM for exact_time.");
    }
    if (value.window_ref !== undefined) throw new Error("payload.window_ref is not allowed for exact_time.");
  } else if (value.time_policy === "window") {
    if (!["morning", "midday", "afternoon", "evening", "sleep"].includes(String(value.window_ref))) {
      throw new Error("payload.window_ref is required and invalid for window.");
    }
    if (value.exact_time !== undefined) throw new Error("payload.exact_time is not allowed for window.");
  } else if (value.exact_time !== undefined || value.window_ref !== undefined) {
    throw new Error("anytime does not accept payload.exact_time or payload.window_ref.");
  }
}

function assertRecurrenceRule(value: unknown, field: string): asserts value is RecurrenceRulePayload {
  if (!isRecord(value)) throw new Error(`${field} must be an object.`);
  const types = ["once", "daily", "weekdays", "every_n_days", "weekly", "monthly_safe", "interval_after_completion"];
  if (!types.includes(String(value.type))) throw new Error(`${field}.type is unsupported.`);
  assertLocalDate(value.anchor_date, `${field}.anchor_date`);
  assertTimeShape(value);
  if (value.until !== undefined) {
    assertLocalDate(value.until, `${field}.until`);
    if (String(value.until) < String(value.anchor_date)) throw new Error(`${field}.until must not precede anchor_date.`);
  }
  if (value.count !== undefined && (typeof value.count !== "number" || !Number.isInteger(value.count) || value.count < 1)) {
    throw new Error(`${field}.count must be a positive integer.`);
  }
  if (value.type === "weekdays") {
    if (!Array.isArray(value.weekdays) || value.weekdays.length < 1 || value.weekdays.length > 7) {
      throw new Error(`${field}.weekdays must contain 1-7 weekdays.`);
    }
    const allowed = new Set(["1", "2", "3", "4", "5", "6", "7", "mon", "monday", "tue", "tuesday", "wed", "wednesday", "thu", "thursday", "fri", "friday", "sat", "saturday", "sun", "sunday"]);
    if (!value.weekdays.every((day) => allowed.has(String(day).toLowerCase()))) {
      throw new Error(`${field}.weekdays contains an invalid weekday.`);
    }
  } else if (value.weekdays !== undefined) {
    throw new Error(`${field}.weekdays is only valid for weekdays recurrence.`);
  }
  if (value.type === "every_n_days" || value.type === "interval_after_completion") {
    if (typeof value.interval !== "number" || !Number.isInteger(value.interval) || value.interval < 1) {
      throw new Error(`${field}.interval must be a positive integer.`);
    }
  } else if (value.interval !== undefined) {
    throw new Error(`${field}.interval is only valid for interval recurrence.`);
  }
  if (value.type === "monthly_safe") {
    if (typeof value.day_of_month !== "number" || !Number.isInteger(value.day_of_month) || value.day_of_month < 1 || value.day_of_month > 31) {
      throw new Error(`${field}.day_of_month must be 1-31.`);
    }
  } else if (value.day_of_month !== undefined) {
    throw new Error(`${field}.day_of_month is only valid for monthly_safe recurrence.`);
  }
}

function assertCompleteOccurrencePayload(value: unknown): asserts value is CompleteOccurrencePayload {
  assertOccurrenceActionPayload(value);
}

function assertUndoCompletionPayload(value: unknown): asserts value is UndoCompletionPayload {
  assertOccurrenceActionPayload(value);
}

function assertSkipItemPayload(value: unknown): asserts value is SkipItemPayload {
  assertOccurrenceActionPayload(value);
  const reasons = ["not_relevant_today", "already_did_this", "too_busy", "pet_not_feeling_well", "do_not_suggest_for_now"];
  if (value.skip_reason !== undefined && !reasons.includes(String(value.skip_reason))) {
    throw new Error("payload.skip_reason is invalid.");
  }
  if (value.confirm_required !== undefined && typeof value.confirm_required !== "boolean") {
    throw new Error("payload.confirm_required must be boolean.");
  }
}

function assertOccurrenceActionPayload(value: unknown): asserts value is Record<string, unknown> & CompleteOccurrencePayload {
  if (!isRecord(value)) throw new Error("payload must be an object.");
  assertNonEmptyString(value.occurrence_id, "payload.occurrence_id");
  if (value.note !== undefined && typeof value.note !== "string") throw new Error("payload.note must be a string.");
}

function assertNonEmptyString(value: unknown, field: string): asserts value is string {
  if (typeof value !== "string" || value.trim() === "") throw new Error(`${field} is required.`);
}

function assertLocalDate(value: unknown, field: string): asserts value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) {
    throw new Error(`${field} must be YYYY-MM-DD.`);
  }
}

async function authenticate(request: Request): Promise<AuthUser> {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) throw new Error("Missing bearer token.");

  const response = await fetch(`${env("SUPABASE_URL")}/auth/v1/user`, {
    headers: {
      authorization,
      apikey: env("SUPABASE_ANON_KEY"),
    },
  });
  if (!response.ok) throw new Error("Invalid bearer token.");
  const body = await response.json() as { id?: unknown };
  if (typeof body.id !== "string") throw new Error("Authenticated user id missing.");
  return { id: body.id };
}

async function assertActiveMembership(actorUserId: string, householdId: string): Promise<void> {
  const params = new URLSearchParams({
    select: "id",
    household_id: `eq.${householdId}`,
    user_id: `eq.${actorUserId}`,
    status: "eq.active",
    limit: "1",
  });
  const rows = await restGet<Array<{ id: string }>>(`household_memberships?${params.toString()}`);
  if (rows.length !== 1) throw taggedError("FORBIDDEN", "Active household membership required.");
}

async function findReplay(actorUserId: string, key: string): Promise<null | { command: string; payload_hash: string; response_body: Json; status: "succeeded" | "failed"; error_code: string | null }> {
  const params = new URLSearchParams({
    select: "command,payload_hash,response_body,status,error_code",
    actor_user_id: `eq.${actorUserId}`,
    client_idempotency_key: `eq.${key}`,
    limit: "1",
  });
  const rows = await restGet<Array<{ command: string; payload_hash: string; response_body: Json; status: "succeeded" | "failed"; error_code: string | null }>>(`command_log?${params.toString()}`);
  return rows[0] ?? null;
}

/**
 * `command_log.request_body` is durable and support-readable, so a live
 * invitation token must never reach it (DM 10 §7.4/§17). The payload hash is
 * computed from the ORIGINAL payload, so redaction here does not affect
 * idempotency matching.
 */
function envelopeForStorage(envelope: CommandEnvelope): CommandEnvelope {
  if (isRecord(envelope.payload) && typeof envelope.payload.token === "string") {
    return { ...envelope, payload: { ...envelope.payload, token: "[redacted]" } };
  }
  return envelope;
}

async function recordCommandFailure(actorUserId: string, envelope: CommandEnvelope, payloadHash: string, errorCode: string): Promise<void> {
  await restPost("command_log", {
    actor_user_id: actorUserId,
    client_idempotency_key: envelope.client_idempotency_key,
    command: envelope.command,
    payload_hash: payloadHash,
    request_body: envelopeForStorage(envelope),
    response_body: { ok: false, code: errorCode },
    status: "failed",
    error_code: errorCode,
    recorded_at: envelope.recorded_at,
    effective_at: envelope.effective_at ?? null,
    completed_at: new Date().toISOString(),
  });
}

async function safeRecordFailure(actorUserId: string, envelope: CommandEnvelope, payloadHash: string, errorCode: string): Promise<void> {
  try {
    await recordCommandFailure(actorUserId, envelope, payloadHash, errorCode);
  } catch {
    // The original command error is more useful to the caller than a secondary logging failure.
  }
}

async function rpc<T>(functionName: string, body: Record<string, Json>): Promise<T> {
  return restPost<T>(`rpc/${functionName}`, body);
}

async function restGet<T>(path: string): Promise<T> {
  const response = await fetch(`${env("SUPABASE_URL")}/rest/v1/${path}`, {
    headers: serviceHeaders(),
  });
  return parseRestResponse<T>(response);
}

async function restPost<T = Json>(path: string, body: unknown): Promise<T> {
  const response = await fetch(`${env("SUPABASE_URL")}/rest/v1/${path}`, {
    method: "POST",
    headers: {
      ...serviceHeaders(),
      "content-type": "application/json",
      prefer: "return=representation",
    },
    body: JSON.stringify(body),
  });
  return parseRestResponse<T>(response);
}

async function parseRestResponse<T>(response: Response): Promise<T> {
  const text = await response.text();
  const parsed = text ? JSON.parse(text) as T : null as T;
  if (!response.ok) {
    const record: Record<string, unknown> = isRecord(parsed) ? parsed : {};
    throw taggedError(
      typeof record.code === "string" ? record.code : "DATABASE_ERROR",
      typeof record.message === "string" ? record.message : response.statusText,
    );
  }
  return parsed;
}

function serviceHeaders(): Record<string, string> {
  const serviceRoleKey = env("SUPABASE_SERVICE_ROLE_KEY");
  return {
    apikey: serviceRoleKey,
    authorization: `Bearer ${serviceRoleKey}`,
  };
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`${name} is not configured.`);
  return value;
}

function success<T>(command: WritePathCommand, result: T, idempotentReplay: boolean): CommandSuccess<T> {
  return { ok: true, command, idempotent_replay: idempotentReplay, result };
}

function failure(code: string, message: string, command?: WritePathCommand, idempotentReplay = false): CommandFailure {
  return { ok: false, command, code, message, idempotent_replay: idempotentReplay };
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isJson(value: unknown): value is Json {
  if (value === null) return true;
  if (["string", "number", "boolean"].includes(typeof value)) return Number.isFinite(value as number) || typeof value !== "number";
  if (Array.isArray(value)) return value.every(isJson);
  if (isRecord(value)) return Object.values(value).every(isJson);
  return false;
}

function isFutureDate(date: string): boolean {
  const today = new Date().toISOString().slice(0, 10);
  return date > today;
}

async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function stableStringify(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (isRecord(value)) {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function taggedError(code: string, message: string): Error & { code: string } {
  const error = new Error(message) as Error & { code: string };
  error.code = code;
  return error;
}

function codeOf(error: unknown): string {
  if (isRecord(error) && typeof error.code === "string") {
    if (error.code === "42501") return "FORBIDDEN";
    if (error.code === "23505") return "IDEMPOTENCY_CONFLICT";
    if (error.code === "PC001") return "REQUIRED_CONFIRMATION";
    // Invitation outcomes are distinct codes on purpose: ON-05 must explain
    // exactly why a link cannot be used (US-012), never a generic failure.
    if (error.code === "PC010") return "INVITATION_NOT_FOUND";
    if (error.code === "PC011") return "INVITATION_EXPIRED";
    if (error.code === "PC012") return "INVITATION_ALREADY_RESOLVED";
    if (error.code === "PC013") return "ALREADY_A_MEMBER";
    if (error.code === "PC014") return "HOUSEHOLD_CLOSED";
    if (error.code === "PC015") return "SINGLE_HOUSEHOLD_LIMIT";
    if (error.code === "40001") return "REVISION_CONFLICT";
    if (error.code === "22023" || error.code === "23514" || error.code === "22P02") return "VALIDATION_FAILED";
    return error.code;
  }
  return "COMMAND_FAILED";
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : "Unknown error.";
}

function statusForError(code: string | null | undefined): number {
  switch (code) {
    case "FORBIDDEN":
      return 403;
    case "IDEMPOTENCY_CONFLICT":
    case "REVISION_CONFLICT":
    case "INVITATION_ALREADY_RESOLVED":
    case "ALREADY_A_MEMBER":
    case "HOUSEHOLD_CLOSED":
    case "SINGLE_HOUSEHOLD_LIMIT":
      return 409;
    case "INVITATION_NOT_FOUND":
      return 404;
    case "INVITATION_EXPIRED":
      return 410;
    case "VALIDATION_FAILED":
    case "REQUIRED_CONFIRMATION":
    case "BAD_REQUEST":
      return 400;
    default:
      return 500;
  }
}
