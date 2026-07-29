import Foundation
import XCTest
@testable import PetCompanion

@MainActor
final class RemotePushRegistrationTests: XCTestCase {
    private final class MockTransport: DeviceTokenTransport {
        private(set) var registrations: [DeviceTokenRegistration] = []
        private(set) var unregisters: [String] = []
        var registerError: Error?

        func register(_ registration: DeviceTokenRegistration) async throws {
            if let registerError { throw registerError }
            registrations.append(registration)
        }

        func unregister(token: String) async throws {
            unregisters.append(token)
        }
    }

    func testDidReceiveDeviceTokenRegistersHexTokenForActiveAccount() async throws {
        let transport = MockTransport()
        let service = RemotePushRegistrationService(transport: transport)
        let accountId = UUID()
        service.activate(accountId: accountId)

        let bytes: [UInt8] = Array(repeating: 0xAB, count: 32)
        service.didReceiveDeviceToken(Data(bytes))

        // Allow the async submit Task to run.
        await Task.yield()
        await waitUntil(timeout: 1.0) { !transport.registrations.isEmpty }

        XCTAssertEqual(transport.registrations.count, 1)
        let registration = try XCTUnwrap(transport.registrations.first)
        XCTAssertEqual(registration.token, String(repeating: "ab", count: 32))
        XCTAssertEqual(registration.environment, .sandbox)
        XCTAssertEqual(service.lastRegisteredToken, registration.token)
    }

    func testDeactivateUnregistersLastToken() async {
        let transport = MockTransport()
        let service = RemotePushRegistrationService(transport: transport)
        service.activate(accountId: UUID())
        service.didReceiveDeviceToken(Data(Array(repeating: 0x01, count: 32)))
        await waitUntil(timeout: 1.0) { service.lastRegisteredToken != nil }

        service.deactivate()
        await waitUntil(timeout: 1.0) { !transport.unregisters.isEmpty }

        XCTAssertEqual(transport.unregisters.count, 1)
        XCTAssertNil(service.lastRegisteredToken)
    }

    func testRegistrationFailureIsNonFatal() async {
        let transport = MockTransport()
        transport.registerError = NSError(domain: "test", code: 1)
        let service = RemotePushRegistrationService(transport: transport)
        service.activate(accountId: UUID())
        service.didReceiveDeviceToken(Data(Array(repeating: 0xCD, count: 32)))
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(service.lastRegisteredToken)
        XCTAssertEqual(transport.registrations.count, 0)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
