# Hosted Supabase Deployment Runbook

**Status:** Ready
**Version:** 1.0
**Last updated:** 2026-07-27

This runbook moves the verified local PetCompanion backend to a new hosted
Supabase project. It intentionally does not copy local test accounts or
household data. The production project starts clean with the reviewed content
seed and creates real accounts through the app.

## 1. Create the project

In the Supabase dashboard:

1. Create a new project named `PetCompanion`.
2. Choose the closest available region to the founding household.
3. Generate a strong database password and save it in a password manager.
4. Wait until project provisioning is complete.
5. In **Project Settings → API**, copy:
   - Project URL;
    - https://fhiqnhmqbkapydvyvost.supabase.co
   - publishable key (or legacy anonymous key if that is what the dashboard
    - sb_publishable_hZ68iCvx2pFAClNN1nJkdw_8HRjGj3W
     exposes).
6. Never copy the secret/service-role key into Xcode, the app bundle, source
   control, screenshots, or chat.

The project URL and publishable key identify the public client and are expected
to ship in the app. Row-level security—not secrecy of the publishable
credential—protects household data.

## 2. Link the repository

Install or update the CLI, authenticate, and link the new project:

```sh
brew install supabase/tap/supabase
supabase login
cd /Users/nic/Appdev/PetCompanion
supabase link --project-ref <project-ref>
```

Use the project reference shown in the dashboard URL/settings. Enter the saved
database password when prompted.

Confirm that the CLI is targeting the intended empty project before pushing:

```sh
supabase projects list
supabase migration list
```

## 3. Apply schema and reviewed seed content

Preview the migration push:

```sh
supabase db push --dry-run
```

Then apply migrations and seed content:

```sh
supabase db push --include-seed
```

Use `supabase db push` (CLI) for hosted schema — not MCP `apply_migration`,
which invents its own version and drifts from filenames in
`supabase/migrations/` (see `docs/22-handoff.md` §6).

Multi-device plan reconciliation also needs the Realtime publication migration
(`*_plan_household_realtime_publication.sql`): `dispositions`,
`task_occurrences`, and `plans` must be in `supabase_realtime` with
`REPLICA IDENTITY FULL`. A plain `db push` applies it; no extra dashboard
toggle is required beyond Realtime being enabled on the project. Linked hosted
(`fhiqnhmqbkapydvyvost`) already has `20260729180800` applied and verified
(2026-07-29) — do not push unrelated pending migrations just for this.

The seed contains product content such as development stages and training
catalogue entries. It does not create production caregivers, households, or
passwords.

Verify the remote migration ledger:

```sh
supabase migration list
```

After any Care schema change (for example
`*_care_weight_and_providers.sql`), confirm both tables exist and PostgREST
can see them:

```sh
supabase db query --linked "select table_name from information_schema.tables where table_schema='public' and table_name in ('weight_measurements','providers') order by 1;"
# Optional if REST still returns schema-cache misses:
supabase db query --linked "notify pgrst, 'reload schema';"
```

## 4. Deploy Edge Functions

Deploy the server-authoritative functions:

```sh
supabase functions deploy write-path
supabase functions deploy generate-plan
supabase functions deploy process-notification-candidates
```

Redeploy `write-path` whenever Care, Events, Life media, or device-token
mutation commands change (`record_weight`, `edit_weight`, `remove_weight`,
`create_provider`, `edit_provider`, `remove_provider`, `create_event`,
`edit_event`, `cancel_event`, `archive_event`, `create_milestone`,
`prepare_milestone_media`, `complete_milestone_media`, `fail_milestone_media`,
`remove_milestone_media`, `register_device_token`, `unregister_device_token`).
Schema alone is not enough for writes.

**Life milestone media (2026-07-29):** migration
`20260729182127_life_milestone_media` creates the private `household-media`
Storage bucket (INSERT+SELECT+UPDATE RLS for upsert), `media` metadata, and
write-path prepare/complete/fail/remove commands. After `db push`, redeploy
`write-path`. No service-role secrets belong in the repo.

**Care note media (2026-07-29):** migration `20260729183256_care_note_media`
reuses `household-media` + `media` for care note / document photo attach
(`prepare_care_note_media` / complete / fail / remove). Enables `kind =
document` (title required). After `db push`, redeploy `write-path`.

**Care note PDF attachments (2026-07-29):** migration
`20260729185241_care_note_media_pdf` adds `application/pdf` to the shared
`media.mime_type` check and `household-media` bucket allow-list. Care prepare
accepts PDF (images unchanged); Life milestone prepare stays image-only.
After `db push`, redeploy `write-path`.

