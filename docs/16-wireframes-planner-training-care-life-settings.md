# Wireframes — Planner, Training, Care, Life, Settings

**Status:** Draft  
**Version:** 0.1  
**Last updated:** 2026-07-29
**Related documents:** [Information Architecture](05-information-architecture.md),
[Wireframes — Onboarding and Home](14-wireframes-onboarding-home.md),
[UI Design System](09-ui-design-system.md), [Core Features](03-core-features.md),
[User Stories](04-user-stories.md)

## 1. Purpose and scope

Completes the wireframe coverage of the MVP: the Planner, Training, Care, and
Life tabs, the Settings stack, and the global sheets. Conventions, exclusions,
and the component vocabulary are inherited from
[doc 14](14-wireframes-onboarding-home.md); frames below use its notation and
the design-system components. Screens with conventional structure are
specified as compact tables instead of frames.

## 2. Planner stack

### PL-01 — Calendar (agenda-first)

Updated 2026-07-29: the Planner primary surface is the forward-scrolling
household-local agenda (not a single selected day). Week rail and month jump
remain secondary anchors; occurrence actions, recurrence, and honest
empty/unplanned/offline states are unchanged.

```text
┌─────────────────────────────┐
│  Planner        [Month ▾]   │ ← month jump; agenda is default
│  ◂  This week  ▸            │
├─────────────────────────────┤
│  TODAY · Wed Jul 29         │
│  ┌───────────────────────┐  │
│  │ ◻ Evening meal  🐕Maple│  │ ← occurrence row; pet badge
│  │   Evening window      │  │   only when >1 pet
│  ├───────────────────────┤  │
│  │ ▦ Puppy class 18:30   │  │ ← event row (distinct glyph,
│  │   Community hall     ›│  │   not a checkbox — US-080)
│  └───────────────────────┘  │
│  THU Jul 30                 │
│  · (no items)  [+ Add]      │ ← empty day inline add
│  FRI Jul 31                 │
│  ┌───────────────────────┐  │
│  │ ▦ Vet appointment 14:00│ │
│  │ ◻ Bring health records│  │ ← linked prep task under event
│  └───────────────────────┘  │
│  ⋯ scrolls forward ⋯        │
├─────────────────────────────┤
│  ▢ Home ▣ Planner … Life (+)│
└─────────────────────────────┘
```

- **Actions:** tap occurrence → HM-02; tap event → PL-04; (+) → GL-01;
  Month ▾ → jump grid (dates with item dots); pull past → previous days
  (read-only history). Scrolling near the end extends the forward window.
- **States:** empty week (calm copy + add); offline (cached window, stale
  line); loading skeleton rows.
- **A11y:** day headers are headings; event vs task announced by type.
- **Traces:** F11; US-080; household time zone rules (DM §8).
- **Shipped:** forward agenda window in household time zone (`PlannerStore`
  + `PlannerAgendaGrouping`); week navigator + month jump as secondary
  affordances; inline empty-day add for today/future only.
  **Update 2026-07-29 (US-080):** confirmed household Events attach into the
  visible agenda window via `EventService`; day sections mix event rows
  (kind glyph + chevron, no completion checkbox) with task occurrences;
  tap opens a read-only detail sheet (edit remains Care → Appointments).
  **Update 2026-07-29 (month-grid dots):** month jump uses a custom grid;
  filled dots mark days with tasks and/or confirmed events from the loaded
  window plus the visible/fetchable month (VoiceOver: “Has tasks or events”).
### PL-02 — Task editor (create/edit)

```text
┌─────────────────────────────┐
│  ✕            New task  Save│
│  Title     [ Brush Maple  ] │
│  Pet       [ Maple ▾]       │  ← hidden when 1 pet
│  Date      [ Thu Jul 30  ▾] │
│  Time      (•) Anytime      │
│            ( ) Window [▾]   │
│            ( ) Exact  [__:_]│
│  Repeat    [ Every 3 days ▾]│  ← explicit supported options
│  ┌───────────────────────┐  │
│  │ Repeats every 3 days  │  │  ← human-readable summary
│  │ starting Thu Jul 30   │  │    before save (US-051)
│  └───────────────────────┘  │
│  For       [ Anyone ▾]      │  ← anyone / me / partner
│  Reminder  [ At window ▾]   │
└─────────────────────────────┘
```

- **Edit mode on a recurring task adds the mandatory chooser:**
  `( ) This occurrence only  ( ) This and future` — shown before any change
  is saved (US-054/US-055; schedule split per DM §8.6).
