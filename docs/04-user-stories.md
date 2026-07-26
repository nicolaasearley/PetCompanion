# User Stories and Acceptance Criteria

**Status:** Draft  
**Version:** 0.2  
**Last updated:** 2026-07-26  
**Related documents:** [Product Requirements Document](00-product-requirements-document.md),
[Core Feature Specification](03-core-features.md), and
[Daily Plan Engine](12-daily-plan-engine.md)

## 1. Purpose

This document describes PetCompanion from the user's point of view. It is
organized around outcomes and journeys rather than screens. Each story has
acceptance criteria that can later become design checks, implementation tests,
and release evidence.

## 2. Roles

### Prospective owner

A person preparing for a puppy who may know an expected birth or homecoming date
but does not yet have a daily care routine.

### Household owner

The person who creates a household and controls membership and household
lifecycle.

### Full caregiver

An invited household member who can participate in everyday care and update
shared pet records.

### System

PetCompanion's deterministic planning and notification services.

Professional and limited-caregiver roles are deferred.

## 3. Acceptance-language conventions

- **Given** establishes relevant starting state.
- **When** describes the action or event.
- **Then** describes the observable outcome.
- “Authorized caregiver” means an active household owner or full caregiver.
- “Current day” means the pet household's configured local calendar day.
- General care content must never be interpreted as professional veterinary
  advice.

## 4. Core journey map

```text
Create account
  → Create household
  → Add puppy
  → Receive first plan
  → Invite caregiver
  → Complete shared tasks
  → Record training or care
  → Preserve daily history
  → Generate tomorrow's plan
```

## 5. Story inventory

| Epic | Stories | Release slice |
| --- | --- | --- |
| E01 Account access | US-001–US-004 | A |
| E02 Household collaboration | US-010–US-015 | A–B |
| E03 Puppy profile | US-020–US-025 | A |
| E04 Daily Plan | US-030–US-041 | A–C |
| E05 Tasks and schedules | US-050–US-058 | A–D |
| E06 Training and socialization | US-060–US-068 | C |
| E07 Health and care | US-070–US-078 | D |
| E08 Calendar and notifications | US-080–US-086 | D |
| E09 Life timeline and media | US-090–US-095 | E |
| E10 Settings, privacy, and resilience | US-100–US-109 | B–E |

## 6. E01 — Account access

### US-001 — Create an individual account

**Priority:** P0  
**As a** new caregiver,  
**I want** my own PetCompanion account,  
**so that** I can securely participate without sharing credentials.

**Acceptance criteria**

- Given valid required account information, when the user submits registration,
  then an account is created using the selected identity method.
- The user is taken into household setup or invitation acceptance.
- The account has no access to a household until membership is created.
- Duplicate or invalid credentials produce a clear, non-destructive error.
- Protected data is not available before authentication is established.

### US-002 — Return to an existing account

**Priority:** P0  
**As a** returning caregiver,  
**I want** to resume my account securely,  
**so that** I can see the current household plan.

**Acceptance criteria**

- A valid saved session restores only the user's authorized households.
- An expired session requests reauthentication without deleting local,
  unsynchronized work.
- Signing out removes access to protected local screens.
- Authentication failure does not reveal private household details.

### US-003 — Recover account access

**Priority:** P1  
**As a** caregiver who cannot sign in,  
**I want** a secure recovery path,  
**so that** I do not lose access to my household history.

**Acceptance criteria**

- Recovery uses the verified method supported by the identity provider.
- Expired or used recovery credentials cannot be reused.
- A successful recovery preserves existing household membership.
- Recovery activity is recorded for security diagnostics.

### US-004 — Delete my account

**Priority:** P1  
**As a** user,  
**I want** to delete my account,  
**so that** I retain control of my personal data.

**Acceptance criteria**

- Before confirmation, the product explains effects on households, ownership,
  authored records, and pending invitations.
- The final household owner must transfer ownership or close the household
  before deletion can complete.
- Active sessions are revoked after deletion begins.
- Retention and recovery behavior match the published policy.

## 7. E02 — Household collaboration

### US-010 — Create a household

**Priority:** P0  
**As a** new owner,  
**I want** to create a household,  
**so that** pets, plans, and caregivers have a shared home.

**Acceptance criteria**

- An authenticated user can create a household with an editable name.
- The creator becomes the household owner.
- The household receives a time zone based on an explicit or confirmed default.
- Creating the household does not create duplicate memberships if retried.

### US-011 — Invite a caregiver

**Priority:** P0  
**As a** household owner,  
**I want** to invite my partner,  
**so that** we can coordinate puppy care using separate accounts.

**Acceptance criteria**

- The owner can create a single-use, expiring invitation.
- The invitation identifies the intended household without exposing private pet
  records before acceptance.
