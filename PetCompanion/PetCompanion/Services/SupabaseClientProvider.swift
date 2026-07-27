import Foundation
import Supabase

/// Builds and holds the `SupabaseClient` used by the `Real*Service`
/// implementations — Slice A WP-2 (doc 06 §6, §11).
@MainActor
enum SupabaseClientProvider {
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
    /// stack up") cheaply.
    ///
    /// The `apikey` header is required. Hosted Supabase rejects every API
    /// route without it — `{"message":"No API key found in request"}`, 401 —
    /// whereas the local gateway served this path unauthenticated. Omitting it
    /// made the probe report a perfectly healthy hosted project as
    /// unreachable. The key is the public publishable credential, so this
    /// remains an unauthenticated probe requiring no session.
    ///
    /// The timeout allows for a real network round trip and TLS handshake;
    /// the original value was tuned for localhost.
    static func isReachable(
        config: BackendConfig,
        timeout: TimeInterval = 8
    ) async -> Bool {
        var request = URLRequest(url: config.url.appendingPathComponent("auth/v1/health"))
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
