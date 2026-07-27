import Foundation

/// Slice A WP-2 manual verification aid — NOT part of the product.
///
/// UI automation of the simulator wasn't available in this environment (no
/// windowed Simulator.app reachable for AppleScript/Accessibility-driven
/// taps), so this probe exercises the exact same path ON-02 → ON-06 → ON-07
/// would (`model.auth.createAccount` → `model.households.createHousehold`
/// → `model.households.createPet`) directly against whatever backend
/// `AppModel` resolved at launch, and prints the result so it can be read
/// back from `simctl launch --stdout=<file>`.
///
/// Only runs when explicitly requested (`PC_RUN_INTEGRATION_PROBE=1` in the
/// process environment, set via `SIMCTL_CHILD_PC_RUN_INTEGRATION_PROBE=1`
/// when launching through `simctl`) so ordinary Debug runs are unaffected.
#if DEBUG
enum IntegrationProbe {
    static func runIfRequested(model: AppModel) async {
        guard ProcessInfo.processInfo.environment["PC_RUN_INTEGRATION_PROBE"] == "1" else { return }

        print("PC_PROBE backendMode=\(model.backendMode)")
        guard model.backendMode == .local else {
            print("PC_PROBE RESULT=SKIPPED reason=backend_not_local")
            return
        }

        do {
            let stamp = Int(Date().timeIntervalSince1970)
            let email = "probe-\(stamp)@example.com"
            let creation = try await model.auth.createAccount(email: email, password: "ProbePassword123")
            guard case .authenticated(let user) = creation else {
                print("PC_PROBE RESULT=FAILURE reason=email_confirmation_required")
                return
            }
            print("PC_PROBE step=createAccount id=\(user.id) displayName=\(user.displayName)")

            let household = try await model.households.createHousehold(
                name: "Probe Household \(stamp)",
                timeZone: TimeZone.current.identifier
            )
            print("PC_PROBE step=createHousehold id=\(household.id) name=\(household.name) timeZone=\(household.timeZone)")

            let pet = try await model.households.createPet(
                name: "ProbePup",
                birthInfo: .estimated(ageWeeks: 10, asOfDate: Date()),
                homecomingDate: nil
            )
            print("PC_PROBE step=createPet id=\(pet.id) name=\(pet.name) householdId=\(pet.householdId)")

            let fetchedHousehold = try await model.households.currentHousehold()
            let fetchedPets = try await model.households.pets(householdId: household.id)
            print("PC_PROBE step=verifyReads householdMatches=\(fetchedHousehold?.id == household.id) petCount=\(fetchedPets.count)")

            print("PC_PROBE RESULT=SUCCESS")
        } catch {
            print("PC_PROBE RESULT=FAILURE error=\(error)")
        }
    }

