# Wireframes — Onboarding and Home

**Status:** Draft  
**Version:** 0.1  
**Last updated:** 2026-07-26  
**Related documents:** [Information Architecture](05-information-architecture.md),
[Daily Plan Engine](12-daily-plan-engine.md), [Core Features](03-core-features.md),
[User Stories](04-user-stories.md), [UI Design System](09-ui-design-system.md)

## 1. Purpose

Low-fidelity, annotated wireframes for the onboarding stack (ON-01–ON-09) and
the Home stack (HM-01–HM-04), covering Slices A–B plus the pre-arrival variant
now in Slice A. These are structural blueprints for visual design and
implementation: every region, action, and state is specified; visual styling,
exact spacing, and final copy belong to the
[UI Design System](09-ui-design-system.md) and content design.

## 2. Scope

- All onboarding screens and the four Home-stack screens from the
  [IA screen inventory](05-information-architecture.md).
- Home variants: pre-arrival, post-arrival normal, busy/essentials, needs
  attention, empty, offline/stale.
- Annotations for actions, states, accessibility, and traceability.

### Explicit exclusions

- Planner, Training, Care, Life, and Settings wireframes (next batch).
- Visual design tokens, iconography, illustration, final microcopy.
- Tablet and landscape layouts.

## 3. Conventions

- Frames are portrait phone screens. `[ ]` marks a tappable control; `( )`
  marks a radio/choice; `⋯` marks content continuing.
- Every frame lists: **Actions** (primary first), **States**, **A11y**,
  **Traces** (features/stories).
- The wireframes assume the accepted five-tab navigation; the tab bar appears
  only on HM-01 (`▣ Home ▢ Planner ▢ Training ▢ Care ▢ Life`).

## 4. Onboarding stack

Onboarding is a linear stack with a progress affordance from ON-06 onward
("Step 1 of 3": household → pet → routine). Every optional step has a visible
skip. Back never loses entered data within the session.

### ON-01 — Welcome

```text
┌─────────────────────────────┐
│                             │
│        (brand mark)         │
│                             │
│   Raising a puppy,          │
│   one day at a time.        │
│                             │
│   A shared daily plan for   │
│   your household — what     │
│   matters today, what's     │
│   done, what's next.        │
│                             │
│  [ Get started ]            │  ← primary
│  [ I have an account ]      │  ← secondary → ON-03
│                             │
│  Joining someone? Open      │
│  your invitation link.      │  ← informational only
└─────────────────────────────┘
```

- **Actions:** Get started → ON-02; I have an account → ON-03. Opening an
  invitation link at any time routes to ON-05 after auth.
- **States:** none (static). Offline: both actions available; auth calls fail
  gracefully on the next screen with retry.
- **A11y:** logo has no announced role; headline is the page heading; buttons
  ≥ platform minimum target.
- **Traces:** F01, US-001, US-002.

### ON-02 — Create account / ON-03 — Sign in / ON-04 — Recovery

One shared structure; fields depend on the chosen identity method
(Technical Architecture decision):

```text
┌─────────────────────────────┐
│ ‹ Back                      │
│  Create your account        │   (ON-03: "Welcome back")
│                             │
│  Each caregiver gets their  │
│  own account — no shared    │
│  passwords.                 │
│                             │
│  [ Continue with <method> ] │   ← identity-provider methods,
│  [ Continue with email    ] │     stacked, per tech architecture
│                             │
│  ── error region ──         │   ← inline, non-destructive
│                             │
│  ON-03 only:                │
│  [ Can't sign in? ]         │   → ON-04
└─────────────────────────────┘
```

- **Actions:** authenticate → route: pending invitation → ON-05; existing
  household → HM-01; otherwise → ON-06.
- **States:** submitting (buttons disabled, progress inline); error (invalid
  credentials, account exists, network unavailable — retained input, specific
  copy, retry); ON-04 confirmation state does not reveal whether an account
  exists beyond what the provider safely permits.
- **A11y:** errors announced via live region and focus moved to the error;
  fields labeled; no timeout that discards input.
- **Traces:** F01; US-001–US-003.

### ON-05 — Invitation review

```text
┌─────────────────────────────┐
│  You're invited             │
│                             │
│  ┌───────────────────────┐  │
│  │ (household icon)      │  │
│  │ Earley Household      │  │  ← household name only
│  │ Invited by Nic        │  │  ← inviter display name only
│  │ Expires in 6 days     │  │
│  └───────────────────────┘  │
│                             │
│  You'll see and share this  │
│  household's pets, plans,   │
│  and records.               │  ← visibility explanation (US-102)
│                             │
│  [ Accept invitation ]      │
│  [ Decline ]                │
└─────────────────────────────┘
```

