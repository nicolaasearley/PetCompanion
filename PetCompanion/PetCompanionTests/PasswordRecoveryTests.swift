import XCTest
@testable import PetCompanion

@MainActor
final class PasswordRecoveryTests: XCTestCase {
    func testAppURLRouterSeparatesInvitationsRecoveryAndAuthCallbacks() throws {
        let token = String(repeating: "a", count: InvitationToken.length)
        XCTAssertEqual(
            AppURLRouter.destination(for: try XCTUnwrap(URL(string: "petcompanion://invitation/\(token)"))),
            .invitation(token)
        )
        XCTAssertEqual(
            AppURLRouter.destination(for: try XCTUnwrap(URL(string: "petcompanion://password-reset?code=secret"))),
            .passwordRecovery
        )
        XCTAssertEqual(
            AppURLRouter.destination(for: try XCTUnwrap(URL(string: "petcompanion://auth-callback?code=secret"))),
            .authenticationCallback
        )
        XCTAssertNil(
            AppURLRouter.destination(for: try XCTUnwrap(URL(string: "https://example.com/password-reset?code=secret")))
        )
        XCTAssertNil(
            AppURLRouter.destination(for: try XCTUnwrap(URL(string: "petcompanion://unrelated")))
        )
    }

    func testEmailAndPasswordValidation() throws {
        XCTAssertEqual(try AuthValidation.normalizedEmail("  caregiver@example.com\n"), "caregiver@example.com")
        XCTAssertThrowsError(try AuthValidation.normalizedEmail("not-an-email"))
        XCTAssertThrowsError(try AuthValidation.validatePassword("short"))
        XCTAssertNil(
            AuthValidation.passwordConfirmationError(
                password: "eightplus",
                confirmation: "eightplus"
            )
        )
        XCTAssertEqual(
            AuthValidation.passwordConfirmationError(
                password: "eightplus",
                confirmation: "different"
            ),
            "The passwords don't match yet."
        )
    }

    func testValidMockRecoveryLinkBecomesReadyAndCompletes() async throws {
        let model = AppModel.mock()
        let url = try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=valid"))

        await model.open(url)
        XCTAssertEqual(model.passwordRecoveryState, .ready)

        try await model.completePasswordRecovery(password: "new-password")
        XCTAssertEqual(model.passwordRecoveryState, .complete)

        await model.dismissPasswordRecovery()
        XCTAssertNil(model.passwordRecoveryState)
        XCTAssertTrue(model.consumePasswordRecoverySignInRequest())
        XCTAssertFalse(model.consumePasswordRecoverySignInRequest())
    }

    func testInvalidMockRecoveryLinkNeverShowsPasswordForm() async throws {
        let model = AppModel.mock()
        let url = try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=invalid"))

        await model.open(url)

        XCTAssertEqual(model.passwordRecoveryState, .invalid)
    }

    func testColdLaunchRecoveryWaitsForBackendActivation() async throws {
        let model = AppModel.bootstrap(selection: .mock)
        let url = try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=valid"))

        await model.open(url)
        XCTAssertNil(model.passwordRecoveryState)

        await model.activateConfiguredBackend()
        XCTAssertEqual(model.passwordRecoveryState, .ready)
    }

    func testSessionRestoreWindowBlocksRecoveryBeforeExchange() async throws {
        let auth = ControlledAuthService()
        let restoringUser = UserAccount(id: UUID(), displayName: "Restoring")
        auth.currentUser = restoringUser
        let households = SuspendingHouseholdService()
        let model = makeModel(auth: auth, households: households)

        let restoration = Task { try await model.didAuthenticate(restoringUser) }
        await waitUntil { households.currentHouseholdStarted }
        XCTAssertNil(model.currentUser)

        await model.open(
            try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=valid"))
        )

        XCTAssertEqual(model.passwordRecoveryState, .signedInBlocked)
        XCTAssertTrue(auth.establishCalls.isEmpty)
        XCTAssertEqual(auth.currentUser, restoringUser)
        households.resumeCurrentHousehold(returning: nil)
        _ = try await restoration.value
    }

