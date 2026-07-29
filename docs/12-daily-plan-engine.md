# Daily Plan Engine

**Status:** Draft  
**Version:** 0.2  
**Last updated:** 2026-07-26  
**Owner:** Product  
**Related document:** [Product Requirements Document](00-product-requirements-document.md)

## 1. Purpose

The Daily Plan Engine turns a pet's profile, development stage, household
schedule, care requirements, and recorded progress into a focused plan for the
current day.

It is the connective tissue between PetCompanion's care, training,
socialization, planning, and memory features. It is also the product's primary
reason for daily use.

The engine should answer four questions within seconds:

- What must happen today?
- What would be especially helpful today?
- What has already been done, and by whom?
- What should the household prepare for next?

## 2. Product outcome

A caregiver should be able to open PetCompanion, understand the day, and take
the next useful action without searching through menus or constructing a plan
manually.

A successful plan feels:

- **Relevant:** Each item has a clear reason to be present.
- **Manageable:** The plan reflects the household's actual capacity.
- **Coordinated:** Every caregiver sees the same completion state.
- **Adaptable:** The plan responds sensibly to progress and changes.
- **Trustworthy:** Required care is distinct from general recommendations.
- **Forgiving:** An imperfect day does not create guilt or an endless backlog.

## 3. Scope

### 3.1 Included in MVP

- A deterministic, rules-based plan
- One shared plan per pet per local calendar day
- Required, scheduled, recommended, and upcoming items
- User-created and system-suggested tasks
- One-time and recurring schedules
- Training, socialization, grooming, health, and household-routine inputs
- Completion attribution across household members
- Complete, skip, snooze, and reschedule actions
- A short explanation for system recommendations
- Notification candidates derived from plan items
- Plan history
- Predictable regeneration when relevant information changes

### 3.2 Excluded from MVP

- Generative-AI-created care or training advice
- Automatic medical decisions
- Autonomous changes to veterinarian-entered schedules
- Weather-based recommendations unless a reliable weather integration is later
  approved for the MVP
- Location tracking
- Wearable data
- Trainer or veterinary portals
- Automatic assignment optimization across caregivers
- Habit or behavior prediction based on statistical models

## 4. Guiding principles

### 4.1 Obligations before suggestions

Medication, confirmed appointments, and other explicitly required care must
remain visible before optional enrichment or training recommendations.

### 4.2 A plan is not a backlog

The plan represents what is useful today. Optional items that were missed
yesterday should not automatically accumulate.

### 4.3 Stable unless something meaningful changes

The plan should not reorder itself unexpectedly throughout the day. Completion,
an edited schedule, a newly recorded health requirement, or an explicit refresh
may change the plan. Passive re-ranking should not make the interface feel
unpredictable.

### 4.4 Recommendations must be explainable

Every system-suggested item must have a short, human-readable reason such as:

- “Recommended for Maple's current development stage.”
- “It has been four days since the last recall session.”
- “This appointment is tomorrow.”
- “You chose three training days per week.”

### 4.5 User intent outranks optimization

The engine may suggest, prioritize, and warn. It should not silently override a
caregiver's explicit schedule, veterinarian-entered instruction, or choice to
skip an optional activity.

### 4.6 Safety is a content and interface responsibility

The engine schedules approved content; it does not invent veterinary guidance.
Safety-critical instructions require provenance, review, and clear language
outside the prioritization algorithm.

## 5. Terminology

### Plan

The shared, date-specific collection of plan items for one pet.

### Plan item

A task, event, reminder, or recommendation displayed in the plan.

### Task definition

The reusable description of an activity, such as “Brush coat” or “Practice
recall.”

### Task instance

One scheduled or generated occurrence of a task definition.

### Source

The origin of a plan item: user, schedule, health record, event, training
roadmap, development-stage rule, or system maintenance rule.

### Required item

An item backed by explicit care instructions, medication, a confirmed
appointment, or a user designation that should not be silently removed.

### Scheduled item

An activity the household intentionally placed on a date or recurrence pattern.

### Recommended item

An optional activity selected by the engine because it is timely and relevant.

### Upcoming item

An event or requirement outside the current day that benefits from advance
awareness or preparation.

### Development stage

A configurable life-stage label used to select suitable guidance. It is not a
medical diagnosis and should not be treated as a precise universal boundary.

### Local day

The calendar day in the pet household's configured time zone.

## 6. Plan structure

The Home screen should present the plan in this order:

1. **Needs attention**
2. **Today**
3. **Recommended**
4. **Coming up**
5. **Completed**

Empty sections should be hidden.