- **Actions:** Accept → membership created → HM-01 (shared plan, active pet
  context set). Decline → confirmation → ON-01 or the user's own household.
- **States:** expired / revoked / already used → explanatory full-frame state,
  no household data, no error styling blame; already-a-member → routed to
  HM-01 with a notice.
- **A11y:** card content read as one group; accept/decline reachable in order.
- **Traces:** F02; US-012; Scenario F copy rules.

### ON-06 — Create household

```text
┌─────────────────────────────┐
│ ‹ Back        Step 1 of 3   │
│  Name your household        │
│                             │
│  Household name             │
│  [ Earley Household      ]  │  ← prefilled suggestion, editable
│                             │
│  Time zone                  │
│  [ Europe/Stockholm      ▾] │  ← detected default, explicit,
│                             │     confirmable (US-010)
│  Plans and reminders use    │
│  this time zone.            │
│                             │
│  [ Continue ]               │
└─────────────────────────────┘
```

- **States:** creation retry is idempotent (no duplicate membership, US-010);
  offline → queued-not-available explanation (account/household creation
  requires connectivity in MVP).
- **Traces:** F02; US-010.

### ON-07 — Add your puppy

```text
┌─────────────────────────────┐
│ ‹ Back        Step 2 of 3   │
│  Tell us about your puppy   │
│                             │
│  Name        [ Maple      ] │
│                             │
│  Birth date                 │
│  (•) Exact   [ 2026-05-30 ] │
│  ( ) Not sure — estimate    │
│        [ about 8 ] weeks    │  ← estimate stores age + today
│        old as of today      │     as reference (DM §8.2)
│                             │
│  Is Maple home yet?         │
│  ( ) Home with us           │
│  (•) Coming home [2026-08-08]│ ← optional homecoming date
│                             │
│  [ Continue ]               │
│  [ Add details later ]      │  ← photo, breed, sex, etc. → CA-02
└─────────────────────────────┘
```

- **Actions:** Continue validates dates (homecoming ≥ birth when both exact;
  no future birth date) with inline explanations before save (US-023).