**Events foundation (2026-07-29):** migration
`20260729180221_events_foundation` adds `events` + write-path RPCs and
extends `write_path_generation_context` so confirmed upcoming events replace
the hard-coded `[]` (training_state / socialization history preserved). If
hosted recorded that version without objects, apply forward repair
`20260729181429_events_foundation_hosted_apply`, then
`20260729182036_events_client_write_lockdown` (revoke client INSERT/UPDATE/DELETE).
After `db push`, redeploy `write-path` so clients can call the new commands.

**Event notification candidates / US-086 (2026-07-29):** migration
`20260729184100_event_notification_candidates_us086` adds nullable
`notification_candidates.event_id`, class `event_reminder`,
`refresh_event_notification_candidates`, and wires create/edit/cancel/archive
event RPCs to cancel-and-recreate candidates on reschedule (and clear on
cancel/archive). `verify_due_notification_candidates` / claim also understand
event-linked rows. After `db push`, redeploy `write-path` (RPC bodies changed;
no new Edge commands). SQL suite: `supabase/tests/event_notifications.sql`.
iOS also schedules on-device Event local notifications from the same
`reminder_config` (separate from APNs); see `docs/11` and decision log
2026-07-29 Event local notifications entry.

**`event_prep_vet` catalogue + engine (2026-07-29):** content migration
`20260729184527_event_prep_vet_content` seeds
`prep.gather_records_questions` (task definition). Redeploy
`generate-plan` after `npm run bundle:edge` so hosted `_shared/engine.mjs`
includes `rule.event_prep_vet` in `SUPPORTED_RULES`. `write-path` does not
embed the engine — skip unless mutation commands also changed. Linked hosted
already has the content migration + `generate-plan` v5 (verified 2026-07-29).

`process-notification-candidates` uses `verify_jwt = false` in
`supabase/config.toml` because it is invoked by cron/ops with the service-role
bearer or `NOTIFICATION_DISPATCH_SECRET`, not caregiver JWTs.

Supabase provides `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and
`SUPABASE_SERVICE_ROLE_KEY` to deployed functions. The service-role credential
stays server-side.

### 4.1 APNs secrets (remote push foundation)

Device-token storage and candidate verification do **not** require APNs keys.
Full remote delivery does. Never put Auth Key `.p8` files in the repo
(`.gitignore` already blocks `*.p8` / `AuthKey_*.p8`).

1. In [Apple Developer](https://developer.apple.com/account/resources/authkeys/list),
   create an APNs Auth Key (`.p8`). Note the **Key ID** and your **Team ID**.
2. Confirm the iOS App ID has Push Notifications enabled and that Debug uses
   the `development` aps-environment entitlement
   (`PetCompanion.entitlements`) while Release uses `production`
   (`PetCompanionRelease.entitlements`).
3. Set Edge Function secrets (Dashboard → Edge Functions → Secrets, or CLI):

```sh
# Paste the PEM once; do not echo it into shell history or commit it.
supabase secrets set \
  APNS_KEY_ID=<key-id> \
  APNS_TEAM_ID=<team-id> \
  APNS_TOPIC=com.nic.petcompanion \
  APNS_PRIVATE_KEY="$(cat /path/to/AuthKey_XXXXX.p8)"

# Optional: shared header for ops/cron callers of process-notification-candidates
supabase secrets set NOTIFICATION_DISPATCH_SECRET="$(openssl rand -hex 32)"
```

Prefer `APNS_PRIVATE_KEY_BASE64` if multiline PEM handling is awkward in your
secret store. After secrets are set, redeploy
`process-notification-candidates`. The foundation stub still leaves candidates
`scheduled` until the HTTP/2 sender slice lands; it will report
`apns_configured: true` once secrets are present.

Smoke the stub without sending:

```sh
curl -sS -X POST \
  "$SUPABASE_URL/functions/v1/process-notification-candidates" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "content-type: application/json" \
  -d '{}'
```

Expect `ok: true` and either `skipped_apns_not_configured` (no secrets) or
`apns_configured: true` / `sender_enabled: false` (secrets present, sender
not wired yet).

## 5. Configure authentication

In **Authentication → URL Configuration**:

1. Set the production site URL when the public web/help domain exists.
   Until then, hosted `site_url` remains `http://localhost:3000` (companion
   of the local allow-list entry; not exercised while confirmations are off).
2. ~~Add `petcompanion://password-reset` to the **Redirect URLs** allow-list.~~
   **Done 2026-07-29** via Management API `PATCH /v1/projects/.../config/auth`
   with only `uri_allow_list` (not `supabase config push`). Hosted allow-list
   is now `http://localhost:3000,petcompanion://password-reset`. It must
   exactly match `RealAuthService.passwordRecoveryRedirectURL` and the URL
   scheme registered in `PetCompanion/BackendInfo.plist`.