### 6.1 Needs attention

Contains overdue or unresolved required items, time-sensitive conflicts, and
important actions that cannot safely disappear into the normal list.

This section should be uncommon. It must not become a generic container for
everything unfinished.

### 6.2 Today

Contains required and household-scheduled items for the current date. Items may
be grouped into broad time windows when useful:

- Morning
- Midday
- Afternoon
- Evening
- Anytime

### 6.3 Recommended

Contains a deliberately small number of optional training, socialization,
handling, grooming, or preparation suggestions.

The default visible budget is:

- Up to **three** recommendations on a normal day
- Up to **one** recommendation on a reduced-capacity day
- Zero recommendations when urgent or unusually demanding required care makes
  additional suggestions inappropriate

The user may expand the section to see additional eligible ideas, but those
ideas should not count as part of the primary daily plan.

### 6.4 Coming up

Shows a small number of relevant future items, normally within the next seven
days. Longer lead times are allowed when preparation is necessary.

### 6.5 Completed

Collapses completed items while retaining the completion time and caregiver.
Users can expand the section, add a note, or undo an accidental completion.

## 7. Inputs

The engine may consume the following inputs when available.

### 7.1 Pet profile

- Birth date or estimated age
- Homecoming date
- Species
- Breed or breed group
- Sex where relevant to an approved rule
- Current life stage
- Health or mobility constraints entered by the owner
- Household time zone

Breed-specific logic is not required for MVP. Breed may be stored without
affecting recommendations until reviewed breed-specific content exists.

### 7.2 Household configuration

- Caregiver membership
- Default wake, meal, work, and sleep windows
- Available activity windows
- Preferred reminder behavior
- Normal, reduced, or custom daily capacity
- Days selected for recurring routines
- Locale and time zone

### 7.3 User-created schedules

- One-time tasks
- Recurring tasks
- Events and appointments
- User-selected priorities
- Explicit due dates and time windows

### 7.4 Health and care records

- Medication schedules
- Preventive-care schedules
- Vaccination or veterinary follow-ups entered by the user
- Grooming cadence
- Feeding routine
- Provider instructions

The app must preserve whether a schedule was entered by the owner, copied from
reviewed product content, or recorded from a professional instruction.

### 7.5 Training state

- Skills selected by the owner
- Skill prerequisites
- Current progress state
- Recent practice dates
- Desired practice frequency
- Recent difficulty or session outcome
- Paused skills

### 7.6 Socialization state

- Eligible experience categories
- Recent positive exposures
- Experiences marked unavailable, unsuitable, or paused
- User-selected goals

### 7.7 Recent plan history

- Completed items
- Skipped items and optional reasons
- Snoozed or rescheduled items
- Recent recommendation frequency
- Recently dismissed suggestions

### 7.8 Future context

Not part of the initial implementation, but the input contract should allow
later use of:

- Weather
- Travel
- Professional homework
- Wearable summaries
- Contextual AI recommendations

These inputs must not be simulated before the associated product capability
exists.

## 8. Task taxonomy

Every plan item has one primary category and one obligation class.

### 8.1 Primary categories

| Category | Examples |
| --- | --- |
| Health | Medication, vaccination follow-up, weight check |
| Feeding | Meal, food transition step |
| Routine | Potty opportunity, bedtime routine, crate routine |
| Training | Name response, recall, settle, handling exercise |
| Socialization | New surface, calm observation, household sound |
| Grooming | Brushing, nail handling, tooth care |
| Event | Veterinary appointment, puppy class, grooming visit |
| Preparation | Pack records, purchase food, prepare for appointment |
| Life | Weekly growth photo, milestone reflection |
| Household | Review invitation, update emergency contact |

### 8.2 Obligation classes

| Class | Meaning | Can disappear automatically? |
| --- | --- | --- |
| Required | Explicit care or confirmed commitment | No |
| Scheduled | Household intentionally scheduled it | No |
| Recommended | Timely optional suggestion | Yes |
| Informational | Advance notice or context | Yes |

### 8.3 Origin types

- `user_created`
- `recurring_schedule`
- `health_schedule`
- `calendar_event`
- `training_program`
- `development_rule`
- `socialization_rule`
- `system_preparation_rule`

Origin must remain available for explanation, analytics, editing rights, and
future debugging.

## 9. Content and rule model

The engine should separate four concepts:

1. **Content:** What the activity is and how to do it.
2. **Eligibility:** When it may be suggested.
3. **Scheduling:** When a specific occurrence is due.
4. **Presentation:** Where and how it appears in the plan.

