# PetCompanion Supabase Backend

This directory contains the Slice A backend foundation: local Supabase config,
schema migrations, content seed data, and the `write-path` Edge Function.

## Prerequisites

1. Install Docker Desktop and make sure the Docker daemon is running.
2. Install the Supabase CLI without adding project-local generated files:
   ```sh
   brew install supabase/tap/supabase
   ```
3. From the repository root:
   ```sh
   cd /Users/nic/Appdev/PetCompanion
   ```

## Local Database

Start Supabase:

```sh
supabase start
```

Apply migrations and seed data:

```sh
supabase db reset
```

`db reset` applies `supabase/migrations/*.sql` and then runs
`supabase/seed.sql` because `config.toml` has seeding enabled.

## Edge Function

Serve the write path locally:

```sh
supabase functions serve write-path --env-file supabase/.env.local
```

The function expects:

```sh
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_ANON_KEY=<local anon key from supabase start>
SUPABASE_SERVICE_ROLE_KEY=<local service role key from supabase start>
```

Request envelope:

```json
{
  "command": "create_household",
  "payload": {
    "name": "Maple House",
    "time_zone": "America/Toronto"
  },
  "client_idempotency_key": "client-generated-uuid",
  "recorded_at": "2026-07-26T20:00:00Z"
}
```

Implemented commands:

- `create_household`
- `create_pet`

Stubbed commands return `NOT_IMPLEMENTED` through the real auth and
idempotency plumbing:

- `set_routine_preferences`
- `create_task`
- `complete_occurrence`
- `undo_completion`
- `skip_item`

## Checks

When Docker and the Supabase CLI are available:

```sh
supabase db reset
supabase functions serve write-path --env-file supabase/.env.local
```

Typecheck the shared command types and Edge Function:

```sh
cd packages/write-path
npx tsc --noEmit
```

This environment did not have Docker, `supabase`, `psql`, or `deno`
installed, so database execution checks could not be run here.
