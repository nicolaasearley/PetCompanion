import Foundation
import XCTest
@testable import PetCompanion

@MainActor
final class OfflineOperationQueueTests: XCTestCase {
    private struct Payload: Encodable {
        let value: String
    }

    private final class Transport: OfflineOperationTransport {
        enum Outcome {
            case success
            case unavailable
            case rejected
        }

        var outcomes: [Outcome]
        private(set) var executed: [OfflineOperation] = []

        init(_ outcomes: [Outcome]) {
            self.outcomes = outcomes
        }

        func execute(_ operation: OfflineOperation) async throws -> Data {
            executed.append(operation)
            let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
            switch outcome {
            case .success:
                return Data(#"{"ok":true,"result":{}}"#.utf8)
            case .unavailable:
                throw OfflineTransportError.unavailable(
                    code: "OFFLINE",
                    message: "No connection"
                )
            case .rejected:
                throw OfflineTransportError.rejected(
                    code: "VALIDATION_FAILED",
                    message: "Invalid change"
                )
            }
        }
    }

    func testDiskPersistencePreservesEnvelopeIdentityAndTimestamp() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountId = UUID()
        let failingTransport = Transport([.unavailable, .unavailable])
        let firstQueue = OfflineOperationQueue(
            transport: failingTransport,
            store: OfflineOperationStore(baseDirectory: directory)
        )
        firstQueue.activate(accountId: accountId)

        do {
            _ = try await firstQueue.submit(
                command: "create_task",
                payload: Payload(value: "first"),
                effectiveAt: "2026-07-27T08:15:00.000Z"
            )
            XCTFail("Expected the write to remain queued")
        } catch OfflineMutationError.queued {
            // Expected.
        }
        let original = try XCTUnwrap(firstQueue.operations.first)
        XCTAssertEqual(original.state, .failed)
        do {
            _ = try await firstQueue.submit(
                command: "create_task",
                payload: Payload(value: "second")
            )
            XCTFail("The younger write must stay behind the failed head")
        } catch OfflineMutationError.queued {
            // Expected.
        }
        XCTAssertEqual(firstQueue.operations.map(\.payloadFingerprint).count, 2)
        firstQueue.deactivate()

        let recoveryTransport = Transport([.success, .success])
        let recoveredQueue = OfflineOperationQueue(
            transport: recoveryTransport,
            store: OfflineOperationStore(baseDirectory: directory)
        )
        recoveredQueue.activate(accountId: accountId)
        let recovered = try XCTUnwrap(recoveredQueue.operations.first)
        XCTAssertEqual(recoveredQueue.operations.map(\.command), ["create_task", "create_task"])
        let recoveredFingerprints = recoveredQueue.operations.map(\.payloadFingerprint)
        XCTAssertEqual(recovered.clientIdempotencyKey, original.clientIdempotencyKey)
        XCTAssertEqual(recovered.recordedAt, original.recordedAt)
        XCTAssertEqual(recovered.effectiveAt, "2026-07-27T08:15:00.000Z")
        XCTAssertEqual(recovered.payload, original.payload)

        await recoveredQueue.replayPending()
        let replayed = try XCTUnwrap(recoveryTransport.executed.first)
        XCTAssertEqual(replayed.clientIdempotencyKey, original.clientIdempotencyKey)
        XCTAssertEqual(replayed.recordedAt, original.recordedAt)
        XCTAssertEqual(
            recoveryTransport.executed.map(\.payloadFingerprint),
            recoveredFingerprints
        )
        XCTAssertTrue(recoveredQueue.operations.isEmpty)
        XCTAssertTrue(recoveredQueue.status.isCurrent)
    }

    func testStrictFIFOBlocksYoungerOperationUntilHeadRecovers() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = Transport([.unavailable, .success, .success])
        let queue = OfflineOperationQueue(
            transport: transport,
            store: OfflineOperationStore(baseDirectory: directory)
        )
        queue.activate(accountId: UUID())

        do {
            _ = try await queue.submit(command: "first", payload: Payload(value: "A"))
        } catch OfflineMutationError.queued {
            // Expected.
        }
        _ = try await queue.submit(command: "second", payload: Payload(value: "B"))

        XCTAssertEqual(transport.executed.map(\.command), ["first", "first", "second"])
        XCTAssertTrue(queue.operations.isEmpty)
    }

    func testRejectionIsRetainedAndDoesNotPoisonFollowingOperation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = Transport([.rejected, .success])
        let queue = OfflineOperationQueue(
            transport: transport,
            store: OfflineOperationStore(baseDirectory: directory)
        )
        queue.activate(accountId: UUID())

        do {
            _ = try await queue.submit(command: "invalid", payload: Payload(value: "A"))
            XCTFail("Expected rejection")
        } catch OfflineMutationError.rejected(_, let code, _) {
            XCTAssertEqual(code, "VALIDATION_FAILED")
        }
        _ = try await queue.submit(command: "valid", payload: Payload(value: "B"))

        XCTAssertEqual(transport.executed.map(\.command), ["invalid", "valid"])
        XCTAssertEqual(queue.operations.count, 1)
        XCTAssertEqual(queue.operations.first?.state, .rejected)
        XCTAssertEqual(queue.status.rejectedCount, 1)
        XCTAssertEqual(queue.status.pendingCount, 0)
    }

    func testAccountActivationNeverLoadsOrReplaysAnotherAccountsQueue() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstAccount = UUID()
        let secondAccount = UUID()
        let transport = Transport([.unavailable])
        let queue = OfflineOperationQueue(
            transport: transport,
            store: OfflineOperationStore(baseDirectory: directory)
        )
        queue.activate(accountId: firstAccount)
        do {
            _ = try await queue.submit(command: "first-account", payload: Payload(value: "A"))
        } catch OfflineMutationError.queued {
            // Expected.
        }

        queue.deactivate()
        queue.activate(accountId: secondAccount)
        XCTAssertTrue(queue.operations.isEmpty)
        await queue.replayPending()
        XCTAssertEqual(transport.executed.count, 1)

        queue.deactivate()
        queue.activate(accountId: firstAccount)
        XCTAssertEqual(queue.operations.map(\.command), ["first-account"])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineOperationQueueTests-\(UUID().uuidString)")
    }
}