This prevents instructional content from being duplicated inside scheduling
logic.

### 9.1 Rule requirements

Every system rule should have:

- Stable identifier
- Version
- Name
- Description
- Source or reviewer metadata
- Eligible species and life stages
- Optional minimum and maximum age guidance
- Prerequisites
- Exclusions and safety constraints
- Frequency or cooldown
- Estimated effort
- Default time window
- Category
- Default priority
- Explanation template
- Effective and retirement dates

### 9.2 Rule precedence

When instructions conflict, use this precedence:

1. Explicit professional schedule recorded by the owner
2. Explicit household schedule or user choice
3. Confirmed event or appointment
4. Reviewed product care rule
5. Training-program rule
6. General development-stage recommendation

The engine should surface a meaningful conflict rather than silently choose when
two high-precedence instructions cannot both be followed.

## 10. Plan-generation lifecycle

### 10.1 Initial generation

A plan is created when:

- The local day begins
- The user first opens the app on that local day
- A newly created pet has no plan for the current day

Generation must be idempotent: repeated requests for the same inputs and plan
version should not create duplicate task instances.

### 10.2 Meaningful regeneration

The plan may be recalculated when:

- A medication or care schedule is added or changed
- An event is created, moved, or cancelled
- The pet profile changes in a way that affects eligibility
- The user changes daily capacity
- A task is completed, skipped, snoozed, or rescheduled
- A training skill is started, paused, or completed
- A household time zone changes
- The user explicitly refreshes recommendations

Regeneration should preserve stable identifiers and user-entered changes.

### 10.3 Plan freezing

At the first meaningful interaction of the day, the visible recommended set
becomes stable. Completing one recommendation may reveal another only when the
user asks for another activity or when the product explicitly presents it as an
optional replacement.

This avoids a plan that seems to grow whenever an item is completed.

### 10.4 Historical plans

At the end of the local day:

- Completed items remain in history.
- Skipped items retain their disposition.
- Unfinished recommendations expire.
- Unfinished scheduled items follow their recurrence or rescheduling policy.
- Unfinished required items remain unresolved until completed, explicitly
  dismissed with appropriate confirmation, or replaced by an updated schedule.

Historical plans must not be retroactively altered by later rule versions.

## 11. Generation pipeline

The MVP engine should use a deterministic pipeline.

### Step 1 — Establish context

Resolve:

- Pet
- Household
- Local date and time zone
- Life stage
- Capacity setting
- Active schedules
- Relevant history window

If the birth date is unknown, use an explicitly entered estimated stage or
disable age-dependent suggestions until the user supplies sufficient context.

### Step 2 — Materialize obligations

Create instances for:

- Required health and medication schedules
- Confirmed events
- User-created one-time tasks
- Recurring household tasks

### Step 3 — Create preparation items

For future events, generate reviewed preparation tasks when their lead-time
rules are met. Example: “Gather vaccination records” before an appointment.

### Step 4 — Find eligible recommendations

Evaluate active rules against:

- Species and stage
- Prerequisites
- Exclusions
- Cooldown
- Recent progress
- User preferences
- Paused or dismissed activities

### Step 5 — Remove duplicates and conflicts

Combine equivalent activities and suppress recommendations already represented
by an obligation.

### Step 6 — Score eligible recommendations

Calculate a transparent priority score using the model in Section 12.

### Step 7 — Apply variety and capacity

Select a small set that fits the day, avoids unnecessary repetition, and
represents useful category diversity.

### Step 8 — Assign presentation

Place items into Needs attention, Today, Recommended, Coming up, or Completed.
Assign time windows without inventing exact times.

### Step 9 — Persist the plan

Save:

- Rule and content versions
- Input summary or reproducibility references
- Selected items and scores
- Explanations
- Plan version
- Generation timestamp

### Step 10 — Derive notification candidates

Create notification candidates from the saved plan. Notification delivery is a
separate process and must respect caregiver preferences and permissions.

## 12. Prioritization

### 12.1 Priority tiers

Priority tiers determine section and broad ordering before numeric scoring.

| Tier | Description | Examples |
| --- | --- | --- |
| P0 | Urgent unresolved required item | Missed time-sensitive medication |
| P1 | Required today | Medication, confirmed appointment |
| P2 | Intentionally scheduled today | Puppy class, selected training session |
| P3 | Timely recommendation | Stage-relevant training or socialization |
| P4 | Optional enrichment | Growth photo, extra activity |
| P5 | Future awareness | Appointment later in the week |

P0 is a product escalation label, not a medical assessment. Product copy must
not diagnose urgency beyond the source instruction.

