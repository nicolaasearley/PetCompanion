# Technical Architecture

**Status:** Draft  
**Version:** 0.1  
**Last updated:** 2026-07-26  
**Related documents:** [Product Requirements Document](00-product-requirements-document.md),
[Data Model](10-data-model.md), [Daily Plan Engine](12-daily-plan-engine.md),
[Information Architecture](05-information-architecture.md),
[Decision Log](13-decision-log.md)

## 1. Purpose

This document defines how PetCompanion will be built and operated: client
platform, backend, authentication, storage, synchronization, notifications,
media, observability, security, and environments. It resolves the open
implementation decisions queued in [Data Model §19](10-data-model.md) far
enough for implementation to begin, and marks the stack selection as a
**Proposed** decision awaiting owner approval in the
[Decision Log](13-decision-log.md).

## 2. Scope

- The private MVP (Slices A–E) for one founding household, built so a public
  release is an operational change (scale, review, policy), not a rewrite.
- Concrete technology recommendations with rationale and alternatives.

### Explicit exclusions

- Public-launch scaling, multi-region, and cost optimization.
- Deferred integrations (wearables, veterinary records, poster OCR, weather).
- CI/CD tool specifics and repository layout (implementation plan concern).

## 3. Architecture principles

1. **The data model is the contract.** The schema, invariants, and
   per-operation conflict rules in [Data Model](10-data-model.md) §13/§18 are
   normative; the stack must be able to enforce them at the data layer.
2. **Server is authoritative; clients are optimistic.** All writes converge on
   the server's per-operation resolution; clients render optimistically and
   reconcile.
3. **The engine is a pure function.** Plan generation is a deterministic,
   side-effect-free package: `(context, catalogue, history) → plan`. Where it
   *runs* is deployment detail; its purity is what makes it scenario-testable
   (engine §31) and portable to the device later.
4. **Authorization lives in the database.** Household tenancy is enforced with
   row-level security, not application-code diligence.
5. **Boring where possible.** One language across client, server, and engine;
   managed services for undifferentiated infrastructure; no microservices.

## 4. Proposed stack (Proposed decision — see Decision Log)

| Layer | Choice | Rationale | Main alternative |
| --- | --- | --- | --- |
| Client | **Native iOS — SwiftUI** (revised 2026-07-26; see Decision Log) | Household is iOS-only; best native polish, accessibility, and platform fit; owner-created Xcode project (deployment target iOS 27) | React Native (original choice; re-opens if an Android caregiver joins) |
| Backend platform | **Supabase (managed Postgres + Auth + Storage + Realtime + Edge Functions)** | Postgres RLS maps 1:1 to the household tenancy decision; auth, storage, and realtime included; trivial to self-host or migrate later since it is plain Postgres | Custom Node/Fastify service + managed Postgres (more control, more to build); Firebase (weaker relational integrity for the invariants) |
| Server language | **TypeScript** (engine + edge functions); **Swift** on the client with generated model types from the shared schema | One server toolchain; native client | — |
| Plan engine | **Pure TypeScript package** `@petcompanion/engine`, run **server-side** in MVP (edge function + scheduled jobs) | Single authoritative plan per household; no per-device drift; server-side generation makes client language irrelevant to the engine | Device-side generation (drift risk, harder idempotency) |
| Push notifications | **APNs** via a server-side sender (Slice D) | iOS-only household | Expo Push (moot after platform revision) |
| Crash/error reporting | **Sentry** (client + functions) | Standard, low-effort | — |
| Product analytics | **First-party `analytics_event` table** in Postgres | Keeps the F14/DM §17 sensitive-data boundary enforceable in one place; a vendor tool can consume the sanitized stream later | PostHog/Amplitude from day one (harder to guarantee exclusions) |

## 5. System overview

```mermaid
flowchart LR
    subgraph Device["Caregiver device (iOS / Android)"]
        App[Expo app<br/>UI + local cache + op queue]
    end
    subgraph Supabase["Supabase project"]
        Auth[Auth<br/>identity + sessions]
        PG[(Postgres<br/>RLS by household)]
        RT[Realtime<br/>household channels]
        Store[(Storage<br/>household media buckets)]
        EF[Edge Functions<br/>writes API · plan engine · jobs]
    end
    Push[Expo Push → APNs / FCM]

    App -- auth flows --> Auth
    App -- reads (RLS) + subscriptions --> PG
    App <-- household updates --- RT
    App -- operation queue (idempotent writes) --> EF
    EF -- invariant-enforcing writes --> PG
    EF -- candidates due --> Push
    App -- upload/download (scoped URLs) --> Store
```