- A pending invitation can be revoked.
- Repeated invite submission does not create uncontrolled duplicates.
- A full caregiver cannot invite another member unless later permission rules
  explicitly allow it.

### US-012 — Accept or decline an invitation

**Priority:** P0  
**As an** invited caregiver,  
**I want** to accept or decline from my account,  
**so that** I control which household I join.

**Acceptance criteria**

- A valid invitation can be accepted only by an authenticated user.
- Acceptance creates one active membership.
- An expired, revoked, or already-used invitation explains why it cannot be
  accepted.
- Declining does not expose household records or affect the inviter's account.

### US-013 — See household members

**Priority:** P0  
**As an** authorized caregiver,  
**I want** to see who belongs to the household,  
**so that** I understand who can view and change shared information.

**Acceptance criteria**

- Active and pending members are visibly distinguished.
- Each member's current role is shown.
- No private authentication details are displayed.
- Membership changes update across active devices.

### US-014 — Remove a caregiver

**Priority:** P1  
**As a** household owner,  
**I want** to remove a member,  
**so that** former caregivers no longer have access.

**Acceptance criteria**

- Removal requires confirmation and identifies the affected member.
- The removed member loses authorization on subsequent requests.
- Queued offline writes are authorization-checked and rejected when no longer
  allowed.
- Historical actions retain attribution to the former member.

### US-015 — Transfer ownership or leave

**Priority:** P1  
**As a** household owner,  
**I want** to transfer ownership before leaving,  
**so that** the household is not orphaned.

**Acceptance criteria**

- Ownership can transfer only to an active eligible member.
- The final owner cannot leave without transferring ownership or closing the
  household.
- Transfer is recorded as a material audit event.
- Failed transfer leaves the original ownership unchanged.

## 8. E03 — Puppy profile

### US-020 — Add a puppy with minimal information

**Priority:** P0  
**As a** puppy owner,  
**I want** to add my puppy quickly,  
**so that** I can receive useful guidance without completing a long form.

**Acceptance criteria**

- Name, dog species, and exact birth date or estimated age are sufficient.
- Optional fields can be skipped.
- The puppy is attached to the current household.
- The first plan can be generated when minimum required context exists.
- Setup should be completable without health or breed information.

### US-021 — Use an estimated age

**Priority:** P0  
**As an** owner who does not know the exact birth date,  
**I want** to record an estimated age,  
**so that** the app remains useful without claiming false precision.

**Acceptance criteria**

- The interface distinguishes an estimate from an exact date.
- Display language uses appropriate approximation.
- Development guidance does not imply an exact birthday.
- The owner can later replace the estimate with an exact date.

### US-022 — Prepare before homecoming

**Priority:** P0 (promoted from P2 — see the 2026-07-26 pre-arrival decision
in the [Decision Log](13-decision-log.md))  
**As a** prospective owner,  
**I want** to enter a future homecoming date,  
**so that** the plan focuses on preparation before daily puppy care begins.

**Acceptance criteria**

- A future homecoming date suppresses post-arrival routines unless manually
  scheduled.
- Preparation tasks can use the homecoming date.
- The experience transitions to post-arrival mode on the confirmed date.
- Changing the date updates future preparation without rewriting history.

### US-023 — Edit puppy information

**Priority:** P0  
**As an** authorized caregiver,  
**I want** to correct the puppy's profile,  
**so that** guidance is based on accurate information.

**Acceptance criteria**

- Authorized caregivers can edit permitted profile fields.
- Changes that affect current guidance cause a controlled plan recalculation.
- Historical plans preserve their original stage and content versions.
- Invalid date relationships are explained before saving.

### US-024 — Add or replace a profile photo

**Priority:** P1  
**As a** caregiver,  
**I want** a recognizable puppy photo,  
**so that** pet-specific actions feel clear and personal.

**Acceptance criteria**

- The user can capture or select a supported image after granting permission.
- Upload failure does not block the rest of the profile.
- Replacing the photo does not affect existing records.
- Media access remains household-authorized.

### US-025 — Archive a pet profile

**Priority:** P1  
**As a** household owner,  
**I want** to archive a profile,  
**so that** it stops producing active plans without immediately losing history.

**Acceptance criteria**

- Archiving requires confirmation and explains effects on future schedules.
- Archived pets stop generating plans and notifications.
- Authorized users can still view retained history.
- Restoration behavior is defined and does not duplicate schedules.

## 9. E04 — Daily Plan

### US-030 — Receive the first useful plan

**Priority:** P0  
**As a** new puppy owner,  
**I want** an understandable first plan,  
**so that** I know what to do next.

**Acceptance criteria**

- The plan identifies the puppy and current local day.
- User-scheduled obligations appear even when recommendation content is
  unavailable.