- **States:** validation inline (invalid dates); unsupported recurrence
  patterns are simply not constructible — the option list is the supported
  set (US-051); save conflict (stale revision) surfaces both versions.
- **Traces:** F05; US-050–US-055.

### PL-03 / PL-04 — Event editor and detail (compact spec)

| Aspect | PL-03 Event editor | PL-04 Event detail |
| --- | --- | --- |
| Content | Title, kind (vet/class/grooming/other), pet, date, all-day toggle, time, location text, provider (vet kind), notes, reminder lead times (multi-select) | Event header (kind icon, title, when, where), provider link, linked preparation tasks with live states, reminder summary, map-free location text |
| Primary action | Save | Edit |
| Secondary | Cancel event (confirm; explains prep-task and reminder effects) | Add preparation task; reschedule (→ editor) |
| Key rules | Rescheduling cancels old notification candidates, creates new (US-086 — server `refresh_event_notification_candidates`) | Completed prep stays completed after moves (Scenario G); cancelled event shows struck state, not deletion |
| States | Validation; revision conflict | Event moved/cancelled since notification tap → truthful current state |
| Traces | F11; US-081, US-086 | US-074, US-086 |

- **Shipped (foundation, 2026-07-29):** Event CRUD via write-path; Settings →
  Appointments & events list + editor (kind, pet, date, all-day/time, location,
  notes, reminder lead multi-select). Cancel retains the row; archive
  soft-deletes. Generation context feeds confirmed events into the engine.
  Planner agenda event rows, PL-04 prep-task linkage, and notification
  candidate refresh on reschedule remain follow-ups.

## 3. Training stack

### TR-01 — Training overview

Updated 2026-07-29 (owner-directed hierarchy change): the socialization
passport is promoted from a plain `BROWSE` row to a hero tile leading the
whole screen, above Active goals — its own domain, not a training skill, but
the caregiver action this screen exists to surface first. There is exactly
one entry point to it now; the old `BROWSE` row is removed rather than
duplicated. The tile shows the passport's stable purpose line ("Gentle,
positive, varied — quality beats quantity.") and a chevron, not a live
reading of it — `TrainingView` does not load a `SocializationStore` just to
decorate the tile, so nothing here is a fabricated "current state" (F09; no
score, no ratio, doc 22 §7 truthfulness).

```text
┌─────────────────────────────┐
│  Training        🐕 Maple ▾ │
├─────────────────────────────┤
│  ┌───────────────────────┐  │
│  │ 🐾 Socialization       │  │ ← hero tile, first on screen
│  │    passport            │  │
│  │ Gentle, positive,      │  │
│  │ varied — quality beats │  │
│  │ quantity.          ›   │  │
│  └───────────────────────┘  │
│  ACTIVE GOALS (2)           │
│  ┌───────────────────────┐  │
│  │ Recall                │  │
│  │ Practicing · last     │  │ ← progress state + recency
│  │ session 2 days ago    │  │
│  │ Practicing            │  │ ← owner-reported state bar
│  │ ■ ■ ■ □ □ □           │  │   (discrete steps, NOT %)
│  │ Owner-reported · not  │  │
│  │ a score               │  │
│  │ [ Log session ]       │  │
│  ├───────────────────────┤  │
│  │ Paw handling          │  │
│  │ Reliable at home ·    │  │
│  │ yesterday   [ Log ]   │  │
│  └───────────────────────┘  │
│  SUGGESTED NEXT             │
│  ┌───────────────────────┐  │
│  │ Start "Leave it"      │  │
│  │ Fits the exploration  │  │ ← explanation inline
│  │ stage · prereqs met   │  │
│  └───────────────────────┘  │
│  BROWSE                     │
│  [ Skill catalogue › ]      │
│  RECENT SESSIONS            │
│  · Recall — Nic, Mon ✓ went │
│    well                     │
├─────────────────────────────┤
│  ▢ Home … ▣ Training …      │
└─────────────────────────────┘
```

- **Progress affordance (2026-07-29):** Active goal cards, TR-03, and TR-05
  show a segmented bar driven only by the owner-reported
  `TrainingProgressState` position among F08's continuum. Rejects design-mock
  “Module Completion 60%” and any session-count ratio as a completion score
  (docs/22 §5.2; `PRODUCT.md`). Labels name the state; “Paused” prefixes the
  title without moving the continuum step. Socialization category cards still
  show **no** progress bars (F09).
