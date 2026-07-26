# PetCompanion Product Requirements Document

**Status:** Draft  
**Version:** 0.1  
**Last updated:** 2026-07-26  
**Working product name:** PetCompanion  
**Initial release focus:** Puppy ownership

## 1. Executive summary

PetCompanion is a guided care and coordination platform for pet owners. Its
first release helps new puppy owners understand what to do today, coordinate
care across a household, prepare for what comes next, and preserve a meaningful
record of their puppy's development.

The product is not intended to be another pet encyclopedia or a collection of
unrelated trackers. Its central experience is a personalized Daily Plan that
combines the puppy's age, development stage, schedule, health requirements,
training progress, and household activity into a short, practical set of
priorities.

The initial product will be designed around a real first-use household raising a
Golden Retriever puppy, while retaining the flexibility required for a future
public release and lifelong dog care.

## 2. Mission

Give every pet owner the confidence, guidance, and tools needed to raise a
healthy, happy, well-trained companion through personalized daily guidance and
lifelong care.

## 3. Vision

PetCompanion becomes the central hub for every stage of pet ownership—from the
period before adoption through a pet's senior years.

Rather than making owners search for information and manually translate it into
a routine, PetCompanion proactively communicates:

- What matters today
- What has already been completed
- What is coming next
- How the pet is progressing

See [Product Vision](01-product-vision.md) for the extended vision and product
principles.

## 4. Problem statement

New puppy owners are responsible for many overlapping activities:

- Training and socialization
- Feeding and potty routines
- Veterinary care and vaccinations
- Medication and preventive care
- Grooming and handling
- Appointments, classes, and events
- Supplies and household preparation
- Photos, milestones, and memories

The information needed to manage these responsibilities is scattered across
websites, videos, calendars, reminders, notes, paper records, and conversations
between caregivers. Guidance is often conflicting, generic, or disconnected
from the individual puppy's age and progress.

This creates several recurring questions:

- What should we focus on this week?
- Did someone already feed or medicate the puppy?
- Are we behind on training or socialization?
- When is the next vaccination or appointment?
- What do we need to prepare for next?
- Is this behavior normal for the puppy's current stage?

PetCompanion should reduce this uncertainty without creating another complicated
system for owners to maintain.

## 5. Product positioning

PetCompanion is the operating system for pet ownership.

The first release is a focused puppy companion, but the product foundation
should support adolescent, adult, and senior life stages without a redesign.

### PetCompanion is

- A proactive guide
- A shared household coordinator
- A time- and development-aware planner
- A trusted record of care, progress, and memories

### PetCompanion is not

- A generic reminder application
- A static pet encyclopedia
- A veterinary diagnosis service
- A social network
- A collection of disconnected tracking tools

## 6. Product principles

### 6.1 Guidance over information

The product should translate relevant knowledge into clear actions. Educational
content supports a decision or task rather than becoming the primary experience.

### 6.2 Time-centric by default

The puppy's age, development stage, schedule, and recent progress determine what
the product emphasizes.

### 6.3 Reduce cognitive load

Owners should be able to understand today's priorities within seconds. Common
actions should require minimal input, and optional features should not obscure
essential care.

### 6.4 Shared care without shared credentials

Each caregiver should have an individual account within a shared household.
Actions are synchronized and attributed so household members can coordinate
without asking whether something has already been completed.

### 6.5 Calm, trustworthy, and worth opening daily

The product should feel warm and reassuring rather than childish, clinical, or
overstimulating. Progress mechanics should encourage consistency without
punishing imperfect days.

### 6.6 Built for the entire life

The MVP remains puppy-focused, while foundational concepts allow the experience
to evolve through adolescence, adulthood, and senior care.

### 6.7 Advice must be responsible

General care guidance must be distinguishable from veterinary advice.
Safety-critical records and reminders require clear provenance, limitations,
and escalation language where appropriate.

## 7. Target users

### 7.1 Primary persona: first-time puppy parent

Typically an individual, couple, or young family preparing for or raising their
first puppy.

**Goals**

- Raise a healthy, confident, well-behaved dog
- Know what to prioritize at each stage
- Build consistent household routines
- Avoid missing important health and development milestones
- Feel confident without becoming overwhelmed

**Pain points**

- Conflicting advice
- Not knowing what they do not know
- Difficulty coordinating between caregivers
- Too many tools and information sources
- Uncertainty about whether progress is appropriate

### 7.2 Secondary persona: experienced organized owner

