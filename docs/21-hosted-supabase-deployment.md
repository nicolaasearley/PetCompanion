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

The seed contains product content such as development stages and training
catalogue entries. It does not create production caregivers, households, or
passwords.

Verify the remote migration ledger:

```sh
supabase migration list
```

## 4. Deploy Edge Functions

Deploy the two server-authoritative functions:

```sh
supabase functions deploy write-path
supabase functions deploy generate-plan
```

Supabase provides `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and
`SUPABASE_SERVICE_ROLE_KEY` to deployed functions. The service-role credential
stays server-side.

## 5. Configure authentication

In **Authentication → URL Configuration**:

1. Set the production site URL when the public web/help domain exists.
2. Add the app’s verified confirmation/deep-link URL before enabling link
   handling in a distributed build.
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
8. A second account cannot read the first household through REST or the app.
9. Edge Function logs contain no secrets or free-form private notes.

Run the repository’s remote-safe smoke script if one is added by Slice B. Do
not run destructive local reset commands against the linked hosted project.

## 8. Before TestFlight

- Confirm the Release archive contains the hosted URL and publishable key only.
- Review authentication redirect URLs and email templates.
- Confirm RLS isolation tests against a disposable hosted test household.
- Configure notification entitlements only when remote APNs delivery is added.
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
```

Then configure the iOS Release build with the Project URL and publishable key
and run the hosted smoke checklist in Section 7.