3. Keep email/password sign-up enabled.
4. Decide whether email confirmation is required for the private test. The app
   supports the confirmation-required state.

**Decided 2026-07-27:** email confirmation is **off** for the private
founding-household test, so accounts are usable immediately and no
confirmation link is sent. This is recorded as code in
`supabase/config.toml` under `[auth.email]` and applied with
`supabase config push`. Re-enable it, and configure a production SMTP
provider and a real `site_url`, before any wider distribution.

Note that `supabase config push` sends the whole file, not one setting. Any
value the file leaves unspecified is pushed as a CLI default, which is how
the hosted project's TOTP enrolment, e-mail send throttle, and OTP length
were briefly overwritten before being pinned back. Keep `config.toml` an
accurate description of the hosted project: a push that reports every
service `up_to_date` is the signal that it is.

For an initial private TestFlight test, use Supabase’s default email provider
only within its documented limits. Configure a production SMTP provider before
public distribution.

The local `supabase/config.toml` carries the same recovery URL in
`auth.additional_redirect_urls`, so `supabase config push` also describes the
hosted requirement. Review the full config diff before pushing: the command
still sends every auth setting, not only this allow-list entry.

Do not weaken RLS or grant direct client writes to make onboarding easier. All
invariant-bearing writes must continue through `write-path`.

## 6. Configure the iOS Release build

Release builds already select the hosted backend and fail visibly when
configuration is missing. Provide:

```text
PC_SUPABASE_URL = https://<project-ref>.supabase.co
PC_SUPABASE_ANON_KEY = <publishable-key>
```

These can be entered as Release build settings in a local, uncommitted
`.xcconfig`, or supplied as `PETCOMPANION_SUPABASE_URL` and
`PETCOMPANION_SUPABASE_ANON_KEY` environment variables for a development
scheme.

Do not set `PC_BACKEND_MODE` to `local` in Release and never add the database
password or service-role key.

## 7. Hosted smoke test

Use a new test email and verify:

1. Account creation and the configured email-confirmation behavior.
2. Household creation.
3. Puppy creation with exact, estimated, and unknown birth information.
4. Routine setup.
5. Daily Plan generation.
6. Task creation and every Slice B occurrence action.
7. Sign out, relaunch, and session restoration.
8. From sign-in, request password recovery for both an existing address and a
   synthetic unregistered address; both acknowledgements must be identical.
9. Open the existing account’s email on the same device, set a valid new
   password, and verify the old password fails while the new password signs in.
10. Verify an expired/reused link shows the invalid-link state and no password
    form. Also confirm no password or raw Auth response appears in device logs.
11. While signed in, open a recovery link and verify the app does not exchange
    it, sign out, change account context, or disturb queued work.
12. A second account cannot read the first household through REST or the app.
13. Edge Function logs contain no secrets or free-form private notes.

Run the repository’s remote-safe smoke script if one is added by Slice B. Do
not run destructive local reset commands against the linked hosted project.

## 8. Before TestFlight

- Confirm the Release archive contains the hosted URL and publishable key only.
- Review authentication redirect URLs and email templates.
- Confirm RLS isolation tests against a disposable hosted test household.
- Confirm Push entitlements ship in Debug (`development`) and Release
  (`production`). APNs Auth Key secrets are configured per §4.1 before
  enabling remote delivery; local reminders still work without them.
- Add production privacy/support URLs and App Store privacy answers.
- Establish database backups and budget alerts in Supabase.
- Professionally review health-adjacent and training seed content before public
  distribution.

## 9. Recovery

For this first deployment, the safest rollback is to stop using the new,
otherwise-empty project and create a replacement. Never attempt to “roll back”
by deleting migration rows or manually weakening constraints. Once production
household data exists, every schema correction must be a new forward migration.

## 10. Handoff checklist

When you are ready to create the hosted project, the only values Codex needs
from you are:

1. confirmation that the new Supabase project is provisioned;
2. its project reference;
3. its Project URL;
4. its publishable key.

Keep the database password in your password manager and enter it directly when
the CLI prompts. Do not paste the database password or service-role key into a
project file or chat.

After that handoff, the deployment sequence is:

```sh
supabase link --project-ref <project-ref>
supabase db push --dry-run
supabase db push --include-seed
supabase functions deploy write-path
supabase functions deploy generate-plan
supabase functions deploy process-notification-candidates
```

Configure APNs secrets only when ready for remote delivery (§4.1). Do not
commit `.p8` keys.

Then configure the iOS Release build with the Project URL and publishable key
and run the hosted smoke checklist in Section 7.