An experienced dog owner who needs less instruction but values shared schedules,
records, routines, progress tracking, and memories.

### 7.3 Future users

- Breeders transferring puppy history to a new household
- Trainers assigning and reviewing homework
- Veterinarians sharing records or care instructions
- Groomers, dog walkers, and pet sitters with limited permissions

Detailed personas and research findings will live in
[Target Audience](02-target-audience.md).

## 8. Core experience

### 8.1 Today's Plan

The Home experience should immediately establish:

- The puppy's current age and development stage
- Required care tasks
- A small number of recommended priorities
- Completed household activity
- Upcoming appointments or deadlines
- One or more timely training or socialization recommendations

Example:

> Good morning  
> Maple is 12 weeks old  
>
> Today's priorities  
> Breakfast — completed by Sarah  
> Potty break  
> Five-minute recall practice  
> Meet one new person  
> Handle paws for two minutes  
>
> Coming soon  
> Vaccination appointment in five days  
>
> Recommended  
> Maple is ready to begin “Leave It”

The Daily Plan is the product's primary engagement loop and the integration
point for care, training, planning, and progress.

The rules and behavior of this system will be defined in
[Daily Plan Engine](12-daily-plan-engine.md).

### 8.2 Development-aware guidance

PetCompanion should understand more than chronological age. Guidance should
adapt to meaningful puppy stages, initially expected to include:

- Preparing for arrival
- Settling in
- Foundations
- Exploration and socialization
- Teething
- Early adolescence
- Adolescence
- Adulthood

Stage boundaries and recommendations must be treated as adaptable guidance, not
false precision. Breed, health, environment, and individual progress may alter
what is appropriate.

### 8.3 Household coordination

The system should model:

```text
User
  └── Household membership
        └── Household
              └── Pet
                    ├── Plans and tasks
                    ├── Training
                    ├── Health
                    ├── Events
                    └── Memories
```

Each person uses an individual account. Household activity is synchronized and
attributed. The foundation should support roles and limited access later, even
if MVP members initially have equivalent permissions.

## 9. Product pillars

### 9.1 Care

- Health history
- Vaccinations
- Medication and preventive care
- Veterinary contacts and appointments
- Weight and growth
- Feeding
- Grooming and handling
- Important documents

### 9.2 Training

- Age-appropriate training roadmap
- Searchable skill catalogue
- Short lesson instructions
- Recommended session duration and frequency
- Training session logging
- Progress states
- Common mistakes
- Supporting images or video when reliable content is available

The initial training philosophy should prioritize humane, reward-based methods.
Content quality and expert review requirements remain to be defined.

### 9.3 Socialization

- Guided exposure categories
- Positive-experience logging
- Progress across people, animals, sounds, surfaces, environments, and transport
- Timely suggestions based on development stage
- Safety and vaccination-aware context

The experience should reward thoughtful, positive exposure rather than
encouraging owners to race through a checklist.

### 9.4 Planner

- Daily Plan
- Calendar
- One-time and recurring tasks
- Reminders
- Appointments and events
- Manual event creation
- Future poster capture and text extraction

### 9.5 Life

- Photos and videos
- Milestones
- Journal entries
- Growth photos
- Events and first experiences
- A chronological life timeline

Media should be connectable to training sessions, events, milestones, and health
records rather than existing only in a separate gallery.

### 9.6 Insights

- Training consistency
- Socialization breadth
- Task completion patterns
- Weight and growth trends
- Upcoming care requirements
- Developmental progress

Insights should help an owner make decisions. Vanity charts without a clear use
should not be included.

See [Core Features](03-core-features.md) for feature-level specifications as they
are developed.

## 10. Key user journeys

### 10.1 Before adoption

1. Create an account and household.
2. Add an expected puppy profile.
3. Enter the birth date and expected homecoming date when known.
4. Receive a preparation timeline.
5. Track supplies, home preparation, records, and appointments.
6. Invite another caregiver.
7. Transition automatically into the homecoming experience.

### 10.2 Puppy onboarding

1. Create or complete the puppy profile.
2. Add known health and vaccination information.
3. Confirm household routine and notification preferences.
4. Review the current development stage.
5. Receive the first Daily Plan.

### 10.3 Daily household use

1. Open the app and scan today's priorities.
2. See what another caregiver has already completed.
3. Complete, skip, or reschedule a task.
4. Follow a short training or care instruction.
5. Add a quick note, photo, measurement, or event.
6. Preview what is coming next.

