# Core Feature Specification

**Status:** Draft  
**Version:** 0.2  
**Last updated:** 2026-07-26  
**Related documents:** [Product Requirements Document](00-product-requirements-document.md),
[User Stories](04-user-stories.md), and
[Daily Plan Engine](12-daily-plan-engine.md)

## 1. Purpose

This document converts the PetCompanion vision into bounded product
capabilities. It defines what each feature must accomplish, what is excluded,
which other capabilities it depends on, and how the team will know it works.

This is a product specification, not a commitment to a particular platform or
technical implementation.

## 2. Prioritization

### P0 — Core loop

Required to prove the product's central promise:

- Individual accounts
- Shared household
- Puppy profile
- Daily Plan, including the pre-arrival preparation variant
- Tasks and completion history
- Basic scheduling and in-app reminders
- Two-caregiver synchronization

### P1 — Complete private MVP

Required for the intended puppy-care experience:

- Development-stage timeline
- Training catalogue and progress
- Socialization tracking
- Health and vaccination records
- Calendar and device notifications
- Milestones and photos
- Privacy, export, and deletion foundations

### P2 — Valuable extension

Useful after the core experience is reliable:

- Expanded pre-arrival preparation content breadth (the core pre-arrival plan
  variant is P0 — see the 2026-07-26 pre-arrival decision in the
  [Decision Log](13-decision-log.md))
- Growth visualization
- Journal
- Richer grooming routines
- Video attachments
- Poster capture and event extraction

### Deferred

Not part of the MVP:

- Generative AI coach
- Wearable integrations
- Trainer, breeder, or veterinarian portals
- Veterinary-record synchronization
- Marketplace
- Social feed or community
- Broad multi-species support
- Automatic first-year video generation

## 3. Smallest complete product loop

The first end-to-end release slice must allow:

1. A user to create an account.
2. The user to create a household.
3. The user to add a puppy profile.
4. PetCompanion to create a useful plan for the current day.
5. The user to invite a second caregiver.
6. Either caregiver to complete a shared task.
7. Both caregivers to see the same attributed completion.
8. The system to preserve the result and generate the following day's plan
   without recreating completed occurrences.

Anything that does not support or validate this loop should not delay the first
working product slice.

## 4. Cross-feature requirements

Every MVP feature must:

- Enforce household authorization at the data layer.
- Retain pet identity on pet-specific actions.
- Support loading, empty, error, and unavailable states.
- Provide accessible names, focus behavior, contrast, and text scaling.
- Use the household time zone for calendar behavior.
- Preserve created, updated, and actor metadata where accountability matters.
- Avoid presenting general guidance as veterinary diagnosis or instruction.
- Support analytics using structured metadata rather than sensitive free text.
- Define offline behavior instead of failing ambiguously.
- Use recoverable deletion where synchronization or accidental loss is a risk.

## 5. Feature inventory

| ID | Capability | Priority | Primary outcome |
| --- | --- | --- | --- |
| F01 | Account and authentication | P0 | Each caregiver has a secure identity |
| F02 | Household and membership | P0 | Care is shared without shared credentials |
| F03 | Pet profile and lifecycle | P0 | Guidance has sufficient pet context |
| F04 | Daily Plan | P0 | Owners know what matters today |
| F05 | Tasks, schedules, and completion | P0 | Plans can be acted on and remembered |
| F06 | Shared activity and synchronization | P0 | Caregivers see one trustworthy state |
| F07 | Development timeline | P1 | Owners know what is relevant now and next |
| F08 | Training catalogue and progress | P1 | Owners can practice suitable skills |
| F09 | Socialization passport | P1 | Owners can plan and record positive exposure |
| F10 | Health and care records | P1 | Important care history and schedules are organized |
| F11 | Calendar and notifications | P1 | Time-sensitive commitments are not overlooked |
| F12 | Milestones, journal, and media | P1/P2 | Progress and memories form a meaningful timeline |
| F13 | Settings, privacy, and data control | P1 | Users retain control and trust |
| F14 | Product analytics and diagnostics | P0/P1 | The product can be improved safely |

