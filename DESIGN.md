---
name: PetCompanion
description: Calm daily guidance for a lifetime of shared pet care.
colors:
  warm-cream: "#FAF7F2"
  white: "#FFFFFF"
  warm-linen: "#F1EDE5"
  warm-ink: "#26221C"
  warm-ink-secondary: "#5C554A"
  warm-ink-tertiary: "#8A8172"
  warm-border: "#E4DED3"
  deep-pine: "#2F5D50"
  deep-pine-pressed: "#254A40"
  honey: "#C9903A"
  terracotta: "#A6472E"
  terracotta-soft: "#F9E9E2"
  success-green: "#3E7A5E"
  slate-info: "#4E6E8E"
  danger-red: "#9E3B2E"
typography:
  display:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "28pt"
    fontWeight: 600
    lineHeight: 1.21
  title:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "22pt"
    fontWeight: 600
    lineHeight: 1.27
  headline:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "17pt"
    fontWeight: 600
    lineHeight: 1.29
  body:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "16pt"
    fontWeight: 400
    lineHeight: 1.38
  label:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "12pt"
    fontWeight: 500
    lineHeight: 1.33
rounded:
  input: "12pt"
  card: "16pt"
  pill: "999pt"
spacing:
  xs: "4pt"
  sm: "8pt"
  md: "12pt"
  base: "16pt"
  lg: "20pt"
  xl: "24pt"
  section: "32pt"
  spacious: "48pt"
components:
  button-primary:
    backgroundColor: "{colors.deep-pine}"
    textColor: "{colors.white}"
    rounded: "{rounded.input}"
    height: "50pt"
    padding: "0 20pt"
  button-secondary:
    backgroundColor: "{colors.warm-linen}"
    textColor: "{colors.warm-ink}"
    rounded: "{rounded.input}"
    height: "50pt"
    padding: "0 20pt"
  card:
    backgroundColor: "{colors.white}"
    textColor: "{colors.warm-ink}"
    rounded: "{rounded.card}"
    padding: "16pt"
  input:
    backgroundColor: "{colors.white}"
    textColor: "{colors.warm-ink}"
    rounded: "{rounded.input}"
    height: "50pt"
    padding: "0 16pt"
---

# Design System: PetCompanion

## 1. Overview

**Creative North Star: "The Calm Household Companion"**

PetCompanion should feel like a clear, thoughtful presence beside a busy new
owner: warm enough to invite daily use, quiet enough to reduce cognitive load,
and precise enough to trust with shared care. The interface uses familiar
Apple-native patterns and lets the user's puppy, plan, and memories provide the
emotion.

This is task-focused product UI. It rejects cartoon pet-game styling, clinical
record-software density, decorative dashboards, novelty controls, and
gamification pressure.

**Key Characteristics:**

- Today-first hierarchy with one obvious next action.
- Warm neutral surfaces and a restrained deep-pine accent.
- Spacious, near-flat cards with familiar platform affordances.
- Honest loading, queued, offline, error, and empty states.
- Accessible type, targets, contrast, and motion by default.

## 2. Colors

Warm paper neutrals create calm; deep pine carries action and selection, while
honey and terracotta appear only where their meaning earns attention.

### Primary

- **Deep Pine** (`#2F5D50`): primary actions, active navigation, links, and
  focus. Pressed state uses `#254A40`.

### Secondary

- **Quiet Honey** (`#C9903A`): sparing warmth in illustration fills and
  non-semantic highlights. Never use it for body text.

### Tertiary

- **Muted Terracotta** (`#A6472E`): overdue and needs-attention emphasis.
  Pair with Soft Terracotta (`#F9E9E2`) and a text or icon cue.
- **Slate Information** (`#4E6E8E`): queued, upcoming, and informational state.
- **Steady Green** (`#3E7A5E`): confirmed completion and success.
- **True Failure Red** (`#9E3B2E`): destructive actions and real failures only.

### Neutral

- **Warm Cream** (`#FAF7F2`): app background.
- **Paper White** (`#FFFFFF`): cards, fields, and sheets.
- **Warm Linen** (`#F1EDE5`): grouped regions and secondary controls.
- **Warm Ink** (`#26221C`): primary text.
- **Soft Ink** (`#5C554A`): secondary text and metadata.
- **Faded Ink** (`#8A8172`): placeholders and disabled text.
- **Warm Border** (`#E4DED3`): hairlines and card outlines.