### 10.4 Training a skill

1. Open a suggested skill or browse the catalogue.
2. Review prerequisites and a concise lesson.
3. Start and complete a short session.
4. Record outcome and optional media.
5. Receive an appropriate future practice suggestion.

### 10.5 Recording health care

1. Add an appointment, vaccination, medication, measurement, or document.
2. Associate it with the puppy and relevant provider.
3. Create follow-up reminders where needed.
4. Surface the relevant item in the Daily Plan.
5. Make the record available to authorized household members.

### 10.6 Capturing an event

1. Enter event details manually.
2. In a later release, photograph a poster or import from another source.
3. Review extracted date, time, location, and notes.
4. Save the event and choose reminders.
5. Attach memories after attendance.

Detailed flows and acceptance criteria will live in
[User Stories](04-user-stories.md).

## 11. Information architecture

The working top-level model is:

- **Home:** Daily Plan, current stage, priorities, and upcoming items
- **Pets:** profiles and pet-specific records
- **Training:** roadmap, catalogue, lessons, sessions, and socialization
- **Planner:** calendar, tasks, reminders, and events
- **Life:** timeline, milestones, journal, photos, and videos
- **Profile:** account, household, members, preferences, privacy, and settings

This is a hypothesis, not a final navigation commitment. User flows should
determine whether each destination deserves top-level placement and whether
Care belongs within Pets or needs a more direct route.

See [Information Architecture](05-information-architecture.md).

## 12. Functional requirements

### 12.1 Accounts and households

- Users can create and authenticate individual accounts.
- A user can create or join a household.
- A household can contain multiple members and pets.
- Authorized members see synchronized household activity.
- Records retain who created or completed them.
- Invitation and removal behavior must be defined before public release.

### 12.2 Pet profiles

- Store name, photo, species, breed, sex, birth date, homecoming date, and
  relevant care details.
- Support incomplete information during the pre-adoption period.
- Derive age and development stage from profile data and configuration.
- Support multiple pets without complicating the single-pet experience.

### 12.3 Daily Plan

- Generate a plan for the current local day.
- Separate required, scheduled, recommended, and upcoming items.
- Respect household routines, preferences, and completed activity.
- Allow completion, reassignment where supported, skipping, and rescheduling.
- Preserve history without carrying every missed optional item into a backlog.
- Explain adaptive recommendations in plain language.

### 12.4 Training and socialization

- Browse and search a structured catalogue.
- Filter or recommend activities using age, stage, prerequisites, and progress.
- Record short sessions and progress.
- Schedule future practice.
- Associate notes and media with a session.

### 12.5 Health and care

- Record vaccinations, medication, weight, appointments, providers, and notes.
- Support recurring medication or preventive-care schedules.
- Attach relevant documents or media.
- Display appropriate disclaimers and urgent-care guidance boundaries.

### 12.6 Planner and reminders

- Create one-time and recurring tasks or events.
- Display upcoming care, training, and life events in one coherent schedule.
- Deliver configurable reminders to the appropriate household members.
- Handle time zones, daylight-saving changes, and notification permissions.

### 12.7 Milestones and media

- Capture photos and videos or select existing media.
- Associate media with a pet, date, task, session, event, or milestone.
- Browse a chronological timeline.
- Retain original capture time separately from upload time.

## 13. Non-functional requirements

### 13.1 Privacy and security

- Treat health records, household data, location, and media as private by
  default.
- Enforce household authorization on every protected record.
- Avoid shared-account patterns.
- Define export, deletion, retention, and account-recovery behavior before
  public launch.
- Collect only data needed to provide a clear product benefit.

### 13.2 Reliability

- Care records and task completion must not be silently lost.
- Synchronization conflicts must resolve predictably and preserve attribution.
- Reminders should degrade safely when notifications are unavailable.
- Core records should remain accessible during intermittent connectivity where
  the selected architecture reasonably permits it.

### 13.3 Accessibility

- Target WCAG 2.2 AA for applicable interfaces.
- Support platform text scaling, screen readers, sufficient contrast, and
  reduced motion.
- Do not use color as the only indicator of status.
- Keep frequent actions comfortably operable with one hand on mobile.

### 13.4 Performance

- The Daily Plan should feel immediately available at launch.
- Common logging actions should provide instant feedback.
- Media processing and synchronization should not block core planning and care
  workflows.

### 13.5 Explainability