## 6. F01 — Account and authentication

### Objective

Give every caregiver an individual, recoverable identity without requiring
shared household credentials.

### MVP requirements

- Create an account using the selected authentication methods.
- Sign in and sign out.
- Restore an existing session securely.
- Recover account access.
- Verify contact information when required by the chosen identity system.
- View and edit a display name.
- Delete the account through a confirmed flow.
- Prevent one user's session from exposing another household's data.

### Permissions

- A user may edit only their own account profile and preferences.
- Household access is granted through active membership, not knowledge of a pet
  or household identifier.

### Dependencies

- Identity provider or authentication service
- Secure session storage
- F02 Household and membership
- F13 Privacy and data control

### Excluded

- Social profiles
- Public usernames
- Professional account types
- Multiple active personas

### Failure states

- Invalid or expired credentials
- Verification link expired
- Recovery destination unavailable
- Account already exists
- Network unavailable during sign-in
- Account scheduled for or already deleted

### Acceptance criteria

- A new user can create an account and begin household setup.
- A returning user can sign in and reach their authorized household.
- Signing out removes protected local session access.
- Account recovery does not expose whether unrelated accounts or households
  exist beyond what the identity provider safely permits.
- Account deletion explains effects on household-owned records before
  confirmation.

## 7. F02 — Household and membership

### Objective

Allow multiple people to coordinate care for one or more pets while retaining
individual identity, preferences, and attribution.

### MVP requirements

- Create a household with a user-editable name.
- Make the creator the initial household owner.
- Invite a caregiver through a single-use, expiring invitation.
- Accept or decline an invitation while signed into an individual account.
- List active and pending members.
- Remove or leave a household subject to ownership safeguards.
- Attribute household actions to the acting member.
- Support at least one owner and full caregiver role.
- Prevent the final owner from leaving until ownership is transferred or the
  household is closed.

### Initial role model

| Action | Owner | Full caregiver |
| --- | --- | --- |
| View household pets and shared records | Yes | Yes |
| Complete tasks and add records | Yes | Yes |
| Edit household routines | Yes | Yes |
| Invite members | Yes | No by default |
| Remove members | Yes | No |
| Transfer ownership | Yes | No |
| Close household | Yes | No |

The authorization model should allow limited caregivers later without exposing
unfinished role controls in the MVP.

### Dependencies

- F01 Account and authentication
- F06 Shared activity and synchronization

### Excluded

- Public household discovery
- Anonymous shared links
- Professional access
- Fine-grained record-by-record permissions

### Failure states

- Invitation expired, revoked, or already used
- Invitee already belongs to the household
- Owner attempts to remove the final owner
- Member loses access while using another device
- Invitation targets an unintended account

### Acceptance criteria

- Two users can use different credentials to join one household.
- Both can see the household's pets and shared plan.
- A removed member loses access on the next authorized request and active
  sessions are invalidated appropriately.
- Every shared completion retains actor attribution.
- Invitation acceptance never requires sharing the owner's password.

## 8. F03 — Pet profile and lifecycle

### Objective

Capture enough trusted context to personalize the product without making setup
feel like a medical intake form.

### Required profile fields

- Name
- Species, restricted to dog in the initial user experience
- Birth date or estimated age
- Household

### Optional profile fields

- Profile photo
- Breed or mixed-breed description
- Sex
- Homecoming date
- Weight
- Veterinarian contact
- Microchip reference
- Food and allergies
- Notes

### MVP requirements

- Create, view, and edit a profile.
- Mark age as exact or estimated.
- Calculate age using the household's local date.
- Determine a configurable development stage.
- Support a future homecoming date.
- Archive a profile without immediately destroying its history.
- Display the pet name and image clearly on pet-specific actions.
- Support multiple pets in the data model even if the first experience is
  optimized for one.

### Dependencies

- F02 Household and membership
- F07 Development timeline
- F10 Health and care records

### Excluded

- Pedigree management
- Breed verification
- Genetic analysis
- Clinical problem list
- Ownership marketplace or transfer workflow

### Failure states