### 12.2 Recommendation score

Within P3 and P4, use a configurable score:

```text
score =
  base_priority
  + stage_relevance
  + due_frequency
  + user_selected_goal
  + continuity_value
  + preparation_urgency
  + variety_bonus
  - recent_repetition
  - estimated_burden
  - dismissal_penalty
  - conflict_penalty
```

Initial component ranges should be small integers and kept in configuration.
The exact weights must be validated with scenario tests rather than embedded as
unexplained constants.

### 12.3 Hard constraints

A recommendation is ineligible when:

- Required profile information is missing
- A prerequisite is incomplete
- The task is paused
- A safety exclusion applies
- The activity was explicitly dismissed for its cooldown period
- An equivalent task is already present
- Its recurrence maximum has been reached
- The pet is outside the rule's approved stage or age range

### 12.4 Soft constraints

A recommendation may be deprioritized when:

- It appeared very recently
- The day already contains an activity from the same category
- Its estimated effort exceeds remaining capacity
- The household frequently skips it
- A higher-value continuation activity is available

Frequent skipping should prompt a preference review after an appropriate
threshold; it should not cause the system to infer that an essential task is
unimportant.

## 13. Capacity and plan size

### 13.1 Capacity modes

The household can choose:

- **Normal day:** Standard recommendation budget
- **Busy day:** One short optional recommendation at most
- **Essentials only:** Required and intentionally scheduled items only
- **Custom:** User chooses available time or desired plan intensity

The setting can apply to one day or become the household default.

### 13.2 Effort bands

Recommendations should use simple effort metadata:

- **Tiny:** About 1–2 minutes
- **Short:** About 3–5 minutes
- **Moderate:** About 6–15 minutes
- **Extended:** More than 15 minutes

These are planning estimates, not promises.

### 13.3 Selection limits

Default primary-plan limits:

- No limit on genuine required items
- No limit on household-scheduled items, though overload should be indicated
- Three visible optional recommendations
- One optional item from the same category unless continuity strongly favors a
  second
- Three visible upcoming items

If the user schedules an unrealistic number of items, the engine should offer
to spread optional work across the week without moving required care
automatically.

## 14. Deduplication and conflict handling

### 14.1 Equivalent items

Equivalent tasks should merge when they refer to the same pet, activity,
effective window, and outcome.

Example:

- A recurring “Brush Maple” task exists.
- The grooming rule also suggests brushing today.
- The recommendation is suppressed, and the scheduled task may display the
  grooming rationale.

### 14.2 Conflicting times

If two fixed commitments overlap:

- Keep both visible.
- Mark the conflict.
- Allow the user to edit one.
- Do not silently reschedule either.

### 14.3 Conflicting instructions

If a general product recommendation conflicts with an explicit recorded
professional instruction:

- Suppress the general recommendation.
- Preserve the professional instruction.
- Explain that the household's recorded care schedule is being followed.

The app must not determine that one medical instruction is clinically superior
to another.

### 14.4 Multiple pets

Each pet has an individual plan. A future household overview may combine items,
but completion must remain linked to the correct pet.

## 15. Time behavior

### 15.1 Time precision

Use the least precision necessary:

- Exact time for medications or confirmed appointments when provided
- Time window for flexible routines
- Anytime for untimed recommendations

The engine should not invent an exact time from a broad preference.

### 15.2 Time zones

- Plans use the household's configured time zone.
- A time-zone change should request confirmation when it would alter timed care.
- Travel behavior requires a dedicated design before medication schedules are
  automatically shifted.

### 15.3 Day boundary

The default day boundary is midnight in the household time zone.

For late-night routines that extend beyond midnight, an item may remain attached
to the prior waking day when its schedule explicitly defines that behavior.
This exception should be narrowly implemented and tested.

## 16. Plan-item lifecycle

### 16.1 States

```text
planned
  ├── completed
  ├── skipped
  ├── snoozed
  ├── rescheduled
  ├── cancelled
  └── expired
```

Additional state:

- `needs_attention` is a presentation flag, not a terminal state.

### 16.2 Complete

Completion records:

- Completing household member
- Completion timestamp
- Optional effective time if logged later
- Optional note, result, or media
- Source device and synchronization metadata

### 16.3 Skip

Optional items can be skipped without friction. The product may offer reasons:

- Not relevant today
- Already did this
- Too busy
- Pet not feeling well
- Do not suggest for now

Reasons are optional unless the action affects a required item.

Skipping a required or professional-schedule item should use language appropriate
to its source and may require confirmation. The app should never shame the user.