- Recommendations should communicate why they appear.
- Rules affecting health or development guidance should have traceable sources
  and versions.
- The product must not present uncertain general guidance as a personalized
  medical conclusion.

## 14. Design direction

The intended experience is:

- Warm
- Calm
- Modern
- Spacious
- Friendly
- Premium
- Trustworthy

The product should avoid:

- Childish cartoon styling
- Dense dashboards
- Excessive nested navigation
- Gamification that produces guilt
- Unexplained scores
- Clinical language where plain language is sufficient

The interface should prioritize today's actions while allowing deeper records
to remain discoverable.

See [UI Design System](09-ui-design-system.md).

## 15. High-level domain model

Core concepts currently include:

- User
- Household
- Household Member
- Pet
- Development Stage
- Plan
- Task
- Task Completion
- Training Skill
- Training Session
- Socialization Experience
- Health Record
- Medication Schedule
- Event
- Reminder
- Media
- Journal Entry
- Milestone

The implementation model must distinguish between reusable catalogue content,
rules or templates, scheduled instances, and user-recorded outcomes.

See [Data Model](10-data-model.md).

## 16. MVP scope

### 16.1 Must have

- Individual user accounts
- Shared household foundation
- Puppy profiles
- Age and development-stage awareness
- Daily Plan, including the pre-arrival preparation variant and homecoming
  countdown
- Tasks, scheduling, and reminders
- Training catalogue and progress
- Basic socialization tracking
- Core health and vaccination records
- Calendar
- Milestones and photos

### 16.2 Should have if capacity permits

- Expanded pre-arrival preparation content breadth
- Weight history and simple growth visualization
- Grooming schedules
- Journal entries
- Supporting training media
- Basic household activity attribution

### 16.3 Excluded from MVP

- AI coach
- Automated behavior analysis
- Wearable integrations
- Trainer, breeder, or veterinarian portals
- Veterinary record synchronization
- Marketplace
- Social feed or community
- Insurance and food recommendations
- Automatic poster scanning
- Automatic first-year video generation
- Broad support for species other than dogs

Final priorities require effort estimates and validation of the Daily Plan
experience.

## 17. Success measures

Initial metrics should measure whether the product provides sustained guidance,
not merely whether it is downloaded.

### Proposed product outcomes

- Users can identify today's priorities without searching.
- Household members can tell what has already been completed.
- Owners report greater confidence about what to do next.
- Important scheduled care is completed on time.
- The product remains useful beyond the puppy's first weeks at home.

### Candidate quantitative measures

- Onboarding completion
- Time to first useful Daily Plan
- Daily and weekly active households
- Daily Plan view and completion rate
- Percentage of active households with multiple members
- Training sessions logged per active week
- Health and appointment reminders completed on time
- Week 1, week 4, month 3, and month 6 retention

Numeric targets will be established after an initial baseline exists. Targets
from the earliest brainstorm—such as 60% Daily Plan completion and 70% weekly
retention—should be treated as hypotheses rather than commitments.

## 18. Risks and open questions

### Product risks

- The Daily Plan becomes a noisy checklist instead of meaningful guidance.
- Owners experience guilt or notification fatigue.
- The MVP attempts to cover too many care categories.
- Training guidance lacks sufficient authority or consistency.
- The product is useful only during the first few weeks.

### Safety and trust risks

- General guidance is mistaken for veterinary advice.
- Health schedules vary by location, provider, and individual animal.
- Socialization advice fails to account for vaccination or disease risk.
- Shared-household permissions expose private information.

### Technical risks

- Scheduling and recurrence rules become difficult to reason about.
- Offline activity produces synchronization conflicts.
- Media storage creates unexpected cost or privacy obligations.
- Future flexibility introduces premature complexity into the MVP.

### Open questions

- Which mobile platforms should the first implementation target?
- Is an account required before the user experiences initial value?
- What is the minimum viable form of household sharing?
- Which content requires professional review?
- How are development stages defined and localized?
- Which care schedules are product defaults versus user- or vet-entered?
- How many items should appear in a useful Daily Plan?
- Which events should generate notifications, and for whom?
- What must work offline?
- What information should be exportable for a veterinarian or trainer?

Open decisions and their rationale will be tracked in
[Decision Log](13-decision-log.md).

## 19. Roadmap

### Phase 0 — Product discovery

- Complete and review this PRD
- Fully specify the Daily Plan Engine
- Define critical user stories and acceptance criteria
- Validate primary needs with prospective users
- Finalize MVP scope and success measures

