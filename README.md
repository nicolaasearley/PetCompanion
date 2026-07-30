# Settle

**Working product name:** Settle (user-facing). The repository, Xcode target, bundle
identifier (`com.nic.petcompanion`), and URL scheme (`petcompanion://`) remain
**PetCompanion** until a deliberate rename pass.

Settle brings personalized guidance and coordination for puppy owners into one calm, time-centric experience. Rather than fragmenting guidance across websites, videos, calendars, and conversations, it consolidates what matters today, what comes next, and how the puppy is progressing. It is an operating system for pet ownership, with the first release purpose-built for new puppy owners in a shared household. This is a private MVP for one founding household.

## Repository Layout

- **docs/** — living specifications for product, design, and technical decisions. See [docs/README.md](docs/README.md) for the index.
- **PetCompanion/** — native SwiftUI iOS app; Xcode 27 project with target iOS 27.
- **supabase/** — Postgres migrations, seed data, and edge functions for the backend.
- **packages/** — TypeScript packages: `engine` (deterministic daily-plan generator) and `write-path` (command envelope types).

## Tech Stack

- **Client:** Native iOS and SwiftUI. The Supabase Swift SDK handles auth,
  RLS-protected reads, and Edge Function calls. A disk-backed last-known-good
  plan cache, durable account-scoped FIFO mutation queue, and permission-aware
  local reminders are implemented.
- **Backend:** Supabase (managed Postgres, auth, storage, realtime, edge functions). Row-level security enforces household tenancy.
- **Plan Engine:** Pure TypeScript package (`@petcompanion/engine`) run server-side in the MVP via edge functions and scheduled jobs. Single authoritative plan per household; no per-device drift.
- **Server Language:** TypeScript (edge functions, engine package). Swift on the client with generated model types from the schema.

## Getting Started

**For the iOS app:**

Open `PetCompanion/PetCompanion.xcodeproj` in Xcode and run on a simulator or device.

**For the backend:**

Install Docker and the Supabase CLI:

```sh
brew install supabase/tap/supabase
```

From the repository root, start the local Supabase stack. Run `db reset` on
first setup, after migration changes, or when you intentionally want a clean
seeded database; it deletes existing local data.

```sh
supabase start
supabase db reset
```

In a second terminal, serve both Edge Functions:

```sh
supabase functions serve
```

The Docker daemon must be running. The `db reset` command applies all
migrations in `supabase/migrations/` and runs `supabase/seed.sql`.

## Current Status

The local private MVP now builds and runs end to end through Slice B: account
and puppy onboarding, real recurring routines, a persisted Daily Plan,
full Planner task creation and occurrence actions, append-only history,
permission-aware local reminders, visible offline queue state, recommendation
acceptance, capacity changes, quick add, and offline plan fallback. The iOS,
engine, TypeScript, database-isolation, command, generation, and coordination
test suites are green.

See [Current Build Status](docs/19-current-build-status.md) for the exact
implemented boundary and next slices, and
[Implementation Plan — Slice A](docs/17-implementation-plan-slice-a.md) for
the foundation, [Implementation Plan — Slice B](docs/20-implementation-plan-slice-b.md)
for daily coordination, and
[Hosted Supabase Deployment](docs/21-hosted-supabase-deployment.md) for the
next environment handoff. Material product and architecture decisions are
logged in [Decision Log](docs/13-decision-log.md).
