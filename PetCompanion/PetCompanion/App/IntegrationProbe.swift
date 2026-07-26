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
            let user = try await model.auth.createAccount(email: email, password: "ProbePassword123")
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

        do {
            let user = try await model.auth.signIn(email: email, password: password)
            log("PC_PLAN_PROBE step=signIn id=\(user.id) displayName=\(user.displayName)")

            let destination = await model.didAuthenticate(user)
            log("PC_PLAN_PROBE step=didAuthenticate destination=\(destination)")

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

            // Slice A residual limitation: acting on an unaccepted
            // recommendation must fail loudly, not crash or fake a promotion.
            if let recommendation = snapshot.items.first(where: { $0.kind == .recommendation && $0.occurrenceId == nil }) {
                do {
                    _ = try await model.plans.completeItem(itemId: recommendation.id, petId: pet.id, on: Date())
                    log("PC_PLAN_PROBE RESULT=FAILURE reason=recommendation_complete_did_not_throw")
                } catch PlanServiceError.recommendationNotYetActionable {
                    log("PC_PLAN_PROBE step=recommendationGuard result=OK")
                } catch {
                    log("PC_PLAN_PROBE step=recommendationGuard result=UNEXPECTED error=\(error)")
                }
            } else {
                log("PC_PLAN_PROBE step=recommendationGuard result=SKIPPED reason=no_unaccepted_recommendation")
            }

            // Real write-path round trip: complete then undo an obligation
            // occurrence, if the seeded plan has one.
            if let obligationItem = snapshot.items.first(where: { $0.occurrenceId != nil }) {
                let completed = try await model.plans.completeItem(itemId: obligationItem.id, petId: pet.id, on: Date())
                log("PC_PLAN_PROBE step=completeObligation itemKey=\(obligationItem.itemKey) isCompleted=\(completed.isCompleted(obligationItem))")

                let undone = try await model.plans.undoCompletion(itemId: obligationItem.id, petId: pet.id, on: Date())
                log("PC_PLAN_PROBE step=undoObligation itemKey=\(obligationItem.itemKey) isCompleted=\(undone.isCompleted(obligationItem))")
            } else {
                log("PC_PLAN_PROBE step=completeObligation result=SKIPPED reason=no_occurrence_backed_item")
            }

            log("PC_PLAN_PROBE RESULT=SUCCESS")
        } catch {
            log("PC_PLAN_PROBE RESULT=FAILURE error=\(error)")
        }
    }
}
#endif