- Optional suggestions do not exceed the selected capacity.
- Each suggestion has a plain-language explanation.
- Missing optional profile information does not produce an empty error state.

### US-031 — Distinguish obligations from suggestions

**Priority:** P0  
**As a** caregiver,  
**I want** required and scheduled work separated from recommendations,  
**so that** I understand what is essential and what is optional.

**Acceptance criteria**

- Required, scheduled, recommended, and upcoming items have understandable
  labels or placement.
- Optional activities do not visually obscure required care.
- The interface does not label a general recommendation as medically required.
- An item detail identifies its source.

### US-032 — Complete a plan item

**Priority:** P0  
**As a** caregiver,  
**I want** to mark an item complete quickly,  
**so that** the household knows it has been handled.

**Acceptance criteria**

- Completion records the actor and timestamp.
- The item moves to Completed without generating an automatic replacement.
- Other authorized devices converge on the same state.
- A failed completion clearly remains pending or safely retries.
- Completing a task twice does not create two completed occurrences.

### US-033 — Undo an accidental completion

**Priority:** P0  
**As a** caregiver,  
**I want** to undo an accidental completion,  
**so that** the shared record remains accurate.

**Acceptance criteria**

- A recent completion offers an accessible undo action.
- Undo returns the same occurrence to an appropriate active state.
- The correction synchronizes to the household.
- The audit history retains enough information to diagnose the change.

### US-034 — Skip an optional recommendation

**Priority:** P0  
**As a** caregiver,  
**I want** to skip an optional suggestion without guilt,  
**so that** the plan reflects real life.

**Acceptance criteria**

- An optional recommendation can be skipped without a mandatory reason.
- The item leaves the active plan and is recorded as skipped.
- It does not become overdue the next day.
- The user may optionally pause similar future suggestions.
- Copy remains neutral and non-punitive.

### US-035 — Handle a missed required item

**Priority:** P0  
**As a** caregiver,  
**I want** an unresolved required item to remain visible,  
**so that** it is not silently forgotten.

**Acceptance criteria**

- The item moves to Needs attention after its configured window.
- Original due information and source remain visible.
- The app does not invent instructions about doubling, changing, or
  discontinuing care.
- Completion, correction, or appropriate dismissal remains an explicit user
  action.

### US-036 — Choose a busy-day plan

**Priority:** P0  
**As a** caregiver with limited time,  
**I want** to reduce optional work for today,  
**so that** the plan stays achievable.

**Acceptance criteria**

- Busy day displays no more than one primary optional recommendation.
- Essentials only suppresses optional recommendations.
- Required and household-scheduled items remain visible.
- The setting can apply to only today or become a default.

### US-037 — Understand why an item was recommended

**Priority:** P0  
**As a** caregiver,  
**I want** to know why the app suggested an activity,  
**so that** I can trust or adjust it.

**Acceptance criteria**

- “Why this?” identifies the main eligibility reason.
- Relevant recent history and estimated effort appear when available.
- The explanation offers a way to pause or replace the recommendation.
- Numeric scoring and internal implementation detail remain hidden.

### US-038 — Replace a recommendation

**Priority:** P1  
**As a** caregiver,  
**I want** another suitable idea,  
**so that** I can adapt the day without abandoning guidance.

**Acceptance criteria**

- Replacement candidates satisfy current eligibility and safety constraints.
- The replaced item does not reappear during the same plan interaction.
- Replacement stays within the plan's capacity budget.
- The system records replacement for product improvement.

### US-039 — Preview what is coming next

**Priority:** P1  
**As a** caregiver,  
**I want** to see upcoming commitments,  
**so that** I can prepare without opening the calendar.

**Acceptance criteria**

- A small number of relevant future items appears in chronological order.
- Fixed events display the recorded date and time.
- Preparation tasks can appear before the related event.
- Cancelled or moved events update the preview.

### US-040 — Review a previous day

**Priority:** P1  
**As a** caregiver,  
**I want** to review prior plans,  
**so that** I can understand what happened without recreating a backlog.

**Acceptance criteria**

- Historical completed, skipped, expired, and unresolved items remain
  distinguishable.
- Historical recommendations do not become active when viewed.
- Actor and effective completion time are retained.
- Later content updates do not rewrite the historical explanation.

### US-041 — Generate the next day's plan

**Priority:** P0  
**As a** household,  
**I want** tomorrow's plan to reflect today's activity,  
**so that** guidance progresses without duplication.

**Acceptance criteria**

- Completed occurrences are not recreated as unfinished items.
- Expired recommendations do not carry forward as overdue.
- Eligible future practice can be selected using the configured cooldown.
- Required unresolved items follow their defined carry-forward policy.
- Repeated generation is idempotent.