- **States:** the form is completable with name + birth info only (US-020);
  estimate path shows qualified language preview ("We'll say 'about 8
  weeks'"). No health or breed questions here — ever (F03).
- **A11y:** radio semantics for exact/estimate and home/coming-home; date
  pickers operable by screen reader; validation announced.
- **Traces:** F03; US-020, US-021, US-022.

### ON-08 — Routine basics (optional)

```text
┌─────────────────────────────┐
│ ‹ Back        Step 3 of 3   │
│  When does your day run?    │
│                             │
│  We use broad windows — no  │
│  exact times needed.        │
│                             │
│  Morning   [ 6–9  ▾]        │
│  Midday    [ 11–13 ▾]       │
│  Evening   [ 17–21 ▾]       │
│  Sleep     [ 22–6  ▾]       │
│                             │
│  Meals per day  [ 3 ▾]      │  ← from stage-appropriate template
│                             │
│  [ Looks right ]            │
│  [ Skip — use defaults ]    │
└─────────────────────────────┘
```

- **States:** skipping applies reviewed defaults for the pet's stage
  (engine §19.3); pre-arrival households see a note that routines activate at
  homecoming.
- **Traces:** F13; US-100.

### ON-09 — Notification primer (optional, deferred to Slice D)

```text
┌─────────────────────────────┐
│  One quiet summary a day    │
│                             │
│  A morning summary and the  │
│  reminders you choose.      │
│  No noise, no guilt.        │
│                             │
│  [ Enable notifications ]   │  → platform prompt
│  [ Not now ]                │  → app remains fully usable
└─────────────────────────────┘
```

- **States:** denial recorded; no repeated prompting (US-085); reminders stay
  visible in-app.
- **Traces:** F11; US-082, US-085.

### Onboarding exit

Landing is always HM-01 with the first generated plan — pre-arrival variant
when homecoming is in the future (Scenario A; Slice A proof).

## 5. Home stack

### HM-01 — Daily Plan, post-arrival normal day

```text
┌─────────────────────────────┐
│ (🐕) Maple ▾   12 wks ·     │ ← pet header; "▾" only when >1 pet
│      Foundations ›     (👤) │ ← stage chip → HM-06; avatar → ST-01
│  Good morning, Sarah        │
│  ⟳ updated 2 min ago        │ ← sync line ONLY when stale/queued
├─────────────────────────────┤
│  NEEDS ATTENTION            │ ← section hidden when empty
│  ┌─▲─────────────────────┐  │
│  │ Medication · was 8:00 │  │
│  │ From Maple's care     │  │
│  │ record        [Open ›]│  │ → HM-02; no dose advice
│  └───────────────────────┘  │
│  TODAY                      │
│  Morning                    │ ← window group headers
│  ┌───────────────────────┐  │
│  │ ✓ Breakfast           │  │ ← completed inline…
│  │   by Sarah, 7:42 AM   │  │   …moves to Completed on refresh
│  ├───────────────────────┤  │
│  │ ◻ Potty routine       │  │ ← tap row = HM-02; tap ◻ = complete
│  └───────────────────────┘  │
│  Evening                    │
│  ┌───────────────────────┐  │
│  │ ◻ Evening meal        │  │
│  └───────────────────────┘  │
│  RECOMMENDED       [Adjust] │ ← Adjust → HM-04 capacity
│  ┌───────────────────────┐  │
│  │ Practice name response│  │
│  │ Training · ~3 min     │  │ ← category + effort band
│  │ Why this? ›           │  │ → HM-03
│  ├───────────────────────┤  │
│  │ Observe one new       │  │
│  │ environment           │  │
│  │ Socialization · ~5 min│  │
│  └───────────────────────┘  │
│  [ Another idea ]           │ ← replacement (US-038), stays
│                             │   within budget
│  COMING UP                  │
│  · Vet appointment          │
│    Fri 2:00 PM            › │ → PL-04
│  · Bring health records     │
│    prepare by Thu         › │
│  COMPLETED (2)            ▾ │ ← collapsed; expand for list,
│                             │   undo, notes (US-033)
├─────────────────────────────┤
│  ▣ Home ▢ Planner ▢ Training│
│        ▢ Care ▢ Life    (+) │ ← (+) = GL-01 quick add
└─────────────────────────────┘
```

- **Actions:** complete (checkbox), open item (row → HM-02), Why this?
  (→ HM-03), Another idea (replace within budget), Adjust (→ HM-04), expand
  Completed, undo from Completed, quick add (GL-01), stage chip (→ HM-06),
  avatar (→ ST-01).
- **Section order is fixed** per engine §6; empty sections are hidden; at most
  3 recommendation cards (Normal). Completing never grows the plan
  (engine §10.3).
- **A11y:** each section header is a heading; checkbox and row are separate
  accessible targets; completion announced ("Breakfast completed");
  obligation class conveyed by section + label, never color alone.
- **Traces:** F04–F06; US-030–US-041, US-108; engine §6, §13.

### HM-01 — Pre-arrival variant (Slice A)

```text
┌─────────────────────────────┐
│ (🐾) Maple ▾           (👤) │
│  Coming home in 13 days     │ ← countdown replaces age/stage line
│  Getting ready together     │
├─────────────────────────────┤
│  TODAY                      │
│  ┌───────────────────────┐  │
│  │ ◻ Confirm first vet   │  │
│  │   appointment         │  │ ← household-scheduled
│  ├───────────────────────┤  │
│  │ ◻ Secure electrical   │  │
│  │   cords               │  │ ← preparation checklist
│  └───────────────────────┘  │
│  RECOMMENDED                │
│  ┌───────────────────────┐  │
│  │ Choose the first-night│  │
│  │ sleeping setup        │  │
│  │ Preparation · ~10 min │  │
│  │ Why this? ›           │  │ "Homecoming is 13 days away"
│  └───────────────────────┘  │
│  COMING UP                  │
│  · Maple comes home —       │
│    Aug 8                  › │
│  · First vet visit —        │
│    Aug 11                 › │
├─────────────────────────────┤
│  ▣ Home ▢ Planner ▢ Training│
│        ▢ Care ▢ Life    (+) │
└─────────────────────────────┘
```

- **Rules:** no feeding/potty/routine items appear unless manually scheduled
  (engine §26.1); preparation recommendations key off the homecoming date. On
  the homecoming local date, first open shows a one-time transition moment:
  "Maple is home! Set up your daily routine" → re-entrant ON-08 content, then
  the post-arrival plan.
- **Traces:** US-022; engine §26.1; IA §14; pre-arrival Decision Log entry.

### HM-01 — Reduced-capacity, empty, and degraded variants

| Variant | Differences from normal |
| --- | --- |
| **Busy day** | "Busy day" pill next to Adjust; Recommended shows ≤ 1 card (engine §13.1) |
| **Essentials only** | Pill shown; Recommended section hidden entirely; required + scheduled untouched |
| **All caught up (empty)** | Calm success illustration + "You're all caught up. Add something to the plan or enjoy the day together." + [Add a task] [Browse ideas]; no error styling (US-108, engine §25.2) |
| **Recommendations unavailable** | Today/Coming up render from saved data; Recommended hidden; no user-facing error (engine §25.3) |
| **Offline / stale** | Header sync line: "Showing last synced plan — 9:14 AM"; queued items badge "queued"; completed-by-partner claims suppressed (US-058, US-106) |
| **Insufficient profile** | Obligations render; one inline prompt card asks for the single smallest missing input (engine §25.1) |

### HM-02 — Plan item detail

```text
┌─────────────────────────────┐
│ ‹ Back                      │
│  Potty routine              │
│  Routine · Scheduled        │ ← category · obligation class
│  Today, morning window      │
│  For: anyone                │ ← assignment (US-052)
│                             │
│  From your household        │
│  routine ›                  │ ← source/origin, tappable to
│                             │   owning schedule (US-031)
│  ── notes (household) ──    │
│  "Went right away" — Nic    │
│                             │
│  [ Mark complete ]          │ ← primary
│  [ Snooze ] [ Reschedule ]  │
│  [ Skip ]                   │ ← optional items: frictionless;
│                             │   required: source-appropriate
│                             │   confirmation (engine §16.3)
└─────────────────────────────┘
```

**Medication variant (US-072)** — differences:

- Header shows pet photo + name prominently (clear pet identity).
- A "Last given" block sits above the primary action:
  `Last given: today 8:03 AM by Nic` — with a prominent notice when that was
  within the current due window ("Recently completed — still mark again?").
- Dose shown exactly as entered; source: "From Maple's medication record ›".
- Missed state: original due time retained, neutral copy, provider contact
  shown when recorded (US-073); never dose advice.
- **A11y:** last-given notice announced before the action button in focus
  order.
- **Traces:** F05, F10; US-032–US-035, US-053, US-054, US-072, US-073.

### HM-03 — "Why this?" sheet

```text
┌─────────────────────────────┐
│  Why recall practice?       │
│                             │
│  Recall is part of Maple's  │
│  foundations stage, and the │
│  last session was 4 days    │
│  ago.                       │ ← stored explanation text
│  Takes about 5 minutes.     │ ← effort band
│                             │
│  [ Swap for another idea ]  │
│  [ Pause suggestions like   │
│    this ]                   │
│  [ Done ]                   │
└─────────────────────────────┘
```

- No numeric scores, ever (US-037). Pause writes a PetPreference /
  SocializationExclusion as appropriate.
- **Traces:** F04; US-037, US-038; engine §20.

### HM-04 — Capacity sheet

```text
┌─────────────────────────────┐
│  How much can today hold?   │
│                             │
│  (•) Normal — up to 3 ideas │
│  ( ) Busy — 1 short idea    │
│  ( ) Essentials only —      │
│      just the must-dos      │
│                             │
│  Apply to:                  │
│  (•) Just today             │
│  ( ) Every day (default)    │
│                             │
│  [ Apply ]                  │
└─────────────────────────────┘
```

- Applying triggers meaningful regeneration (engine §10.2); required and
  scheduled items are visibly unaffected. Custom mode intentionally absent
  (IA §18.2).
- **Traces:** F04; US-036; engine §13.1.

## 6. Cross-cutting interaction rules

1. **Complete is one tap** from HM-01; everything else is at most two.
2. Undo is available immediately after completion (inline confirmation with
   undo affordance) and later via Completed (US-033).
3. Optimistic UI everywhere: actions render instantly, queue when offline, and
   resolve to saved/queued/failed — never ambiguous (US-107).
4. No red/error styling for normal life events (skips, busy days, empty days);
   error styling is reserved for actual failures.
5. Every screen in this document renders meaningfully with cached data and no
   network, except account/household creation.

## 7. Open questions

1. Complete affordance: checkbox tap vs swipe-to-complete (or both) — decide
   in visual design with an accessibility-first default (checkbox).
2. Whether "Another idea" lives at section level (as drawn) or per-card —
   prototype test.
3. The homecoming transition moment's exact form (full-screen vs inline
   card) — content design.
4. Greeting personalization ("Good morning, Sarah") — confirm it doesn't
   conflict with shared-device use.

## 8. Validation criteria

1. Every ON/HM screen state in IA §15 has a drawn or tabulated treatment here.
2. A design tool mockup can be produced for Slices A–B without asking any
   structural question not answered in this document or the IA.
3. Scenario A (first value) and the Slice A proof are traversable frame by
   frame, in both pre- and post-arrival forms.
4. The medication detail variant satisfies US-072/US-073 acceptance criteria
   before usability testing refines the interaction.
