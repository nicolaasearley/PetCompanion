# UI Design System

**Status:** Draft  
**Version:** 0.1  
**Last updated:** 2026-07-26  
**Related documents:** [Product Requirements Document §14](00-product-requirements-document.md),
[Information Architecture](05-information-architecture.md),
[Wireframes — Onboarding and Home](14-wireframes-onboarding-home.md),
[Technical Architecture](06-technical-architecture.md)

## 1. Purpose

The visual and interaction foundations for PetCompanion: tokens, typography,
color, spacing, core components, motion, and content voice — concrete enough
that visual design and implementation produce one coherent product without
per-screen invention.

## 2. Scope and exclusions

Covers the mobile MVP (native iOS SwiftUI per the revised platform decision,
light and dark mode). Excludes: brand
identity beyond a working palette (logo, final name treatment), marketing
surfaces, illustration library production, and tablet layouts. Token values
below are a validated starting point, not a final brand; changing them is a
design pass, not a re-architecture, because all usage is token-based.

## 3. Design principles

From PRD §14 — warm, calm, modern, spacious, friendly, premium, trustworthy —
operationalized:

1. **Calm by default.** Generous whitespace, one accent at a time, no
   competing saturated colors. Error styling appears only for true failures —
   never for skips, busy days, or empty days.
2. **Today first.** Visual weight follows the plan hierarchy: Needs attention
   > Today > Recommended > everything else.
3. **Warm, not childish.** Warm neutrals and organic accents; no cartoon
   mascots, paw-print wallpaper, or rounded-to-mush typography.
4. **Trust through restraint.** Provenance badges, attribution lines, and
   guidance boundaries are quiet but always present. No unexplained scores,
   no streaks, no guilt mechanics.
5. **Accessible is the default state.** Every token pair ships contrast-
   verified; every component ships with its focus, dynamic-type, and
   reduced-motion behavior defined.

## 4. Color

Semantic tokens only — components never reference raw hex values.

### 4.1 Core palette (light)

| Token | Value | Use |
| --- | --- | --- |
| `color.bg` | `#FAF7F2` | App background (warm cream) |
| `color.surface` | `#FFFFFF` | Cards, sheets |
| `color.surface-subtle` | `#F1EDE5` | Grouped sections, collapsed areas |
| `color.ink` | `#26221C` | Primary text (warm near-black) |
| `color.ink-secondary` | `#5C554A` | Secondary text, metadata |
| `color.ink-tertiary` | `#8A8172` | Placeholders, disabled text |
| `color.border` | `#E4DED3` | Hairlines, dividers |
| `color.primary` | `#2F5D50` | Primary actions, active tab, links (deep pine) |
| `color.primary-pressed` | `#254A40` | Pressed state |
| `color.on-primary` | `#FFFFFF` | Text/icons on primary |
| `color.accent` | `#C9903A` | Sparing highlights (honey) — never for text on light bg |
| `color.attention` | `#A6472E` | Needs-attention accents (muted terracotta) |
| `color.attention-bg` | `#F9E9E2` | Needs-attention card tint |
| `color.success` | `#3E7A5E` | Completion confirmations |
| `color.info` | `#4E6E8E` | Upcoming/informational accents (slate) |
| `color.danger` | `#9E3B2E` | True failures and destructive actions only |
| `color.danger-bg` | `#FBE7E2` | True-failure banner/card tint |

### 4.2 Dark mode

Same token names; values: `bg #17140F`, `surface #201C15`,
`surface-subtle #2A251C`, `ink #F3EFE7`, `ink-secondary #BFB7A8`,
`border #3A342A`, `primary #7FB5A4`, `on-primary #17140F`,
`attention #E08A6D`, `attention-bg #3A251D`, `success #8CC0A6`,
`info #93AEC7`, `danger #E0796A`, `danger-bg #3B231D`, `accent #D9A85C`,
`ink-tertiary #8A8172` (shared with light), `primary-pressed #6BA292`. Dark
mode ships with the MVP (platform-following, no in-app override initially).

### 4.3 Color rules

- Text on `bg`/`surface` uses `ink`/`ink-secondary` only; both pairs meet
  WCAG AA at their assigned sizes (verify any token change against 4.5:1
  body / 3:1 large-text thresholds before merging).
- Obligation classes are communicated by **section, label, and icon** —
  color is reinforcement only (PRD §13.3). Required items get no special
  color until they enter Needs attention.
- `accent` is decorative (chips, illustration fills); never sole carrier of
  meaning, never body text.
- `attention-bg` and `danger-bg` are not interchangeable: `attention-bg`
  marks something in the plan that needs the caregiver's eyes (still true,
  still actionable, never a failure); `danger-bg` marks a write or load that
  actually failed. A true-failure banner (e.g. Home's inline error, the
  socialization save/remove banner) fills with `danger-bg`, never
  `attention-bg` — the two read as the same muted terracotta family at a
  glance, and conflating them told a caregiver a failure was merely a
  to-do (doc 22 §7).
