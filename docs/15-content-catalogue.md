# Content Catalogue (Seed)

**Status:** Draft — all content `pending_professional_review`  
**Version:** 0.1  
**Last updated:** 2026-07-26  
**Related documents:** [Daily Plan Engine](12-daily-plan-engine.md),
[Data Model](10-data-model.md), [Core Features](03-core-features.md),
[Decision Log](13-decision-log.md)

## 1. Purpose

The initial governed content that makes the Daily Plan valuable: development
stages, the pre-arrival preparation checklist, routine templates, training
skills, socialization experiences, grooming cadence, and the recommendation
rules that select from them. This is the seed for the ContentVersion system
defined in [Data Model §10.4–10.5](10-data-model.md); each block below carries
the metadata the engine requires (engine §9.1).

## 2. Scope and safety boundary

- **Audience:** the founding household's private MVP only. Every entry ships
  with review status `pending_professional_review`; promoting any of it to an
  external audience is gated on named review (PRD §20, seed-governance
  decision in the [Decision Log](13-decision-log.md)).
- **Explicitly empty domains:** vaccination schedules, medication content,
  dosing, parasite-prevention schedules, diagnosis-adjacent content, and
  breed-specific health claims. These are never product content — such records
  are always user- or professional-entered (engine §22.2). Nutrition content
  is limited to routine *structure* (meal count), never food choice or amounts.
- **Method boundary:** all training content is reward-based; nothing in this
  catalogue may describe punishment-based, aversive, or flooding techniques
  (F08 exclusions).
- **Copy rule:** stage ages and cadences are guidance bands, not clinical
  boundaries; rendered copy must use approximating language and defer to the
  household's veterinarian for anything health-adjacent.

## 3. Governance

- **Identity and versioning:** every entry has a stable `content_id`
  (namespaced key below) and starts at version 1. Any change that alters
  meaning bumps the version through the ContentVersion workflow
  (`draft → review → published → retired`); historical plans keep the version
  they used (DM §10.1).
- **Review states:** `pending_professional_review` (private use only) →
  `professionally_reviewed` (named reviewer + date recorded) — required before
  beta for training, socialization, and stage content.
- **Provenance:** every entry records source category
  (`product_seed`), author, and date. User-visible surfaces show review status
  where the IA specifies (TR-03, HM-03).
- **Change control:** additions or meaning-level edits to this catalogue are
  content-pipeline work; they never require app releases.

## 4. Development stages

`content_id: stage.<key>` — bands are approximate, overlapping, and adaptable
(F07); the engine treats them as eligibility inputs, not truths about an
individual puppy.

| Key | Name | Approximate band | Focus areas (rendered as stage guidance) |
| --- | --- | --- | --- |
| `preparing` | Preparing for arrival | homecoming date in the future | Home setup and safety, supplies, routine agreement, choosing a veterinarian, first-night plan |
| `settling_in` | Settling in | first ~2 weeks home | Predictable routine, sleep and crate comfort, gentle bonding, name response, potty rhythm, low-pressure exploration of home |
| `foundations` | Foundations | ~8–12 weeks | Marker and name basics, short fun training, handling comfort, positive early socialization within veterinary guidance, alone-time foundations |
| `exploration` | Exploration and socialization | ~12–16 weeks | Broadening positive exposure, recall foundations, leash introduction, continuing handling and grooming comfort |
| `teething` | Teething | ~16–24 weeks | Appropriate chew management, patience with mouthing, maintaining training momentum, calm-settle practice |
| `early_adolescence` | Early adolescence | ~6–9 months | Reinforcing recall and leash skills as independence grows, impulse-control games, sustaining socialization quality |
| `adolescence` | Adolescence | ~9–18 months | Consistency through regression phases, generalizing skills to new places, exercise balance |
| `adulthood` | Adulthood | ~18 months + | Maintenance practice, enrichment variety, routine care rhythm |