**The One Accent Rule.** One saturated semantic color may lead a view. Color
reinforces meaning; labels, icons, and structure always carry it too.

## 3. Typography

**Display Font:** SF Pro (Apple system fallback)
**Body Font:** SF Pro (Apple system fallback)
**Label Font:** SF Pro (Apple system fallback)

**Character:** A single disciplined system family keeps the product familiar,
legible, and calm. Hierarchy comes from measured size and weight changes, not
novelty faces.

### Hierarchy

- **Display** (semibold, 28pt/34pt): greetings and onboarding headlines.
- **Headline** (semibold, 17pt/22pt): section headings and compact hierarchy.
- **Title** (semibold, 22pt/28pt): screen and sheet titles.
- **Body** (regular, 16pt/22pt): plan titles and primary content.
- **Label** (medium, 12pt/16pt): badges, chips, timestamps, and quiet metadata.

**The Complete Thought Rule.** Important titles and actions reflow with Dynamic
Type; they are not truncated to preserve a card's original height.

## 4. Elevation

The system is flat by default. Depth comes from warm tonal layers, one-point
borders, and sheet presentation. A single soft ambient shadow is reserved for
floating quick-add controls and detached sheets; ordinary cards never stack
shadows.

**The Earned Lift Rule.** Elevation communicates interaction or hierarchy. It
is never decorative.

## 5. Components

### Buttons

- **Shape:** familiar and gently rounded (12pt), 50pt high.
- **Primary:** Deep Pine with white label; full-width in setup flows.
- **Pressed / Focus:** darken to `#254A40`; retain the platform focus and
  accessibility treatments.
- **Secondary / Tertiary:** Warm Linen tonal fill or text-only Deep Pine.
- **State:** disabled and loading states preserve layout and announce status.

### Chips

- **Style:** pill shape, caption typography, Warm Linen background, semantic
  icon only when it adds information.
- **State:** capacity, provenance, queued, effort, and review chips must not
  look actionable unless they are tappable.

### Cards / Containers

- **Corner Style:** 16pt.
- **Background:** Paper White over Warm Cream.
- **Shadow Strategy:** flat at rest.
- **Border:** one point Warm Border.
- **Internal Padding:** 16pt with 12pt between sibling cards.

### Inputs / Fields

- **Style:** Paper White, one-point Warm Border, 12pt radius, label above.
- **Focus:** Deep Pine border/focus treatment.
- **Error / Disabled:** red icon and plain-language message for errors; Faded
  Ink for disabled state.

### Navigation

Use five familiar labeled tabs in this order: Home, Planner, Training, Care,
Life. Active items use filled symbols and Deep Pine; inactive items remain
neutral. Contextual settings open from the profile entry rather than becoming
a sixth tab.

### Daily Plan Item

The signature card combines a 44pt completion target, full item title, quiet
category and timing metadata, and optional attribution. Recommendations never
pretend to be accepted tasks; queued and stale operations remain visibly
distinguishable from confirmed server state.

## 6. Do's and Don'ts

### Do:

- **Do** make the next useful action visible without requiring navigation.
- **Do** use Warm Cream (`#FAF7F2`) and Paper White (`#FFFFFF`) as the calm
  surface foundation.
- **Do** preserve familiar iOS interaction patterns and 44pt touch targets.
- **Do** render loading, offline, queued, stale, empty, and error states
  truthfully.
- **Do** support VoiceOver, Reduce Motion, and the largest Dynamic Type sizes.

### Don't:

- **Don't** resemble a cartoon pet game, a dense analytics dashboard, an
  encyclopedia, a generic reminder app, or a social feed.
- **Don't** use puppy-themed novelty decoration, paw-print wallpaper, rainbow
  category colors, or clinical-looking medical software.
- **Don't** add streak pressure, guilt mechanics, caregiver comparisons, or
  unexplained scores.
- **Don't** use glassmorphism, gratuitous animation, decorative shadows, or
  novelty controls.
- **Don't** hide a failed or unconfirmed write behind optimistic success.
