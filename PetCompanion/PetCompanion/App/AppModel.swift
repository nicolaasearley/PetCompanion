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

    enum PasswordRecoveryState: Equatable {
        case validating
        case ready
        case invalid
        case signedInBlocked
        case complete

        var returnsToMain: Bool {
            self == .signedInBlocked
        }
    }

    struct AppURLNotice: Equatable {
        let title: String
        let message: String
    }

    enum PasswordResetRequestOutcome: Equatable {
        case genericAcknowledgement
    }

    private(set) var backendMode: BackendMode
    private(set) var backendMessage: String?
    private let backendSelection: BackendSelection

    private(set) var auth: any AuthService
    private(set) var households: any HouseholdService
    // `.mock` uses engine §26 fixtures; real environments use the
    // server-authoritative generate-plan and write-path functions.
    private(set) var plans: any PlanService
    /// Training catalogue, goals and sessions (F08). Mock builds read the
    /// in-memory catalogue; real environments read the server's reviewed
    /// content and write through the write path.
    private(set) var training: any TrainingService
    /// Full occurrence/schedule coordination is installed for real
    /// environments after the Supabase client is available. Mock/preview
    /// builds keep using Planner's compatibility adapter.
    private(set) var planner: (any PlannerService)?
    /// Real environments expose the durable, account-scoped mutation queue
    /// so Home/Planner can render exact pending/failure counts.
    private(set) var mutationQueue: OfflineOperationQueue?
    /// Socialization passport backing (F09). Nil in mock/preview builds, where
    /// `makeSocializationStore()` falls back to the in-memory service.
    private(set) var socialization: (any SocializationService)?
    /// Care weight + providers (F10). Nil in mock/preview builds, where
    /// `makeWeightStore()` / `makeProvidersStore()` fall back to in-memory.
    private(set) var care: (any CareService)?
    /// Vaccination history (F10 / US-070). Separate from `care` so medications
    /// WIP on CareService stays isolated — same pattern as socialization.
    private(set) var vaccinations: (any VaccinationService)?
    /// Grooming history (F10 / US-076). Separate from `care` / vaccinations so
    /// Notes Care WIP stays isolated.
    private(set) var grooming: (any GroomingService)?
    /// Care notes / document refs + photo attach (F10). Separate from `care` so
    /// grooming/medications WIP stays isolated.
    private(set) var careNotes: (any CareNoteService)?
    /// Life milestones (F12). Nil in mock/preview builds, where
    /// `makeLifeStore()` falls back to the in-memory service.
    private(set) var life: (any LifeService)?
    /// Household appointments & events (F11). Nil in mock/preview builds,
    /// where `makeEventStore()` falls back to the in-memory service.
    private(set) var events: (any EventService)?
    /// Local-only reminder coordinator. Permission is requested only by an
    /// explicit settings action through this protocol.
    private(set) var notifications: any LocalNotificationServicing
    /// Remote APNs device-token registration. Additive to local reminders;
    /// Simulator failures are non-fatal.
    private(set) var pushRegistration: any RemotePushRegistering
    /// The Daily Plan Home and Planner both render. Whoever confirms a change
    /// publishes it here so the other surface is never left showing
    /// pre-action state (doc 19).
    let planState = SharedPlanState()
    /// Multi-device plan reconciliation. Mock installs a no-op bridge; real
    /// backends subscribe to household Realtime changes and re-fetch.
    private(set) var planRealtime: (any PlanRealtimeReconciling)?

    var phase: Phase = .onboarding
    var currentUser: UserAccount?
    var household: Household?
    /// Active pet context — per-device selection (IA §11). Slice A is
    /// single-pet, so this is simply the first pet.
    var activePet: Pet?
    /// Where an authenticated caregiver should resume when setup was
    /// interrupted. `OnboardingFlowView` consumes this once on appearance.
    private(set) var pendingOnboardingDestination: PostAuthDestination?
    private(set) var passwordRecoveryState: PasswordRecoveryState?
    private(set) var appURLNotice: AppURLNotice?
    private var pendingInvitationToken: String?
    private var shouldShowSignIn = false
    private var pendingAppURLs: [URL] = []
    private var appURLOperationGeneration = 0
    private var recoverySession: PasswordRecoverySession?
    private var passwordResetDispatchTasks: [UUID: Task<Void, Never>] = [:]
    var pendingPasswordResetDispatchCount: Int { passwordResetDispatchTasks.count }
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
        training: any TrainingService,
        notifications: (any LocalNotificationServicing)? = nil,
        pushRegistration: (any RemotePushRegistering)? = nil,
        mutationQueue: OfflineOperationQueue? = nil,
        backendSelection: BackendSelection = .mock,
        backendMode: BackendMode = .mock
    ) {
        self.auth = auth
        self.households = households
        self.plans = plans
        self.training = training
        self.notifications = notifications ?? LocalNotificationService.live()
        self.pushRegistration = pushRegistration ?? RemotePushRegistrationService.disabled()
        self.mutationQueue = mutationQueue
        self.backendSelection = backendSelection
        self.backendMode = backendMode
        // Mock / preview always get a no-op reconciler so UI never crashes
        // when auth lifecycle calls start/stop.
        self.planRealtime = PlanRealtimeReconciler(
            bridge: NoOpPlanRealtimeBridge()
        ) { [weak self] in
            await self?.reconcilePlanFromRemote()
        }
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
            training: MockTrainingService(backend: backend),
            backendSelection: selection,
            backendMode: .resolving
        )
    }

    static func mock() -> AppModel {
        mock(backend: MockBackend())
    }

    static func mock(backend: MockBackend) -> AppModel {
        let model = AppModel(
            auth: MockAuthService(backend: backend),
            households: MockHouseholdService(backend: backend),
            plans: MockPlanService(backend: backend),
            training: MockTrainingService(backend: backend)
        )
        model.care = InMemoryCareService()
        model.vaccinations = InMemoryVaccinationService()
        model.grooming = InMemoryGroomingService()
        model.careNotes = InMemoryCareNoteService()
        model.life = InMemoryLifeService()
        model.events = InMemoryEventService()
        return model
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
            care = care ?? InMemoryCareService()
            vaccinations = vaccinations ?? InMemoryVaccinationService()
            grooming = grooming ?? InMemoryGroomingService()
            careNotes = careNotes ?? InMemoryCareNoteService()
            life = life ?? InMemoryLifeService()
            events = events ?? InMemoryEventService()
            // Keep the no-op realtime bridge installed at init.
            backendMode = .mock
            await openPendingAppURL()
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
        let pushRegistration = RemotePushRegistrationService.live(client: client)
        let realAuth = RealAuthService(client: client)
        auth = realAuth
        households = RealHouseholdService(client: client, operationQueue: operationQueue)
        plans = RealPlanService(
            client: client,
            operationQueue: operationQueue,
            notifications: notifications,
            householdTimeZone: { [weak self] in self?.household?.clock.timeZone }
        )
        training = RealTrainingService(client: client, operationQueue: operationQueue)
        planner = RealPlannerService(
            client: client,
            model: self,
            operationQueue: operationQueue
        )
        mutationQueue = operationQueue
        socialization = RealSocializationService(
            client: client,
            operationQueue: operationQueue
        )
        care = RealCareService(
            client: client,
            operationQueue: operationQueue
        )
        vaccinations = RealVaccinationService(
            client: client,
            operationQueue: operationQueue
        )
        grooming = RealGroomingService(
            client: client,
            operationQueue: operationQueue
        )
        careNotes = RealCareNoteService(
            client: client,
            operationQueue: operationQueue
        )
        life = RealLifeService(
            client: client,
            operationQueue: operationQueue
        )
        events = RealEventService(
            client: client,
            operationQueue: operationQueue
        )
        self.notifications = notifications
        self.pushRegistration = pushRegistration
        planRealtime?.stop()
        planRealtime = PlanRealtimeReconciler(
            bridge: SupabasePlanRealtimeBridge(client: client)
        ) { [weak self] in
            await self?.reconcilePlanFromRemote()
        }
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
                planRealtime?.stop()
                operationQueue.deactivate()
                notifications.deactivate()
                pushRegistration.deactivate()
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
        await openPendingAppURL()
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
        /// A link opened before authentication resumes at invitation review.
        case reviewInvitation(String)
    }

    /// Post-auth routing prioritizes a pending invitation, then resumes an
    /// existing household or the first incomplete setup step.
    func didAuthenticate(_ user: UserAccount) async throws -> PostAuthDestination {
        mutationQueue?.activate(accountId: user.id)
        notifications.activate(accountId: user.id)
        pushRegistration.activate(accountId: user.id)
        await mutationQueue?.replayPending()

        do {
            if let token = pendingInvitationToken {
                commitAuthenticatedUser(user)
                pendingInvitationToken = nil
                pendingOnboardingDestination = .reviewInvitation(token)
                return .reviewInvitation(token)
            }

            let existing = try await households.currentHousehold()
            let pet: Pet?
            if let existing {
                pet = try await households.pets(householdId: existing.id).first
            } else {
                pet = nil
            }

            commitAuthenticatedUser(user)
            household = existing
            activePet = pet
            if existing != nil, pet != nil {
                phase = .main
                syncPlanRealtimeLifecycle()
                resolveDeferredDeepLink()
                return .main
            }
            if existing != nil {
                pendingOnboardingDestination = .addPet
                return .addPet
            }
            pendingOnboardingDestination = .createHousehold
            return .createHousehold
        } catch {
            rollbackAuthenticationBootstrap()
            throw error
        }
    }

    private func commitAuthenticatedUser(_ user: UserAccount) {
        shouldShowSignIn = false
        currentUser = user
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
            syncPlanRealtimeLifecycle()
            return .main
        }
        pendingOnboardingDestination = .addPet
        return .addPet
    }

    func consumePendingOnboardingDestination() -> PostAuthDestination? {
        defer { pendingOnboardingDestination = nil }
        return pendingOnboardingDestination
    }

    func consumePasswordRecoverySignInRequest() -> Bool {
        defer { shouldShowSignIn = false }
        return shouldShowSignIn
    }

    /// Onboarding exit: landing is always HM-01 with the first generated
    /// plan (doc 14 §4 "Onboarding exit").
    func finishOnboarding() {
        phase = .main
        syncPlanRealtimeLifecycle()
        resolveDeferredDeepLink()
    }

    func signOut() {
        planRealtime?.stop()
        mutationQueue?.deactivate()
        notifications.deactivate()
        pushRegistration.deactivate()
        auth.signOut()
        currentUser = nil
        household = nil
        activePet = nil
        planState.clear()
        pendingOnboardingDestination = nil
        pendingDeepLink = nil
        deferredDeepLink = nil
        passwordRecoveryState = nil
        recoverySession = nil
        appURLNotice = nil
        pendingInvitationToken = nil
        shouldShowSignIn = false
        pendingAppURLs.removeAll()
        appURLOperationGeneration += 1
        phase = .onboarding
    }

    // MARK: - App URLs and password recovery

    func open(_ url: URL) async {
        guard backendMode != .resolving else {
            pendingAppURLs.append(url)
            return
        }
        guard backendMode != .unavailable else {
            pendingAppURLs.append(url)
            return
        }

        appURLOperationGeneration += 1
        let operationGeneration = appURLOperationGeneration
        let priorRecoverySession = recoverySession
        recoverySession = nil
        passwordRecoveryState = nil
        if let priorRecoverySession {
            await auth.discardPasswordRecoverySession(priorRecoverySession)
            guard operationGeneration == appURLOperationGeneration else { return }
        }

        switch AppURLRouter.destination(for: url) {
        case .invitation(let token):
            shouldShowSignIn = false
            pendingInvitationToken = token
            if currentUser != nil {
                pendingOnboardingDestination = .reviewInvitation(token)
                phase = .onboarding
            }
        case .passwordRecovery:
            guard currentUser == nil, auth.currentUser == nil, phase != .main else {
                passwordRecoveryState = .signedInBlocked
                return
            }
            shouldShowSignIn = false
            passwordRecoveryState = .validating
            do {
                let session = try await auth.establishPasswordRecoverySession(from: url)
                guard operationGeneration == appURLOperationGeneration else {
                    await auth.discardPasswordRecoverySession(session)
                    return
                }
                recoverySession = session
                passwordRecoveryState = .ready
            } catch {
                guard operationGeneration == appURLOperationGeneration else { return }
                passwordRecoveryState = error as? AuthError == .recoveryRequiresSignOut
                    ? .signedInBlocked
                    : .invalid
            }
        case .authenticationCallback:
            guard currentUser == nil, phase != .main else {
                appURLNotice = AppURLNotice(
                    title: "Already signed in",
                    message: "Sign out before opening a link for another account."
                )
                return
            }
            var callbackSession: AuthenticationCallbackSession?
            do {
                let established = try await auth.handleAuthenticationCallback(from: url)
                callbackSession = established
                guard operationGeneration == appURLOperationGeneration else {
                    await auth.discardAuthenticationCallbackSession(established)
                    return
                }
                let destination = try await didAuthenticate(established.user)
                auth.completeAuthenticationCallbackSession(established)
                if destination != .main {
                    pendingOnboardingDestination = destination
                }
            } catch {
                if let callbackSession {
                    await auth.discardAuthenticationCallbackSession(callbackSession)
                }
                guard operationGeneration == appURLOperationGeneration else { return }
                rollbackAuthenticationBootstrap()
                appURLNotice = AppURLNotice(
                    title: "This link can’t be used",
                    message: "The sign-in link is invalid, expired, or couldn’t finish setup. Request a new link or sign in again."
                )
            }
        case nil:
            break
        }
    }

    func completePasswordRecovery(password: String) async throws {
        guard passwordRecoveryState == .ready, recoverySession != nil else {
            throw AuthError.invalidRecoveryLink
        }
        let operationGeneration = appURLOperationGeneration
        try await auth.updatePassword(password)
        guard operationGeneration == appURLOperationGeneration,
              passwordRecoveryState == .ready
        else {
            return
        }
        passwordRecoveryState = .complete
    }

    func dismissPasswordRecovery() async {
        guard let state = passwordRecoveryState else { return }
        appURLOperationGeneration += 1
        let session = recoverySession
        recoverySession = nil

        if state.returnsToMain {
            passwordRecoveryState = nil
            return
        }

        // A recovery callback creates a short-lived authenticated session.
        // Clear it before returning to sign-in so setup is never entered under
        // stale recovery credentials.
        shouldShowSignIn = true
        planRealtime?.stop()
        mutationQueue?.deactivate()
        notifications.deactivate()
        pushRegistration.deactivate()
        currentUser = nil
        household = nil
        activePet = nil
        planState.clear()
        pendingOnboardingDestination = nil
        pendingDeepLink = nil
        deferredDeepLink = nil
        phase = .onboarding
        passwordRecoveryState = nil
        if let session {
            await auth.discardPasswordRecoverySession(session)
        }
    }

    func requestPasswordReset(email: String) async throws -> PasswordResetRequestOutcome {
        let normalized = try AuthValidation.normalizedEmail(email)
        let service = auth
        let taskID = UUID()
        let dispatch = Task { [weak self] in
            // Supabase deliberately returns a generic response, but hosted
            // throttles and future provider behavior can still vary by
            // address. No service result is allowed to alter the UI state.
            try? await service.requestPasswordReset(email: normalized)
            self?.passwordResetDispatchTasks.removeValue(forKey: taskID)
        }
        passwordResetDispatchTasks[taskID] = dispatch
        try? await Task.sleep(for: .milliseconds(600))
        return .genericAcknowledgement
    }

    func dismissAppURLNotice() {
        appURLNotice = nil
    }

    private func rollbackAuthenticationBootstrap() {
        planRealtime?.stop()
        mutationQueue?.deactivate()
        notifications.deactivate()
        pushRegistration.deactivate()
        currentUser = nil
        household = nil
        activePet = nil
        planState.clear()
        pendingOnboardingDestination = nil
        phase = .onboarding
    }

    private func openPendingAppURL() async {
        let urls = pendingAppURLs
        pendingAppURLs.removeAll()
        for url in urls {
            await open(url)
        }
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
        if target.destination == .event {
            pendingDeepLink = await resolveEventDeepLink(target)
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

    /// Event reminders land on Planner when the appointment is still
    /// confirmed; cancelled/archived/missing degrade like plan items.
    private func resolveEventDeepLink(_ target: AppDeepLinkTarget) async -> ResolvedDeepLink {
        guard let eventId = target.eventId else {
            return NotificationDeepLinkResolver.resolve(target, against: nil)
        }
        guard let household else {
            return .unavailable(.noAccess)
        }
        let service = events ?? InMemoryEventService()
        do {
            let loaded = try await service.loadEvents(householdId: household.id)
            return NotificationDeepLinkResolver.resolveEvent(
                eventId: eventId,
                against: loaded
            )
        } catch {
            if error is EventError {
                return .unavailable(.planUnavailable)
            }
            return .unavailable(.planUnavailable)
        }
    }

    private func resolveDeferredDeepLink() {
        guard phase == .main, let target = deferredDeepLink else { return }
        deferredDeepLink = nil
        Task { await open(target) }
    }

    /// Builds the socialization passport's store for the active pet (F09).
    /// Returns nil only when there is no pet yet — the passport is about one
    /// puppy's real experiences, so there is nothing honest to show without
    /// one.
    func makeSocializationStore() -> SocializationStore? {
        guard let activePet else { return nil }
        return SocializationStore(
            service: socialization ?? InMemorySocializationService(),
            petId: activePet.id,
            petName: activePet.name,
            calendar: household?.clock.calendar ?? .current
        )
    }

    func makeWeightStore() -> WeightStore? {
        guard let activePet else { return nil }
        return WeightStore(
            service: care ?? InMemoryCareService(),
            petId: activePet.id,
            petName: activePet.name
        )
    }

    func makeProvidersStore() -> ProvidersStore? {
        guard let household else { return nil }
        return ProvidersStore(
            service: care ?? InMemoryCareService(),
            householdId: household.id
        )
    }

    func makeMedicationsStore() -> MedicationsStore? {
        guard let activePet else { return nil }
        return MedicationsStore(
            service: care ?? InMemoryCareService(),
            petId: activePet.id,
            petName: activePet.name,
            calendar: household?.clock.calendar ?? .current,
            currentUserId: currentUser?.id
        )
    }

    func makeVaccinationStore() -> VaccinationStore? {
        guard let activePet else { return nil }
        return VaccinationStore(
            service: vaccinations ?? InMemoryVaccinationService(),
            petId: activePet.id,
            petName: activePet.name,
            calendar: household?.clock.calendar ?? .current
        )
    }

    func makeGroomingStore() -> GroomingStore? {
        guard let activePet else { return nil }
        return GroomingStore(
            service: grooming ?? InMemoryGroomingService(),
            petId: activePet.id,
            petName: activePet.name,
            calendar: household?.clock.calendar ?? .current
        )
    }

    func makeCareNoteStore() -> CareNoteStore? {
        guard let activePet else { return nil }
        return CareNoteStore(
            service: careNotes ?? InMemoryCareNoteService(),
            petId: activePet.id,
            petName: activePet.name,
            calendar: household?.clock.calendar ?? .current
        )
    }

    func makeLifeStore() -> LifeStore? {
        guard let activePet else { return nil }
        return LifeStore(
            service: life ?? InMemoryLifeService(),
            petId: activePet.id,
            petName: activePet.name,
            calendar: household?.clock.calendar ?? .current
        )
    }

    func makeEventStore() -> EventStore? {
        guard let household else { return nil }
        let pets: [(id: UUID, name: String)] = {
            if let activePet { return [(activePet.id, activePet.name)] }
            return []
        }()
        return EventStore(
            service: events ?? InMemoryEventService(),
            householdId: household.id,
            pets: pets,
            calendar: household.clock.calendar,
            timeZoneId: household.timeZone,
            notifications: notifications
        )
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

    // MARK: - Multi-device plan reconciliation

    /// Testing seam: swap the reconciler (e.g. controllable bridge) without
    /// standing up a Supabase client.
    func installPlanRealtimeForTesting(_ reconciler: any PlanRealtimeReconciling) {
        planRealtime?.stop()
        planRealtime = reconciler
    }

    /// Subscribe when authenticated into the main tabs with a household;
    /// tear down otherwise. Safe to call repeatedly.
    func syncPlanRealtimeLifecycle() {
        guard let planRealtime else { return }
        if phase == .main, let householdId = household?.id {
            planRealtime.start(householdId: householdId)
        } else {
            planRealtime.stop()
        }
    }

    /// Foreground / reconnect: ask the reconciler for a debounced truthful
    /// refresh. No-op when not subscribed (mock, onboarding, signed out).
    func refreshPlanAfterForeground() {
        planRealtime?.requestRefresh()
    }

    /// Foreground safety refresh for on-device Event reminders (US-086 parity).
    /// Reloads confirmed events and replaces the `pc.event.*` pending set so
    /// reschedules made on another device cancel stale local banners.
    func refreshEventRemindersAfterForeground() async {
        guard phase == .main, let household else { return }
        let service = events ?? InMemoryEventService()
        do {
            let loaded = try await service.loadEvents(householdId: household.id)
            await notifications.reconcileEvents(
                events: loaded,
                timeZoneId: household.timeZone
            )
        } catch {
            // Leave existing local schedules; a later Care load retries.
        }
    }

    /// Re-reads today's plan from `PlanService` and publishes only
    /// server-verified snapshots. Never invents cross-device merges.
    /// Uses `resectioningCompleted: false` so a remote completion appears
    /// inline (doc 09 §8) rather than forcing a regenerate on every event.
    func reconcilePlanFromRemote() async {
        guard phase == .main, let activePet else {
            planState.noteReconciliationSignal()
            return
        }
        do {
            let snapshot = try await plans.plan(
                forPet: activePet.id,
                on: Date(),
                resectioningCompleted: false
            )
            if snapshot.servedFromCacheAt == nil {
                planState.publishRemote(snapshot)
            } else {
                // Cache-served answers are not authority for multi-device
                // convergence; keep the live snapshot and still nudge Planner.
                planState.noteReconciliationSignal()
            }
        } catch {
            planState.noteReconciliationSignal()
        }
    }
}
