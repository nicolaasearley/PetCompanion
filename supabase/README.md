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
supabase functions serve write-path
```

Build the dependency-free engine bundle and serve plan generation:

```sh
cd packages/engine
npm install
npm run bundle:edge
cd ../..
supabase functions serve generate-plan
```

Serving either function starts the local runtime for both configured functions.
The Supabase CLI supplies local project credentials automatically.

Authenticated generation request:

```sh
curl -X POST http://127.0.0.1:54321/functions/v1/generate-plan \
  -H "Authorization: Bearer <user-access-token>" \
  -H "Content-Type: application/json" \
  -d '{"pet_id":"<pet-uuid>","force":false}'
```

The first open plan for a pet/local date is stable: passive requests return
the persisted plan without changing its recommendation set or version. Send
`"force": true` for an explicit refresh, or a `capacity_override` for a
user-initiated one-day capacity change.

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
- `set_default_capacity`
- `create_task`
- `accept_recommendation`
- `complete_occurrence`
- `undo_completion`
- `skip_item`

`set_routine_preferences` accepts the iOS routine shape (`start_hour`,
`end_hour`, `meals_per_day`), normalizes it, and atomically supersedes the
household's managed daily meal, potty, and wind-down schedules.

`accept_recommendation` promotes a recommendation into the same
TaskDefinition → TaskSchedule → TaskOccurrence model as every other task. Its
payload is:

```json
{
  "plan_item_id": "<uuid>",
  "complete": true,
  "pinned": false,
  "note": "optional"
}
```

## Day close

Every plan-generation request invokes timezone-aware elapsed-plan cleanup.
Hosted deployments may additionally schedule the same idempotent RPC:

```sh
curl -X POST "$SUPABASE_URL/rest/v1/rpc/close_elapsed_plans" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"at_instant":"2026-07-27T04:00:00Z"}'
```

This expires still-planned recommendations and closes each open plan only
after midnight in its own `time_zone_snapshot`. Required occurrences are not
auto-dismissed.

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
npm install
npm run typecheck
npm test
npm run bundle:edge
cd ../write-path
npm install
npm run typecheck
```
