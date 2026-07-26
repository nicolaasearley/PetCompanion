import Foundation

/// Supabase project coordinates the app can point at — Slice A WP-2.
///
/// This is intentionally a plain Swift struct rather than an .xcconfig: the
/// owner-created Xcode project has no build-setting plumbing for injecting
/// per-environment values into Info.plist yet, and Slice A only needs one
/// real environment (local). Promote this to real .xcconfig-backed values
/// (`SUPABASE_URL` / `SUPABASE_ANON_KEY` build settings read via
/// `Bundle.main.infoDictionary`) when `prod` is provisioned (doc 06 §14).
struct BackendConfig {
    let url: URL
    let anonKey: String

    /// The local Supabase stack started with `supabase start` (doc 17 WP-0).
    /// Values below are read from `supabase status` output — they are the
    /// well-known, publicly-documented local development defaults (not
    /// secrets; every `supabase init` project prints the same anon key
    /// until a stack changes its `JWT_SECRET`). The simulator reaches this
    /// over `127.0.0.1` because it shares the Mac's loopback interface.
    // `nonisolated`: this is an inert value type (URL + String) read from
    // default-parameter positions in nonisolated contexts (e.g. function
    // signature defaults); the module's default actor isolation
    // (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) would otherwise make
    // these static members MainActor-isolated for no reason, since
    // `BackendConfig` holds no actor-affine state.
    nonisolated static let local = BackendConfig(
        url: URL(string: "http://127.0.0.1:54321")!,
        anonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
    )

    // TODO(prod): once the `prod` Supabase project is provisioned (doc 06
    // §14), replace this with values pulled from a real secrets source
    // (e.g. an .xcconfig injected at CI build time + Info.plist keys read
    // via Bundle.main), never hardcoded here. Tracked as an explicit Slice
    // A→B follow-up; do not ship a production build against `.local`.
    nonisolated static var production: BackendConfig {
        fatalError("BackendConfig.production is not configured yet — prod Supabase project is provisioned but no client config exists (doc 06 §14).")
    }
}