## 10. E05 — Tasks and schedules

### US-050 — Add a one-time task

**Priority:** P0  
**As a** caregiver,  
**I want** to add a task for my puppy,  
**so that** it appears in the shared plan.

**Acceptance criteria**

- A task requires a title, pet, and date.
- Time can be exact, a broad window, or omitted.
- The task is visible to authorized household members.
- Retrying creation does not produce duplicates.

### US-051 — Create a recurring routine

**Priority:** P0  
**As a** caregiver,  
**I want** a routine to repeat predictably,  
**so that** I do not recreate it every day.

**Acceptance criteria**

- Supported recurrence options are presented explicitly.
- The interface shows a human-readable recurrence summary before saving.
- Each due window creates one occurrence.
- Unsupported patterns are not silently approximated.

### US-052 — Assign a task

**Priority:** P1  
**As a** caregiver,  
**I want** to assign a task to myself, my partner, or anyone,  
**so that** responsibility is clear when needed.

**Acceptance criteria**

- Only active eligible household members can be assigned.
- Unassigned or “anyone” tasks can be completed by either caregiver.
- Removing an assigned member returns future tasks to a defined unassigned
  state.
- Assignment changes are visible to the household.

### US-053 — Snooze within today

**Priority:** P1  
**As a** caregiver,  
**I want** to snooze an item,  
**so that** I am reminded later without changing its due date.

**Acceptance criteria**

- Snooze changes reminder emphasis, not the underlying occurrence date.
- The selected snooze time must remain meaningful for the current item.
- Completing the item cancels the snoozed notification candidate.
- Other caregivers can still see the active item.

### US-054 — Reschedule one occurrence

**Priority:** P0  
**As a** caregiver,  
**I want** to move one occurrence,  
**so that** a changed day does not alter the entire routine.

**Acceptance criteria**

- The user chooses a new valid date or time.
- Only the selected occurrence changes.
- The original occurrence is not left as a duplicate.
- The change is attributed and synchronized.

### US-055 — Change future recurrence

**Priority:** P1  
**As a** caregiver,  
**I want** to update future occurrences,  
**so that** a routine can evolve.

**Acceptance criteria**

- The interface distinguishes “this occurrence” from “this and future.”
- Historical occurrences remain unchanged.
- Future notification candidates are recalculated.
- A failed edit leaves the previous schedule intact.

### US-056 — Log a task after it happened

**Priority:** P1  
**As a** caregiver,  
**I want** to record something completed earlier,  
**so that** the history is accurate even when I forgot to log it immediately.

**Acceptance criteria**

- The user can enter an effective completion time within allowed bounds.
- The record separately retains when it was logged.
- Actor attribution remains the person recording it unless another supported
  attribution flow is explicitly designed.
- The correction affects future interval-based schedules predictably.

### US-057 — Add a completion note

**Priority:** P1  
**As a** caregiver,  
**I want** to add context to a completion,  
**so that** the household understands how it went.

**Acceptance criteria**

- A note is optional.
- The note is visible only to authorized household members.
- Concurrent note edits preserve both versions when safe merging is impossible.
- Free text is excluded from ordinary product analytics.

### US-058 — Work temporarily offline

**Priority:** P1  
**As a** caregiver without connectivity,  
**I want** to complete an existing task,  
**so that** care does not stop when the network does.

**Acceptance criteria**

- The most recently saved plan remains readable.
- Supported dispositions queue locally with clear state.
- Synchronization rechecks household authorization.
- Conflicts resolve using documented operation-specific rules.
- The user can see when household state may be stale.

## 11. E06 — Training and socialization

### US-060 — Browse suitable training skills

**Priority:** P1  
**As a** puppy owner,  
**I want** to browse structured training skills,  
**so that** I know what can be taught.

**Acceptance criteria**

- Skills are grouped and searchable.
- Each skill identifies stage guidance, prerequisites, effort, and review
  status.
- Unmet prerequisites are clear.
- Browsing does not automatically schedule every viewed skill.

### US-061 — Start a training goal

**Priority:** P1  
**As a** caregiver,  
**I want** to select a skill to work on,  
**so that** it can appear in future plans.

**Acceptance criteria**

- Starting a skill records it as an active household goal for the pet.
- Eligible practice can enter the recommendation pool.
- The first practice step is available immediately.
- Starting the same goal twice remains idempotent.

### US-062 — Follow a short lesson

**Priority:** P1  
**As a** caregiver,  
**I want** concise practice instructions,  
**so that** I can train without reading a long article.

**Acceptance criteria**

- The lesson includes steps, estimated effort, and common mistakes.
- Safety or prerequisite notes are visible before practice.
- Content source and version are retained.
- The lesson remains usable without supporting video.