### 16.4 Snooze

Snooze changes the reminder or display emphasis within the current day. It does
not change the underlying due date.

### 16.5 Reschedule

Rescheduling creates or moves an occurrence to a new date or time and records
the change. For recurring tasks, the user chooses:

- This occurrence
- This and future occurrences

### 16.6 Undo

Recent completions and skips can be undone. Corrections must preserve an audit
trail without cluttering the normal interface.

## 17. Recurrence and missed items

### 17.1 Recurrence types

The scheduling model should support:

- Specific date and time
- Daily
- Selected weekdays
- Every N days
- Weekly
- Monthly by safe calendar rule
- Interval after last completion
- A finite series

Complex clinical recurrence rules should not be approximated. If the scheduler
cannot represent an instruction accurately, it must allow a simpler explicit
schedule or manual entry.

### 17.2 Missed required items

When a required item passes its due window:

- Mark it as needs attention.
- Retain the original due time.
- Show source-appropriate next-step language.
- Do not automatically mark it complete.
- Do not independently advise doubling, changing, or discontinuing a dose.

### 17.3 Missed scheduled items

A scheduled non-critical item remains visible until the end of its configured
window. Afterward, it can be rescheduled, skipped, or left unfinished according
to the schedule policy.

### 17.4 Missed recommendations

Recommendations expire at the end of the day. The engine may suggest the
activity on a future day if it remains eligible, but it should be a new instance
rather than yesterday's overdue item.

## 18. Household coordination

### 18.1 Shared state

All authorized household members see:

- The same current plan for a pet
- Current completion state
- Who completed an item
- Relevant notes
- Schedule changes

### 18.2 Assignment

MVP tasks may be:

- Unassigned
- Assigned to one household member
- Available to any household member

An unassigned item completed by any authorized member becomes complete for the
household.

### 18.3 Simultaneous completion

If two devices complete the same item:

- Treat the operation as idempotent.
- Preserve the earliest valid completion as the primary completion.
- Retain enough audit information to diagnose the duplicate.
- Notify neither user of an error when the final state is correct.

Medication tasks may require a more prominent recent-completion confirmation to
reduce accidental duplicate administration. This interaction needs dedicated
usability testing.

### 18.4 Activity attribution

Use reassuring, factual copy:

- “Completed by Sarah at 7:42 AM”
- “Rescheduled by Nic”

Avoid competitive leaderboards or caregiver scoring.

### 18.5 Permissions

The MVP may begin with household owners and full members, but the model should
leave room for:

- Owner
- Full caregiver
- Limited caregiver
- Read-only professional

Authorization must be enforced at the data layer, not only hidden in the user
interface.

## 19. Personalization

### 19.1 Explicit personalization

Users can control:

- Household routines
- Available days and time windows
- Reminder preferences
- Daily capacity
- Active training goals
- Paused activities
- Suggestion frequency

### 19.2 Behavioral adaptation

MVP adaptation should be conservative and explainable.

Allowed examples:

- Reduce repetition after recent completion.
- Continue a skill that the owner actively selected.
- Offer a preference review after repeated skips.
- Prefer shorter activities on a busy day.

Not allowed in MVP:

- Inferring a health condition
- Inferring household conflict
- Changing required care based on engagement
- Claiming the puppy has mastered a skill without explicit user input

### 19.3 New-user defaults

The first plan should work with minimal setup. Defaults should come from reviewed
templates selected using known stage and household preferences.

When information is unknown, the app should ask only for inputs necessary to
produce a safer or substantially more relevant plan.

## 20. Explainability

Every system recommendation should support a “Why this?” explanation with:

- Primary reason
- Relevant recent history when applicable
- Estimated effort
- Source category
- A way to adjust or pause the recommendation

Example:

> **Why recall practice?**  
> Recall is part of Maple's current foundations stage, and the last session was
> four days ago. This activity takes about five minutes.

Required items should show their source:

> Scheduled from Maple's medication record.

The interface should not expose numeric priority scores to users.

## 21. Notifications

The Daily Plan Engine produces notification candidates; a separate notification
service decides whether and where to deliver them.

### 21.1 Notification classes

- Time-sensitive required care
- Confirmed event reminder
- User-requested task reminder
- Daily Plan summary
- Optional recommendation
- Household completion update

### 21.2 Defaults

- Required care follows the explicit reminder configuration.
- Confirmed events use user-selected lead times.
- The Daily Plan may send one configurable morning summary.
- Optional recommendations should not generate multiple unsolicited alerts.
- Routine household completions should update in-app without notifying everyone
  unless requested.