**Read path:** clients read Postgres directly through RLS-protected queries
and subscribe to their household's realtime channel for convergence
(completions appearing on the partner's device, Scenario B).

**Write path:** all mutations go through edge-function endpoints — never
direct table writes — so idempotency keys, invariants, per-operation conflict
rules, audit events, and notification-candidate maintenance are enforced in
exactly one place (DM §13, §18). RLS still applies underneath as
defense-in-depth.

## 6. Client application (native iOS, SwiftUI)

- **Structure:** SwiftUI app (the owner-created Xcode project, iOS 27
  target, file-system-synchronized groups); five-tab navigation per the IA;
  feature modules mirror the IA stacks (Onboarding, Home, Planner, Training,
  Care, Life, Settings) plus `DesignSystem` (tokens/components from doc 09)
  and `Sync` (cache + operation queue).
- **Backend access:** the Supabase Swift SDK for auth, RLS-protected reads,
  and realtime subscriptions; write-path edge functions called through a
  thin typed client. Model types generated from the shared schema.
- **Local cache:** SwiftData (or GRDB/SQLite if SwiftData friction emerges —
  implementation choice) holding the household's synchronized state: current
  + recent plans, occurrences, schedules, records. Fulfills the offline
  floor (US-058): read last-synced plan, queue dispositions and notes.
- **Operation queue:** every mutation is an operation record (type, payload,
  `client_idempotency_key`, `recorded_at`, `effective_at`) persisted
  locally first, rendered optimistically, then flushed FIFO to the writes
  API. Server responses mark ops confirmed/failed; failures surface per
  US-107 (saved / queued / failed — never ambiguous). Authorization is
  re-checked server-side at apply time (Scenario F).
- **State freshness:** last-successful-sync timestamp drives the stale
  indicator (US-106). Realtime events update the cache in place.
- **Client-generated ids** (UUIDv7) for records created offline; server
  validates uniqueness.
- **Secure storage:** session tokens in the Keychain; signing out clears
  protected cache (US-002).

## 7. Backend and data storage

- **Schema:** direct mapping of the [Data Model](10-data-model.md) entities to
  Postgres tables; enumerations as Postgres enums; embedded value objects
  (RecurrenceRule, birth information) as typed JSONB with check constraints on
  shape.
- **Invariants:** every DM §18 invariant becomes a database constraint where
  expressible (unique partial indexes for one-active-membership, one plan per
  pet/day, one effective completion, occurrence keys, dedupe keys; check
  constraints for date relationships) and a write-path check otherwise
  (≥ 1 active owner, archived-pet guards), covered by tests.
- **RLS policies:** `household_id IN (select household_id from memberships
  where user_id = auth.uid() and status = 'active')` as the universal read
  policy; content tables world-readable; user-owned tables self-only. Writes
  are denied to clients entirely on invariant-bearing tables (edge functions
  use the service role), which is what makes the single write path real.
- **Audit:** `audit_event` written transactionally with its triggering
  mutation inside the write path (DM §15).
- **Migrations:** versioned SQL migrations in the repository; schema types
  generated for the client and engine packages.

## 8. Plan engine placement and jobs

- `@petcompanion/engine` implements the ten-step pipeline (engine §11) as a
  pure function over a `GenerationContext` assembled by the caller. Scenario
  fixtures (engine §31, YAML) run against the package directly in CI.
- **Triggers** (engine §10.1–10.2): scheduled job at local-day start per
  household time zone; on-demand generation on first app open of the day;
  regeneration on the meaningful-change events, invoked by the write path
  after the triggering mutation commits. Generation takes an advisory lock
  per (pet, local_date) so concurrent requests coalesce (DM §13).
- **Day-close job:** after local midnight per household: close plans, expire
  recommendations, apply missed-item policy, set needs-attention flags
  (engine §10.4, §17).
- **Materialization:** calendar-based occurrences maintained over the 14-day
  window by the same jobs; `interval_after_completion` next-occurrence
  creation happens in the write path when a completion commits (DM §8.6).

## 9. Notifications pipeline

1. Write path and plan generation maintain `notification_candidate` rows
   (create on schedule/plan changes; cancel on completion, reschedule,
   archival — DM §14).
2. A scheduler function runs every few minutes: selects due candidates,
   re-verifies the pre-delivery checklist (still active, not completed,
   recipient authorized, quiet hours vs. time-sensitive exception, dedupe key
   unsent — engine §21.3–21.4), renders copy per the recipient's lock-screen
   detail preference (US-109), and hands off to Expo Push.
3. Delivery outcomes land in `notification_delivery`; failures and
   suppressions feed the staleness guardrail metrics (F14).
4. Notification payloads carry only routing data (deep-link target ids), never
   health text; the app resolves content after auth (IA §10).

## 10. Media

- Supabase Storage, one bucket, keys prefixed by household; access via
  short-lived signed URLs issued by the write path after authorization —
  never public URLs (F12).
- Client resizes images before upload (long edge cap + quality target defined
  in implementation); EXIF capture time extracted client-side into
  `media.capture_time`, then EXIF GPS stripped before upload (privacy floor).
- Upload lifecycle per DM §12.6: parent record saves first; media rows move
  `pending_upload → available | upload_failed` with per-item retry
  (Scenario H). Removal detaches and schedules storage deletion per retention
  policy.
- Private-MVP limits: photos only (video is P2), 10 MB per upload, soft
  1,000-item household cap with a friendly notice (tunable).

## 11. Authentication and sessions

- Supabase Auth. **MVP methods:** email + password with email verification,
  plus **Sign in with Apple and Google** enabled at the provider so household
  members can choose (resolves the F01 "selected methods" placeholder;
  recovery = provider-standard email reset, US-003).
- Sessions: refresh-token rotation, tokens in secure storage; sign-out and
  account-deletion revoke sessions (US-002, US-004).
- Membership removal takes effect on next authorized request via RLS/write
  path (F02); realtime subscriptions for the household are torn down on the
  next auth check.
- Invitations: the share token is generated server-side, stored hashed
  (DM §7.4), redeemed through an authenticated edge function that atomically
  creates the membership.

## 12. Security and privacy

- TLS everywhere; at-rest encryption via the managed platform; no additional
  field-level encryption in the private MVP (revisit at public release —
  DM §19.9).
- Secrets in platform secret storage; no secrets in the repository or client.
- The client never holds another household's data by construction (RLS) and
  never caches across sign-outs.
- Data lifecycle behaviors (export, account deletion, pet deletion, household
  close, retention windows) implement F13/US-103/US-104; concrete retention
  numbers are set in the privacy policy work before public release
  (placeholder defaults for the private MVP: 30-day tombstone sync window,
  30-day purge delay after household close).
- Analytics events are validated against an allowlist schema at write time so
  DM §17 exclusions are structurally enforced, not conventions.

## 13. Observability

- **Diagnostics (separate from analytics, F14):** structured logs in edge
  functions with request ids; Sentry on client and functions; guardrail
  dashboards from the first-party tables — duplicate plan items, stale
  notifications, sync-conflict rate, suppressed deliveries (engine §29.3).
- **Scenario suite in CI:** engine fixtures, recurrence/DST/leap-day cases,
  idempotency and convergence tests (engine §27, §30.18) run on every change
  to the engine or write path.

## 14. Environments and delivery

- **Environments:** `dev` (local Supabase + simulators) and `prod` (the
  founding household). A `staging` environment is added before any external
  beta.
- **Distribution:** TestFlight for the private MVP (iOS-only per the revised
  platform decision).
- **Delivery order = release slices A–E**, each ending with its proof
  demonstrated on real devices with both caregivers' accounts.

## 15. Open questions

1. ~~Minimum OS versions.~~ **Resolved 2026-07-26:** iOS-only; the Xcode
   project targets iOS 27 (acceptable for a two-device household; lower only
   if a caregiver's device requires it).
2. Whether Realtime subscriptions cover all convergence needs or a periodic
   pull remains as fallback (recommend keeping a 60-second foreground pull as
   belt-and-braces in MVP).
3. Export format specifics (JSON archive + media manifest) — design with
   US-103 before Slice E.
4. Whether the write path is one edge function with a command router or a
   function per command family (implementation taste; no product impact).

## 16. Validation criteria

This architecture is validated when:

1. Every DM §19 deferred decision has either a resolution here or an explicit
   open question above.
2. A walking skeleton exists: sign-in → household → pet → server-generated
   plan → optimistic completion → convergence on a second device — the
   Slice A/B spine on real hardware.
3. The engine package passes the scenario fixtures with no database access.
4. RLS tests prove cross-household isolation for every table (attempted reads
   and writes as a non-member fail).
5. A simulated offline day (complete, note, partner completes same item)
   replays to the documented convergence outcome (Scenarios B, C, F).