    func testQueuedWorkReplaysBeforeHouseholdResolution() async throws {
        let accountID = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuthReplayOrdering-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OfflineOperationStore(baseDirectory: directory)
        let offlineTransport = QueueTestTransport(error: URLError(.notConnectedToInternet))
        let seedQueue = OfflineOperationQueue(transport: offlineTransport, store: store)
        seedQueue.activate(accountId: accountID)
        struct Payload: Encodable { let name: String }
        _ = try? await seedQueue.submit(
            command: "create_household",
            payload: Payload(name: "Queued Household")
        )
        seedQueue.deactivate()

        let replayTransport = QueueTestTransport()
        let replayQueue = OfflineOperationQueue(transport: replayTransport, store: store)
        let households = ReplayObservingHouseholdService {
            replayTransport.executeCount > 0
        }
        let model = makeModel(
            auth: ControlledAuthService(),
            households: households,
            mutationQueue: replayQueue
        )
        let user = UserAccount(id: accountID, displayName: "Caregiver")

        _ = try await model.didAuthenticate(user)

        XCTAssertTrue(households.replayHadFinishedWhenResolved)
        XCTAssertEqual(replayTransport.executeCount, 1)
        XCTAssertEqual(replayQueue.activeAccountId, accountID)
    }

    func testBootstrapFailureDeactivatesActivatedResources() async throws {
        let accountID = UUID()
        let queue = OfflineOperationQueue(transport: QueueTestTransport())
        let notifications = TestNotificationService()
        let model = makeModel(
            auth: ControlledAuthService(),
            households: FailingHouseholdService(),
            notifications: notifications,
            mutationQueue: queue
        )

        do {
            _ = try await model.didAuthenticate(
                UserAccount(id: accountID, displayName: "Caregiver")
            )
            XCTFail("Expected household bootstrap to fail")
        } catch TestAuthError.failed {
            // Expected.
        }

        XCTAssertNil(queue.activeAccountId)
        XCTAssertEqual(notifications.activatedAccountIDs, [accountID])
        XCTAssertEqual(notifications.deactivateCount, 1)
        XCTAssertNil(model.currentUser)
        XCTAssertNil(model.household)
        XCTAssertEqual(model.phase, .onboarding)
    }

    func testInvitationOpenedBeforeSignInResumesAfterAuthentication() async throws {
        let model = AppModel.mock()
        let token = String(repeating: "b", count: InvitationToken.length)
        await model.open(try XCTUnwrap(URL(string: "petcompanion://invitation/\(token)")))

        let user = try await model.auth.signIn(email: "invitee@example.com", password: "password")
        let destination = try await model.didAuthenticate(user)

        XCTAssertEqual(destination, .reviewInvitation(token))
    }

    func testOrdinaryAuthCallbackStillRoutesThroughAuthService() async throws {
        let model = AppModel.mock()
        let url = try XCTUnwrap(
            URL(string: "petcompanion://auth-callback?code=mock&mock_email=caregiver@example.com")
        )

        await model.open(url)

        XCTAssertNotNil(model.currentUser)
        XCTAssertEqual(model.consumePendingOnboardingDestination(), .createHousehold)
        XCTAssertNil(model.passwordRecoveryState)
    }

