# Driving PetCompanion for a UX review

This target exists so a reviewer can **walk the app** — tap, type, scroll,
navigate — and get a folder of PNGs back. It is not a correctness suite. A
step that cannot be reached is recorded as a note and the walk continues,
because a partly-covered scenario is more useful than a red X.

XCUITest is used because it is the only thing that works here. Xcode 27
removed `Simulator.app` and moved `SimulatorKit.framework`, so
FBSimulatorControl-based tooling cannot load, and `xcrun simctl` can install,
launch and screenshot but **cannot inject touches**. XCUITest drives the app
through accessibility via `testmanagerd` and depends on none of that.

## Before the first run (required)

```
xcrun simctl keychain booted reset
```

Without this, iOS offers saved iCloud Keychain credentials in the QuickType
bar over the sign-in form, and **a real email address ends up in the
screenshots**. The harness refuses to write a PNG showing an address it did
not type itself, so the symptom is missing screenshots plus a `REFUSED to
capture` line in `NOTES.txt`. If you see that, run the command above.

Boot the simulator first if nothing is booted:

```
xcrun simctl boot 'iPhone 17'
```

## Run one scenario at one text size

```
xcodebuild test \
  -project PetCompanion/PetCompanion.xcodeproj \
  -scheme PetCompanionUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  -only-testing:PetCompanionUITests/HomeScenarioTests/testAtAccessibilityXXXL
```

Screenshots land in:

```
/tmp/petcompanion-ui/home-ax5-light/
    01-home-daily-plan.png
    02-home-scrolled.png
    ...
    NOTES.txt
```

The folder is `<scenario>-<textsize>-<appearance>`, and it is **wiped at the
start of each run** of that same variant. Different variants never collide,
so a default and an AX5 run can sit side by side for comparison.

`NOTES.txt` is the part to read first: it lists the launch arguments actually
used, anything the walk could not reach, and any surface the mock backend
cannot populate.

## Scenarios and variants

Every scenario offers the same three variants:

| Test method | Text size | Appearance |
| --- | --- | --- |
| `testAtDefaultText` | `UICTContentSizeCategoryL` | light |
| `testAtAccessibilityXXXL` | `UICTContentSizeCategoryAccessibilityXXXL` | light |
| `testAtDefaultTextDark` | `UICTContentSizeCategoryL` | dark — **requires the simctl step below** |

Dark appearance is a **device** setting. Run this before `xcodebuild`, and
put it back afterwards:

```
xcrun simctl ui booted appearance dark    # before testAtDefaultTextDark
xcrun simctl ui booted appearance light   # afterwards
```

`-UIUserInterfaceStyle Dark` as a launch argument does **nothing** on iOS 27
— it was tried, and the "dark" screenshots differed from the light ones by
0.05% of their pixels, which was the clock. The harness measures the
appearance it actually rendered and writes a `WARNING` line into `NOTES.txt`
if it does not match the variant name, so a folder called `-dark` full of
light screenshots announces itself instead of quietly misleading you.

| Test class | Scenario folder | Covers |
| --- | --- | --- |
| `OnboardingScenarioTests` | `onboarding` | ON-01 Welcome, ON-02 Create account, ON-03 Sign in → ON-06 household → ON-07 pet → ON-08 routines → Home |
| `HomeScenarioTests` | `home` | HM-01 Daily Plan, plan-item detail sheet, HM-04 capacity sheet, quick-add |
| `PlannerScenarioTests` | `planner` | PL-01 agenda, week navigation, task detail, jump-to-date |
| `TrainingScenarioTests` | `training` | TR-01 overview, TR-02 catalogue, TR-03 lesson, starting a goal, logging a session |
| `PassportScenarioTests` | `passport` | TR-06 passport, TR-07 a category, the record sheet |
| `SettingsScenarioTests` | `settings` | ST-01 hub, ST-04 members & invitations |

Run a whole scenario (all three variants) by dropping the method name, or
everything by dropping `-only-testing:` entirely. The full sweep is ~18 runs
of roughly 35–60s each, so prefer selecting.

## Why variants are test methods, not environment variables

The natural design is one test per scenario with `TEST_RUNNER_PC_UI_TEXT_SIZE`
selecting the size. That was tried and **it does not work**: under
`xcodebuild test` the `TEST_RUNNER_`-prefixed values never reached the runner
process, and the run silently fell back to the default size. Silently is the
problem — a reviewer would have believed they were looking at AX5 while
looking at default text, and concluded large-text layout was fine.

So the variant is in the test name. Ask for the wrong one and the command
fails instead of lying.

## The text-size mechanism is verified, not assumed

`-UIPreferredContentSizeCategoryName` is applied at launch and its effect is
confirmed two ways:

* every scenario measures a known text element's rendered frame and writes it
  to `NOTES.txt` (`text-scale probe`). On Home, the `TODAY` header measures
  **20.3pt tall at default and 63.3pt at AX5**;
* the resulting images differ by **51%** of their pixels on Home and **32%**
  on Welcome.

Both variants pass an explicit size — `standard` does **not** inherit the
device. That matters: this simulator was already sitting at an enlarged text
size, so an inherited "default" baseline rendered at roughly AX1 and would
have made the app look far more AX5-tolerant than it is.

## What mock mode cannot show

Launching with `-PetCompanionBackend mock` gives in-memory fixtures and no
network. `AppModel.bootstrap()` starts at onboarding and `MockBackend` starts
empty — `seedForPreview` is wired to SwiftUI previews only — so **every
signed-in surface is reached by walking onboarding first**. The account is
synthetic (`critic@example.test`); `MockBackend.signIn` ignores the password
entirely, so nothing here is a credential.

Authentication goes through **ON-03 Sign in**, not ON-02 Create account.
ON-02's password field declares `.newPassword`, so iOS covers the keyboard
with a "Use Strong Password?" panel whose close control is inconsistently
exposed — sometimes a button, sometimes a plain image — and about half of
runs could not get past it. ON-03 declares `.password` and raises no panel.
`MockBackend.signIn` is find-or-create, so signing in with an unseen address
produces exactly the user that creating an account would have. ON-02 is still
photographed, just not filled in.

Out of reach, and deliberately not faked:

* **Accepting a household invitation (ON-05).** Needs a second real identity
  on a live backend. Creating an invitation is reachable; accepting is not.
* **Sync status and rejected changes (ST-01).** The offline mutation queue is
  only constructed for a real backend, so Settings shows "Demo data".
* **Care and Life tabs.** Placeholder surfaces, not part of this brief.

## Keeping the unit suite fast

The `PetCompanion` scheme declares this bundle but marks it skipped, so the
existing suite is unaffected:

```
xcodebuild test -project PetCompanion/PetCompanion.xcodeproj -scheme PetCompanion \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0'
```

still runs the 69 unit tests and none of these.

## Debugging a scenario that will not advance

Set `ReviewDriver.dumpsElementTree = true` and re-run. Every blocker found
while building this harness — the "Use Strong Password?" panel, the QuickType
AutoFill suggestion, the "Save Password?" alert — was invisible in the logs
and obvious in the tree.

Never kill `xcodebuild` mid-run: it corrupts simulator state and the next run
fails for a different and more confusing reason.