- Birth date is in the future without a future litter context
- Homecoming precedes birth date
- Estimated age lacks sufficient detail
- Photo upload fails
- Pet is archived while scheduled items remain

### Acceptance criteria

- A user can create the minimum profile in under two minutes.
- The interface distinguishes exact birth date from estimated age.
- Editing age or homecoming date causes relevant future plans to recalculate
  without rewriting historical plans.
- Missing optional fields do not block the first plan.
- An archived pet no longer produces plans or notifications.

## 9. F04 — Daily Plan

### Objective

Present one short, shared, trustworthy answer to “What should we do today?”

### MVP requirements

- Generate one plan per pet per household-local day.
- Generate a preparation-focused plan variant while the pet's homecoming date
  is in the future, and transition automatically to the post-arrival plan on
  the homecoming date (US-022, engine §26.1).
- Present Needs attention, Today, Recommended, Coming up, and Completed sections.
- Distinguish required, scheduled, recommended, and informational items.
- Show no more than three primary recommendations on a Normal day.
- Support Busy and Essentials-only capacity.
- Explain why each system recommendation appears.
- Keep the visible recommendation set stable after meaningful interaction.
- Preserve historical plans with rule and content versions.
- Avoid duplicate tasks during regeneration.
- Continue showing saved obligations when recommendation generation fails.

### User actions

- Complete
- Undo completion
- Skip
- Snooze within the day
- Reschedule
- Pin an optional item
- Replace or pause a recommendation
- Change today's capacity
- Open details or explanation

### Dependencies

- F03 Pet profile
- F05 Tasks, schedules, and completion
- F06 Shared activity and synchronization
- [Daily Plan Engine](12-daily-plan-engine.md)

### Excluded

- AI-generated plan items
- Clinical decision-making
- Automatic caregiver workload balancing
- Automatic plan changes based on inferred mood or behavior

### Failure states

- Insufficient profile information
- Rule or content unavailable
- Plan is stale because the device is offline
- Conflicting fixed commitments
- Required item lacks a valid schedule
- Household time zone changes

### Acceptance criteria

- A caregiver understands required and optional work without opening another
  screen.
- The plan stays within the configured optional-item budget.
- Completing an item does not cause the plan to grow unexpectedly.
- System recommendations have plain-language explanations.
- A missed optional item expires instead of becoming an overdue backlog item.
- A missed required item remains visible without inventing medical advice.
- The complete engine criteria in the Daily Plan Engine specification pass.

## 10. F05 — Tasks, schedules, and completion

### Objective

Provide the durable action model underneath planning, care, and training.

### MVP requirements

- Create a one-time task.
- Create supported recurring schedules.
- Assign an exact time, broad window, or no time.
- Assign to one caregiver or any caregiver.
- Complete, skip, snooze, reschedule, cancel, and undo.
- Record actor, timestamp, effective time, and optional note.
- Choose whether an edit applies to one occurrence or future occurrences.
- Retain origin and obligation class.
- Keep system definitions separate from user task occurrences.

### Supported recurrence

- Specific date
- Daily
- Selected weekdays
- Every N days
- Weekly
- Monthly using a defined safe calendar policy
- Interval after last completion
- Finite series

### Dependencies

- F02 Household
- F03 Pet profile
- Shared time and recurrence library chosen in technical architecture

### Excluded

- Arbitrary natural-language recurrence
- Unsupported clinical dosing patterns
- Automatic duration prediction

### Failure states

- Invalid date or time window
- Unsupported recurrence
- Device changes time zone
- Occurrence edited concurrently
- User attempts to modify a locked professional-source record

### Acceptance criteria

- A recurring task produces one occurrence for each valid due window.
- Regeneration is idempotent.
- Editing one occurrence does not alter the series unless explicitly selected.
- An offline completion can synchronize without duplicating the occurrence.
- The interface never silently approximates an unsupported recurrence.

## 11. F06 — Shared activity and synchronization

### Objective

Make the household's current state trustworthy across devices.

### MVP requirements