    func testRecoveryOpenedFromMainNeverExchangesOrChangesExistingAccount() async throws {
        let auth = ControlledAuthService()
        let model = makePreviewModel(auth: auth)
        let originalUser = try XCTUnwrap(model.currentUser)
        auth.currentUser = originalUser
        let originalHousehold = model.household
        let originalPet = model.activePet

        await model.open(try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=valid")))
        XCTAssertEqual(model.passwordRecoveryState, .signedInBlocked)
        XCTAssertEqual(auth.establishCalls.count, 0)
        XCTAssertEqual(auth.discardedRecoverySessions.count, 0)
        XCTAssertEqual(auth.signOutCalls, 0)
        XCTAssertEqual(model.currentUser, originalUser)
        XCTAssertEqual(auth.currentUser, originalUser)
        XCTAssertEqual(model.household, originalHousehold)
        XCTAssertEqual(model.activePet, originalPet)

        await model.dismissPasswordRecovery()

        XCTAssertEqual(model.phase, .main)
        XCTAssertEqual(model.currentUser, originalUser)
        XCTAssertEqual(model.household, originalHousehold)
        XCTAssertEqual(model.activePet, originalPet)
        XCTAssertFalse(model.consumePasswordRecoverySignInRequest())
    }

    func testDismissalPublishesSignInRouteBeforeSuspendingSessionDiscard() async throws {
        let auth = ControlledAuthService()
        auth.establishBehavior = .immediate
        auth.suspendDiscard = true
        let model = makeModel(auth: auth)

        await model.open(try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=valid")))
        XCTAssertEqual(model.passwordRecoveryState, .ready)

        let dismissal = Task { await model.dismissPasswordRecovery() }
        await waitUntil { auth.discardStarted }

        XCTAssertNil(model.passwordRecoveryState)
        XCTAssertEqual(model.phase, .onboarding)
        XCTAssertTrue(model.consumePasswordRecoverySignInRequest())
        XCTAssertFalse(model.consumePasswordRecoverySignInRequest())

        auth.resumeDiscard()
        await dismissal.value
    }

    func testOlderFailureCannotOverwriteNewerSuccessfulLink() async throws {
        let auth = ControlledAuthService()
        auth.establishBehavior = .controlled
        let model = makeModel(auth: auth)
        let oldURL = try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=old"))
        let newURL = try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=new"))

        let oldOperation = Task { await model.open(oldURL) }
        await waitUntil { auth.establishCalls.contains(oldURL) }
        let newOperation = Task { await model.open(newURL) }
        await waitUntil { auth.establishCalls.contains(newURL) }

        auth.resumeEstablish(newURL, with: .success(PasswordRecoverySession()))
        await newOperation.value
        XCTAssertEqual(model.passwordRecoveryState, .ready)

        auth.resumeEstablish(oldURL, with: .failure(TestAuthError.failed))
        await oldOperation.value
        XCTAssertEqual(model.passwordRecoveryState, .ready)
    }

    func testOlderSuccessAfterNewerSuccessOnlyDiscardsOlderSession() async throws {
        let auth = ControlledAuthService()
        auth.establishBehavior = .controlled
        let model = makeModel(auth: auth)
        let oldURL = try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=old-success"))
        let newURL = try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=new-success"))

        let oldOperation = Task { await model.open(oldURL) }
        await waitUntil { auth.establishCalls.contains(oldURL) }
        let newOperation = Task { await model.open(newURL) }
        await waitUntil { auth.establishCalls.contains(newURL) }

        let newSession = PasswordRecoverySession()
        auth.resumeEstablish(newURL, with: .success(newSession))
        await newOperation.value
        let oldSession = PasswordRecoverySession()
        auth.resumeEstablish(oldURL, with: .success(oldSession))
        await oldOperation.value

        XCTAssertEqual(model.passwordRecoveryState, .ready)
        XCTAssertEqual(auth.discardedRecoverySessions, [oldSession])
        XCTAssertFalse(auth.discardedRecoverySessions.contains(newSession))
    }

    func testRecoveryExchangeCompletingAfterDismissalCannotResurrectUI() async throws {
        let auth = ControlledAuthService()
        auth.establishBehavior = .controlled
        let model = makeModel(auth: auth)
        let url = try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=slow"))

        let openOperation = Task { await model.open(url) }
        await waitUntil { auth.establishCalls.contains(url) }
        XCTAssertEqual(model.passwordRecoveryState, .validating)

        await model.dismissPasswordRecovery()
        XCTAssertNil(model.passwordRecoveryState)
        let staleSession = PasswordRecoverySession()
        auth.resumeEstablish(url, with: .success(staleSession))
        await openOperation.value

        XCTAssertNil(model.passwordRecoveryState)
        XCTAssertEqual(auth.discardedRecoverySessions, [staleSession])
    }

    func testNewInvitationClearsReadyRecoveryAndOwnedSession() async throws {
        let auth = ControlledAuthService()
        let model = makeModel(auth: auth)
        await model.open(
            try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=valid"))
        )
        let session = try XCTUnwrap(auth.activeRecoverySession)
        let token = String(repeating: "c", count: InvitationToken.length)

        await model.open(
            try XCTUnwrap(URL(string: "petcompanion://invitation/\(token)"))
        )

        XCTAssertNil(model.passwordRecoveryState)
        XCTAssertEqual(auth.discardedRecoverySessions, [session])
    }

    func testOrdinaryCallbackClearsReadyRecoveryBeforeAdoptingSession() async throws {
        let auth = ControlledAuthService()
        auth.callbackBehavior = .success(UserAccount(id: UUID(), displayName: "Confirmed"))
        let model = makeModel(auth: auth)
        await model.open(
            try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=valid"))
        )
        let session = try XCTUnwrap(auth.activeRecoverySession)

        await model.open(
            try XCTUnwrap(URL(string: "petcompanion://auth-callback?code=valid"))
        )

        XCTAssertNil(model.passwordRecoveryState)
        XCTAssertEqual(auth.discardedRecoverySessions, [session])
        XCTAssertNotNil(model.currentUser)
    }

    func testInvalidNewURLClearsReadyRecoveryAndOwnedSession() async throws {
        let auth = ControlledAuthService()
        let model = makeModel(auth: auth)
        await model.open(
            try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=valid"))
        )
        let session = try XCTUnwrap(auth.activeRecoverySession)

        await model.open(try XCTUnwrap(URL(string: "petcompanion://unrelated")))

        XCTAssertNil(model.passwordRecoveryState)
        XCTAssertEqual(auth.discardedRecoverySessions, [session])
    }

    func testRecoveryOwnershipSurvivesTokenRotationEquivalentCleanup() async throws {
        let auth = ControlledAuthService()
        let session = try await auth.establishPasswordRecoverySession(
            from: try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=valid"))
        )
        auth.simulateRecoveryTokenRefresh()

        await auth.discardPasswordRecoverySession(session)

        XCTAssertEqual(auth.discardedRecoverySessions, [session])
        XCTAssertNil(auth.activeRecoverySession)
    }

    func testStaleRecoveryHandleCannotDiscardNewerOwnership() async throws {
        let auth = ControlledAuthService()
        let url = try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=valid"))
        let stale = try await auth.establishPasswordRecoverySession(from: url)
        let newer = try await auth.establishPasswordRecoverySession(from: url)

        await auth.discardPasswordRecoverySession(stale)

        XCTAssertTrue(auth.discardedRecoverySessions.isEmpty)
        XCTAssertEqual(auth.activeRecoverySession, newer)
    }

    func testNewerSameUserOrdinarySessionInvalidatesRecoveryOwnership() async throws {
        let auth = ControlledAuthService()
        let user = UserAccount(id: UUID(), displayName: "Same User")
        auth.currentUser = user
        auth.allowRecoveryAlongsideCurrentUserForOwnershipTest = true
        let recovery = try await auth.establishPasswordRecoverySession(
            from: try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=valid"))
        )
        auth.adoptNewOrdinarySession(for: user)

        await auth.discardPasswordRecoverySession(recovery)

        XCTAssertTrue(auth.discardedRecoverySessions.isEmpty)
        XCTAssertEqual(auth.currentUser, user)
        XCTAssertEqual(auth.signOutCalls, 0)
    }

    func testEveryResetServiceOutcomeProducesSameGenericAcknowledgement() async throws {
        for behavior in [
            ControlledAuthService.RequestBehavior.success,
            .failure(TestAuthError.nonexistentEquivalent),
            .failure(TestAuthError.rateLimited),
            .failure(TestAuthError.transport)
        ] {
            let auth = ControlledAuthService()
            auth.requestBehavior = behavior
            let model = makeModel(auth: auth)

            let outcome = try await model.requestPasswordReset(email: "caregiver@example.com")

            XCTAssertEqual(outcome, .genericAcknowledgement)
            await waitUntil { auth.requestCalls == ["caregiver@example.com"] }
            await waitUntil { model.pendingPasswordResetDispatchCount == 0 }
        }
    }

    func testSuspendingResetTransportCannotDelayGenericAcknowledgementIndefinitely() async throws {
        let auth = ControlledAuthService()
        auth.requestBehavior = .suspended
        let model = makeModel(auth: auth)

        let outcome = try await model.requestPasswordReset(email: "caregiver@example.com")

        XCTAssertEqual(outcome, .genericAcknowledgement)
        XCTAssertNotNil(auth.requestContinuation)
        XCTAssertEqual(model.pendingPasswordResetDispatchCount, 1)
        auth.resumeRequest()
        await waitUntil { model.pendingPasswordResetDispatchCount == 0 }
    }

    func testRecoveryAndCallbackFailuresMapToVisibleSafeState() async throws {
        let auth = ControlledAuthService()
        auth.establishBehavior = .failure(TestAuthError.failed)
        auth.callbackBehavior = .failure(TestAuthError.failed)
        let model = makeModel(auth: auth)

        await model.open(try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=invalid")))
        XCTAssertEqual(model.passwordRecoveryState, .invalid)

        await model.dismissPasswordRecovery()
        await model.open(
            try XCTUnwrap(URL(string: "petcompanion://auth-callback?code=bad"))
        )
        XCTAssertEqual(model.appURLNotice?.title, "This link can’t be used")
        XCTAssertFalse(model.appURLNotice?.message.contains("failed") == true)
        XCTAssertNil(model.currentUser)
    }

    func testAuthCallbackBootstrapFailureRollsBackAndShowsNotice() async throws {
        let auth = ControlledAuthService()
        let callbackUser = UserAccount(id: UUID(), displayName: "Caregiver")
        auth.callbackBehavior = .success(callbackUser)
        let model = makeModel(auth: auth, households: FailingHouseholdService())

        await model.open(
            try XCTUnwrap(URL(string: "petcompanion://auth-callback?code=valid"))
        )

        XCTAssertNil(model.currentUser)
        XCTAssertNil(model.household)
        XCTAssertEqual(model.phase, .onboarding)
        XCTAssertEqual(auth.discardCallbackCalls, 1)
        XCTAssertEqual(model.appURLNotice?.title, "This link can’t be used")
    }
}

private enum TestAuthError: Error {
    case failed
    case nonexistentEquivalent
    case rateLimited
    case transport
}

@MainActor
private final class ControlledAuthService: AuthService {
    enum EstablishBehavior {
        case immediate
        case controlled
        case failure(Error)
    }

    enum RequestBehavior {
        case success
        case failure(Error)
        case suspended
    }

    var currentUser: UserAccount?
    var establishBehavior: EstablishBehavior = .immediate
    var requestBehavior: RequestBehavior = .success
    var callbackBehavior: Result<UserAccount, Error> = .failure(TestAuthError.failed)
    var suspendDiscard = false
    var allowRecoveryAlongsideCurrentUserForOwnershipTest = false

    private(set) var establishCalls: [URL] = []
    private(set) var discardedRecoverySessions: [PasswordRecoverySession] = []
    private(set) var activeRecoverySession: PasswordRecoverySession?
    private(set) var discardCallbackCalls = 0
    private(set) var signOutCalls = 0
    private(set) var requestCalls: [String] = []
    private(set) var discardStarted = false
    private(set) var requestContinuation: CheckedContinuation<Void, Never>?

    private var establishContinuations:
        [URL: CheckedContinuation<Result<PasswordRecoverySession, Error>, Never>] = [:]
    private var discardContinuation: CheckedContinuation<Void, Never>?

    func createAccount(email: String, password: String) async throws -> AccountCreationResult {
        .authenticated(try await signIn(email: email, password: password))
    }

    func signIn(email: String, password: String) async throws -> UserAccount {
        activeRecoverySession = nil
        let user = UserAccount(id: UUID(), displayName: "Caregiver")
        currentUser = user
        return user
    }

    func requestPasswordReset(email: String) async throws {
        requestCalls.append(email)
        switch requestBehavior {
        case .success:
            return
        case .failure(let error):
            throw error
        case .suspended:
            await withCheckedContinuation { requestContinuation = $0 }
        }
    }

    func establishPasswordRecoverySession(from url: URL) async throws -> PasswordRecoverySession {
        establishCalls.append(url)
        guard currentUser == nil || allowRecoveryAlongsideCurrentUserForOwnershipTest else {
            throw AuthError.recoveryRequiresSignOut
        }
        let session: PasswordRecoverySession
        switch establishBehavior {
        case .immediate:
            session = PasswordRecoverySession()
        case .failure(let error):
            throw error
        case .controlled:
            let result: Result<PasswordRecoverySession, Error> = await withCheckedContinuation { continuation in
                establishContinuations[url] = continuation
            }
            session = try result.get()
        }
        activeRecoverySession = session
        return session
    }

    func updatePassword(_ password: String) async throws {}

    func handleAuthenticationCallback(from url: URL) async throws -> AuthenticationCallbackSession {
        activeRecoverySession = nil
        let session = AuthenticationCallbackSession(user: try callbackBehavior.get())
        currentUser = session.user
        return session
    }

    func discardPasswordRecoverySession(_ session: PasswordRecoverySession) async {
        guard activeRecoverySession == session else { return }
        activeRecoverySession = nil
        discardedRecoverySessions.append(session)
        discardStarted = true
        if suspendDiscard {
            await withCheckedContinuation { discardContinuation = $0 }
        }
    }

    func completeAuthenticationCallbackSession(_ session: AuthenticationCallbackSession) {}

    func discardAuthenticationCallbackSession(_ session: AuthenticationCallbackSession) async {
        discardCallbackCalls += 1
        currentUser = nil
    }

    func signOut() {
        activeRecoverySession = nil
        signOutCalls += 1
        currentUser = nil
    }

    func resumeEstablish(
        _ url: URL,
        with result: Result<PasswordRecoverySession, Error>
    ) {
        establishContinuations.removeValue(forKey: url)?.resume(returning: result)
    }

    func resumeDiscard() {
        discardContinuation?.resume()
        discardContinuation = nil
    }

    func resumeRequest() {
        requestContinuation?.resume()
        requestContinuation = nil
    }

    func simulateRecoveryTokenRefresh() {
        // Ownership intentionally does not depend on an access token.
    }

    func adoptNewOrdinarySession(for user: UserAccount) {
        activeRecoverySession = nil
        currentUser = user
    }
}

@MainActor
private class TestHouseholdService: HouseholdService {
    func currentHousehold() async throws -> Household? { throw TestAuthError.failed }
    func createHousehold(name: String, timeZone: String) async throws -> Household {
        throw TestAuthError.failed
    }
    func members(householdId: UUID) async throws -> [HouseholdMember] { throw TestAuthError.failed }
    func pets(householdId: UUID) async throws -> [Pet] { throw TestAuthError.failed }
    func createPet(name: String, birthInfo: BirthInfo, homecomingDate: Date?) async throws -> Pet {
        throw TestAuthError.failed
    }
    func saveRoutinePreferences(_ preferences: HouseholdPreference) async throws {
        throw TestAuthError.failed
    }
    func invitations(householdId: UUID) async throws -> [HouseholdInvitation] {
        throw TestAuthError.failed
    }
    func createInvitation(householdId: UUID, expiresInHours: Int) async throws -> CreatedInvitation {
        throw TestAuthError.failed
    }
    func revokeInvitation(id: UUID) async throws { throw TestAuthError.failed }
    func previewInvitation(token: String) async throws -> InvitationPreview {
        throw TestAuthError.failed
    }
    func acceptInvitation(token: String) async throws -> Household { throw TestAuthError.failed }
    func declineInvitation(token: String) async throws { throw TestAuthError.failed }
}

@MainActor
private final class FailingHouseholdService: TestHouseholdService {}

@MainActor
private final class SuspendingHouseholdService: TestHouseholdService {
    private(set) var currentHouseholdStarted = false
    private var continuation: CheckedContinuation<Household?, Never>?

    override func currentHousehold() async throws -> Household? {
        currentHouseholdStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func resumeCurrentHousehold(returning household: Household?) {
        continuation?.resume(returning: household)
        continuation = nil
    }
}

@MainActor
private final class ReplayObservingHouseholdService: TestHouseholdService {
    private let didReplay: () -> Bool
    private(set) var replayHadFinishedWhenResolved = false

    init(didReplay: @escaping () -> Bool) {
        self.didReplay = didReplay
    }

    override func currentHousehold() async throws -> Household? {
        replayHadFinishedWhenResolved = didReplay()
        return nil
    }
}

@MainActor
private final class QueueTestTransport: OfflineOperationTransport {
    private let error: Error?
    private(set) var executeCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    func execute(_ operation: OfflineOperation) async throws -> Data {
        executeCount += 1
        if let error { throw error }
        return Data("{}".utf8)
    }
}

@MainActor
private final class TestNotificationService: LocalNotificationServicing {
    var preferences = LocalNotificationPreferences.defaults
    var permission = NotificationPermission.notDetermined
    private(set) var activatedAccountIDs: [UUID] = []
    private(set) var deactivateCount = 0

    func activate(accountId: UUID) {
        activatedAccountIDs.append(accountId)
    }

    func deactivate() {
        deactivateCount += 1
    }

    func setEnabled(_ enabled: Bool) async -> NotificationPermission { permission }
    func updatePreferences(_ preferences: LocalNotificationPreferences) async {
        self.preferences = preferences
    }
    func reconcile(snapshot: PlanSnapshot, now: Date) async {}
    func reconcileEvents(
        events: [HouseholdEvent],
        timeZoneId: String,
        now: Date
    ) async {}
    func cancelPending() async {}
}

@MainActor
private func makeModel(
    auth: any AuthService,
    households: (any HouseholdService)? = nil,
    notifications: (any LocalNotificationServicing)? = nil,
    mutationQueue: OfflineOperationQueue? = nil
) -> AppModel {
    let backend = MockBackend()
    return AppModel(
        auth: auth,
        households: households ?? MockHouseholdService(backend: backend),
        plans: MockPlanService(backend: backend),
        training: MockTrainingService(backend: backend),
        notifications: notifications,
        mutationQueue: mutationQueue
    )
}

@MainActor
private func makePreviewModel(auth: any AuthService) -> AppModel {
    let backend = MockBackend()
    let seed = backend.seedForPreview(preArrival: false)
    let model = AppModel(
        auth: auth,
        households: MockHouseholdService(backend: backend),
        plans: MockPlanService(backend: backend),
        training: MockTrainingService(backend: backend)
    )
    model.currentUser = seed.user
    model.household = seed.household
    model.activePet = seed.pet
    model.phase = .main
    return model
}

@MainActor
private func waitUntil(
    timeoutIterations: Int = 100,
    _ condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<timeoutIterations where !condition() {
        await Task.yield()
    }
    XCTAssertTrue(condition())
}