### Phase 1 — Experience design

- Map core journeys
- Validate information architecture
- Produce wireframes
- Establish the visual design system
- Prototype and test the Daily Plan

### Phase 2 — Technical planning

- Select platforms and implementation stack
- Finalize the domain model
- Define authentication, permissions, synchronization, and notifications
- Establish environments, privacy requirements, and delivery milestones

### Phase 3 — MVP

- Build and test the smallest complete daily-guidance loop
- Add supporting training, care, planning, and memory workflows
- Use the product with the initial household and puppy
- Iterate from observed use before preparing a public release

### Later horizons

- Full dog life-cycle support
- Richer family and caregiver roles
- Context-aware AI assistance
- Trainer and breeder collaboration
- Veterinary integrations
- Carefully selected commercial services

See [Roadmap](08-roadmap.md).

## 20. Release gates

The MVP should not be considered ready for external users until:

- The Daily Plan produces understandable and manageable priorities.
- Two household members can coordinate without shared credentials or ambiguous
  completion state.
- Core records synchronize reliably.
- Health guidance boundaries and content provenance are defined.
- Key flows meet accessibility requirements.
- Privacy, export, and deletion behavior are documented.
- Analytics measure product outcomes without collecting unnecessary sensitive
  information.
- The product has been exercised through realistic pre-adoption and puppy-care
  scenarios.

## 21. Supporting specifications

This PRD owns overall product intent and scope. Detailed decisions belong in the
following living documents:

1. [Product Vision](01-product-vision.md)
2. [Target Audience](02-target-audience.md)
3. [Core Features](03-core-features.md)
4. [User Stories](04-user-stories.md)
5. [Information Architecture](05-information-architecture.md)
6. [Technical Architecture](06-technical-architecture.md)
7. [Monetization](07-monetization.md)
8. [Roadmap](08-roadmap.md)
9. [UI Design System](09-ui-design-system.md)
10. [Data Model](10-data-model.md)
11. [API and Integrations](11-api-integrations.md)
12. [Daily Plan Engine](12-daily-plan-engine.md)
13. [Decision Log](13-decision-log.md)
14. [Wireframes — Onboarding and Home](14-wireframes-onboarding-home.md)
15. [Content Catalogue (Seed)](15-content-catalogue.md)
16. [Wireframes — Planner, Training, Care, Life, Settings](16-wireframes-planner-training-care-life-settings.md)
17. [Implementation Plan — Slice A](17-implementation-plan-slice-a.md)
18. [Content Copy — Lessons and Stage Language](18-content-copy.md)

## 22. Immediate next step

Planning state as of 2026-07-26:

- [Information Architecture](05-information-architecture.md) and
  [Data Model](10-data-model.md): complete; their structural decisions are
  **Accepted** in the [Decision Log](13-decision-log.md).
- Pre-arrival mode is promoted into Slice A (Accepted decision).
- [Wireframes for onboarding and Home](14-wireframes-onboarding-home.md):
  drafted.
- [Technical Architecture](06-technical-architecture.md): drafted, with the
  implementation stack **Proposed** and awaiting approval.
- [Content Catalogue seed](15-content-catalogue.md): drafted, all entries
  `pending_professional_review`; its governance decision is Proposed.

All planning-phase decisions are now **Accepted** in the
[Decision Log](13-decision-log.md) (2026-07-26 owner approvals), and the
Phase 1/2 planning deliverables exist: full wireframe coverage (docs 14, 16),
[UI Design System foundations](09-ui-design-system.md),
[Technical Architecture](06-technical-architecture.md),
[Content Catalogue](15-content-catalogue.md) with authored
[lesson and stage copy](18-content-copy.md), and the
[Slice A Implementation Plan](17-implementation-plan-slice-a.md).

Next steps, in order:

1. **Begin Slice A implementation** per the
   [implementation plan](17-implementation-plan-slice-a.md): WP-0 repository
   and environments, then the walking skeleton (WP-1–WP-4). This is the
   handoff point to the implementing coding agent.
2. Produce visual designs from the wireframes using the design-system tokens
   (can run in parallel with WP-0–WP-4; required before WP-5 Home UI polish).
3. Identify the professional reviewer for training, socialization, and stage
   content — a release gate before any external audience, not before private
   use.
4. Confirm the two device platforms and schedule the non-developer
   acceptance run for the end of Slice A.