- Synchronize plan state and completion activity.
- Update the visible actor and time after completion.
- Treat repeated completion of the same occurrence as idempotent.
- Queue supported actions when temporarily offline.
- Show when displayed data may be stale.
- Preserve conflicting notes rather than silently overwriting them.
- Invalidate access after membership removal.
- Maintain an audit trail for material schedule and health changes.

### Dependencies

- F01 Account
- F02 Household
- F05 Tasks
- Technical synchronization design

### Excluded

- Real-time presence indicators
- Chat between caregivers
- Competitive caregiver statistics

### Failure states

- Two users complete the same task
- Two users edit one schedule
- Offline user acts after membership removal
- Server accepts an action but response is lost
- Device clock is incorrect

### Acceptance criteria

- Two caregivers converge on one completion state.
- Repeating a completion request does not create a second completion.
- Schedule conflicts are surfaced instead of silently overwritten.
- The interface identifies stale state when it cannot confirm current household
  activity.
- Authorization is rechecked when queued actions synchronize.

## 12. F07 — Development timeline

### Objective

Help owners understand the puppy's current stage, timely focus areas, and what
is coming next.

### MVP requirements

- Show current age and development stage.
- Present reviewed focus areas for the current stage.
- Preview the next stage without implying an exact universal transition.
- Link focus areas to relevant training, socialization, care, or preparation
  actions.
- Preserve content version and review metadata.
- Allow estimated-age profiles to use appropriately qualified language.

### Dependencies

- F03 Pet profile
- Governed content system
- F04 Daily Plan

### Excluded

- Diagnosis of developmental delay
- Breed-specific timelines without reviewed content
- Claims that every puppy follows identical stage boundaries

### Acceptance criteria

- The timeline updates when the profile age changes.
- Historical plans retain the stage and rule version used at the time.
- A stage focus can produce an explainable plan recommendation.
- Users can distinguish guidance from a clinical assessment.

## 13. F08 — Training catalogue and progress

### Objective

Help owners choose and practice humane, stage-appropriate skills in short,
repeatable sessions.

### Initial catalogue groups

- Foundations
- House manners
- Handling and grooming preparation
- Leash skills
- Recall and safety
- Calm behavior
- Fun skills

### MVP requirements

- Browse and search skills.
- View prerequisites, stage guidance, effort, frequency, steps, and common
  mistakes.
- Start, pause, resume, and retire an active goal.
- Log a session with duration, outcome, note, and optional media reference.
- Track progress using understandable states.
- Suggest future practice using the Daily Plan Engine.
- Identify content source, version, and review status.

### Initial progress states

- Not started
- Introduced
- Practicing
- Reliable in familiar setting
- Generalizing
- Maintained
- Paused

The interface must explain that a progress state is owner-reported, not a formal
certification.

### Dependencies

- F03 Pet profile
- F04 Daily Plan
- F12 Media for attachments
- Reviewed reward-based training content

### Excluded

- Remote trainer feedback
- Automated video evaluation
- Competitive rankings
- Punishment-based or unsafe instruction

### Acceptance criteria

- A user can find a suitable skill and understand the first practice step.
- Starting a skill makes it eligible for plan recommendations.
- Pausing a skill suppresses future recommendations.
- Logging a session updates recent history without automatically declaring
  mastery.
- Content with unmet prerequisites is not presented as ready to practice.

## 14. F09 — Socialization passport

### Objective

Encourage thoughtful, positive, varied exposure without turning socialization
into a race through a checklist.

### Initial categories

- People
- Animals
- Sounds
- Surfaces
- Environments
- Handling
- Transportation
- Household objects

### MVP requirements

- Browse suggested experience categories.
- Add a custom experience.
- Record date, context, response, note, and optional media.
- Mark an experience unavailable, inappropriate, or paused.
- Suggest eligible experiences through the Daily Plan.
- Emphasize quality and comfort rather than raw count.
- Show vaccination- and health-related caution only from reviewed content or
  owner-recorded professional guidance.

### Dependencies

- F03 Pet profile
- F04 Daily Plan
- Governed content

### Excluded