- `info` is also the truthful-queued/offline tone, not `success` or
  `danger`: a write that only reached the on-device durable queue
  (`OfflineMutationError.queued`) is real and non-losable but not yet
  server-confirmed, so it must not read as a green "done" or a red
  "failed". `PlanItemCard`'s queued chip and `SocializationBanner`'s
  `.queued` tone both use `info` (slate) with the sync-in-progress glyph
  (`arrow.triangle.2.circlepath`) for exactly this state.

## 5. Typography

Platform system fonts for the MVP (SF Pro / Roboto) — premium feel comes from
scale discipline and spacing, and system fonts give dynamic type for free. A
brand display face is a later, token-level swap.

| Token | Size/line (pt) | Weight | Use | Platform text-style mapping |
| --- | --- | --- | --- | --- |
| `type.display` | 28/34 | Semibold | Greeting, onboarding headlines | Title 1 |
| `type.title` | 22/28 | Semibold | Screen titles | Title 2 |
| `type.heading` | 17/22 | Semibold | Section headers (TODAY, RECOMMENDED — rendered as small-caps label style, `ink-secondary`) | Headline |
| `type.body` | 16/22 | Regular | Item titles, primary content | Body |
| `type.secondary` | 14/20 | Regular | Metadata, attribution, explanations | Subheadline |
| `type.caption` | 12/16 | Medium | Badges, chips, timestamps | Caption |

Dynamic type: all styles map to platform text styles and scale to the largest
accessibility sizes; layouts reflow (cards grow, no truncation of item titles
or action labels — US-105).

## 6. Spacing, shape, elevation

- **Spacing scale (4pt base):** 4, 8, 12, 16, 20, 24, 32, 48. Screen margins
  20; card padding 16; between cards 12; between sections 32 (spacious per
  the direction).
- **Radius:** cards and sheets 16; buttons 12; chips/badges full; inputs 12.
- **Elevation:** near-flat. Cards use `surface` + 1px `border`; a single soft
  shadow level is reserved for sheets and the floating quick-add button.
  No stacked shadows, no glassmorphism.
- **Icons:** outlined, rounded terminals, 24pt grid, 1.8pt stroke; filled
  variant only for active tab state.

## 7. Core components

Specs bind to the wireframes; states listed are mandatory to implement.

### 7.1 Plan item card

The product's centerpiece (HM-01).

- Anatomy: complete control (28pt circle checkbox, 44pt touch target) ·
  title (`type.body`) · meta line (`type.secondary`: category · effort band /
  due window / "by Sarah, 7:42 AM") · optional trailing affordance
  ("Why this? ›", "Open ›").
- States: default; pressed; **completing** (checkmark draw + settle,
  ~200 ms); **completed** (title stays full-contrast, check filled
  `success`, meta shows attribution — no strikethrough, completion is an
  achievement not a deletion); **queued** (small "queued" chip, `info`);
  needs-attention variant (`attention-bg` tint, `attention` leading icon set
  in a small surface-colored disc for presence); disabled/stale. A leading
  accent bar was tried and dropped (2026-07-29 visual refresh) — a
  side-stripe reads as a decorative tell, and tint plus icon alone already
  carry the state without a third redundant cue.
- Recommendation variant adds the explanation affordance and never shows a
  checkbox pre-accepted — its primary tap opens HM-02/HM-03; accepting is
  explicit.

### 7.2 Buttons

Primary (filled `primary`), secondary (tonal `surface-subtle` + `ink`),
tertiary (text, `primary`), destructive (text or filled `danger` — filled
only inside confirmation dialogs). Height 50pt; full-width in flows; loading
state replaces label with inline progress; never two primary buttons on one
screen.

### 7.3 Section header

Small-caps label (`type.heading` treatment), `ink-secondary`, with optional
trailing action ("Adjust", "▾"). Rendered as a real accessibility heading.
The "Needs attention" header renders in `attention` instead — the one
section that outranks the rest of the plan hierarchy (§3.2) gets the one
extra cue; every other header stays neutral so this remains reinforcement,
not a second accent competing with it.

### 7.4 Sheets

Bottom sheets for capacity, quick add, pet switcher, "Why this?": grabber,
title, content, detached from tab bar; focus-trapped; dismiss via swipe,
scrim tap, and an explicit close for assistive tech.

### 7.5 Chips and badges

Capacity pill ("Busy day"), provenance badges ("From your vet record" /
"Owner-entered"), review-status badge, effort band, "queued". `type.caption`,
`surface-subtle` background, icon optional. Badges are informative, never
tappable-looking unless tappable.

### 7.6 List rows, inputs, pickers

Standard 56pt rows with chevrons for navigation lists (Care, Settings).
Inputs: 12pt radius, `border` outline, `primary` focus ring, label above,
error text below in `danger` with icon (never color-only). Radio groups per
ON-07 with whole-row targets.

