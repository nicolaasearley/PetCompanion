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

    enum BackendMode: Equatable {
        case resolving
        case mock
        case local
        case hosted
        case unavailable
    }

    private(set) var backendMode: BackendMode
    private(set) var backendMessage: String?
    private let backendSelection: BackendSelection

    private(set) var auth: any AuthService
    private(set) var households: any HouseholdService
    // `.mock` uses engine §26 fixtures; real environments use the
    // server-authoritative generate-plan and write-path functions.
    private(set) var plans: any PlanService
    /// Full occurrence/schedule coordination is installed for real
    /// environments after the Supabase client is available. Mock/preview
    /// builds keep using Planner's compatibility adapter.
    private(set) var planner: (any PlannerService)?
    /// Real environments expose the durable, account-scoped mutation queue
    /// so Home/Planner can render exact pending/failure counts.
    private(set) var mutationQueue: OfflineOperationQueue?
    /// Local-only reminder coordinator. Permission is requested only by an
    /// explicit settings action through this protocol.
    private(set) var notifications: any LocalNotificationServicing
    /// The Daily Plan Home and Planner both render. Whoever confirms a change
    /// publishes it here so the other surface is never left showing
    /// pre-action state (doc 19).
    let planState = SharedPlanState()

    var phase: Phase = .onboarding
    var currentUser: UserAccount?
    var household: Household?
    /// Active pet context — per-device selection (IA §11). Slice A is
    /// single-pet, so this is simply the first pet.
    var activePet: Pet?
    /// Where an authenticated caregiver should resume when setup was
    /// interrupted. `OnboardingFlowView` consumes this once on appearance.
    private(set) var pendingOnboardingDestination: PostAuthDestination?
    /// A tapped reminder that has already been resolved against current
    /// state. `MainTabView` consumes it once; nothing is ever presented
    /// before resolution (doc 20 §4.10).
    var pendingDeepLink: ResolvedDeepLink?
    /// A reminder tapped before the caregiver reached the main tabs. Deep
    /// links are auth-gated (IA §10), so the target waits rather than
    /// resolving against a session that does not exist yet.
    private var deferredDeepLink: AppDeepLinkTarget?

    init(
        auth: any AuthService,
        households: any HouseholdService,
        plans: any PlanService,
        notifications: (any LocalNotificationServicing)? = nil,
        backendSelection: BackendSelection = .mock,
        backendMode: BackendMode = .mock
    ) {
        self.auth = auth
        self.households = households
        self.plans = plans
        self.notifications = notifications ?? LocalNotificationService.live()
        self.backendSelection = backendSelection
        self.backendMode = backendMode
    }

    /// App launch model. Its fixture services are deliberately hidden while
    /// the requested backend is resolving; they exist only because service
    /// protocol properties need an initial value.
    static func bootstrap(selection: BackendSelection = .resolve()) -> AppModel {
        let backend = MockBackend()
        return AppModel(
            auth: MockAuthService(backend: backend),
            households: MockHouseholdService(backend: backend),
            plans: MockPlanService(backend: backend),
            backendSelection: selection,
            backendMode: .resolving
        )
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

    /// Resolves the explicitly selected environment and restores a session.
    /// Failure remains visible; there is no implicit switch to demo data.
    func activateConfiguredBackend() async {
        guard backendMode == .resolving || backendMode == .unavailable else { return }
        backendMessage = nil

        let config: BackendConfig
        let resolvedMode: BackendMode
        switch backendSelection {
        case .mock:
            backendMode = .mock
            return
        case .local(let selected):
            config = selected
            resolvedMode = .local
        case .hosted(let selected):
            config = selected
            resolvedMode = .hosted
        case .invalid(let message):
            backendMessage = message
            backendMode = .unavailable
            return
        }

        backendMode = .resolving
        guard await SupabaseClientProvider.isReachable(config: config) else {
            backendMessage = resolvedMode == .local
                ? "The local PetCompanion service is not running. Start Supabase in the project folder, then retry."
                : "PetCompanion couldn't reach its service. Check your connection, then retry."
            backendMode = .unavailable
            return
        }

        let client = SupabaseClientProvider.makeClient(config: config)
        let operationQueue = OfflineOperationQueue(
            transport: SupabaseWritePathTransport(client: client)
        )
        let notifications = LocalNotificationService.live()
        let realAuth = RealAuthService(client: client)
        auth = realAuth
        households = RealHouseholdService(client: client, operationQueue: operationQueue)
        plans = RealPlanService(
            client: client,
            operationQueue: operationQueue,
            notifications: notifications,
            householdTimeZone: { [weak self] in self?.household?.clock.timeZone }
        )
        planner = RealPlannerService(
            client: client,
            model: self,
            operationQueue: operationQueue
        )
        mutationQueue = operationQueue
        self.notifications = notifications
        backendMode = resolvedMode

        // Session restore (US-002): `RealAuthService` seeds `currentUser`
        // synchronously from the on-disk session at init, but that's
        // optimistic (unverified/possibly expired). Confirm it here so a
        // previously-signed-in caregiver lands on HM-01 instead of
        // onboarding.
        if let user = realAuth.currentUser {
            do {
                let destination = try await didAuthenticate(user)
                if destination != .main {
                    pendingOnboardingDestination = destination
                }
            } catch {
                // A local database reset or an expired hosted refresh token
                // can leave a syntactically valid session in Keychain. That
                // is an authentication state, not a backend outage: discard
                // it and let the caregiver sign in again.
                operationQueue.deactivate()
                notifications.deactivate()
                realAuth.signOut()
                currentUser = nil
                household = nil
                activePet = nil
                planState.clear()
                pendingOnboardingDestination = nil
                backendMessage = "Your previous session expired. Sign in again to continue."
                backendMode = resolvedMode
                phase = .onboarding
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

    enum PostAuthDestination: Equatable {
        /// Existing household — straight to HM-01 (doc 14 ON-02/03 routing).
        case main
        /// No household yet — continue to ON-06.
        case createHousehold
        /// Household exists but setup stopped before the first pet.
        case addPet
    }

    /// Post-auth routing: pending invitation handling is Slice B (ON-05);
    /// Slice A routes between an existing household and household creation.
    func didAuthenticate(_ user: UserAccount) async throws -> PostAuthDestination {
        currentUser = user
        mutationQueue?.activate(accountId: user.id)
        notifications.activate(accountId: user.id)
        await mutationQueue?.replayPending()
        if let existing = try await households.currentHousehold() {
            household = existing
            if let pet = try await households.pets(householdId: existing.id).first {
                activePet = pet
                phase = .main
                resolveDeferredDeepLink()
                return .main
            }
            pendingOnboardingDestination = .addPet
            return .addPet
        }
        pendingOnboardingDestination = .createHousehold
        return .createHousehold
    }

    /// Post-acceptance routing (ON-05 → HM-01). An invited caregiver
    /// normally lands straight in the shared plan; a household that has no
    /// pet yet continues at ON-07 rather than showing an empty Home.
    @discardableResult
    func joinedHousehold(_ joined: Household) async -> PostAuthDestination {
        household = joined
        if let pet = try? await households.pets(householdId: joined.id).first {
            activePet = pet
            phase = .main
            return .main
        }
        pendingOnboardingDestination = .addPet
        return .addPet
    }

    func consumePendingOnboardingDestination() -> PostAuthDestination? {
        defer { pendingOnboardingDestination = nil }
        return pendingOnboardingDestination
    }

    /// Onboarding exit: landing is always HM-01 with the first generated
    /// plan (doc 14 §4 "Onboarding exit").
    func finishOnboarding() {
        phase = .main
        resolveDeferredDeepLink()
    }

    func signOut() {
        mutationQueue?.deactivate()
        notifications.deactivate()
        auth.signOut()
        currentUser = nil
        household = nil
        activePet = nil
        planState.clear()
        pendingOnboardingDestination = nil
        pendingDeepLink = nil
        deferredDeepLink = nil
        phase = .onboarding
    }

    // MARK: - Notification deep links

    /// Resolves a tapped reminder before anything is presented (doc 20
    /// §4.10). The notification carries no authority of its own: the
    /// destination is decided by what the plan says right now, and a target
    /// that is gone or unreadable degrades to a truthful surface rather than
    /// to a stale card (IA §10).
    func open(_ target: AppDeepLinkTarget) async {
        guard phase == .main else {
            deferredDeepLink = target
            return
        }
        guard target.destination == .planItem else {
            pendingDeepLink = NotificationDeepLinkResolver.resolve(target, against: nil)
            return
        }
        guard let petId = target.petId ?? activePet?.id else {
            pendingDeepLink = .unavailable(.targetNoLongerInPlan)
            return
        }
        if petId != activePet?.id {
            guard let household,
                  let pets = try? await households.pets(householdId: household.id)
            else {
                pendingDeepLink = .unavailable(.planUnavailable)
                return
            }
            guard let pet = pets.first(where: { $0.id == petId }) else {
                pendingDeepLink = .unavailable(.targetNoLongerInPlan)
                return
            }
            // The destination sets the active pet context (IA §10).
            activePet = pet
        }

        let snapshot: PlanSnapshot
        do {
            snapshot = try await plans.plan(
                forPet: petId,
                on: target.localDate ?? Date(),
                resectioningCompleted: false
            )
        } catch {
            pendingDeepLink = .unavailable(NotificationDeepLinkResolver.failure(for: error))
            return
        }

        // The read that resolved the link is also the freshest plan the app
        // has; publishing it saves Home a second round trip on arrival.
        if snapshot.servedFromCacheAt == nil {
            planState.snapshot = snapshot
        }
        pendingDeepLink = NotificationDeepLinkResolver.resolve(target, against: snapshot)
    }

    private func resolveDeferredDeepLink() {
        guard phase == .main, let target = deferredDeepLink else { return }
        deferredDeepLink = nil
        Task { await open(target) }
    }

    func replayOfflineOperations() async {
        await mutationQueue?.replayPending()
        guard mutationQueue?.status.pendingCount == 0, let activePet else { return }
        _ = try? await plans.plan(
            forPet: activePet.id,
            on: Date(),
            resectioningCompleted: false
        )
    }
}