- Universal numeric socialization score
- Location tracking
- Automated emotion classification
- Advice that overrides local veterinary guidance

### Acceptance criteria

- Recording an experience prevents unnecessary immediate repetition.
- The product does not reward overwhelming exposure volume.
- A paused or unsuitable experience is not recommended.
- Users can see breadth by category without receiving a clinical score.

## 15. F10 — Health and care records

### Objective

Organize important care history and schedules while keeping the boundary between
record-keeping and veterinary advice unmistakable.

### MVP record types

- Vaccination
- Medication
- Preventive care
- Veterinary appointment
- Weight measurement
- Grooming record
- General health note
- Provider contact
- Document reference

### MVP requirements

- Add, view, edit, and archive supported records.
- Record source and whether details came from the owner or a professional
  instruction.
- Schedule follow-up tasks and reminders.
- Display last completion for medication occurrences.
- Attach notes or media where supported.
- Show neutral guidance boundaries.
- Preserve change history for medication and critical schedules.

### Dependencies

- F03 Pet profile
- F05 Tasks and schedules
- F11 Notifications
- F13 Privacy

### Excluded

- Diagnosis
- Dose calculation
- Treatment recommendation
- Veterinary interoperability
- Insurance claims

### Failure states

- Unsupported recurrence
- Missing medication or pet identity
- Conflicting instructions
- Duplicate vaccination record
- Attachment unavailable

### Acceptance criteria

- A caregiver can record a professional instruction without PetCompanion
  altering it.
- A medication occurrence shows pet, medication, due time, and recent
  completion clearly.
- The product never recommends doubling or changing a missed dose.
- Health records are private to authorized household members.
- Archived or superseded schedules no longer generate new occurrences.

## 16. F11 — Calendar and notifications

### Objective

Place tasks, appointments, and reminders in a coherent schedule and deliver
useful prompts without creating notification fatigue.

### MVP requirements

- Show tasks and events by day.
- Create and edit a manual event.
- Support all-day and timed events.
- Choose event and task reminder lead times.
- Generate a configurable morning Daily Plan summary.
- Deliver time-sensitive reminders to selected caregivers.
- Cancel stale notification candidates after completion or rescheduling.
- Respect per-user notification preferences and quiet hours.
- Keep in-app reminders useful when device permission is denied.

### Dependencies

- F05 Tasks
- F06 Synchronization
- Device notification service
- Household time-zone behavior

### Excluded

- External calendar synchronization
- Email import
- Poster scanning
- Location-based reminders

### Acceptance criteria

- A completed task does not produce a later stale notification.
- Each caregiver can configure their own delivery preferences.
- Notification text does not expose sensitive health details unless opted in.
- Event rescheduling updates future reminder candidates.
- Denied device permission does not hide the item inside the app.

## 17. F12 — Milestones, journal, and media

### Objective

Create a chronological record that connects care and training progress with the
memories owners value.

### MVP requirements

- Create a milestone with date, title, note, and photo.
- Capture or select a photo using platform permission controls.
- Associate media with the correct pet.
- Browse a chronological life timeline.
- Preserve capture date separately from upload date when available.
- Remove an attachment without deleting the associated record.
- Handle upload failure without losing the text record.

### P2 requirements

- Video attachments
- General journal entries
- Weekly growth-photo prompts
- Media linked to training sessions and events

### Dependencies

- F03 Pet profile
- Media storage architecture
- F13 Privacy and data control

### Excluded

- Public media sharing
- Automatic montage generation
- Facial or behavior recognition

### Acceptance criteria

- A failed photo upload does not discard the milestone.
- Media cannot be accessed without household authorization.
- Timeline ordering uses the event or capture date rather than upload order.
- Deleting media clearly explains whether the original device copy is affected.

## 18. F13 — Settings, privacy, and data control

### Objective

Give users clear control over household behavior, notifications, personal data,
and account lifecycle.

### MVP requirements

- Edit household name, time zone, routines, and default capacity.
- Edit per-user notification preferences and quiet hours.
- Explain household visibility and roles.
- Export supported household and pet records in a documented format before
  public release.
