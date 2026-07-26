import Foundation
import Observation

/// App-level session state: which services to use, who is signed in, and
/// whether the app shows onboarding or the main tabs.
///
/// Services are protocol-typed so the Supabase-backed implementations slot
/// in later with no UI changes (doc 17 WP-2/WP-5).
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case onboarding
        case main
    }

    let auth: any AuthService
    let households: any HouseholdService
    let plans: any PlanService

    var phase: Phase = .onboarding
    var currentUser: UserAccount?
    var household: Household?
    /// Active pet context — per-device selection (IA §11). Slice A is
    /// single-pet, so this is simply the first pet.
    var activePet: Pet?

    init(auth: any AuthService, households: any HouseholdService, plans: any PlanService) {
        self.auth = auth
        self.households = households
        self.plans = plans
    }

    static func mock() -> AppModel {
        mock(backend: MockBackend())
    }

    static func mock(backend: MockBackend) -> AppModel {
        AppModel(
            auth: MockAuthService(backend: backend),
            households: MockHouseholdService(backend: backend),
            plans: MockPlanService(backend: backend)
        )
    }

    /// A signed-in household with the Maple fixture, for previews.
    static func preview(preArrival: Bool = false) -> AppModel {
        let backend = MockBackend()
        let model = mock(backend: backend)
        let seed = backend.seedForPreview(preArrival: preArrival)
        model.currentUser = seed.user
        model.household = seed.household
        model.activePet = seed.pet
        model.phase = .main
        return model
    }

    // MARK: - Flow

    enum PostAuthDestination {
        /// Existing household — straight to HM-01 (doc 14 ON-02/03 routing).
        case main
        /// No household yet — continue to ON-06.
        case createHousehold
    }

    /// Post-auth routing: pending invitation handling is Slice B (ON-05);
    /// Slice A routes between an existing household and household creation.
    func didAuthenticate(_ user: UserAccount) async -> PostAuthDestination {
        currentUser = user
        if let existing = try? await households.currentHousehold(),
           let pet = (try? await households.pets(householdId: existing.id))?.first {
            household = existing
            activePet = pet
            phase = .main
            return .main
        }
        return .createHousehold
    }

    /// Onboarding exit: landing is always HM-01 with the first generated
    /// plan (doc 14 §4 "Onboarding exit").
    func finishOnboarding() {
        phase = .main
    }

    func signOut() {
        auth.signOut()
        currentUser = nil
        household = nil
        activePet = nil
        phase = .onboarding
    }
}