### 21.3 Duplicate prevention

Before delivery, verify:

- The item is still active.
- It has not already been completed.
- Another device or caregiver has not just completed it.
- The user has permission to see the item.
- A notification with the same idempotency key has not been sent.

### 21.4 Quiet hours

Respect per-user quiet hours except where the user has explicitly configured a
time-sensitive care reminder. The product must clearly explain this exception
when the reminder is configured.

## 22. Safety and trust

### 22.1 Content governance

Health, training, socialization, nutrition, and development guidance should have:

- Identified source
- Reviewer status
- Jurisdiction or locale where relevant
- Version and review date
- Safety exclusions
- Escalation language

### 22.2 Veterinary boundary

PetCompanion can help record and remember care. It should not diagnose,
prescribe, or alter professional instructions.

When a user records a concerning symptom, the MVP may preserve the note and
offer neutral contact options if configured. It should not generate a treatment
plan.

### 22.3 Medication protections

Medication plan items require:

- Clear pet identity
- Medication name as entered
- Dose display when entered by the user
- Due time and last completion
- Completing caregiver
- Confirmation behavior proportionate to duplicate-dose risk
- No automatic dose calculation

### 22.4 Sensitive data

Plan generation and analytics should use the minimum data required. Health
details must not appear in lock-screen notification text unless the user opts
into that level of detail.

## 23. Offline and synchronization behavior

### 23.1 Offline access

Where supported by the final architecture, users should be able to:

- View the most recently synchronized plan
- Complete or skip an existing item
- Add a simple note

Operations should queue for synchronization.

### 23.2 Conflict resolution

Use operation-specific rules:

- Completion is idempotent.
- Text notes preserve both versions when they cannot be safely merged.
- Schedule edits use version checks and surface conflicts.
- Deletions use recoverable tombstones during the synchronization window.

### 23.3 Stale-plan indicator

If the current plan may be stale because synchronization has not occurred, show
a subtle status. Do not imply that another caregiver has not completed an item
when the app cannot verify current state.

## 24. Manual control

The owner must be able to:

- Add a task
- Edit user-created schedules
- Pin an optional item to Today
- Remove or pause a recommendation
- Select a different suggested activity
- Change capacity for the day
- Reschedule an occurrence
- Correct completion history

System-created historical records should remain auditable, even when hidden from
the normal interface.

## 25. Failure and empty states

### 25.1 Insufficient profile information

Show required household tasks and ask for the smallest missing input needed to
offer development-aware guidance.

### 25.2 No items today

Present a calm success state:

> You're all caught up. Add something to the plan or enjoy the day together.

Do not generate filler work to avoid an empty screen.

### 25.3 Engine unavailable

Show the last saved plan with its last-updated time. Manual tasks and existing
records should remain usable when possible.

### 25.4 Rule error

Exclude the faulty recommendation, record the rule failure for diagnosis, and
continue generating the rest of the plan. A non-essential rule failure should
not prevent required items from appearing.

### 25.5 Notification permission denied

Keep reminders visible in-app and explain how to enable device notifications.
Do not repeatedly prompt after dismissal.

## 26. Example plans

The following examples validate product behavior. They are illustrative product
scenarios, not veterinary schedules.

### 26.1 Pre-arrival plan

**Context**

- Puppy comes home in 10 days.
- Two household members are active.
- No daily care routine exists yet.

**Today**

- Confirm first veterinary appointment — scheduled by household
- Finish securing electrical cords — preparation checklist

**Recommended**

- Choose the first-night sleeping setup — because homecoming is approaching
- Review the household potty routine — short household preparation

**Coming up**

- Puppy homecoming — in 10 days
- First veterinary appointment — in 13 days

**Expected behavior**

- No feeding or potty completions appear before homecoming.
- Preparation recommendations use the expected homecoming date.
- The plan does not assume exact health requirements.

### 26.2 Normal day with a 10-week-old puppy

**Context**

- Normal capacity
- Recall is an active training goal.
- Paw handling was practiced yesterday.
- A veterinary appointment is three days away.

**Today**

- Breakfast — completed by Sarah at 7:42 AM
- Morning potty routine
- Evening meal

**Recommended**

- Practice name response for three minutes
- Calmly observe one new environment
- Gather records and questions — veterinary appointment in three days

**Coming up**

- Veterinary appointment — Friday at 2:00 PM
- Bring existing health records — prepare by Thursday

**Expected behavior**

- Paw handling is not selected again because it was practiced yesterday.
- Recall may remain in the eligible pool but does not force every active goal
  into the plan.