- Delete an account with clear household consequences.
- Close a household when authorized.
- Archive or permanently delete a pet through a deliberate flow.
- Publish privacy and retention behavior appropriate to the release audience.

### Dependencies

- All data-owning features
- Authentication and authorization
- Export and deletion jobs

### Excluded

- Public profile controls
- Advertising preferences
- Sale of personal data

### Acceptance criteria

- Users can identify who has access to their household.
- Removing access prevents future authorized reads and writes.
- Export includes documented core records and indicates unsupported media
  behavior.
- Destructive actions identify scope and provide confirmation.
- Privacy settings do not imply protection that the backend fails to enforce.

## 19. F14 — Product analytics and diagnostics

### Objective

Measure whether PetCompanion reduces uncertainty and supports consistent care
without collecting unnecessary sensitive information.

### MVP requirements

- Measure onboarding progression and time to first plan.
- Measure plan views and structured item dispositions.
- Measure synchronization and duplicate-generation failures.
- Measure notification staleness and delivery outcomes where permitted.
- Separate product analytics from operational diagnostics.
- Exclude free-form health notes, media contents, and precise unnecessary
  location data.
- Support deletion or anonymization consistent with the privacy policy.

### Dependencies

- Event taxonomy
- Consent and privacy design
- Observability architecture

### Excluded

- Advertising profiles
- Cross-app tracking
- Analysis of private media
- Training models on user content without a separately reviewed decision

### Acceptance criteria

- Every collected field has a documented product or operational purpose.
- Sensitive text and media are absent from ordinary analytics events.
- The team can detect duplicate plan items and stale notifications.
- Analytics failure does not block core user actions.

## 20. Release slices

### Slice A — Single-caregiver plan

- F01 basic account
- F02 household creation
- F03 minimal pet profile, including a future homecoming date
- F04 saved Daily Plan, including the pre-arrival preparation variant and the
  homecoming transition
- F05 completion and history

**Proof:** One person can create a puppy — before or after homecoming — and
complete a useful plan.

### Slice B — Shared care

- Household invitations
- Second caregiver
- Attributed completion
- Cross-device synchronization
- Idempotent simultaneous completion

**Proof:** Two people can coordinate without asking whether a task was done.

### Slice C — Guided puppy experience

- Development timeline
- Training catalogue
- Socialization
- Plan recommendations and explanations

**Proof:** The plan reflects stage and progress rather than only manual tasks.

### Slice D — Care and schedule

- Health records
- Calendar
- Recurrence
- Device notifications

**Proof:** Important user-entered care and appointments remain visible and
timely.

### Slice E — Meaning and readiness

- Milestones and photos
- Settings and data controls
- Accessibility review
- Privacy and release gates

**Proof:** The product is coherent, trustworthy, and ready for sustained private
use.

## 21. MVP-wide acceptance criteria

The private MVP is functionally complete when:

1. Two caregivers can join one household using individual accounts.
2. A puppy profile can generate a stable, explainable Daily Plan.
3. Both caregivers converge on the same task completion state.
4. Required and scheduled work is visually distinct from recommendations.
5. Recurrence and local-date behavior pass the defined scenario suite.
6. Training and socialization progress affect later recommendations.
7. User-recorded health schedules appear without being clinically altered.
8. Calendar changes cancel or update notification candidates.
9. Media and health data remain household-private.
10. Empty, offline, stale, denied-permission, and synchronization-conflict states
    are intentionally handled.
11. Critical flows meet the accessibility target.
12. The product records enough structured diagnostics to find plan,
    synchronization, and notification failures.

## 22. Open product decisions

- First client platform and minimum operating-system version
- Initial authentication methods
- Whether account creation can be deferred until after a preview plan
- Exact owner and full-caregiver permissions
- Default routine templates for meals and potty opportunities
- Initial development-stage definitions
- Content review and governance process
- Initial training and socialization catalogue size
- Medication completion confirmation interaction
- Minimum offline capability
- Media limits for private MVP
- Export format and deletion retention window

These decisions should be resolved in the information architecture, technical
architecture, data model, and content-planning work that follows.
