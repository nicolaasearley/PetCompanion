import Foundation

/// Coordinates for one Supabase environment. The anonymous key is a public
/// client credential; privileged service-role keys must never enter the app.
struct BackendConfig: Equatable, Sendable {
    let url: URL
    let anonKey: String

    /// Well-known credentials printed by a local `supabase start`.
    nonisolated static let local = BackendConfig(
        url: URL(string: "http://127.0.0.1:54321")!,
        anonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
    )
}

/// Explicit runtime selection. A real build never quietly turns into the
/// in-memory demo when its configured backend is unavailable.
enum BackendSelection: Equatable, Sendable {
    case mock
    case local(BackendConfig)
    case hosted(BackendConfig)
    case invalid(String)

    nonisolated static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:],
        isDebug: Bool = {
            #if DEBUG
            true
            #else
            false
            #endif
        }()
    ) -> BackendSelection {
        let argumentMode: String? = {
            guard let index = arguments.firstIndex(of: "-PetCompanionBackend"),
                  arguments.indices.contains(index + 1)
            else { return nil }
            return arguments[index + 1]
        }()
        let configuredMode = argumentMode
            ?? environment["PETCOMPANION_BACKEND"]
            ?? normalized(info["PC_BACKEND_MODE"])
            ?? (isDebug ? "local" : "hosted")

        switch configuredMode.lowercased() {
        case "mock":
            return .mock
        case "local":
            return .local(.local)
        case "hosted", "production", "prod":
            guard let urlString = environment["PETCOMPANION_SUPABASE_URL"]
                    ?? normalized(info["PC_SUPABASE_URL"]),
                  let url = URL(string: urlString),
                  let key = environment["PETCOMPANION_SUPABASE_ANON_KEY"]
                    ?? normalized(info["PC_SUPABASE_ANON_KEY"]),
                  !key.isEmpty
            else {
                return .invalid(
                    "This build is configured for the hosted service, but its public Supabase URL and anonymous key are missing."
                )
            }
            return .hosted(BackendConfig(url: url, anonKey: key))
        default:
            return .invalid("Unknown backend mode “\(configuredMode)”. Use local, hosted, or mock.")
        }
    }

    private nonisolated static func normalized(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