### US-063 — Record a training session

**Priority:** P1  
**As a** caregiver,  
**I want** to record a session and outcome,  
**so that** future practice reflects recent work.

**Acceptance criteria**

- The user can record date, optional duration, progress state, and note.
- Recording updates recent practice history.
- A single session does not automatically declare mastery.
- The session is attributed and visible to the household.

### US-064 — Pause a training goal

**Priority:** P1  
**As a** caregiver,  
**I want** to pause a skill,  
**so that** it stops appearing while we focus elsewhere.

**Acceptance criteria**

- Paused goals are excluded from recommendations.
- Existing history remains visible.
- Resuming restores eligibility subject to current rules.
- Pausing does not mark the skill complete.

### US-065 — Understand training progress

**Priority:** P1  
**As a** caregiver,  
**I want** understandable progress states,  
**so that** I can judge what to practice next.

**Acceptance criteria**

- Progress uses the defined owner-reported states.
- The interface explains that progress is not certification.
- Progress history identifies who changed it.
- The system does not infer mastery from engagement alone.

### US-066 — Browse socialization experiences

**Priority:** P1  
**As a** puppy owner,  
**I want** ideas for varied positive exposure,  
**so that** I do not overlook important categories.

**Acceptance criteria**

- Experiences are organized by category.
- Guidance emphasizes comfort and positive exposure rather than total count.
- Reviewed caution appears where relevant.
- The app does not present a universal clinical score.

### US-067 — Record a socialization experience

**Priority:** P1  
**As a** caregiver,  
**I want** to record an experience and response,  
**so that** the household remembers what the puppy encountered.

**Acceptance criteria**

- The record supports date, category, response, note, and optional media.
- Recent completion reduces unnecessary immediate repetition.
- The record is visible to authorized household members.
- The product does not diagnose behavior from the response.

### US-068 — Pause an unsuitable experience

**Priority:** P1  
**As a** caregiver,  
**I want** to mark an experience unsuitable or unavailable,  
**so that** the app stops suggesting it.

**Acceptance criteria**

- The experience is excluded from future recommendations.
- The choice can be reversed.
- Past records remain intact.
- The system does not replace it with a near-duplicate from the same excluded
  context.

## 12. E07 — Health and care

### US-070 — Record a vaccination

**Priority:** P1  
**As a** caregiver,  
**I want** to record a vaccination from the puppy's documents,  
**so that** the household has an organized history.

**Acceptance criteria**

- The record supports name, date, provider, next date when explicitly known,
  note, and attachment reference.
- The product identifies the data as user-entered or professionally sourced.
- It does not calculate an unconfirmed schedule.
- Possible duplicates can be reviewed without automatic destructive merging.

### US-071 — Record a medication schedule

**Priority:** P1  
**As a** caregiver,  
**I want** to record medication instructions,  
**so that** due occurrences are visible to the household.

**Acceptance criteria**

- Medication name, pet, and schedule are displayed clearly.
- Dose is shown only as explicitly entered.
- Unsupported recurrence is not approximated.
- The record retains source and change history.
- PetCompanion does not calculate a dose.

### US-072 — Complete a medication occurrence

**Priority:** P1  
**As a** caregiver,  
**I want** to see recent medication completion before recording another,  
**so that** duplicate administration risk is reduced.

**Acceptance criteria**

- The action clearly identifies pet, medication, due time, and latest
  completion.
- Completion records caregiver and time.
- A simultaneous duplicate completion converges on one occurrence.
- The interaction receives dedicated usability validation before public release.

### US-073 — Handle a missed medication occurrence

**Priority:** P1  
**As a** caregiver,  
**I want** a missed occurrence to remain visible with neutral next steps,  
**so that** I can consult the recorded instructions or professional.

**Acceptance criteria**

- The item appears in Needs attention.
- The original schedule remains visible.
- The app does not advise doubling, skipping, or changing the dose.
- The user can access the recorded provider details when available.

### US-074 — Record a veterinary appointment

**Priority:** P1  
**As a** caregiver,  
**I want** to add a veterinary appointment,  
**so that** it appears in the calendar and upcoming plan.

**Acceptance criteria**

- The record supports provider, date, time, location, and note.
- The appointment appears in Coming up using its recorded time.
- Moving or cancelling it updates reminder candidates.
- Preparation tasks may link to the appointment.

### US-075 — Record weight

**Priority:** P1  
**As a** caregiver,  
**I want** to record a dated weight,  
**so that** we can see growth over time.

**Acceptance criteria**

- Value, unit, date, and optional note are supported.
- Units are displayed and converted without losing original precision.
- Obvious entry mistakes prompt review without diagnosing health.
- Growth visualization does not claim a clinical assessment.

### US-076 — Add a grooming record