- **States:** no active goals → suggested starters for the stage; content
  unavailable → cached catalogue + logged history intact; no active pet →
  the passport tile does not render (it has nothing to open — F09 is about
  one puppy's real experiences).
- **Traces:** F08; US-060, US-061, US-063, US-065.

### TR-02 — Skill catalogue (compact spec)

Grouped list by the seven groups; search field; each row: name, effort band,
stage-fit chip, prerequisite state ("needs: name response" when unmet —
row still viewable, start disabled with explanation), review-status badge.
Filter: "fits current stage" toggle (default on). Browsing never schedules
anything (US-060). → TR-03 on tap.

### TR-03 — Skill lesson

```text
┌─────────────────────────────┐
│ ‹ Skills                    │
│  Leave it                   │
│  House manners · ~4 min ·   │
│  2–4×/week                  │
│  ⓘ Seed content — pending   │
│    professional review      │ ← review-status badge (F08)
│  PREREQUISITES              │
│  ✓ Marker word              │
│  BEFORE YOU START           │
│  Trade up, never snatch —   │
│  this game builds trust.    │
│  STEPS                      │
│  1. Close a treat in your   │
│     fist ⋯                  │
│  2. Wait for the pull-away  │
│     moment ⋯                │
│  ⋯                          │
│  COMMON MISTAKES            │
│  · Escalating too fast      │
│  · Snatching the item away  │
│                             │
│  Not started                │ ← owner-reported state bar when
│  ■ □ □ □ □ □                │   a goal exists (not a %)
│  Owner-reported · not a     │
│  score                      │
│  [ Start this goal ]        │ ← or [ Log session ] if active
└─────────────────────────────┘
```

- Start is idempotent (US-061); paused goal shows [ Resume ]. Lesson usable
  without media (US-062). When a goal exists, the owner-reported continuum
  bar appears above the actions (docs/09 §7.6a; docs/22 §5.2).
- **Traces:** F08; US-060–US-062; content catalogue §7.

### TR-04 / TR-05 (compact spec)

| Aspect | TR-04 Log session | TR-05 Progress history |
| --- | --- | --- |
| Content | Date (default today, back-dateable within bounds), optional duration, "How did it go?" (free note), optional progress-state change (explicit picker with "owner-reported" note), optional photo | Current owner-reported state bar (discrete continuum steps + named label; no %) + session list (date, actor, note) + progress-state change log with attribution |
| Rules | One session never auto-advances mastery (US-063); state change is a separate deliberate control (US-065) | Read-only; states explained ("not a certification"); bar position is the reported state, not session frequency |
| Traces | US-056, US-063 | US-065 |

### TR-06 — Socialization passport

```text
┌─────────────────────────────┐
│ ‹ Training                  │
│  Socialization              │
│  Gentle, positive, varied — │
│  quality beats quantity.    │
│  ⓘ Ask your vet where Maple │
│    can go before her        │
│    vaccinations are done.   │ ← standing caution (catalogue §8)
│  ┌───────┐ ┌───────┐        │
│  │People │ │Animals│        │ ← category cards: name +
│  │ 4 this│ │ 1 this│        │   recent-breadth line —
│  │ month │ │ month │        │   NO scores, NO progress bars
│  └───────┘ └───────┘        │
│  ┌───────┐ ┌───────┐        │
│  │Sounds │ │Surfaces⋯       │
│  └───────┘ └───────┘        │
│  RECENT                     │
│  · Vacuum at a distance —   │
│    curious · Tue, Sarah     │
└─────────────────────────────┘
```

- **Traces:** F09; US-066; no numeric score ever (F09 exclusion).

### TR-07 / TR-08 (compact spec)

| Aspect | TR-07 Category experiences | TR-08 Record experience |
| --- | --- | --- |
| Content | Suggested experiences with done-recently marks; custom-experience add; per-experience overflow: "Not available / Not right for Maple / Pause" | Experience (prefilled), date, context note, response picker (relaxed · curious · neutral · hesitant · fearful), optional photo |
| Rules | Excluded items visibly paused, reversible (US-068) | Hesitant/fearful selection shows the softer-next-time note, never diagnosis (US-067; catalogue §8) |
| Traces | US-066, US-068 | US-067 |

## 4. Care stack

### CA-01 — Care overview

```text
┌─────────────────────────────┐
│  Care            🐕 Maple ▾ │
│  ┌───────────────────────┐  │
│  │ (photo) Maple         │  │
│  │ 12 weeks · Foundations│  │
│  │ Golden Retriever ♀    │  │
│  │ [ Edit profile › ]    │  │ → CA-02
│  └───────────────────────┘  │
│  UPCOMING CARE              │
│  · Vet appointment — Fri  › │
│  · Worming dose — Sat 8:00 ›│ ← from medication schedule
│  MEDICATIONS (1)            │
│  ┌───────────────────────┐  │
│  │ Worming — as entered  │  │
│  │ every 2 weeks · last  │  │
│  │ given Jul 12 by Nic  ›│  │ → CA-06
│  └───────────────────────┘  │
│  RECORDS                    │
│  [ Vaccinations (2) › ]     │
│  [ Weight & growth › ]      │
│  [ Grooming › ]             │
│  [ Notes & documents › ]    │
│  [ Providers (1) › ]        │
│  RECENT                     │
│  · Weight 6.4 kg — Jul 24   │
│  · Vaccination — Jul 18 ⚕   │ ← provenance badge
└─────────────────────────────┘
```

- **States:** new pet → gentle empty sections ("No records yet — add them as
  they happen"); never a medical-intake pressure.
- **Traces:** F03, F10; US-070–US-078.

### CA-02–CA-05, CA-08, CA-09 (compact spec)

| Screen | Content and rules | Traces |
| --- | --- | --- |
| CA-02 Pet profile | All profile fields incl. exact/estimated birth control (as ON-07), homecoming date, photo; archive entry at bottom behind a confirm flow explaining effects (stops plans/notifications, history kept) | US-020–US-025 |
| CA-03 Records list | Filter chips by type; rows show type icon, title, date, provenance badge (⚕ professional / ✎ owner-entered) | US-070, US-077 |
| CA-04 Record detail | Full fields, attachments, provenance, change history for professional-provenance records; edit/archive | US-070, US-077, US-078 |
| CA-05 Record editor | Typed forms per record type; vaccination: name, date, provider, next-due **only if explicitly known** ("leave blank unless your vet gave a date"); duplicate-suspect notice on save, review not auto-merge. **Shipped 2026-07-29 as Vaccinations history list+editor on CA-01** (US-070) — next due is display-only entered fact, never computed. **Notes (US-077) shipped 2026-07-29 as general_note + document CRUD on CA-01** with image/PDF attachments on `household-media` (Scenario H; Life stays image-only). Grooming history (US-076) also live on CA-01. | US-070, US-076, US-077 |
| CA-08 Weight & growth | Entry list + simple line visualization ("not a clinical assessment" footnote); unit toggle display-only; add: value, unit, date, note; obvious-outlier soft prompt ("6.4 kg → 64 kg — is that right?") | US-075 |
| CA-09 Providers | Contact cards (name, kind, phone tap-to-call, address, notes); referenced-by list | US-073, US-074 |

### CA-06 — Medication schedule detail

```text
┌─────────────────────────────┐
│ ‹ Care                      │
│  Worming treatment          │
│  For Maple  (photo)         │ ← unmistakable pet identity
│  ⚕ From your vet's          │
│    instruction — shown      │
│    exactly as entered       │
│  Dose: "1 tablet"           │ ← verbatim, quoted styling
│  Schedule: every 2 weeks,   │
│  morning window             │
│  LAST GIVEN                 │
│  Jul 12, 8:03 AM — Nic      │
│  NEXT DUE                   │
│  Sat Jul 26, morning        │
│  ── change history ──       │
│  Jul 05 — created by Sarah  │
│  [ Edit schedule ]          │
│  [ Archive schedule ]       │ ← confirm: stops occurrences,
│                             │   cancels reminders, keeps history
└─────────────────────────────┘
```

- **CA-07 editor:** name, dose text (free text, labeled "exactly as your vet
  wrote it"), provenance choice, supported recurrence only; unsupported →
  "enter occurrences manually" path (US-071). Every edit audited
  field-level (DM §11.2).
- **Traces:** F10; US-071–US-073, US-078.

## 5. Life stack (compact spec)

| Screen | Content and rules | Traces |
| --- | --- | --- |
| LF-01 Timeline | Reverse-chronological cards by effective/capture date: milestones (photo-forward), sessions, records (health items as discreet summaries), month markers; type filter chips (no duplicates when filtering); missing media → placeholder + retry | US-092 |
| LF-02 Milestone detail | Photo, title, date, note, attribution; edit; remove-photo flow distinguishing "remove from PetCompanion" vs record deletion, never claiming device copy deleted | US-090, US-093 |
| LF-03 Milestone editor | Title, date, note, photo (permission at point of use; denial keeps text flow); text saves even if upload fails, photo retryable | US-090, US-091, Scenario H |
| LF-05 Media viewer | Full-screen, capture date shown, share-sheet **absent** in MVP (household-private); remove-attachment entry | US-091, US-093 |

LF-04 Journal is P2 and not wireframed yet.

## 6. Settings stack

### ST-04 — Members & invitations / ST-05 — Invite

```text
┌─────────────────────────────┐
│ ‹ Settings                  │
│  Household members          │
│  ┌───────────────────────┐  │
│  │ (👤) Nic — Owner (you)│  │
│  │ (👤) Sarah — Caregiver│  │
│  └───────────────────────┘  │
│  PENDING                    │
│  · sarah@… — expires in 6d  │
│    [ Revoke ]               │
│  [ Invite a caregiver ]     │ → ST-05
│  ── owner only ──           │
│  [ Transfer ownership ]     │
│  [ Leave household ]        │ ← final owner: blocked with
│                             │   explanation until transfer/close
└─────────────────────────────┘
```

ST-05: explanation of what members can see (US-102 copy), [ Create
invitation ] → share sheet with link; single-use + expiry stated; pending
list with revoke. Caregivers see members read-only (no invite button, F02
role table).

- **Traces:** F02; US-011–US-015, US-102.

### ST-01–ST-03, ST-06–ST-08 (compact spec)

| Screen | Content and rules | Traces |
| --- | --- | --- |
| ST-01 Hub | Account card (name, avatar); household section (name, members entry); notifications; privacy & data; about | US-102 |
| ST-02 Account | Display name; credential management (via provider); sign out; delete account — multi-step confirm listing household consequences; sole owner blocked until transfer/close | US-004 |
| ST-03 Household | Name, time zone (change warns when timed care within 24h shifts — DM §8.4), routine windows (ON-08 content re-entrant), default capacity | US-100 |
| ST-06 Notifications | Per-user: morning summary toggle + delivery window, reminder defaults, completion updates (default off), quiet hours, lock-screen detail (discreet default); "time-sensitive reminders can break quiet hours" explanation where enabled | US-082, US-084, US-101, US-109 |
| ST-07 Privacy & data | Export (creates protected, expiring download; lists included/excluded types); archived pets (read-only history entry); delete pet; close household — highest-friction confirm (type household name) | US-025, US-103, US-104 |
| ST-08 About | Version; content provenance and review-status explanation; veterinary-boundary statement; policy links | F13 |

## 7. Global sheets (GL-01, GL-02, GL-03)

| Sheet | Content and rules |
| --- | --- |
| GL-01 Quick add | Grid of: Task · Event · Training session · Socialization · Health record · Weight · Milestone — each routes to the owning editor with pet + date prefilled; order fixed (muscle memory) |
| GL-02 Pet switcher | Pet rows (photo, name, age); check on active; switching swaps context across pet-scoped tabs; archived pets absent |
| GL-03 No access | Neutral full-screen: "You don't have access to this household anymore." + [ Create a household ] [ Enter invitation link ]; zero household data in copy (Scenario F) |

## 8. Open questions

1. Planner month-grid in MVP or agenda-only first (IA §18.5) — recommend
   agenda-only for Slice D, grid fast-follow. **2026-07-29:** agenda-only
   shipped as PL-01 primary; month jump remains the secondary date picker.
   **Same day:** jump sheet shows grid dots for days with tasks/events
   (loaded window + visible month fetch).
2. Whether CA-08's outlier prompt thresholds are worth Slice D scope or
   post-MVP.
3. TR-06 breadth line wording ("4 this month") — must not read as a score;
   content design to validate.
4. Care overview for pre-arrival households: which sections hide vs show
   empty (recommend: show all, empty-calm, since breeder records arrive
   pre-homecoming).

## 9. Validation criteria

1. Every screen in the IA inventory (§6) now has a frame or compact spec
   across docs 14 and 16; every IA §15 state has a defined treatment.
2. Every P0/P1 story in [User Stories](04-user-stories.md) is traceable to a
   drawn surface and its states.
3. Visual design for Slices C–E can proceed without structural questions.
4. The medication surfaces (CA-06/CA-07 + HM-02 variant) jointly satisfy
   US-071–US-073 acceptance criteria pre-usability-testing.
