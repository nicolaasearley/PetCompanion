# PetCompanion Supabase Backend

This directory contains the Slice A backend foundation: local Supabase config,
schema migrations, content seed data, and the `write-path` / `generate-plan`
Edge Functions.

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

Build the dependency-free engine bundle and serve plan generation:

```sh
cd packages/engine
npm run bundle:edge
cd ../..
supabase functions serve generate-plan --env-file supabase/.env.local
```

Authenticated generation request:

```sh
curl -X POST http://127.0.0.1:54321/functions/v1/generate-plan \
  -H "Authorization: Bearer <user-access-token>" \
  -H "Content-Type: application/json" \
  -d '{"pet_id":"<pet-uuid>","force":false}'
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

Implemented write-path commands:

- `create_household`
- `create_pet`
- `set_routine_preferences`
- `create_task`
- `complete_occurrence`
- `undo_completion`
- `skip_item`

## Manual day close

WP-4 intentionally leaves scheduling/`pg_cron` wiring out of scope. Invoke
day close with the service role after a household-local day ends:

```sh
curl -X POST "$SUPABASE_URL/rest/v1/rpc/close_plans_for_date" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"target_date":"2026-07-26"}'
```

This expires still-planned recommendations and then closes every open plan for
the supplied local date. Required occurrences are not auto-dismissed, and
needs-attention remains a presentation-side derivation.

## Checks

When Docker and the Supabase CLI are available, apply migrations through the
normal deployment workflow. The repository test workflow is:

```sh
export PATH="$HOME/.local/bin:$PATH"
bash supabase/tests/run.sh
```

Verify the pure engine and regenerate the function-local bundle:

```sh
cd packages/engine
npm run typecheck
npm test
npm run bundle:edge
```