- The appointment is visible before its due date.
- `rule.event_prep_vet` surfaces preparation while the vet event is within its
  three-day lead window.

### 26.3 Busy household day

**Context**

- User selected Busy day.
- A medication task and puppy class are scheduled.

**Today**

- Medication — 8:00 AM
- Puppy class — 6:30 PM

**Recommended**

- Two-minute name-response practice

**Expected behavior**

- The engine does not add three more optional activities.
- The class may satisfy the day's broader training category for variety scoring.

### 26.4 Essentials-only day

**Context**

- Puppy is not feeling well.
- Owner selects Essentials only.

**Today**

- User-entered care task
- Scheduled medication
- Confirmed veterinary call

**Recommended**

- No recommendations

**Expected behavior**

- Training and socialization suggestions are suppressed.
- Existing required care remains visible.
- The app does not infer a condition or provide treatment.

### 26.5 Missed medication reminder

**Context**

- A user-entered medication occurrence passed its configured time.
- No household member has recorded completion.

**Needs attention**

- Medication was scheduled for 8:00 AM — check the recorded care instructions

**Expected behavior**

- The item remains unresolved.
- The app does not say to double or skip a dose.
- Another caregiver can see the same state.
- Completion requires clear pet and medication context.

### 26.6 Repeatedly skipped recommendation

**Context**

- “Practice settle” has been skipped several times as “Too busy.”

**Expected behavior**

- The engine reduces how often it surfaces the activity.
- It offers a preference such as a shorter version or fewer training days.
- It does not mark the skill complete.
- It does not interpret the skipping as a health or behavior problem.

### 26.7 Two caregivers complete the same task

**Context**

- Both devices were temporarily offline.
- Both users mark breakfast complete.

**Expected behavior**

- The household sees one completed breakfast item.
- The earliest valid completion is displayed.
- Duplicate operations remain available for audit.
- The plan does not create a second meal or show a frightening error.

### 26.8 Appointment moved during the day

**Context**

- A veterinary appointment moves from today to tomorrow.

**Expected behavior**

- The Today event updates without duplicating.
- Preparation tasks retain completion.
- Notification candidates for the old time are cancelled.
- Tomorrow's Coming up section reflects the new time.

## 27. Edge-case checklist

Before MVP completion, scenario tests must cover:

- Unknown birth date
- Estimated age
- Homecoming date in the future
- Multiple pets with similar names
- Household member removed during the day
- Pet moved to another household
- Daylight-saving transition
- Household time-zone change
- Recurrence on a nonexistent calendar date
- Leap day
- App opened after several days offline
- Duplicate completion from two devices
- Schedule edited while another user completes an occurrence
- Notification delivered after another caregiver completes the task
- Deleted or cancelled appointment
- Training prerequisite removed
- Rule version retired
- More required items than fit on one screen
- No eligible recommendations
- All recommendations dismissed
- User changes capacity after the plan is generated
- Pet profile archived or deceased
- Professional instruction conflicts with a general rule
- Media upload failure after a task completion

## 28. Data requirements

The detailed schema belongs in [Data Model](10-data-model.md), but the engine
requires at least the following concepts:

- `Plan`
- `PlanVersion`
- `PlanItem`
- `TaskDefinition`
- `TaskOccurrence`
- `RecurrenceRule`
- `Completion`
- `Disposition`
- `RecommendationRule`
- `ContentVersion`
- `DevelopmentStage`
- `HouseholdPreference`
- `PetPreference`
- `NotificationCandidate`
- `AuditEvent`

### 28.1 Minimum plan-item fields

- Identifier
- Pet identifier
- Plan identifier
- Local date
- Category
- Obligation class
- Origin type and origin identifier
- Title and optional instructions reference
- Scheduled time or time window
- Priority tier
- State
- Assignment
- Estimated effort
- Explanation
- Rule and content versions
- Creation and update timestamps

## 29. Analytics and success measures

Analytics must avoid unnecessary sensitive content. Prefer structured event
metadata over free-form notes.

### 29.1 Core events

- Plan generated
- Plan viewed
- Item viewed
- Item completed
- Item skipped
- Item snoozed
- Item rescheduled
- Recommendation replaced
- Explanation opened
- Capacity changed
- Notification candidate created
- Notification delivered
- Notification acted upon

### 29.2 Product measures

- Time from opening the app to first plan action
- Percentage of active days with a plan view
- Completion rate by obligation class
- Skip rate and reason by recommendation category
- Percentage of plans within the intended recommendation budget
- Recommendation replacement rate
- Duplicate household completion rate
- Notification-to-completion latency
- Week 1, week 4, month 3, and month 6 household retention

