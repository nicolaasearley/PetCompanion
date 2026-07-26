import Foundation

/// Authentication boundary — WP-2. The Supabase Auth implementation slots
/// in behind this protocol later with no UI changes.
@MainActor
protocol AuthService: AnyObject {
    var currentUser: UserAccount? { get }
    func createAccount(email: String, password: String) async throws -> UserAccount
    func signIn(email: String, password: String) async throws -> UserAccount
    func signOut()
}

enum AuthError: LocalizedError {
    case invalidEmail
    case weakPassword
    case invalidCredentials

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            "That email address doesn't look right. Check it and try again."
        case .weakPassword:
            "Choose a password with at least 8 characters."
        case .invalidCredentials:
            "That email and password don't match. Try again."
        }
    }
}

/// Mock implementation: validates shape, simulates latency, then succeeds.
/// Input is retained on error (doc 14 ON-02/ON-03 states).
@MainActor
final class MockAuthService: AuthService {
    private let backend: MockBackend

    init(backend: MockBackend) {
        self.backend = backend
    }

    var currentUser: UserAccount? { backend.currentUser }

    func createAccount(email: String, password: String) async throws -> UserAccount {
        try await submit(email: email, password: password)
    }

    func signIn(email: String, password: String) async throws -> UserAccount {
        try await submit(email: email, password: password)
    }

    func signOut() {
        backend.currentUserId = nil
    }

    private func submit(email: String, password: String) async throws -> UserAccount {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), trimmed.contains("."), trimmed.count >= 5 else {
            throw AuthError.invalidEmail
        }
        guard password.count >= 8 else {
            throw AuthError.weakPassword
        }
        try? await Task.sleep(for: .milliseconds(600))
        return backend.signIn(email: trimmed)
    }
}