    /// Slice A WP-3/WP-4 manual verification aid for `RealPlanService` —
    /// same rationale as `runIfRequested` above (no windowed Simulator.app
    /// reachable here for AppleScript/Accessibility-driven taps through the
    /// sign-in form), so this exercises the exact same calls HM-01 makes
    /// (`model.auth.signIn` → `model.didAuthenticate` → `model.plans.plan`
    /// → `completeItem`/`undoCompletion`) directly against the seeded
    /// "skeleton-test" account/household/pet.
    ///
    /// Only runs when explicitly requested (`PC_RUN_PLAN_PROBE=1`, set via
    /// `SIMCTL_CHILD_PC_RUN_PLAN_PROBE=1` when launching through `simctl`).
    /// Signing in here also leaves a real session in the Keychain, so a
    /// normal subsequent launch (no env var) restores it and lands
    /// straight on Home — that's how the plain screenshot evidence for
    /// this feature was captured, without needing simulator taps.
    ///
    /// Every line also writes to `<Documents>/pc_plan_probe.log` — plain
    /// `print()` output from a `simctl launch`ed process isn't reliably
    /// capturable in this environment (`simctl launch --console`/
    /// `--stdout=<file>` both require a controlling terminal this sandboxed
    /// shell doesn't have, and the unified log only carries OS framework
    /// messages, not raw stdout), so the log file — readable afterward via
    /// `simctl get_app_container <udid> <bundle> data` — is the actual
    /// evidence path, not a backup.
    static func runPlanProbeIfRequested(model: AppModel) async {
        guard ProcessInfo.processInfo.environment["PC_RUN_PLAN_PROBE"] == "1" else { return }

        var lines: [String] = []
        func log(_ line: String) {
            print(line)
            lines.append(line)
        }
        func flush() {
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = documents.appendingPathComponent("pc_plan_probe.log")
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        defer { flush() }

        log("PC_PLAN_PROBE backendMode=\(model.backendMode)")
        guard model.backendMode == .local else {
            log("PC_PLAN_PROBE RESULT=SKIPPED reason=backend_not_local")
            return
        }

        let email = ProcessInfo.processInfo.environment["PC_PLAN_PROBE_EMAIL"] ?? "skeleton-test@petcompanion.local"
        let password = ProcessInfo.processInfo.environment["PC_PLAN_PROBE_PASSWORD"] ?? "walking-skeleton-1"
        let shouldUseRestoredSession =
            ProcessInfo.processInfo.environment["PC_PLAN_PROBE_USE_RESTORED_SESSION"] == "1"

        do {
            if shouldUseRestoredSession {
                log("PC_PLAN_PROBE step=sessionRestore phase=\(model.phase)")
            } else {
                let user = try await model.auth.signIn(email: email, password: password)
                log("PC_PLAN_PROBE step=signIn id=\(user.id) displayName=\(user.displayName)")

                let destination = try await model.didAuthenticate(user)
                log("PC_PLAN_PROBE step=didAuthenticate destination=\(destination)")
            }

            guard let pet = model.activePet else {
                log("PC_PLAN_PROBE RESULT=FAILURE reason=no_active_pet")
                return
            }
            log("PC_PLAN_PROBE step=activePet id=\(pet.id) name=\(pet.name)")

            let snapshot = try await model.plans.plan(forPet: pet.id, on: Date(), resectioningCompleted: false)
            log("PC_PLAN_PROBE step=planFetch planId=\(snapshot.plan.id) version=\(snapshot.plan.planVersion) itemCount=\(snapshot.items.count)")
            for item in snapshot.items {
                log("PC_PLAN_PROBE item key=\(item.itemKey) section=\(item.section.rawValue) kind=\(item.kind.rawValue) occurrenceId=\(item.occurrenceId?.uuidString ?? "nil") title=\"\(item.title)\" explanation=\"\(item.explanationText ?? "")\"")
            }

            // Recommendation acceptance creates a pending occurrence.
            // Completion remains a separate, deliberate action.
            if let recommendation = snapshot.items.first(where: { $0.kind == .recommendation && $0.occurrenceId == nil }) {
                let accepted = try await model.plans.acceptRecommendation(
                    itemId: recommendation.id,
                    petId: pet.id,
                    on: Date()
                )
                let promoted = accepted.items.first(where: { $0.id == recommendation.id })
                let isPending = promoted.flatMap { accepted.occurrence(for: $0) }?.state == .pending
                log(
                    "PC_PLAN_PROBE step=acceptRecommendation "
                        + "occurrenceId=\(promoted?.occurrenceId?.uuidString ?? "nil") "
                        + "isPending=\(isPending)"
                )
            } else {
                log("PC_PLAN_PROBE step=acceptRecommendation result=SKIPPED reason=no_unaccepted_recommendation")
            }

            // Real write-path round trip: complete then undo an obligation
            // occurrence, if the seeded plan has one. Maple's household has
            // no schedules yet (verified: zero `task_occurrences` rows), so
            // fall back to `create_task` (US-050 quick add) to manufacture
            // one and exercise `complete_occurrence`/`undo_completion` for
            // real rather than skipping the write-path check entirely.
            var occurrenceBackedSnapshot = snapshot
            var obligationItem = occurrenceBackedSnapshot.items.first(where: { $0.occurrenceId != nil })
            if obligationItem == nil {
                occurrenceBackedSnapshot = try await model.plans.addOneTimeTask(
                    title: "PC_PLAN_PROBE quick task",
                    petId: pet.id,
                    on: Date()
                )
                obligationItem = occurrenceBackedSnapshot.items.first(where: { $0.occurrenceId != nil })
                log("PC_PLAN_PROBE step=addOneTimeTask itemCount=\(occurrenceBackedSnapshot.items.count) foundOccurrenceItem=\(obligationItem != nil)")
            }

            if let obligationItem {
                let completed = try await model.plans.completeItem(itemId: obligationItem.id, petId: pet.id, on: Date())
                log("PC_PLAN_PROBE step=completeObligation itemKey=\(obligationItem.itemKey) isCompleted=\(completed.isCompleted(obligationItem))")

                let undone = try await model.plans.undoCompletion(itemId: obligationItem.id, petId: pet.id, on: Date())
                log("PC_PLAN_PROBE step=undoObligation itemKey=\(obligationItem.itemKey) isCompleted=\(undone.isCompleted(obligationItem))")
            } else {
                log("PC_PLAN_PROBE step=completeObligation result=SKIPPED reason=no_occurrence_backed_item_even_after_add")
            }

            log("PC_PLAN_PROBE RESULT=SUCCESS")
        } catch {
            log("PC_PLAN_PROBE RESULT=FAILURE error=\(error)")
        }
    }

    /// Slice B authenticated smoke for the production Planner adapter.
    /// Creates an isolated local household, exercises recurrence and
    /// append-only occurrence actions, and writes a deterministic result log
    /// into the app's Documents directory.
    static func runPlannerProbeIfRequested(model: AppModel) async {
        guard ProcessInfo.processInfo.environment["PC_RUN_PLANNER_PROBE"] == "1" else { return }

        var lines: [String] = []
        func log(_ line: String) {
            print(line)
            lines.append(line)
        }
        defer {
            if let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first {
                try? (lines.joined(separator: "\n") + "\n").write(
                    to: documents.appendingPathComponent("pc_planner_probe.log"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        guard model.backendMode == .local else {
            log("PC_PLANNER_PROBE RESULT=SKIPPED reason=backend_not_local")
            return
        }

        do {
            let stamp = Int(Date().timeIntervalSince1970)
            let email = ProcessInfo.processInfo.environment["PC_PLANNER_PROBE_EMAIL"]
                ?? "planner-probe-\(stamp)@example.com"
            let password = ProcessInfo.processInfo.environment["PC_PLANNER_PROBE_PASSWORD"]
                ?? "PlannerProbePassword123"
            if ProcessInfo.processInfo.environment["PC_PLANNER_PROBE_EMAIL"] == nil {
                let creation = try await model.auth.createAccount(
                    email: email,
                    password: password
                )
                guard case .authenticated(let createdUser) = creation else {
                    log("PC_PLANNER_PROBE RESULT=FAILURE reason=email_confirmation_required")
                    return
                }
                log("PC_PLANNER_PROBE step=createAccount id=\(createdUser.id)")
                try await Task.sleep(for: .seconds(1))
            }
            let signedInUser = try await model.auth.signIn(
                email: email,
                password: password
            )
            log("PC_PLANNER_PROBE step=signIn id=\(signedInUser.id)")
            try await Task.sleep(for: .seconds(1))
            _ = try await model.didAuthenticate(signedInUser)
            _ = try await model.households.createHousehold(
                name: "Planner Probe \(stamp)",
                timeZone: "America/Toronto"
            )
            log("PC_PLANNER_PROBE step=createHousehold")
            _ = try await model.didAuthenticate(signedInUser)
            _ = try await model.households.createPet(
                name: "Maple",
                birthInfo: .estimated(ageWeeks: 12, asOfDate: .now),
                homecomingDate: nil
            )
            log("PC_PLANNER_PROBE step=createPet")
            _ = try await model.didAuthenticate(signedInUser)

            guard let planner = model.planner,
                  let pet = model.activePet
            else {
                log("PC_PLANNER_PROBE RESULT=FAILURE reason=no_planner")
                return
            }
            let context = try await planner.context()
            let calendar = context.calendar
            let today = calendar.startOfDay(for: .now)
            let exactTime = calendar.date(
                bySettingHour: 15,
                minute: 30,
                second: 0,
                of: today
            ) ?? today
            let draft = PlannerTaskDraft(
                title: "Planner probe routine",
                petId: pet.id,
                date: today,
                time: .exact(exactTime),
                recurrence: .daily,
                assignment: .anyone,
                reminder: .fifteenMinutesBefore
            )
            let createState = try await planner.save(draft, scope: nil)
            var agenda = try await planner.agenda(on: today)
            guard var item = agenda.items.first(where: { $0.title == draft.title }) else {
                log("PC_PLANNER_PROBE RESULT=FAILURE reason=created_item_missing")
                return
            }
            log("PC_PLANNER_PROBE step=create state=\(createState) occurrence=\(item.id)")

            _ = try await planner.perform(.skip(reason: "Too busy"), on: item)
            item = try await planner.agenda(on: today).items.first(where: { $0.id == item.id })
                ?? item
            _ = try await planner.perform(.undoSkip, on: item)
            item = try await planner.agenda(on: today).items.first(where: { $0.id == item.id })
                ?? item
            _ = try await planner.perform(.complete, on: item)
            item = try await planner.agenda(on: today).items.first(where: { $0.id == item.id })
                ?? item
            _ = try await planner.perform(.undoComplete, on: item)
            item = try await planner.agenda(on: today).items.first(where: { $0.id == item.id })
                ?? item

            if let snooze = calendar.date(byAdding: .minute, value: 15, to: .now),
               calendar.isDate(snooze, inSameDayAs: today) {
                _ = try await planner.perform(.snooze(until: snooze), on: item)
            }

            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            _ = try await planner.perform(
                .reschedule(to: tomorrow, time: .window(.evening), scope: .occurrenceOnly),
                on: item
            )
            agenda = try await planner.agenda(on: tomorrow)
            guard let moved = agenda.items.first(where: { $0.id == item.id }) else {
                log("PC_PLANNER_PROBE RESULT=FAILURE reason=rescheduled_identity_missing")
                return
            }
            let history = try await planner.history(for: moved)
            log(
                "PC_PLANNER_PROBE step=actions movedIdentity=true "
                    + "history=\(history.map(\.action.rawValue).joined(separator: ","))"
            )
            _ = try await planner.perform(.cancel(scope: .occurrenceOnly), on: moved)

            var futureDraft = moved.editableDraft()
            futureDraft.title = "Planner probe updated routine"
            futureDraft.date = tomorrow
            let futureState = try await planner.save(futureDraft, scope: .thisAndFuture)
            log("PC_PLANNER_PROBE step=seriesEdit state=\(futureState)")
            log("PC_PLANNER_PROBE RESULT=SUCCESS")
        } catch {
            log("PC_PLANNER_PROBE RESULT=FAILURE error=\(error)")
        }
    }
}
#endif