**Priority:** P1  
**As a** caregiver,  
**I want** to record brushing, nail care, or another grooming activity,  
**so that** the household can maintain a routine.

**Acceptance criteria**

- The activity type, date, caregiver, and optional note are recorded.
- A recurring grooming schedule can produce plan occurrences.
- Completion does not create a duplicate general recommendation.
- Unsafe or clinical grooming advice is not generated.

### US-077 — Add a general health note

**Priority:** P1  
**As a** caregiver,  
**I want** to record an observation,  
**so that** I can remember it for a future conversation with a professional.

**Acceptance criteria**

- The note supports date, text, and optional attachment.
- The product labels it as an owner observation.
- The system does not diagnose or recommend treatment from the note.
- Free text remains private and outside ordinary analytics.

### US-078 — Archive a superseded care schedule

**Priority:** P1  
**As a** caregiver,  
**I want** to stop an outdated schedule without deleting its history,  
**so that** future reminders are correct.

**Acceptance criteria**

- Archiving stops future occurrences.
- Existing history remains readable.
- Pending notification candidates are cancelled.
- The action records actor, time, and reason when appropriate.

## 13. E08 — Calendar and notifications

### US-080 — Review the household calendar

**Priority:** P1  
**As a** caregiver,  
**I want** one view of upcoming tasks and events,  
**so that** I can plan beyond today.

**Acceptance criteria**

- Events and task occurrences are visually distinguishable.
- Calendar dates use the household time zone.
- Selecting an item opens its source record.
- Multiple pets remain identifiable.

### US-081 — Add a manual event

**Priority:** P1  
**As a** caregiver,  
**I want** to enter a class or community event,  
**so that** it becomes part of our plan.

**Acceptance criteria**

- The event supports title, pet, date, optional time, location, and notes.
- The creator can choose reminder lead times.
- The event appears in calendar and Coming up.
- Manual entry works without poster scanning.

### US-082 — Receive a morning plan summary

**Priority:** P1  
**As a** caregiver,  
**I want** one morning summary,  
**so that** I know the day's priorities without notification overload.

**Acceptance criteria**

- Each caregiver can opt in, opt out, and choose an allowed delivery window.
- The summary reflects the current saved plan.
- Sensitive details are omitted from lock-screen copy unless enabled.
- No summary is sent for an archived pet.

### US-083 — Receive a time-sensitive reminder

**Priority:** P1  
**As a** caregiver,  
**I want** a configured reminder at the appropriate time,  
**so that** I do not overlook a commitment.

**Acceptance criteria**

- Delivery follows the user's configured preferences and permission state.
- The candidate is cancelled if the item is completed or cancelled first.
- Tapping opens the correct pet and occurrence.
- Duplicate notification keys are not delivered twice.

### US-084 — Avoid irrelevant completion notifications

**Priority:** P1  
**As a** caregiver,  
**I want** routine household updates to remain quiet,  
**so that** useful notifications retain attention.

**Acceptance criteria**

- Routine completions update in-app by default.
- Per-user preferences can enable selected completion updates later.
- The product does not notify every member for every action by default.
- Important plan changes remain discoverable in activity history.

### US-085 — Use in-app reminders without device permission

**Priority:** P1  
**As a** user who denied notifications,  
**I want** reminders to remain visible in the app,  
**so that** the product is still usable.

**Acceptance criteria**

- Denied permission does not remove scheduled items.
- The app explains the limitation without repeatedly prompting.
- The user can open platform settings through an explicit action when
  available.
- No delivery success is claimed when permission is absent.

### US-086 — Reschedule an event safely

**Priority:** P1  
**As a** caregiver,  
**I want** changing an event to update related reminders,  
**so that** obsolete alerts are not sent.

**Acceptance criteria**

- Old notification candidates are cancelled.
- New candidates use the updated date and preferences.
- Completed preparation tasks remain completed.
- The calendar and Daily Plan converge on the new schedule.

## 14. E09 — Life timeline and media

### US-090 — Record a milestone

**Priority:** P1  
**As a** puppy owner,  
**I want** to save a milestone,  
**so that** important first experiences become part of the puppy's story.

**Acceptance criteria**

- A milestone supports title, pet, date, note, and optional photo.
- It appears in chronological order by milestone date.
- The record saves even if media upload fails.
- Authorized caregivers can view it.

### US-091 — Capture or select a photo

**Priority:** P1  
**As a** caregiver,  
**I want** to add a photo using platform controls,  
**so that** the timeline contains meaningful memories.

**Acceptance criteria**

- Permission is requested only when the user initiates the action.
- Denial produces a usable explanation and does not block text entry.
- Capture date is preserved separately from upload date where available.
- Media is not publicly accessible.

### US-092 — Browse the life timeline

