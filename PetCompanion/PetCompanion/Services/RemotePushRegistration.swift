import Foundation
import Observation
import UIKit
import UserNotifications

#if canImport(Supabase)
import Supabase
#endif

enum PushEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production
}

struct DeviceTokenRegistration: Equatable, Sendable {
    let token: String
    let environment: PushEnvironment
    var appBuild: String?
    var deviceName: String?
}

/// Abstracts write-path registration so unit tests never need a live Supabase
/// client or APNs hardware.
@MainActor
protocol DeviceTokenTransport: AnyObject {
    func register(_ registration: DeviceTokenRegistration) async throws
    func unregister(token: String) async throws
}

@MainActor
protocol RemotePushRegistering: AnyObject {
    var lastRegisteredToken: String? { get }
    func activate(accountId: UUID)
    func deactivate()
    /// Ask the OS for a remote token when notification permission is already
    /// granted. Safe on Simulator (failure is logged, local reminders continue).
    func refreshRegistration() async
    func didReceiveDeviceToken(_ tokenData: Data)
    func didFailToRegister(error: Error)
}

@MainActor
final class NoOpDeviceTokenTransport: DeviceTokenTransport {
    func register(_ registration: DeviceTokenRegistration) async throws {}
    func unregister(token: String) async throws {}
}

#if canImport(Supabase)
@MainActor
final class WritePathDeviceTokenTransport: DeviceTokenTransport {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func register(_ registration: DeviceTokenRegistration) async throws {
        struct Payload: Encodable {
            let token: String
            let environment: String
            let platform: String
            let app_build: String?
            let device_name: String?
        }
        struct Result: Decodable {
            let device_token: DeviceTokenDTO?
        }
        struct DeviceTokenDTO: Decodable {
            let id: UUID?
            let token: String?
        }
        let _: Result = try await WritePath.send(
            client: client,
            command: "register_device_token",
            payload: Payload(
                token: registration.token,
                environment: registration.environment.rawValue,
                platform: "ios",
                app_build: registration.appBuild,
                device_name: registration.deviceName
            )
        )
    }

    func unregister(token: String) async throws {
        struct Payload: Encodable { let token: String }
        struct Result: Decodable {
            let revoked: Bool?
        }
        let _: Result = try await WritePath.send(
            client: client,
            command: "unregister_device_token",
            payload: Payload(token: token)
        )
    }
}
#endif

/// Captures APNs device tokens and registers them through the write path.
/// Does not own local notification scheduling — that stays in
/// `LocalNotificationService`.
@MainActor
@Observable
final class RemotePushRegistrationService: RemotePushRegistering {
    private let transport: any DeviceTokenTransport
    private let application: UIApplication
    private(set) var lastRegisteredToken: String?
    private var activeAccountId: UUID?
    private var pendingToken: String?
    private var lastErrorDescription: String?

    init(
        transport: any DeviceTokenTransport,
        application: UIApplication = .shared
    ) {
        self.transport = transport
        self.application = application
    }

    #if canImport(Supabase)
    static func live(client: SupabaseClient) -> RemotePushRegistrationService {
        RemotePushRegistrationService(transport: WritePathDeviceTokenTransport(client: client))
    }
    #endif

    static func disabled() -> RemotePushRegistrationService {
        RemotePushRegistrationService(transport: NoOpDeviceTokenTransport())
    }

    func activate(accountId: UUID) {
        activeAccountId = accountId
        Task { await refreshRegistration() }
    }

    func deactivate() {
        let token = lastRegisteredToken
        activeAccountId = nil
        lastRegisteredToken = nil
        pendingToken = nil
        if let token {
            Task {
                try? await transport.unregister(token: token)
            }
        }
    }

    func refreshRegistration() async {
        guard activeAccountId != nil else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            application.registerForRemoteNotifications()
            if let pendingToken {
                await submit(token: pendingToken)
            }
        case .denied, .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func didReceiveDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        pendingToken = token
        guard activeAccountId != nil else { return }
        Task { await submit(token: token) }
    }

    func didFailToRegister(error: Error) {
        // Simulator and missing entitlements land here. Local reminders must
        // keep working; remote registration simply stays unavailable.
        lastErrorDescription = String(describing: error)
        #if DEBUG
        print("Remote push registration failed (non-fatal): \(error.localizedDescription)")
        #endif
    }

    private func submit(token: String) async {
        guard activeAccountId != nil else { return }
        let registration = DeviceTokenRegistration(
            token: token,
            environment: Self.currentEnvironment,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            deviceName: UIDevice.current.name
        )
        do {
            try await transport.register(registration)
            lastRegisteredToken = token
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = String(describing: error)
            #if DEBUG
            print("Remote push token upload failed (non-fatal): \(error.localizedDescription)")
            #endif
        }
    }

    private static var currentEnvironment: PushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}
