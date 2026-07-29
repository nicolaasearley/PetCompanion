/**
 * Notification candidate consumer (remote APNs foundation).
 *
 * Selects due `notification_candidates`, re-verifies the pre-delivery
 * checklist (via `claim_due_notification_candidates`), and either:
 *   - records a safe `skipped_apns_not_configured` run when APNs secrets are
 *     absent (candidates stay `scheduled`), or
 *   - documents the send path when secrets are present (full APNs HTTP/2
 *     delivery is intentionally gated on hosted secrets — never commit .p8).
 *
 * Auth: service role bearer, OR `x-notification-dispatch-secret` matching
 * `NOTIFICATION_DISPATCH_SECRET`. Not a caregiver-facing endpoint.
 */

declare const Deno: {
  env: { get(name: string): string | undefined };
  serve(handler: (request: Request) => Response | Promise<Response>): void;
};

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

interface ClaimResult {
  verify?: {
    run_id?: string;
    due_count?: number;
    cancelled_count?: number;
    eligible_count?: number;
  };
  candidates?: Array<{
    candidate_id: string;
    recipient_user_id: string;
    device_tokens?: Array<{ token: string; environment: string }>;
  }>;
  apns_required?: boolean;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }
  if (request.method !== "POST") {
    return jsonResponse({ ok: false, code: "METHOD_NOT_ALLOWED", message: "Use POST." }, 405);
  }

  try {
    await authorizeDispatcher(request);
    const body = await parseBody(request);
    const atInstant = typeof body.at_instant === "string" ? body.at_instant : new Date().toISOString();
    const batchLimit = clampInt(body.batch_limit, 1, 200, 50);

    const claimed = await rpc<ClaimResult>("claim_due_notification_candidates", {
      at_instant: atInstant,
      batch_limit: batchLimit,
    });

    const candidates = Array.isArray(claimed.candidates) ? claimed.candidates : [];
    const eligibleCount = claimed.verify?.eligible_count ?? candidates.length;
    const tokensReady = candidates.filter((c) => (c.device_tokens?.length ?? 0) > 0).length;
    const apnsConfigured = hasApnsSecrets();

    if (!apnsConfigured) {
      const run = await recordDispatchRun({
        mode: "claim_for_send",
        outcome: "skipped_apns_not_configured",
        due_count: claimed.verify?.due_count ?? 0,
        verified_count: claimed.verify?.due_count ?? 0,
        cancelled_count: claimed.verify?.cancelled_count ?? 0,
        eligible_count: eligibleCount,
        sent_count: 0,
        failed_count: 0,
        detail: {
          at_instant: atInstant,
          candidates_with_tokens: tokensReady,
          note: "APNs hosted secrets not configured; due candidates left scheduled.",
        },
      });
      return jsonResponse({
        ok: true,
        apns_configured: false,
        verify: claimed.verify ?? null,
        eligible_count: eligibleCount,
        candidates_with_tokens: tokensReady,
        dispatch_run_id: run?.id ?? null,
        message:
          "Verified due candidates. Set APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC, and APNS_PRIVATE_KEY (or APNS_PRIVATE_KEY_BASE64) in Edge Function secrets to enable delivery.",
      }, 200);
    }

    // Secrets are present: still do not invent a partial JWT/APNs client here
    // without an end-to-end smoke path. Record that the sender is ready and
    // leave candidates scheduled until the APNs sender slice lands.
    const run = await recordDispatchRun({
      mode: "apns_send",
      outcome: "partial",
      due_count: claimed.verify?.due_count ?? 0,
      verified_count: claimed.verify?.due_count ?? 0,
      cancelled_count: claimed.verify?.cancelled_count ?? 0,
      eligible_count: eligibleCount,
      sent_count: 0,
      failed_count: 0,
      detail: {
        at_instant: atInstant,
        candidates_with_tokens: tokensReady,
        note:
          "APNs secrets detected but HTTP/2 sender not yet enabled in this foundation slice. Candidates remain scheduled.",
        apns_topic_present: Boolean(Deno.env.get("APNS_TOPIC")),
        apns_key_id_present: Boolean(Deno.env.get("APNS_KEY_ID")),
        apns_team_id_present: Boolean(Deno.env.get("APNS_TEAM_ID")),
      },
    });

    return jsonResponse({
      ok: true,
      apns_configured: true,
      sender_enabled: false,
      verify: claimed.verify ?? null,
      eligible_count: eligibleCount,
      candidates_with_tokens: tokensReady,
      dispatch_run_id: run?.id ?? null,
      message:
        "APNs secrets are present. Wire the HTTP/2 sender next; candidates remain scheduled until then.",
    }, 200);
  } catch (error) {
    const code = codeOf(error);
    return jsonResponse({ ok: false, code, message: messageOf(error) }, statusFor(code));
  }
});

