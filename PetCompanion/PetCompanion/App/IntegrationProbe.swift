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
}
#endif
