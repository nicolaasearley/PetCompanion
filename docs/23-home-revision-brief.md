# Home Revision Brief

**Status:** Ready to implement
**Created:** 2026-07-30
**Owner note:** written for an implementing agent. Read `docs/22-handoff.md`
first, especially §6 (traps). `PRODUCT.md` and `docs/09-ui-design-system.md`
outrank this document.

## 1. The problem, in the owner's words

> The idea of this app is to help keep pet owners organized and keep track of
> important details and tasks, and right now it feels like a nuisance or almost
> a job to have to use the app. Users are already going to be tired and
> exhausted from raising a new puppy and the last thing they are going to want
> to do is open the app and check off a bunch of things for basic daily tasks
> like morning feedings.

This is not a styling complaint. **The Home screen currently generates work
instead of reducing it**, which inverts the product's purpose and contradicts
its own written principles:

- `PRODUCT.md` — "Today first. Make the next useful action and its context
  immediately understandable"; anti-references explicitly reject "a generic
  reminder app" and "overfilled dashboards".
- `docs/12-daily-plan-engine.md` §4 — "**a plan is not a backlog**".

Treat "does this reduce or create work for an exhausted owner at 6am?" as the
acceptance test for every decision below.

## 2. Confirmed defects — fix these before any restyling

These are real bugs visible in the owner's screenshot. Do not paper over them
with layout changes.

**2.1 Task titles are catalogue descriptions.** Verified in `supabase/seed.sql`:
the `task_definitions` row for `routine.meals_young_puppy` has the title
`"3 meals/day in morning, midday, evening windows"`. That string is rendered
verbatim as a plan item title, so every meal on Home reads as a policy
statement rather than a task. `routine.potty_young` has the same shape
("Potty opportunities: after each meal, after play, before sleep").

An occurrence needs a short imperative title — "Breakfast", "Midday meal",
"Dinner", "Potty break". The catalogue description belongs in detail or
guidance copy, not the row.

Decide deliberately where to fix this and say which you chose: a new seeded
title field, per-occurrence `title_override` set at routine rebuild
(`write_path_rebuild_routine_schedules`), or client-side mapping. Prefer the
data layer — the same wrong title will otherwise appear in Planner,
notifications and history. Note the window each occurrence belongs to is
already known, so "Breakfast/Midday meal/Dinner" is derivable.

**2.2 Items appear duplicated.** The screenshot shows two identical
"3 meals/day…" rows and two "Morning Walk" rows in the same Morning group.
Diagnose before fixing — do not de-duplicate in the view. Likely candidates:
`write_path_rebuild_routine_schedules` having run more than once and left two
live schedules, or two occurrences materialised into the same window. Query the
household's `task_schedules` and `task_occurrences` and report what you find.
If there genuinely are duplicate schedules, that is a write-path bug with data
implications, not a UI bug.

**2.3 The same item appears twice on one screen.** "Test meds" is in both
Upcoming Care and Needs Attention. One item should occupy one place. Needs
Attention should win when both apply.

**2.4 The greeting renders an email-derived name.** "Good morning,
Nicolaasearley" comes from `MockBackend.displayName(fromEmail:)`-style
derivation. Use a real display name, a first name only, or drop the name.
Never show a mangled email local-part to a user.

## 3. Design direction

Reference screenshots supplied by the owner show: grouped time-of-day sections,
compact rows with small leading icons, real time ranges, and richer treatment
reserved for genuinely significant items (a vet appointment with a map, a
distinct card for a recommendation). Follow that spirit, not the pixels.

**3.1 Weight the item to the task.** A potty break and an annual wellness exam
must not render identically. Small routine items get compact rows; significant
items (appointments, medication, anything in Needs Attention) earn a card with
context and a direct action button.

**3.2 Collapse routine micro-tasks into one grouped row.** This is the core
move and the direct answer to "such small tasks shouldn't need a full block".
Instead of three meal cards and four potty cards, one row per routine with
inline completion targets:

```
🍽  Meals                     ○ ○ ○
🐾  Potty                   ○ ○ ○ ○
```

Every action stays one tap; seven cards become two rows. Each target still
needs a ≥44pt touch area and its own VoiceOver label ("Breakfast, not
completed"), so this is a layout change, not an accessibility shortcut.

**3.3 Lead with the next action, not the whole day.** Above the fold: Needs
Attention (only when non-empty), then the single next thing due. Everything
else is reachable but not shouted. Recommended and Coming up are already
collapsed by default — keep that.

**3.4 Reduce chrome.** The greeting currently consumes a large block. Compact
the header so real content starts higher.

**3.5 Icons and warmth.** The owner notes the app lacks visual life. Category
SF Symbols already exist; use them consistently and consider a pet photo in the
header. Do not add decorative illustration, gradients, glassmorphism, or
shadows — `DESIGN.md §6` prohibits all of these and one glassmorphism
regression has already been removed once.

## 4. The open product question — ask, do not assume

**Should routine micro-tasks be checkable at all by default?**

The deepest reading of the owner's complaint is that ticking off every potty
break is itself the burden. Options, in increasing boldness:

1. Group them (§3.2) but keep every check.
2. Show routines as *context* ("Meals · 3 today") with checking opt-in per
   household.
3. Default routine tracking off; the plan shows what matters and routines are
   available for households that want them.

This changes what the product *is*, so surface it as a recommendation with a
rationale and let the owner decide. Do not silently pick option 3.

## 5. Hard constraints

These are written into the product and are not style preferences.

- **No streaks, no guilt mechanics, no unexplained scores, no caregiver
  comparison** (`PRODUCT.md`). A neutral "2 remaining" is fine; "3 of 8 done"
  read as a performance measure is not. Never colour a low completion count as
  failure.
- **Never carry state by colour alone.** Every state needs text or a symbol too.
- **Dynamic Type through `accessibility-extra-extra-extra-large`**, both
  appearances, and ≥44pt touch targets. The app failed this once and was fixed;
  do not regress it. Verify with the XCUITest harness
  (`PetCompanion/PetCompanionUITests/README.md`) — note its documented traps:
  appearance is a device setting, and text size must come from the test method,
  not an environment variable.
- **Honest states.** Loading, empty, offline, stale, queued and error must each
  say something true and specific. A queued write must never look like success.
  The offline-actionable behaviour was just fixed; keep it.
- **All mutations go through the write path.** Never add a client write to an
  invariant-bearing table.
- **Health boundaries.** Medication copy stays neutral and never advises on a
  missed dose.

## 6. Verification

- iOS unit suite (**228 passing** at time of writing) must stay green, with
  tests added for new grouping/derivation logic.
- If you touch `packages/engine`, run its fixtures and re-run
  `npm run bundle:edge` — a stale `supabase/functions/_shared/engine.mjs` is a
  known silent trap.
- If you touch SQL, run `bash supabase/tests/run.sh` (20 suites) against a
  fresh `supabase db reset`.
- Capture Home before and after at default and AX5, in light and dark, and read
  the screenshots rather than asserting the layout is fine.
- Commit incrementally. This project has repeatedly lost uncommitted work to
  session limits.

## 7. Out of scope

Do not redesign Planner, Training, Care or Life in this pass. Do not rename the
app, change the bundle id, or touch the `petcompanion://` scheme. Do not enable
`rule.growth_photo`.
