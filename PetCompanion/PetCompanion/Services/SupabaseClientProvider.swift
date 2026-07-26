import Foundation
import Supabase

/// Builds and holds the `SupabaseClient` used by the `Real*Service`
/// implementations — Slice A WP-2 (doc 06 §6, §11).
@MainActor
enum SupabaseClientProvider {
    /// One client per process, configured from `BackendConfig.local`. The
    /// SDK owns session persistence (Keychain-backed) and token refresh
    /// internally, so a single long-lived instance is the right shape.
    static let shared: SupabaseClient = makeClient(config: .local)

    static func makeClient(config: BackendConfig) -> SupabaseClient {
        SupabaseClient(supabaseURL: config.url, supabaseKey: config.anonKey)
    }

    /// Cheap, unauthenticated reachability probe used by `AppModel` at
    /// launch to decide mock vs. local (doc 17 WP-2).
    ///
    /// This intentionally does NOT do what the work order first suggested
    /// ("fetch a `development_stages` count") — under the write-path
    /// grants model (migration `202607260001_slice_a_foundation.sql`,
    /// "Base table privileges" section), the `anon` role has **zero**
    /// table grants; every table read requires an authenticated session.
    /// A pre-sign-in count query against `development_stages` with the
    /// anon key 401s by design, every time, whether or not the stack is
    /// reachable — so it can't be used as a reachability signal before
    /// the user has a session. `GET /auth/v1/health` requires no table
    /// grants and no session, and answers the same question ("is the
    /// local stack up") cheaply.
    static func isLocalStackReachable(
        config: BackendConfig = .local,
        timeout: TimeInterval = 2.5
    ) async -> Bool {
        var request = URLRequest(url: config.url.appendingPathComponent("auth/v1/health"))
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