**Priority:** P1  
**As a** caregiver,  
**I want** to browse milestones, care, and training moments chronologically,  
**so that** I can see how the puppy has grown.

**Acceptance criteria**

- Timeline entries identify type, pet, and effective date.
- Filters do not create duplicate records.
- Missing media has a graceful fallback.
- Sensitive health details use appropriate summaries.

### US-093 — Remove an attachment

**Priority:** P1  
**As a** caregiver,  
**I want** to remove an uploaded attachment,  
**so that** I control household media.

**Acceptance criteria**

- The flow distinguishes removing cloud media from deleting a record.
- The original device copy is not claimed to be deleted.
- Authorized deletion removes future access according to retention policy.
- The remaining milestone or record stays intact when requested.

### US-094 — Add a journal entry

**Priority:** P2  
**As a** caregiver,  
**I want** to record a free-form memory or behavior observation,  
**so that** important context is not lost.

**Acceptance criteria**

- The entry supports pet, date, text, and optional media.
- It is private to authorized household members.
- It can be edited with conflict-safe behavior.
- Text is not analyzed for diagnosis in the MVP.

### US-095 — Record a growth photo

**Priority:** P2  
**As a** puppy owner,  
**I want** a recurring growth-photo prompt,  
**so that** I can create a consistent visual history.

**Acceptance criteria**

- The prompt is optional and configurable.
- Skipping it does not become an overdue obligation.
- Photos retain their effective dates.
- Automatic video creation remains out of scope.

## 15. E10 — Settings, privacy, and resilience

### US-100 — Configure household routines

**Priority:** P0  
**As a** caregiver,  
**I want** to set broad routine windows,  
**so that** plans fit our day without pretending every activity has an exact
time.

**Acceptance criteria**

- The household can set broad morning, midday, afternoon, evening, and sleep
  context where required.
- Exact times remain optional except for explicitly timed care.
- Changes affect future scheduling predictably.
- Existing historical plans remain unchanged.

### US-101 — Configure personal notifications

**Priority:** P1  
**As a** caregiver,  
**I want** my own notification settings,  
**so that** my partner and I can receive different prompts.

**Acceptance criteria**

- Preferences belong to the user, not the shared household account.
- Quiet hours are configurable.
- Time-sensitive exceptions are explained when enabled.
- One caregiver's changes do not alter another's settings.

### US-102 — See who has access

**Priority:** P1  
**As a** household member,  
**I want** to understand household visibility,  
**so that** I know who can see pet, health, and media records.

**Acceptance criteria**

- Active members and roles are listed.
- The product explains that shared records are visible to active authorized
  members.
- Pending invitations are distinguishable from active access.
- Removed members no longer appear as active.

### US-103 — Export core records

**Priority:** P1 before public release  
**As a** household owner,  
**I want** an export of supported records,  
**so that** the household is not locked into PetCompanion.

**Acceptance criteria**

- The export identifies included and excluded record types.
- Export creation requires current authorization.
- The format is documented and machine-readable where appropriate.
- Delivery is protected and expires.
- Export does not expose another household.

### US-104 — Close a household

**Priority:** P1 before public release  
**As a** household owner,  
**I want** to close the household deliberately,  
**so that** shared data follows a clear lifecycle.

**Acceptance criteria**

- The flow explains member, pet, schedule, media, retention, and recovery
  effects.
- Confirmation is proportionate to the destructive scope.
- Active reminders and invitations are cancelled.
- Closure cannot occur through an accidental single tap.

### US-105 — Use accessible core flows

**Priority:** P0/P1  
**As a** user with accessibility needs,  
**I want** to operate the core experience with platform accessibility features,  
**so that** I can care for my puppy independently.

**Acceptance criteria**

- Onboarding, plan review, task completion, invitations, and health schedules
  work with a screen reader.
- Text can scale without hiding actions or meaning.
- Status never relies on color alone.
- Motion respects reduced-motion preferences.
- Touch targets and focus order meet the selected platform standard.

### US-106 — Understand stale data

**Priority:** P0  
**As a** caregiver on an unreliable connection,  
**I want** to know when the plan may be stale,  
**so that** I do not assume my partner has done nothing.

**Acceptance criteria**

- The interface shows a subtle last-synchronized state when relevant.
- It does not claim an item is current when verification is unavailable.
- Local actions indicate when they are queued.
- Successful synchronization clears the stale indicator.

### US-107 — Recover from a failed write

**Priority:** P0  
**As a** caregiver,  
**I want** a failed action to resolve clearly,  
**so that** I do not unknowingly lose a completion or create duplicates.

**Acceptance criteria**

- The action reaches a confirmed saved, queued, or failed state.
- Safe retry uses an idempotency key.
- Failure copy identifies what the user should do next.
- Retrying does not create duplicate records.