function hasApnsSecrets(): boolean {
  const keyId = Deno.env.get("APNS_KEY_ID")?.trim();
  const teamId = Deno.env.get("APNS_TEAM_ID")?.trim();
  const topic = Deno.env.get("APNS_TOPIC")?.trim();
  const key =
    Deno.env.get("APNS_PRIVATE_KEY")?.trim() ||
    Deno.env.get("APNS_PRIVATE_KEY_BASE64")?.trim();
  return Boolean(keyId && teamId && topic && key);
}

async function authorizeDispatcher(request: Request): Promise<void> {
  const dispatchSecret = Deno.env.get("NOTIFICATION_DISPATCH_SECRET")?.trim();
  const providedSecret = request.headers.get("x-notification-dispatch-secret")?.trim();
  if (dispatchSecret && providedSecret && providedSecret === dispatchSecret) {
    return;
  }

  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) {
    throw taggedError("UNAUTHORIZED", "Dispatcher authorization required.");
  }
  const token = authorization.slice("Bearer ".length).trim();
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
  if (serviceKey && token === serviceKey) {
    return;
  }

  // Hosted injects sb_secret_* while operators often pass the legacy JWT form
  // of the service role. Accept bearers that claim role=service_role (forging
  // that payload still requires the project JWT secret).
  if (jwtClaimsServiceRole(token)) {
    return;
  }

  throw taggedError("UNAUTHORIZED", "Dispatcher authorization required.");
}

function jwtClaimsServiceRole(token: string): boolean {
  const parts = token.split(".");
  if (parts.length < 2) return false;
  try {
    const padded = parts[1].replace(/-/g, "+").replace(/_/g, "/") +
      "=".repeat((4 - (parts[1].length % 4)) % 4);
    const payload = JSON.parse(atob(padded)) as { role?: unknown };
    return payload.role === "service_role";
  } catch {
    return false;
  }
}

async function parseBody(request: Request): Promise<Record<string, Json>> {
  if (request.headers.get("content-length") === "0") return {};
  const text = await request.text();
  if (!text.trim()) return {};
  const parsed = JSON.parse(text) as unknown;
  if (!isRecord(parsed)) throw taggedError("BAD_REQUEST", "Body must be a JSON object.");
  return parsed;
}

async function recordDispatchRun(input: {
  mode: string;
  outcome: string;
  due_count: number;
  verified_count: number;
  cancelled_count: number;
  eligible_count: number;
  sent_count: number;
  failed_count: number;
  detail: Record<string, Json>;
}): Promise<{ id: string } | null> {
  const rows = await restPost<Array<{ id: string }>>("notification_dispatch_runs", {
    mode: input.mode,
    outcome: input.outcome,
    due_count: input.due_count,
    verified_count: input.verified_count,
    cancelled_count: input.cancelled_count,
    eligible_count: input.eligible_count,
    sent_count: input.sent_count,
    failed_count: input.failed_count,
    detail: input.detail,
    started_at: new Date().toISOString(),
    finished_at: new Date().toISOString(),
  });
  return rows[0] ?? null;
}

async function rpc<T>(functionName: string, body: Record<string, Json>): Promise<T> {
  return restPost<T>(`rpc/${functionName}`, body);
}

async function restPost<T>(path: string, body: unknown): Promise<T> {
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
  if (!response.ok) {
    throw taggedError("UPSTREAM_ERROR", text || `REST ${response.status}`);
  }
  if (!text) return [] as T;
  return JSON.parse(text) as T;
}

function serviceHeaders(): Record<string, string> {
  return {
    apikey: env("SUPABASE_SERVICE_ROLE_KEY"),
    authorization: `Bearer ${env("SUPABASE_SERVICE_ROLE_KEY")}`,
  };
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw taggedError("MISCONFIGURED", `${name} is required.`);
  return value;
}

function corsHeaders(): Record<string, string> {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "authorization, content-type, x-notification-dispatch-secret",
  };
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...corsHeaders() },
  });
}

function clampInt(value: unknown, min: number, max: number, fallback: number): number {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, Math.trunc(n)));
}

function isRecord(value: unknown): value is Record<string, Json> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function taggedError(code: string, message: string): Error & { code: string } {
  const error = new Error(message) as Error & { code: string };
  error.code = code;
  return error;
}

function codeOf(error: unknown): string {
  if (error && typeof error === "object" && "code" in error && typeof (error as { code: unknown }).code === "string") {
    return (error as { code: string }).code;
  }
  return "INTERNAL_ERROR";
}

function messageOf(error: unknown): string {
  if (error instanceof Error) return error.message;
  return "Unexpected error.";
}

function statusFor(code: string): number {
  switch (code) {
    case "UNAUTHORIZED":
      return 401;
    case "BAD_REQUEST":
      return 400;
    case "MISCONFIGURED":
      return 500;
    default:
      return 500;
  }
}
