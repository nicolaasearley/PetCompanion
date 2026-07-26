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

    /// Slice A WP-2 backend switch. `mock` is the in-memory fixture
    /// backend (`MockBackend`); `local` is the real local Supabase stack
    /// (`supabase start`) via supabase-swift. Defaults to `mock` at
    /// construction; `activateLocalBackendIfReachable()` promotes to
    /// `local` at launch when the stack answers, and never demotes back.
    enum BackendMode {
        case mock
        case local
    }

    private(set) var backendMode: BackendMode = .mock

    private(set) var auth: any AuthService
    private(set) var households: any HouseholdService
    // PlanService intentionally stays mock in every backend mode, including
    // `.local` — the daily-plan generation pipeline (`packages/engine`,
    // doc 17 WP-3/WP-4) isn't built yet. Home renders the mock §26 fixture
    // plans (Maple) even when auth/household/pet are talking to the real
    // local Supabase stack. Do not wire this to a `RealPlanService` until
    // WP-3/WP-4 land.
    let plans: any PlanService
    /// The `MockBackend` powering `plans`, in every backend mode. Kept so
    /// `.local` mode can register the real household/pet under their real
    /// ids (see `household`/`activePet` didSet below) — without this,
    /// `MockPlanService` would look up a pet id that only exists in the
    /// real backend and hit `MockBackend.generatePlan`'s "must exist"
    /// precondition (a hard crash, not a catchable error) the moment Home
    /// asks for a plan.
    private let planFixtureBackend: MockBackend

    var phase: Phase = .onboarding
    var currentUser: UserAccount?
    var household: Household? {
        didSet { syncPlanFixtureBackend() }
    }
    /// Active pet context — per-device selection (IA §11). Slice A is
    /// single-pet, so this is simply the first pet.
    var activePet: Pet? {
        didSet { syncPlanFixtureBackend() }
    }

    init(
        auth: any AuthService,
        households: any HouseholdService,
        plans: any PlanService,
        planFixtureBackend: MockBackend
    ) {
        self.auth = auth
        self.households = households
        self.plans = plans
        self.planFixtureBackend = planFixtureBackend
    }

    static func mock() -> AppModel {
        mock(backend: MockBackend())
    }

    static func mock(backend: MockBackend) -> AppModel {
        AppModel(
            auth: MockAuthService(backend: backend),
            households: MockHouseholdService(backend: backend),
            plans: MockPlanService(backend: backend),
            planFixtureBackend: backend
        )
    }

    /// See `planFixtureBackend` above. In mock mode this is a harmless
    /// same-object overwrite (the mock household/write services already
    /// mutate this exact backend); in `.local` mode it's what makes Home
    /// resolvable at all once a real household/pet are set.
    private func syncPlanFixtureBackend() {
        guard let household, let activePet else { return }
        planFixtureBackend.adopt(household: household, pet: activePet)
    }

    /// Slice A WP-2 launch-time backend resolution: probes the local
    /// Supabase stack and, if reachable, swaps `auth`/`households` to the
    /// real implementations and restores any existing session. Falls back
    /// to (and stays on) the mock backend when the stack isn't running —
    /// e.g. CI, a simulator with no local stack started, or `supabase
    /// stop`. Call once, early (`PetCompanionApp` does this from a
    /// `.task` at the root view).
    func activateLocalBackendIfReachable() async {
        guard backendMode == .mock else { return }
        guard await SupabaseClientProvider.isLocalStackReachable() else { return }

        let client = SupabaseClientProvider.shared
        let realAuth = RealAuthService(client: client)
        auth = realAuth
        households = RealHouseholdService(client: client)
        backendMode = .local

        // Session restore (US-002): `RealAuthService` seeds `currentUser`
        // synchronously from the on-disk session at init, but that's
        // optimistic (unverified/possibly expired). Confirm it here so a
        // previously-signed-in caregiver lands on HM-01 instead of
        // onboarding.
        if let user = realAuth.currentUser {
            let destination = await didAuthenticate(user)
            if destination == .createHousehold {
                // Signed in but no household yet — leave `phase` as
                // `.onboarding`; `OnboardingFlowView` starts at Welcome,
                // which is a one-tap re-entry (Sign in) away from here.
                // Slice A doesn't special-case "signed in, mid-onboarding"
                // routing beyond what ON-02/03 already provide.
            }
        }
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
