import { generatePlan } from "../_shared/engine.mjs";

declare const Deno: {
  env: { get(name: string): string | undefined };
  serve(handler: (request: Request) => Response | Promise<Response>): void;
};

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type CapacityMode = "normal" | "busy" | "essentials_only" | "custom";

interface GeneratePlanBody {
  pet_id: string;
  capacity_override?: CapacityMode;
  force?: boolean;
}

interface AuthUser {
  id: string;
}

interface PetAccessRow {
  id: string;
  household_id: string;
  status: string;
}

interface EngineResult {
  plan: Record<string, Json>;
  items: Json[];
  diagnostics: Record<string, Json>;
}

const capacityModes = new Set<CapacityMode>(["normal", "busy", "essentials_only", "custom"]);

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders() });
  if (request.method !== "POST") return jsonResponse({ ok: false, code: "METHOD_NOT_ALLOWED", message: "Use POST." }, 405);

  try {
    const user = await authenticate(request);
    const body = await parseBody(request);
    const saved = await generateAndPersistPlan(user.id, body);
    return jsonResponse({ ok: true, result: saved }, 200);
  } catch (error) {
    const code = codeOf(error);
    return jsonResponse({ ok: false, code, message: messageOf(error) }, statusFor(code));
  }
});

/**
 * The I/O core is exported so orchestration tests can invoke it independently
 * of Deno. SQL tests exercise the two RPC boundaries around the pure engine.
 */
export async function generateAndPersistPlan(
  actorUserId: string,
  input: GeneratePlanBody,
  atInstant = new Date().toISOString(),
): Promise<Json> {
  const pet = await verifyPetAccess(actorUserId, input.pet_id);
  await verifyMembership(actorUserId, pet.household_id);

  // Day close is safe and idempotent. Running it at every generation request
  // gives local/private deployments automatic lifecycle cleanup without
  // requiring an external scheduler; hosted deployments may additionally
  // invoke the same RPC on a cron.
  await rpc<Json>("close_elapsed_plans", { at_instant: atInstant });

  const context = await rpc<Record<string, Json>>("write_path_generation_context", {
    actor_id: actorUserId,
    target_pet_id: input.pet_id,
    capacity_override: input.capacity_override ?? null,
    at_instant: atInstant,
  });

  // The first generated plan is the stable daily set. Passive refreshes return
  // it verbatim so recommendations do not churn or increment plan_version.
  // Capacity changes are intentional mutations and therefore regenerate.
  const existing = await loadOpenPlan(input.pet_id, String(context.local_date));
  if (existing) {
    const persistedPlan = isRecord(existing) && isRecord(existing.plan) ? existing.plan : null;
    const recommendationsFrozen = persistedPlan?.recommendations_frozen_at != null;
    if (recommendationsFrozen || (!input.force && input.capacity_override === undefined)) {
      return existing;
    }
  }

  const generated = generatePlan(context) as EngineResult;

  return rpc<Json>("write_path_persist_plan", {
    actor_id: actorUserId,
    plan_input: generated.plan,
    items_input: generated.items,
    diagnostics_input: generated.diagnostics,
  });
}

async function loadOpenPlan(petId: string, localDate: string): Promise<Json | null> {
  const planParams = new URLSearchParams({
    select: "*",
    pet_id: `eq.${petId}`,
    local_date: `eq.${localDate}`,
    status: "eq.open",
    limit: "1",
  });
  const plans = await restGet<Array<Record<string, Json>>>(`plans?${planParams}`);
  const plan = plans[0];
  if (!plan || typeof plan.id !== "string") return null;

  const itemParams = new URLSearchParams({
    select: "*",
    plan_id: `eq.${plan.id}`,
    order: "section.asc,priority_tier.asc,due_time.asc.nullslast,title.asc,item_key.asc",
  });
  const items = await restGet<Json[]>(`plan_items?${itemParams}`);
  return { plan, items };
}