### 29.3 Guardrail measures

- Average visible item count
- Required items hidden or incorrectly expired
- Duplicate plan-item rate
- Stale notifications
- Synchronization conflict rate
- Repeated dismissals
- Users switching to Essentials only after receiving an overloaded plan

Success is not maximizing task volume. A shorter plan that helps a household
complete appropriate care is preferable to a larger plan with more engagement.

## 30. Acceptance criteria

The MVP Daily Plan Engine is acceptable when:

1. It creates one stable plan per pet per local day without duplicate items.
2. Required and scheduled items appear ahead of optional recommendations.
3. A normal day displays no more than three primary recommendations by default.
4. A Busy day displays no more than one primary recommendation.
5. Essentials only suppresses optional recommendations.
6. Equivalent scheduled and recommended tasks are deduplicated.
7. Every recommendation has a plain-language explanation.
8. Completions identify the household member and synchronize across devices.
9. Simultaneous completion of the same occurrence resolves idempotently.
10. Missed recommendations expire instead of creating a backlog.
11. Missed required items remain visible and are not silently rescheduled.
12. Rescheduling one recurring occurrence does not alter future occurrences
    unless the user chooses that option.
13. A general rule cannot override an explicit professional schedule recorded by
    the owner.
14. Rule failures cannot prevent unrelated required items from appearing.
15. Notification delivery checks current completion state and avoids duplicates.
16. Historical plans retain the rule and content versions used at generation.
17. The plan remains usable with no eligible recommendations.
18. The engine behaves correctly across the edge cases selected for MVP testing.

## 31. Scenario-test format

Each engine rule should be testable using a human-readable fixture:

```yaml
scenario: busy day with medication and class
local_date: 2026-12-14
capacity: busy
pet:
  stage: foundations
obligations:
  - medication at 08:00
  - puppy_class at 18:30
eligible_recommendations:
  - name_response
  - recall
  - paw_handling
expect:
  required:
    - medication
    - puppy_class
  recommended_count_max: 1
  no_duplicates: true
```

The production format may differ, but product scenarios should remain readable
by non-engineers.

## 32. Open questions

- Should the first release generate plans on the server, device, or through a
  hybrid model?
- What is the smallest household setup required before the first plan?
- Should meals and potty opportunities be default plan items or opt-in routine
  templates?
- Which medication confirmation interaction best reduces accidental duplicate
  administration without adding excessive friction?
- How should an owner record “completed, but I forgot to log it”?
- Should one household capacity setting apply to every pet or be pet-specific?
- When should the engine suggest changing a development stage manually?
- Which content domains require named professional review before private use,
  beta testing, and public release?
- What initial rule catalogue is necessary to make the plan valuable without
  overwhelming users?
- Should the Home screen combine multiple pet plans in a future release?

## 33. Delivery sequence

### 33.1 Product definition

- Resolve the open questions that affect MVP scope.
- Define the first task and recommendation catalogue.
- Identify content requiring professional review.
- Turn the example plans into a broader scenario suite.

### 33.2 Experience design

- Wireframe plan sections and item states.
- Prototype completion, skip, snooze, and reschedule.
- Test plan size and explanation language.
- Test shared-care and medication-completion interactions.

### 33.3 Domain design

- Model definitions, occurrences, plans, dispositions, and audit events.
- Define recurrence semantics.
- Define rule versioning and reproducibility.
- Specify synchronization and conflict resolution.

### 33.4 Technical proof

- Implement the deterministic rule pipeline using fixtures.
- Validate idempotent generation and completion.
- Test time zones, recurrence, and simultaneous household actions.
- Instrument guardrail metrics.

### 33.5 MVP integration

- Connect profiles, health, training, planner, and notifications.
- Seed reviewed content.
- Exercise realistic pre-arrival and puppy-care scenarios.
- Iterate using real household use before external release.

## 34. Decisions established by this draft

This specification proposes the following working decisions:

- The MVP engine is deterministic and rules-based.
- Each pet has one shared plan per local calendar day.
- Required and scheduled items are distinct from recommendations.
- The normal recommendation budget is three; Busy day is one; Essentials only
  is zero.
- Recommendations expire rather than becoming overdue.
- The visible recommendation set becomes stable after meaningful interaction.
- Household completions are attributed and idempotent.
- Notification delivery is separate from plan generation.
- Historical plans retain the rule and content versions used to create them.

These decisions should be validated through product scenarios and prototypes
before the specification moves from Draft to Review.
