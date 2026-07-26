export type SliceACommand =
  | "create_household"
  | "create_pet"
  | "set_routine_preferences"
  | "create_task"
  | "complete_occurrence"
  | "undo_completion"
  | "skip_item";

export interface CommandEnvelope<TPayload = unknown> {
  command: SliceACommand;
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
  birth_date_kind: "exact" | "estimated";
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

export interface CommandSuccess<T = unknown> {
  ok: true;
  command: SliceACommand;
  idempotent_replay: boolean;
  result: T;
}

export interface CommandFailure {
  ok: false;
  command?: SliceACommand;
  code: string;
  message: string;
  idempotent_replay?: boolean;
}
