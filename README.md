# PetCompanion

PetCompanion brings personalized guidance and coordination for puppy owners into one calm, time-centric experience. Rather than fragmenting guidance across websites, videos, calendars, and conversations, it consolidates what matters today, what comes next, and how the puppy is progressing. It is an operating system for pet ownership, with the first release purpose-built for new puppy owners in a shared household. This is a private MVP for one founding household.

## Repository Layout

- **docs/** — living specifications for product, design, and technical decisions. See [docs/README.md](docs/README.md) for the index.
- **PetCompanion/** — native SwiftUI iOS app; Xcode 27 project with target iOS 27.
- **supabase/** — Postgres migrations, seed data, and edge functions for the backend.
- **packages/** — TypeScript packages: `engine` (deterministic daily-plan generator) and `write-path` (command envelope types).

## Tech Stack

- **Client:** Native iOS, SwiftUI. The Supabase Swift SDK handles auth, RLS-protected reads, and realtime subscriptions. Local cache via SwiftData with operation queue for offline mutations.
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

From the repository root, start the local Supabase stack:

```sh
supabase start
supabase db reset
```

The `db reset` command applies all migrations in `supabase/migrations/` and runs the seed in `supabase/seed.sql`. The Docker daemon must be running. Note: Docker CLI lives at `~/.local/bin` on this machine if not in your PATH.

## Current Status

Slice A — foundational MVP scope — is in progress. See [docs/17-implementation-plan-slice-a.md](docs/17-implementation-plan-slice-a.md) for the work scope and implementation sequence. Material product and architecture decisions are logged in [docs/13-decision-log.md](docs/13-decision-log.md).
