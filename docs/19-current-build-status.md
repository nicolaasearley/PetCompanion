# Current Build Status

**Status:** Superseded
**Checkpoint:** 2026-07-29
**Canonical status:** [`docs/22-handoff.md`](22-handoff.md) §2 (“Where things stand”) and §7 (open gaps)

This file previously tracked the 2026-07-27 Slice B checkpoint. The large
2026-07-29 uncommitted landing outgrew the lists below (Care records, Life
milestones + photos, Events + US-086, Planner PL-01 agenda, Training passport
hero / honest progress bar, ON-04 recovery, engine cooldown + `event_prep_vet`,
Realtime plan reconciliation, APNs foundation, CI, localization foundation).
**Do not use the “Deliberately remaining” or “Verified” counts in older
revisions of this file as current truth** — several items listed as remaining
there are now shipped, and the pass counts were never re-verified for this
batch.

For product posture, architecture traps, and what is still honestly not built,
read `docs/22-handoff.md`. For hosted deploy steps, read
`docs/21-hosted-supabase-deployment.md`.

## Local run

Still valid:

1. Start Docker.
2. From the repository root, run `supabase start`.
3. On first setup or when intentionally rebuilding local data, run
   `supabase db reset`.
4. In a second terminal, run `supabase functions serve`.
5. Open `PetCompanion/PetCompanion.xcodeproj`.
6. Run the `PetCompanion` scheme on an iOS 27 simulator.

Debug builds currently set `PC_BACKEND_MODE=hosted` in project settings for
some configurations — confirm the active scheme’s backend mode before assuming
local. Mock mode is opt-in via the `-PetCompanionBackend mock` launch
argument. Release builds require hosted Supabase URL and anonymous-key
configuration and fail visibly when missing.

Backend / TypeScript / SQL checks:

```sh
cd packages/engine && npm test && npm run typecheck
cd packages/write-path && npm run typecheck
bash supabase/tests/run.sh   # 20 SQL suites
```

CI (`.github/workflows/ci.yml`) runs the engine, write-path, and SQL suites on
push/PR when `packages/` or `supabase/` change. iOS unit/UI tests remain
local-only.
