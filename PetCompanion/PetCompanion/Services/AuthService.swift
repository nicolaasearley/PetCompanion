import Foundation

/// Authentication boundary — WP-2. The Supabase Auth implementation slots
/// in behind this protocol later with no UI changes.
@MainActor
protocol AuthService: AnyObject {
    var currentUser: UserAccount? { get }
    func createAccount(email: String, password: String) async throws -> AccountCreationResult
    func signIn(email: String, password: String) async throws -> UserAccount
    func requestPasswordReset(email: String) async throws
    func establishPasswordRecoverySession(from url: URL) async throws -> PasswordRecoverySession
    func updatePassword(_ password: String) async throws
    func handleAuthenticationCallback(from url: URL) async throws -> AuthenticationCallbackSession
    func discardPasswordRecoverySession(_ session: PasswordRecoverySession) async
    func completeAuthenticationCallbackSession(_ session: AuthenticationCallbackSession)
    func discardAuthenticationCallbackSession(_ session: AuthenticationCallbackSession) async
    func signOut()
}

struct PasswordRecoverySession: Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

struct AuthenticationCallbackSession: Equatable, Sendable {
    let id: UUID
    let user: UserAccount

    init(id: UUID = UUID(), user: UserAccount) {
        self.id = id
        self.user = user
    }
}

enum AccountCreationResult: Equatable, Sendable {
    case authenticated(UserAccount)
    case confirmationRequired(email: String)
}

enum AuthError: LocalizedError, Equatable {
    case invalidEmail
    case weakPassword
    case invalidCredentials
    case resetRequestFailed
    case invalidRecoveryLink
    case recoveryRequiresSignOut
    case passwordUpdateFailed

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            "That email address doesn't look right. Check it and try again."
        case .weakPassword:
            "Choose a password with at least 8 characters."
        case .invalidCredentials:
            "That email and password don't match. Try again."
        case .resetRequestFailed:
            "We couldn't send reset instructions right now. Check your connection and try again."
        case .invalidRecoveryLink:
            "This password reset link is invalid or has expired. Request a new one to continue."
        case .recoveryRequiresSignOut:
            "You're already signed in. Return to Settle and sign out before using a password reset link."
        case .passwordUpdateFailed:
            "We couldn't update your password. Check your connection and try again."
        }
    }
}

enum AuthValidation {
    static let minimumPasswordLength = 8

    static func normalizedEmail(_ email: String) throws -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), trimmed.contains("."), trimmed.count >= 5 else {
            throw AuthError.invalidEmail
        }
        return trimmed
    }

    static func validatePassword(_ password: String) throws {
        guard password.count >= minimumPasswordLength else {
            throw AuthError.weakPassword
        }
    }

    static func passwordConfirmationError(password: String, confirmation: String) -> String? {
        if password.count < minimumPasswordLength {
            return "Choose a password with at least \(minimumPasswordLength) characters."
        }
        if password != confirmation {
            return "The passwords don't match yet."
        }
        return nil
    }
}

/// Mock implementation: validates shape, simulates latency, then succeeds.
/// Input is retained on error (doc 14 ON-02/ON-03 states).
@MainActor
final class MockAuthService: AuthService {
    private let backend: MockBackend
    private var activeRecoverySession: PasswordRecoverySession?
    private var activeCallbackSession: AuthenticationCallbackSession?

    init(backend: MockBackend) {
        self.backend = backend
    }

    var currentUser: UserAccount? { backend.currentUser }

    func createAccount(email: String, password: String) async throws -> AccountCreationResult {
        .authenticated(try await submit(email: email, password: password))
    }

    func signIn(email: String, password: String) async throws -> UserAccount {
        activeRecoverySession = nil
        return try await submit(email: email, password: password)
    }

    func requestPasswordReset(email: String) async throws {
        _ = try AuthValidation.normalizedEmail(email)
        try? await Task.sleep(for: .milliseconds(600))
    }

    func establishPasswordRecoverySession(from url: URL) async throws -> PasswordRecoverySession {
        guard backend.currentUser == nil else {
            throw AuthError.recoveryRequiresSignOut
        }
        guard AppURLRouter.isMockRecoveryLink(url) else {
            throw AuthError.invalidRecoveryLink
        }
        try? await Task.sleep(for: .milliseconds(250))
        let session = PasswordRecoverySession()
        activeRecoverySession = session
        return session
    }

    func updatePassword(_ password: String) async throws {
        try AuthValidation.validatePassword(password)
        try? await Task.sleep(for: .milliseconds(600))
    }

    func handleAuthenticationCallback(from url: URL) async throws -> AuthenticationCallbackSession {
        activeRecoverySession = nil
        guard let email = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "mock_email" })?
            .value
        else {
            throw AuthError.invalidRecoveryLink
        }
        let session = AuthenticationCallbackSession(
            user: backend.signIn(email: try AuthValidation.normalizedEmail(email))
        )
        activeCallbackSession = session
        return session
    }

    func discardPasswordRecoverySession(_ session: PasswordRecoverySession) async {
        guard activeRecoverySession == session else { return }
        activeRecoverySession = nil
        backend.currentUserId = nil
    }

    func discardAuthenticationCallbackSession(_ session: AuthenticationCallbackSession) async {
        guard activeCallbackSession == session else { return }
        activeCallbackSession = nil
        backend.currentUserId = nil
    }

    func completeAuthenticationCallbackSession(_ session: AuthenticationCallbackSession) {
        guard activeCallbackSession == session else { return }
        activeCallbackSession = nil
    }

    func signOut() {
        activeRecoverySession = nil
        activeCallbackSession = nil
        backend.currentUserId = nil
    }

    private func submit(email: String, password: String) async throws -> UserAccount {
        let trimmed = try AuthValidation.normalizedEmail(email)
        try AuthValidation.validatePassword(password)
        try? await Task.sleep(for: .milliseconds(600))
        return backend.signIn(email: trimmed)
    }
}
