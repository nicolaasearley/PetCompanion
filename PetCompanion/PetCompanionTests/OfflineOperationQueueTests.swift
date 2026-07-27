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
        /// Commands that never recover, keyed to the code the transport reports.
        /// `HTTP_500` models a server that answers but always fails;
        /// `NETWORK_UNAVAILABLE` models a command that never arrives.
        var permanentlyUnavailable: [String: String] = [:]
        private(set) var executed: [OfflineOperation] = []

        init(_ outcomes: [Outcome]) {
            self.outcomes = outcomes
        }

        func execute(_ operation: OfflineOperation) async throws -> Data {
            executed.append(operation)
            if let code = permanentlyUnavailable[operation.command] {
                throw OfflineTransportError.unavailable(
                    code: code,
                    message: "Permanently unavailable"
                )
            }
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

    func testPersistentServerFailureIsSetAsideSoTheQueueDrains() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The server answers but always fails. Without a retry bound this would
        // block the FIFO forever and the younger write would never be sent.
        let transport = Transport([])
        transport.permanentlyUnavailable = ["doomed": "HTTP_500"]
        let queue = OfflineOperationQueue(
            transport: transport,
            store: OfflineOperationStore(baseDirectory: directory)
        )
        queue.activate(accountId: UUID())

        do {
            _ = try await queue.submit(command: "doomed", payload: Payload(value: "A"))
            XCTFail("Expected the write to remain queued")
        } catch OfflineMutationError.queued {
            // Expected.
        }
        do {
            _ = try await queue.submit(command: "healthy", payload: Payload(value: "B"))
            XCTFail("The younger write must stay behind the failing head")
        } catch OfflineMutationError.queued {
            // Expected.
        }

        // Bounded so a regression fails the assertions below instead of hanging.
        for _ in 0..<(OfflineOperationQueue.maxRetryableAttempts * 2) where queue.status.pendingCount > 0 {
            await queue.replayPending()
        }

        let doomed = try XCTUnwrap(queue.operations.first { $0.command == "doomed" })
        XCTAssertEqual(doomed.state, .rejected)
        XCTAssertEqual(doomed.attemptCount, OfflineOperationQueue.maxRetryableAttempts)
        XCTAssertEqual(queue.status.rejectedCount, 1)
        XCTAssertEqual(queue.status.pendingCount, 0)
        XCTAssertTrue(
            transport.executed.contains { $0.command == "healthy" },
            "The younger write must drain once the head is set aside"
        )
        XCTAssertNil(queue.operations.first { $0.command == "healthy" })
    }

    func testSustainedConnectivityLossNeverDiscardsQueuedWork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A household can be offline across many launches. Those attempts never
        // reach the server, so they must not consume the retry budget.
        let transport = Transport([])
        transport.permanentlyUnavailable = ["offline-write": "NETWORK_UNAVAILABLE"]
        let queue = OfflineOperationQueue(
            transport: transport,
            store: OfflineOperationStore(baseDirectory: directory)
        )
        queue.activate(accountId: UUID())

        do {
            _ = try await queue.submit(command: "offline-write", payload: Payload(value: "A"))
            XCTFail("Expected the write to remain queued")
        } catch OfflineMutationError.queued {
            // Expected.
        }

        for _ in 0..<(OfflineOperationQueue.maxRetryableAttempts * 3) {
            await queue.replayPending()
        }

        let pending = try XCTUnwrap(queue.operations.first)
        XCTAssertEqual(pending.state, .failed, "Connectivity loss must stay retryable")
        XCTAssertEqual(queue.status.rejectedCount, 0)
        XCTAssertEqual(queue.status.pendingCount, 1)

        // The moment the server is reachable the original envelope is sent.
        transport.permanentlyUnavailable = [:]
        await queue.replayPending()
        XCTAssertTrue(queue.operations.isEmpty)
        let sent = try XCTUnwrap(transport.executed.last)
        XCTAssertEqual(sent.clientIdempotencyKey, pending.clientIdempotencyKey)
        XCTAssertEqual(sent.recordedAt, pending.recordedAt)
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
