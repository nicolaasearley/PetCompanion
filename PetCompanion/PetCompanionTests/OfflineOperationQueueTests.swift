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

    /// A refused change is never retried, so without a way to discard it the
    /// "needs review" count could only ever climb.
    func testDiscardingARefusedChangeClearsItForGoodAndLeavesRealWorkAlone() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountId = UUID()
        let transport = Transport([.rejected, .unavailable])
        let queue = OfflineOperationQueue(
            transport: transport,
            store: OfflineOperationStore(baseDirectory: directory)
        )
        queue.activate(accountId: accountId)

        do {
            _ = try await queue.submit(command: "skip_item", payload: Payload(value: "A"))
            XCTFail("Expected rejection")
        } catch OfflineMutationError.rejected {
            // Expected.
        }
        do {
            _ = try await queue.submit(command: "complete_occurrence", payload: Payload(value: "B"))
            XCTFail("Expected the second write to remain queued")
        } catch OfflineMutationError.queued {
            // Expected.
        }

        let refused = try XCTUnwrap(queue.rejectedOperations.first)
        XCTAssertEqual(queue.rejectedOperations.count, 1)
        XCTAssertEqual(refused.command, "skip_item")

        queue.discardRejected(operationId: refused.id)

        XCTAssertTrue(queue.rejectedOperations.isEmpty)
        XCTAssertEqual(queue.status.rejectedCount, 0)
        XCTAssertEqual(
            queue.operations.map(\.command),
            ["complete_occurrence"],
            "Discarding one refused change must not touch work still waiting to sync"
        )
        XCTAssertEqual(queue.status.pendingCount, 1)

        // Gone from disk too: a discard the next launch undoes is not a
        // discard, and the copy promised it was permanent.
        queue.deactivate()
        queue.activate(accountId: accountId)
        XCTAssertTrue(queue.rejectedOperations.isEmpty)
        XCTAssertEqual(queue.operations.map(\.command), ["complete_occurrence"])
    }

    func testDiscardOnlyEverRemovesTheRefusedOperationItNames() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = Transport([.unavailable])
        let queue = OfflineOperationQueue(
            transport: transport,
            store: OfflineOperationStore(baseDirectory: directory)
        )
        queue.activate(accountId: UUID())
        do {
            _ = try await queue.submit(command: "complete_occurrence", payload: Payload(value: "A"))
            XCTFail("Expected the write to remain queued")
        } catch OfflineMutationError.queued {
            // Expected.
        }

        let queued = try XCTUnwrap(queue.operations.first)
        queue.discardRejected(operationId: queued.id)

        XCTAssertEqual(
            queue.operations.map(\.command),
            ["complete_occurrence"],
            "Queued work is still going to be sent; only a refusal is discardable"
        )
        queue.discardRejected(operationId: UUID())
        XCTAssertEqual(queue.operations.count, 1)
    }

    /// The review screen has to name the act, because ids and command names
    /// are not something a caregiver can recognise or decide about.
    func testEveryRefusedChangeCanBeDescribedWithoutItsPayload() {
        let commands = [
            "complete_occurrence", "undo_completion", "skip_item", "undo_skip",
            "snooze_occurrence", "reschedule_occurrence", "cancel_occurrence",
            "edit_occurrence", "create_task", "create_recurring_task",
            "edit_schedule_future", "archive_schedule", "accept_recommendation",
            "set_default_capacity", "set_routine_preferences", "create_household",
            "create_pet", "create_invitation", "revoke_invitation",
            "accept_invitation", "decline_invitation",
        ]

        let titles = commands.map { operation(command: $0).displayTitle }
        XCTAssertEqual(Set(titles).count, titles.count, "Two commands must not read as the same act")
        for title in titles {
            XCTAssertFalse(title.contains("_"), "A command name is not a description")
        }
        XCTAssertEqual(operation(command: "skip_item").displayTitle, "Skip a task")
        XCTAssertEqual(
            operation(command: "some_future_command").displayTitle,
            "A change to your household",
            "An unmapped command still has to be describable rather than blank"
        )
    }

    private func operation(command: String) -> OfflineOperation {
        OfflineOperation(
            id: UUID(),
            accountId: UUID(),
            command: command,
            payload: .object([:]),
            payloadFingerprint: command,
            clientIdempotencyKey: UUID().uuidString,
            recordedAt: SupabaseCoding.iso8601Now(),
            effectiveAt: nil,
            createdAt: .now,
            updatedAt: .now,
            state: .rejected,
            attemptCount: 1
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineOperationQueueTests-\(UUID().uuidString)")
    }
}
