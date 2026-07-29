import Foundation

enum AppURLDestination: Equatable {
    case invitation(String)
    case passwordRecovery
    case authenticationCallback
}

enum AppURLRouter {
    static func destination(for url: URL) -> AppURLDestination? {
        guard url.scheme?.lowercased() == InvitationToken.scheme else { return nil }

        switch url.host?.lowercased() {
        case "invitation":
            guard let token = InvitationToken.extract(from: url.absoluteString) else { return nil }
            return .invitation(token)
        case "password-reset":
            return .passwordRecovery
        default:
            return containsAuthenticationParameters(url) ? .authenticationCallback : nil
        }
    }

    static func isMockRecoveryLink(_ url: URL) -> Bool {
        guard destination(for: url) == .passwordRecovery else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return items?.first(where: { $0.name == "mock" })?.value != "invalid"
    }

    private static func containsAuthenticationParameters(_ url: URL) -> Bool {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.queryItems?.contains(where: {
            ["code", "error", "error_code"].contains($0.name)
        }) == true {
            return true
        }
        guard let fragment = components?.fragment else { return false }
        let fragmentItems = URLComponents(string: "?\(fragment)")?.queryItems ?? []
        return fragmentItems.contains { ["access_token", "error", "error_code"].contains($0.name) }
    }
}