**Promoted row (hero tile).** When one navigation row genuinely leads a
screen (e.g. Training's socialization passport, 2026-07-29), it stays the
same `surface` background as an ordinary row or card — never a full-bleed
saturated fill, which would break the One Accent Rule and the "giant
saturated block" anti-reference. Promotion instead comes from: screen
position (first, ahead of everything else), a `type.body` **semibold**
title instead of the row default, one explanatory `type.secondary` line
underneath (what an ordinary chevron row doesn't carry), and a
`primary`-tinted 1.25pt border (`primary` at ~30% opacity) replacing the
neutral `border` stroke. The leading icon keeps the existing icon-disc
language (`surfaceSubtle` circle, `primary` glyph) rather than inventing a
new one.

### 7.6a Training progress state bar (owner-reported)

Accepted 2026-07-29 (closes docs/22 §5 item 2). Training goal cards, the
skill lesson, and progress history may show a calm segmented bar for
`TrainingProgressState`. Rules:

- The bar maps the household's **own reported** continuum state to discrete
  steps (Not started → Maintained). It is **not** a completion percentage,
  module score, or session-count ratio (`PRODUCT.md` unexplained-scores ban;
  F08).
- The current state **name is always visible text**; color only reinforces
  filled steps (same rule as obligation classes in §4.3).
- Caption reads “Owner-reported · not a score” (or the paused variant).
- F08's seventh label, “Paused”, stays a goal lifecycle status: when paused,
  the title prefixes “Paused · …” and the continuum step does not move.
- Tokens only: `primary` / `primary` at reduced opacity for reached steps,
  `surfaceSubtle` + `border` for unreached, `Font.pc` for Dynamic Type,
  platform light/dark via `Color.pc`.
- Socialization (F09) still forbids progress bars and ratios entirely.

### 7.7 Empty states

Illustration slot (calm, abstract, warm — no sad dogs), one sentence of
specific copy, one constructive action. Success-empty (all caught up) uses
the same pattern with a subtle `success` accent (US-108).

### 7.8 Sync/status line

Single `type.caption` line in the header region (`ink-tertiary`, ⟳ icon):
"Updated just now" appears only when stale or queued — silence is the normal
state (US-106).

### 7.9 Tab bar

Five items + labels always visible; active = filled icon + `primary`;
badge-free in MVP (no red dots — notification pressure contradicts calm).

## 8. Motion

- Durations: micro (state changes) 150–200 ms; sheet/screen transitions
  250–300 ms. Easing: standard platform curves; gentle ease-out for entering
  elements.
- Completion moment: checkmark draw + soft settle; **no confetti, no sound**
  by default. The completed card animates to the Completed section only on
  the next natural list update, not instantly (prevents plan-jumping,
  engine §4.3).
- Reduced motion: all transitions become cross-fades; completion becomes an
  instant state change (US-105).
- Nothing animates unprompted while the user is reading.

## 9. Content voice

- **Tone:** a knowledgeable, calm friend. Plain language over clinical terms
  (PRD §14); short sentences; second person.
- **Never:** shame, urgency inflation, streak language ("Don't break your
  streak!"), medical conclusions, exclamation-mark pileups.
- **Attribution copy:** factual — "Completed by Sarah at 7:42 AM",
  "Rescheduled by Nic" (engine §18.4).
- **Estimated age:** always approximated — "about 9 weeks" (US-021).
- **Skips:** neutral — "Skipped. It won't carry over." (US-034).
- **Boundaries:** health-adjacent copy defers explicitly — "check the
  recorded instructions or ask your vet" — and never advises dose changes
  (US-073).
- **Empty days:** celebratory-calm — "You're all caught up."

## 10. Do / don't

| Do | Don't |
| --- | --- |
| One accent color per view | Rainbow category coloring |
| Whitespace between sections (32pt) | Dense dashboard packing |
| Quiet provenance and review badges | Unexplained scores or grades |
| Neutral completion attribution | Leaderboards, caregiver comparisons |
| Real error states for real failures | Red styling on skips/empty days |
| System fonts, disciplined scale | Novelty display fonts, ALL-CAPS body |

## 11. Open questions

1. Working visual identity (name treatment, app icon) — needed before
   TestFlight; palette above is the starting point.
2. Illustration style for empty states and onboarding (abstract organic
   shapes vs. minimal line art) — decide in the first visual-design pass.
3. Haptics on completion (subtle tick) — prototype; default off if in doubt.
4. Whether the brand display typeface arrives before or after MVP.

## 12. Validation criteria

1. Every wireframe in docs 14/16 can be rendered using only these tokens and
   components, with no new one-off styles.
2. All text/background token pairs pass WCAG 2.2 AA in both modes
   (automated check in CI once implementation starts).
3. Home at the largest accessibility text size shows complete, uncut item
   titles and reachable actions.
4. A reduced-motion walkthrough of Slice A shows no residual animation.
5. Screens contain zero raw hex values in implementation review.