async function parseBody(request: Request): Promise<GeneratePlanBody> {
  let value: unknown;
  try {
    value = await request.json();
  } catch {
    throw taggedError("BAD_REQUEST", "Body must be valid JSON.");
  }
  if (!isRecord(value)) throw taggedError("BAD_REQUEST", "Body must be a JSON object.");
  if (typeof value.pet_id !== "string" || !isUuid(value.pet_id)) {
    throw taggedError("BAD_REQUEST", "pet_id must be a UUID.");
  }
  if (value.capacity_override !== undefined && !capacityModes.has(value.capacity_override as CapacityMode)) {
    throw taggedError("BAD_REQUEST", "capacity_override is invalid.");
  }
  if (value.force !== undefined && typeof value.force !== "boolean") {
    throw taggedError("BAD_REQUEST", "force must be boolean.");
  }
  return value as unknown as GeneratePlanBody;
}

async function authenticate(request: Request): Promise<AuthUser> {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) throw taggedError("UNAUTHORIZED", "Missing bearer token.");
  const response = await fetch(`${env("SUPABASE_URL")}/auth/v1/user`, {
    headers: { authorization, apikey: env("SUPABASE_ANON_KEY") },
  });
  if (!response.ok) throw taggedError("UNAUTHORIZED", "Invalid bearer token.");
  const body = await response.json() as { id?: unknown };
  if (typeof body.id !== "string") throw taggedError("UNAUTHORIZED", "Authenticated user id missing.");
  return { id: body.id };
}

async function verifyPetAccess(actorUserId: string, petId: string): Promise<PetAccessRow> {
  const params = new URLSearchParams({
    select: "id,household_id,status",
    id: `eq.${petId}`,
    status: "eq.active",
    limit: "1",
  });
  const rows = await restGet<PetAccessRow[]>(`pets?${params}`);
  const pet = rows[0];
  if (!pet) throw taggedError("NOT_FOUND", "Active pet not found.");
  await verifyMembership(actorUserId, pet.household_id);
  return pet;
}

async function verifyMembership(actorUserId: string, householdId: string): Promise<void> {
  const params = new URLSearchParams({
    select: "id",
    household_id: `eq.${householdId}`,
    user_id: `eq.${actorUserId}`,
    status: "eq.active",
    limit: "1",
  });
  const rows = await restGet<Array<{ id: string }>>(`household_memberships?${params}`);
  if (rows.length !== 1) throw taggedError("FORBIDDEN", "Active household membership required.");
}

async function rpc<T>(name: string, body: Record<string, Json>): Promise<T> {
  return restPost<T>(`rpc/${name}`, body);
}

async function restGet<T>(path: string): Promise<T> {
  const response = await fetch(`${env("SUPABASE_URL")}/rest/v1/${path}`, {
    headers: serviceHeaders(),
  });
  return decode<T>(response);
}

async function restPost<T>(path: string, body: Record<string, Json>): Promise<T> {
  const response = await fetch(`${env("SUPABASE_URL")}/rest/v1/${path}`, {
    method: "POST",
    headers: { ...serviceHeaders(), "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return decode<T>(response);
}

async function decode<T>(response: Response): Promise<T> {
  const text = await response.text();
  const body = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const record = isRecord(body) ? body : {};
    const databaseCode = typeof record.code === "string" ? record.code : "DATABASE_ERROR";
    const message = typeof record.message === "string" ? record.message : `Database request failed (${response.status}).`;
    if (databaseCode === "42501") throw taggedError("FORBIDDEN", message);
    if (databaseCode === "55000") throw taggedError("PLAN_CLOSED", message);
    throw taggedError("DATABASE_ERROR", message);
  }
  return body as T;
}

function serviceHeaders(): Record<string, string> {
  const key = env("SUPABASE_SERVICE_ROLE_KEY");
  return { apikey: key, authorization: `Bearer ${key}` };
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw taggedError("SERVER_MISCONFIGURED", `${name} is not configured.`);
  return value;
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...corsHeaders() },
  });
}

function corsHeaders(): Record<string, string> {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "authorization, apikey, content-type",
    "access-control-allow-methods": "POST, OPTIONS",
  };
}

function taggedError(code: string, message: string): Error & { code: string } {
  return Object.assign(new Error(message), { code });
}

function codeOf(error: unknown): string {
  return isRecord(error) && typeof error.code === "string" ? error.code : "INTERNAL_ERROR";
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : "Unexpected error.";
}

function statusFor(code: string): number {
  if (code === "BAD_REQUEST") return 400;
  if (code === "UNAUTHORIZED") return 401;
  if (code === "FORBIDDEN") return 403;
  if (code === "NOT_FOUND") return 404;
  if (code === "PLAN_CLOSED") return 409;
  return 500;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}