Next-stage preview copy: one sentence per transition, qualified ("Many
puppies begin… around…"), authored in content design from this table.

## 5. Pre-arrival preparation checklist

`content_id: prep.<key>` — system TaskDefinitions surfaced in the `preparing`
stage as scheduled items (household opt-in at onboarding) or recommendations
via the `R-PREP-*` rules in §9. Category `preparation` throughout.

| Key | Title | Effort | Suggested timing (before homecoming) |
| --- | --- | --- | --- |
| `prep.safe_home` | Puppy-proof one room at a time (cords, plants, small objects, cleaners) | moderate | 14–3 days |
| `prep.supplies` | Gather starter supplies (crate, bedding, bowls, collar/harness, lead, chews, food per breeder guidance) | moderate | 14–5 days |
| `prep.vet_choice` | Choose a veterinary practice and save its contact | short | 14–7 days |
| `prep.first_vet_appt` | Book the first veterinary visit | short | 10–3 days |
| `prep.sleep_setup` | Choose and set up the first-night sleeping arrangement | short | 10–2 days |
| `prep.routine_agreement` | Agree the household routine — who does mornings, meals, nights | short | 7–1 days |
| `prep.records_folder` | Start a folder for breeder/rescue paperwork and health records | tiny | 7–1 days |
| `prep.travel_plan` | Plan the journey home (crate/restraint, stops, towels) | short | 5–1 days |
| `prep.name_shortlist` | Settle the name the whole household will use | tiny | any time |
| `prep.first_days_calendar` | Keep the first 2–3 days at home low-key — block the calendar | tiny | 7–1 days |

## 6. Routine templates

`content_id: routine.<key>` — offered at ON-08 and at the homecoming
transition; always user-editable; copy must include "confirm feeding details
with your breeder or veterinarian."

| Key | Applies (stage band) | Template |
| --- | --- | --- |
| `routine.meals_young_puppy` | settling_in, foundations, exploration | 3 meals/day in morning, midday, evening windows |
| `routine.meals_older_puppy` | teething, early_adolescence | 3 → 2 meals/day (household choice) |
| `routine.meals_adolescent` | adolescence, adulthood | 2 meals/day |
| `routine.potty_young` | settling_in, foundations | Potty opportunities: after waking, after each meal, after play, before sleep; scheduled as window items, not exact times |
| `routine.potty_older` | exploration onward | After waking, after meals, before sleep; reduce as reliability grows |
| `routine.sleep` | all | Bedtime wind-down item in the evening window (opt-in) |

## 7. Training skills (seed)

`content_id: skill.<key>` — full lesson copy (steps, tips) is drafted from
these specs in content design; the table is the product-authoritative spec:
group, stage guidance, prerequisites, effort per session, target frequency,
and the common-mistake themes each lesson must cover. All reward-based.

| Key | Skill | Group | Stage from | Prereqs | Effort | Freq/wk | Common-mistake themes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `skill.marker_intro` | Marker word ("yes!") | Foundations | settling_in | — | tiny | 3–5 | Marking late; treating before marking |
| `skill.name_response` | Name response | Foundations | settling_in | — | tiny | 4–6 | Repeating the name; using it for scolding |
| `skill.sit` | Sit | Foundations | foundations | marker_intro | tiny | 3–5 | Luring forever; pushing the rear down |
| `skill.hand_target` | Hand target ("touch") | Foundations | foundations | marker_intro | tiny | 3–4 | Moving the hand toward the puppy |
| `skill.recall_foundations` | Recall ("come") | Recall and safety | foundations | name_response | short | 3–5 | Calling for unpleasant things; repeating the cue; practicing only indoors forever |
| `skill.leave_it` | Leave it | House manners | exploration | marker_intro | short | 2–4 | Snatching the item away; escalating too fast |
| `skill.drop_it` | Drop it (trade) | House manners | exploration | — | short | 2–3 | Chasing the puppy; trading down |
| `skill.crate_comfort` | Crate comfort | Calm behavior | settling_in | — | short | daily at first | Using the crate as punishment; rushing duration |
| `skill.settle_on_mat` | Settle on a mat | Calm behavior | foundations | marker_intro | short | 3–4 | Only practicing when already tired; expecting long holds early |
| `skill.alone_time` | Alone-time foundations | Calm behavior | settling_in | crate_comfort started | short | 3–5 | Sneaking out; jumping to long absences |
| `skill.paw_handling` | Paw handling | Handling and grooming prep | settling_in | — | tiny | 3–4 | Gripping tightly; continuing past discomfort |
| `skill.body_handling` | Ears, mouth, body handling | Handling and grooming prep | foundations | paw_handling started | tiny | 2–4 | Long sessions; skipping the pairing with rewards |
| `skill.harness_intro` | Collar/harness introduction | Leash skills | settling_in | — | tiny | 2–3 | Forcing it on; leaving it on while distressed |
| `skill.loose_leash` | Loose-leash foundations | Leash skills | exploration | harness_intro | short | 3–4 | Letting pulling pay off sometimes; sessions too long |
| `skill.shake` | Shake / give paw | Fun skills | exploration | paw_handling | tiny | 1–2 | Grabbing the paw instead of shaping |

Progress uses the seven owner-reported states (F08); no lesson may imply
certification.

## 8. Socialization catalogue (seed)

`content_id: soc.<category>.<key>` — quality-over-quantity framing throughout
(F09). **Standing caution, rendered on every category until reviewed content
refines it:** "Follow your veterinarian's guidance on where your puppy can go
before their vaccinations are complete. Distance watching and carrying count."

| Category | Seed experiences (positive, low-pressure) |
| --- | --- |
| People | Calm adult visitor; person with a hat/hood; person with a stick or umbrella; child at a distance; delivery worker observed from window |
| Animals | Calm vaccinated adult dog (known); dog seen at a distance; cat at a distance; birds in the garden |
| Sounds | Vacuum at low volume/distance; doorbell; hairdryer; traffic from a distance; recorded thunder at low volume; kitchen clatter |
| Surfaces | Grass; gravel; wet ground; smooth floor; wobbly cushion; low step |
| Environments | Front garden; quiet street (carried if pre-vaccination per vet guidance); car park at a distance; friend's home; outdoor café from a distance |
| Handling | Towel wipe-down; brush touch; nail-clipper shown and touched; being gently held; harness on/off |
| Transportation | Stationary car with treats; short car ride; crate in the car |
| Household objects | Umbrella opening; bin bag rustle; broom; suitcase with wheels; mirror |

Response vocabulary (owner-reported, non-diagnostic): relaxed · curious ·
neutral · hesitant · fearful — with the standing UI note that "hesitant" or
"fearful" means more distance and softer versions next time, not more
repetitions.

## 9. Recommendation rules (seed)

`content_id: rule.<key>` — engine-consumable specs; explanation templates are
the user-visible "Why this?" text (engine §4.4, §20). Shared defaults unless
stated: priority tier P3, category variety applies, hard constraints per
engine §12.3.

| Key | Selects | Eligibility | Cooldown / cadence | Explanation template |
| --- | --- | --- | --- | --- |
| `rule.prep_window` | `prep.*` items by their timing windows | stage `preparing`; days-to-homecoming within the item's window | each item once | "{Puppy} comes home in {n} days." |
| `rule.active_skill_practice` | a session for an active TrainingGoal | goal active; not paused | per skill's freq/wk, min 1 day gap | "{Skill} is an active goal — last practiced {n} days ago." |
| `rule.start_next_skill` | starting an eligible not-started skill | < 2 active goals; prereqs met; stage matches | 3 days after last start | "{Puppy}'s {stage} stage is a good time to begin {skill}." |
| `rule.socialization_breadth` | an experience from the least-recently-visited category | stage settling_in–early_adolescence; category not excluded | ≥ 2 days per category | "{Puppy} hasn't explored {category} recently — one calm, positive experience is plenty." |
| `rule.handling_cadence` | paw/body handling practice | stage settling_in+; skill not paused | 2 days | "Short, pleasant handling now makes grooming and vet visits easier later." |
| `rule.brushing` | brushing session | stage settling_in+ | 3 days (coat-typical default; household-adjustable) | "A brief brushing session keeps {Puppy} comfortable with grooming." |
| `rule.alone_time` | alone-time practice | goal active or stage ≤ foundations | 2 days | "Short, easy departures now help {Puppy} feel fine alone later." |
| `rule.growth_photo` | weekly growth photo | opt-in (P2); tier P4 | 7 days | "It's been a week — a quick photo keeps {Puppy}'s growth story going." |
| `rule.event_prep_vet` | `Gather records and questions` before a vet appointment | vet-kind Event within 3 days | once per event | "{Puppy}'s appointment is {when} — having records and questions ready helps." (origin `system_preparation_rule`, tier P2) |
| `rule.homecoming_routine` | confirm household routine | homecoming is today/tomorrow | once | "{Puppy} is almost home — a shared routine makes the first week calmer." |

Engine-behavior notes: `rule.active_skill_practice` competes normally — active
goals are eligible, not forced, into every plan (engine §26.2);
`rule.socialization_breadth` must never select an excluded experience or
reward volume (F09); all rules respect capacity, variety, and dismissal
cooldowns from engine §12–§13.

## 10. Grooming and care cadence content

Only cadence *suggestions* with neutral copy; every cadence is
household-editable and none is presented as a health requirement:

| Key | Suggestion | Default cadence |
| --- | --- | --- |
| `care.brushing` | Brushing session | every 3 days |
| `care.nail_intro` | Nail-care habituation (touch, one nail when ready) | weekly |
| `care.tooth_intro` | Tooth-brushing habituation | 2–3×/week |
| `care.ear_check` | Calm ear look-and-reward | weekly |

## 11. Open questions

1. Named professional reviewer(s) for training, socialization, and stage
   content — who, and by when relative to any external beta.
2. Golden Retriever-specific content (coat-driven grooming cadence, breed
   guidance) — deferred until reviewed breed content exists (engine §7.1);
   the household can adjust cadences manually meanwhile.
3. Lesson long-copy authoring (steps, tips per §7) — content-design task;
   spec here is the acceptance baseline.
4. Whether `rule.growth_photo` ships in MVP or with P2 journal work.
5. Localization: seed is English-only; locale fields exist in the model.

## 12. Validation criteria

1. Every entry round-trips into the ContentVersion + rule/skill/stage models
   in [Data Model §10](10-data-model.md) without schema changes.
2. The engine's example plans (engine §26.1–26.2) are reproducible using only
   this catalogue plus user data.
3. No entry contains dosing, vaccination scheduling, diagnosis, or
   aversive-method content (checked in content review, enforced by the §2
   boundary).
4. A pre-arrival household receives ≥ 2 useful items per day in the final two
   weeks before homecoming from §5 + §9 alone.
5. A `foundations`-stage household with two active goals receives varied,
   non-repetitive recommendations for 14 consecutive simulated days within
   capacity budgets.