### US-108 — Use an empty plan

**Priority:** P0  
**As a** caregiver with nothing due,  
**I want** a calm empty state,  
**so that** I do not receive filler work.

**Acceptance criteria**

- The plan confirms that nothing currently needs attention.
- The user can add a task or browse optional ideas.
- The engine does not invent unnecessary tasks.
- No error styling appears for a valid empty day.

### US-109 — Protect sensitive notification content

**Priority:** P1  
**As a** privacy-conscious caregiver,  
**I want** control over lock-screen detail,  
**so that** sensitive pet health information is not exposed.

**Acceptance criteria**

- Default health-reminder copy is appropriately discreet.
- Detailed content requires explicit opt-in.
- Changing the preference affects future notifications.
- In-app detail remains available after authentication.

## 16. End-to-end acceptance scenarios

### Scenario A — First value

**Given** a new user has no household,  
**when** they create a household and add a puppy using minimum information,  
**then** PetCompanion produces a stable current-day plan with clear obligations,
no more than the allowed recommendations, and an explanation for each system
suggestion.

### Scenario B — Shared breakfast completion

**Given** two caregivers belong to one household and can see the same task,  
**when** one caregiver completes breakfast,  
**then** both devices converge on one completed occurrence showing the actor and
time, and no stale breakfast reminder is later sent.

### Scenario C — Simultaneous completion

**Given** two devices temporarily cannot see each other's latest state,  
**when** both complete the same occurrence,  
**then** synchronization produces one logical completion, retains diagnostic
audit information, and does not create an alarming user-facing error.

### Scenario D — Tomorrow reflects today

**Given** a caregiver completes a training practice and skips an optional
socialization recommendation,  
**when** the next local day's plan is generated,  
**then** the completed occurrence is not duplicated, the skipped recommendation
is not overdue, and any new suggestions respect cooldown and capacity.

### Scenario E — Recorded medication remains unresolved

**Given** an owner-entered medication schedule has a missed occurrence,  
**when** the due window passes without a recorded completion,  
**then** the item remains in Needs attention with its source and due time, and
PetCompanion does not advise changing the dose.

### Scenario F — Member removal while offline

**Given** a caregiver is removed while their device is offline,  
**when** their queued action later attempts to synchronize,  
**then** authorization is rechecked, the action is rejected safely, and no
protected household data is returned.

### Scenario G — Event is moved

**Given** an appointment has preparation work and notification candidates,  
**when** an authorized caregiver moves the appointment,  
**then** calendar and plan views show the new time, old notifications are
cancelled, new candidates are created, and completed preparation remains
complete.

### Scenario H — Media failure

**Given** a user creates a milestone with a photo,  
**when** the media upload fails,  
**then** the milestone text and date remain saved and the user can retry the
attachment separately.

## 17. Traceability to product outcomes

| Product outcome | Evidence stories |
| --- | --- |
| Know what matters today | US-030, US-031, US-036, US-037 |
| Know what has been done | US-032, US-033, US-041, US-106 |
| Coordinate between caregivers | US-011–US-015, US-032, US-052 |
| Prepare for what comes next | US-039, US-074, US-080, US-086 |
| Track meaningful progress | US-063, US-065, US-067, US-075, US-090 |
| Trust health boundaries | US-071–US-073, US-077, US-109 |
| Retain control of data | US-004, US-014, US-102–US-104 |
| Continue through imperfect connectivity | US-058, US-106, US-107 |

## 18. Definition of ready

A story is ready for implementation when:

- Its user and outcome are understood.
- Acceptance criteria are testable.
- Required content and safety review are identified.
- Dependencies and permissions are resolved.
- Empty, loading, failure, offline, and accessibility behavior are defined where
  relevant.
- Analytics and sensitive-data treatment are specified.
- Designs exist for user-facing states.

## 19. Definition of done

A story is done when:

- Acceptance criteria pass.
- Authorization tests pass.
- Relevant synchronization and idempotency tests pass.
- Accessibility checks pass.
- Analytics contain no prohibited sensitive content.
- Error and empty states have been exercised.
- Documentation and decision records reflect material changes.
- The result is demonstrated in its end-to-end release slice rather than only
  as an isolated screen.

## 20. Remaining validation work

The stories are implementation-ready in structure but still require product
validation in these areas:

- First-plan setup burden
- Normal, Busy, and Essentials-only recommendation limits
- Household invitation expectations
- Medication completion interaction
- Default meal and potty routine behavior
- Development-stage language
- Training and socialization content authority
- Notification volume and privacy
- Minimum useful offline behavior
- Account, household, and pet deletion expectations

These questions should be tested during information-architecture and prototype
work rather than deferred until implementation.
