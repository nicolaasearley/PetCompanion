import Foundation
import Supabase

/// Supabase Auth-backed implementation of `AuthService` — Slice A WP-2
/// (doc 06 §11, doc 17 WP-2). Slots in behind the same protocol the mock
/// implements; no UI changes.
///
/// Email verification (doc 06 §11 "email + password with email
/// verification"): the local stack auto-confirms sign-ups
/// (`supabase/config.toml` has no `[auth.email]` override, and
/// `GET /auth/v1/settings` on the running stack reports
/// `mailer_autoconfirm: true`), so `signUp` returns a session immediately
/// in local mode. Against a hosted project with confirmations enabled,
/// `signUp` would return a user with `session == nil` until the caregiver
/// clicks the emailed link — that path is handled below (`pendingUser`)
/// but cannot be exercised against this local stack. Confirmation emails,
/// when sent, land in Mailpit at the `MAILPIT_URL` from `supabase status`
/// (`http://127.0.0.1:54324` in this environment) rather than a real inbox.
@MainActor
final class RealAuthService: AuthService {
    private let client: SupabaseClient
    private var _currentUser: UserAccount?
    private var authStateTask: Task<Void, Never>?

    var currentUser: UserAccount? { _currentUser }

    init(client: SupabaseClient) {
        self.client = client
        // Optimistic synchronous restore from the Keychain-backed session
        // store (US-002 "session restore"), corrected below once the SDK
        // finishes validating/refreshing it.
        if let session = client.auth.currentSession {
            _currentUser = Self.userAccount(from: session)
        }
        authStateTask = Task { [weak self] in
            guard let self else { return }
            for await (_, session) in client.auth.authStateChanges {
                self.apply(session: session)
            }
        }
    }

    deinit {
        authStateTask?.cancel()
    }

    private func apply(session: Session?) {
        _currentUser = session.map(Self.userAccount(from:))
    }

    func createAccount(email: String, password: String) async throws -> AccountCreationResult {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same shape as the mock's inline validation (ON-02 states) so the
        // form's error UI behaves identically before hitting the network.
        //
        // NB: `PetCompanion.AuthError` is qualified with the module name
        // because `import Supabase` re-exports `Auth.AuthError` (the SDK's
        // own error enum, `@_exported import Auth` in
        // supabase-swift/Sources/Supabase/Exports.swift) under the same
        // unqualified name `AuthError` — an unqualified reference here is
        // ambiguous between the two same-named types.
        guard trimmed.contains("@"), trimmed.contains("."), trimmed.count >= 5 else {
            throw PetCompanion.AuthError.invalidEmail
        }
        guard password.count >= 8 else {
            throw PetCompanion.AuthError.weakPassword
        }

        let displayName = Self.displayName(fromEmail: trimmed)
        let response = try await client.auth.signUp(
            email: trimmed,
            password: password,
            data: ["display_name": .string(displayName)]
        )

        // `user_profiles` is self-insertable by RLS ("user profiles self
        // insert", id = auth.uid()); this only succeeds once a session
        // exists, which local auto-confirm guarantees immediately.
        if response.session != nil {
            try? await upsertProfile(userId: response.user.id, displayName: displayName)
        }

        let account = UserAccount(id: response.user.id, displayName: displayName)
        if response.session != nil {
            _currentUser = account
            return .authenticated(account)
        }
        // Hosted confirmations-on path: onboarding must pause until the
        // caregiver has a real authenticated session.
        return .confirmationRequired(email: trimmed)
    }

    func signIn(email: String, password: String) async throws -> UserAccount {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = try await client.auth.signIn(email: trimmed, password: password)
        let displayName = await resolvedDisplayName(for: session.user)
        let account = UserAccount(id: session.user.id, displayName: displayName)
        _currentUser = account
        return account
    }

    func signOut() {
        _currentUser = nil
        Task { try? await client.auth.signOut() }
    }

    // MARK: - Profile

    /// Source of truth for display name is `user_profiles.display_name`,
    /// not the auth user's metadata (which only reflects what was true at
    /// sign-up time) — falls back to the metadata/email-derived name if
    /// the profile row isn't readable yet.
    private func resolvedDisplayName(for user: User) async -> String {
        struct ProfileRow: Decodable { let display_name: String }
        if let response = try? await client
            .from("user_profiles")
            .select("display_name")
            .eq("id", value: user.id)
            .single()
            .execute(),
           let profile = try? SupabaseCoding.restDecoder.decode(ProfileRow.self, from: response.data) {
            return profile.display_name
        }
        if case .string(let name)? = user.userMetadata["display_name"] {
            return name
        }
        return Self.displayName(fromEmail: user.email ?? "")
    }

    private func upsertProfile(userId: UUID, displayName: String) async throws {
        struct ProfileUpsert: Encodable {
            let id: UUID
            let display_name: String
        }
        _ = try await client
            .from("user_profiles")
            .upsert(ProfileUpsert(id: userId, display_name: displayName), onConflict: "id")
            .execute()
    }

    // MARK: - Helpers

    private static func userAccount(from session: Session) -> UserAccount {
        let name: String
        if case .string(let value)? = session.user.userMetadata["display_name"] {
            name = value
        } else {
            name = displayName(fromEmail: session.user.email ?? "")
        }
        return UserAccount(id: session.user.id, displayName: name)
    }

    /// Same convention as `MockBackend.displayName(fromEmail:)` (doc 14
    /// ON-02 fallback display name) so switching backends doesn't change
    /// what a caregiver sees before they've set anything explicitly.
    static func displayName(fromEmail email: String) -> String {
        let local = email.split(separator: "@").first ?? "Caregiver"
        let first = local.split(whereSeparator: { ".+-_".contains($0) }).first ?? local
        guard !first.isEmpty else { return "Caregiver" }
        return first.prefix(1).uppercased() + first.dropFirst().lowercased()
    }
}
