import Foundation
import Observation

/// Codable JSON payload used to persist type-erased write-path commands.
enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}

struct OfflineOperation: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case queued
        case replaying
        case failed
        case rejected
    }

    let id: UUID
    let accountId: UUID
    let command: String
    let payload: JSONValue
    let payloadFingerprint: String
    let clientIdempotencyKey: String
    /// ISO-8601 instant captured once when the intent is first queued.
    let recordedAt: String
    let effectiveAt: String?
    let createdAt: Date
    var updatedAt: Date
    var state: State
    /// Consecutive attempts that reached the server. Reset by a connectivity
    /// failure, which means the command never got there.
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastErrorCode: String?
    var lastErrorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, command, payload, state
        case accountId = "account_id"
        case payloadFingerprint = "payload_fingerprint"
        case clientIdempotencyKey = "client_idempotency_key"
        case recordedAt = "recorded_at"
        case effectiveAt = "effective_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case attemptCount = "attempt_count"
        case lastAttemptAt = "last_attempt_at"
        case lastErrorCode = "last_error_code"
        case lastErrorMessage = "last_error_message"
    }
}

/// Detailed enough for Home/Planner to report truthfully without inferring
/// queue health from a single boolean.
struct MutationSyncStatus: Equatable, Sendable {
    var queuedCount = 0
    var failedCount = 0
    var rejectedCount = 0
    var isReplaying = false
    var lastMessage: String?

    var pendingCount: Int { queuedCount + failedCount }
    var isCurrent: Bool {
        pendingCount == 0 && rejectedCount == 0 && !isReplaying
    }
}

enum OfflineTransportError: Error, Equatable {
    /// Connectivity, throttling, or server availability: safe to retry with
    /// the exact same envelope.
    case unavailable(code: String, message: String)
    /// Authorization/validation/conflict: retained for explicit user review
    /// and never retried automatically.
    case rejected(code: String, message: String)
}

enum OfflineMutationError: LocalizedError, Equatable {
    case noActiveAccount
    case queued(operationId: UUID)
    case rejected(operationId: UUID, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            "Sign in before saving changes."
        case .queued:
            "Saved on this device. PetCompanion will try again when the service is available."
        case .rejected(_, _, let message):
            message
        }
    }
}

@MainActor
protocol OfflineOperationTransport: AnyObject {
    func execute(_ operation: OfflineOperation) async throws -> Data
}

/// Account-partitioned JSON persistence. Operations remain on disk at sign
/// out, but are never loaded or replayed for a different account.
@MainActor
final class OfflineOperationStore {
    private let directory: URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseDirectory: URL? = nil) {
        directory = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("PetCompanion/OperationQueue", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(accountId: UUID) -> [OfflineOperation] {
        guard let url = fileURL(accountId: accountId),
              let data = try? Data(contentsOf: url),
              let operations = try? decoder.decode([OfflineOperation].self, from: data)
        else { return [] }
        // The encoded array order is the FIFO order. Do not re-sort by a
        // timestamp whose persisted precision can collapse rapid actions.
        return operations.filter { $0.accountId == accountId }
    }

    func save(_ operations: [OfflineOperation], accountId: UUID) {
        guard let url = fileURL(accountId: accountId) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(operations).write(
                to: url,
                options: [.atomic, .completeFileProtection]
            )
        } catch {
            // The queue reports transport state to the UI. A future
            // observability pass can surface local-disk failures separately.
        }
    }

    private func fileURL(accountId: UUID) -> URL? {
        directory?.appendingPathComponent("\(accountId.uuidString).json")
    }
}

/// Disk-backed, strict FIFO mutation queue. Only one replay loop can execute
/// at once. A retryable failure blocks younger operations; a rejected command
/// is retained for review but does not poison later independent writes.
@MainActor
@Observable
final class OfflineOperationQueue {
    /// A retryable failure blocks the queue head by design, so an operation the
    /// server keeps failing would stall every later write indefinitely. After
    /// this many consecutive server failures the operation is set aside for
    /// review so the rest of the queue can drain.
    static let maxRetryableAttempts = 8

    /// Codes meaning the command never reached the server. These must not
    /// consume the retry budget: a household that is simply offline across
    /// several launches would otherwise have legitimate queued work set aside
    /// even though it would succeed the moment connectivity returned.
    private static let connectivityFailureCodes: Set<String> = [
        "NETWORK_UNAVAILABLE",
        "TRANSPORT_ERROR",
    ]

    private let transport: any OfflineOperationTransport
    private let store: OfflineOperationStore
    private(set) var activeAccountId: UUID?
    private(set) var operations: [OfflineOperation] = []
    private(set) var status = MutationSyncStatus()
    private var replayInProgress = false
    private var activationGeneration = UUID()

    init(
        transport: any OfflineOperationTransport,
        store: OfflineOperationStore? = nil
    ) {
        self.transport = transport
        self.store = store ?? OfflineOperationStore()
    }

    func activate(accountId: UUID) {
        guard activeAccountId != accountId else { return }
        persist()
        activationGeneration = UUID()
        activeAccountId = accountId
        operations = store.load(accountId: accountId).map { operation in
            var recovered = operation
            if recovered.state == .replaying {
                recovered.state = .queued
                recovered.lastErrorCode = "INTERRUPTED"
                recovered.lastErrorMessage = "Replay was interrupted before confirmation."
            }
            return recovered
        }
        persist()
        refreshStatus()
    }

    func deactivate() {
        persist()
        activationGeneration = UUID()
        activeAccountId = nil
        operations = []
        replayInProgress = false
        status = MutationSyncStatus()
    }

    /// Write-ahead enqueue followed by serialized replay. If the transport is
    /// unavailable, the exact operation remains durable and `.queued` is
    /// thrown so a service can apply a truthful optimistic presentation.
    func submit<Payload: Encodable>(
        command: String,
        payload: Payload,
        effectiveAt: String? = nil
    ) async throws -> Data {
        guard let accountId = activeAccountId else {
            throw OfflineMutationError.noActiveAccount
        }
        let jsonPayload = try JSONValue.encode(payload)
        let fingerprint = try Self.fingerprint(command: command, payload: jsonPayload)

        let operation: OfflineOperation
        if let existing = operations.first(where: {
            $0.payloadFingerprint == fingerprint
                && $0.command == command
                && $0.state != .rejected
        }) {
            operation = existing
        } else {
            let now = Date()
            operation = OfflineOperation(
                id: UUID(),
                accountId: accountId,
                command: command,
                payload: jsonPayload,
                payloadFingerprint: fingerprint,
                clientIdempotencyKey: UUID().uuidString,
                recordedAt: SupabaseCoding.iso8601Now(),
                effectiveAt: effectiveAt,
                createdAt: now,
                updatedAt: now,
                state: .queued,
                attemptCount: 0
            )
            operations.append(operation)
            persist()
            refreshStatus()
        }

        let responses = await replaySerially()
        if let data = responses[operation.id] {
            return data
        }
        if let retained = operations.first(where: { $0.id == operation.id }),
           retained.state == .rejected {
            throw OfflineMutationError.rejected(
                operationId: retained.id,
                code: retained.lastErrorCode ?? "REJECTED",
                message: retained.lastErrorMessage ?? "The service rejected this change."
            )
        }
        throw OfflineMutationError.queued(operationId: operation.id)
    }

    func replayPending() async {
        _ = await replaySerially()
    }

    func discardRejected(operationId: UUID) {
        operations.removeAll { $0.id == operationId && $0.state == .rejected }
        persist()
        refreshStatus()
    }

    private func replaySerially() async -> [UUID: Data] {
        guard let replayAccountId = activeAccountId, !replayInProgress else { return [:] }
        let replayGeneration = activationGeneration
        replayInProgress = true
        refreshStatus()
        var responses: [UUID: Data] = [:]
        defer {
            if activationGeneration == replayGeneration {
                replayInProgress = false
                refreshStatus()
            }
        }

        while activeAccountId == replayAccountId,
              activationGeneration == replayGeneration,
              let index = operations.firstIndex(where: {
            $0.state == .queued || $0.state == .failed
              }) {
            operations[index].state = .replaying
            operations[index].attemptCount += 1
            operations[index].lastAttemptAt = Date()
            operations[index].updatedAt = Date()
            operations[index].lastErrorCode = nil
            operations[index].lastErrorMessage = nil
            let operation = operations[index]
            persist()
            refreshStatus()

            do {
                let data = try await transport.execute(operation)
                guard activeAccountId == replayAccountId,
                      activationGeneration == replayGeneration
                else { return responses }
                responses[operation.id] = data
                operations.removeAll { $0.id == operation.id }
                persist()
            } catch OfflineTransportError.rejected(let code, let message) {
                guard activeAccountId == replayAccountId,
                      activationGeneration == replayGeneration
                else { return responses }
                guard let retainedIndex = operations.firstIndex(where: { $0.id == operation.id }) else {
                    continue
                }
                operations[retainedIndex].state = .rejected
                operations[retainedIndex].lastErrorCode = code
                operations[retainedIndex].lastErrorMessage = message
                operations[retainedIndex].updatedAt = Date()
                persist()
                // Rejection is terminal for this command; continue the FIFO
                // with the next independent intent.
            } catch OfflineTransportError.unavailable(let code, let message) {
                guard activeAccountId == replayAccountId,
                      activationGeneration == replayGeneration
                else { return responses }
                markFailed(operationId: operation.id, code: code, message: message)
                // An exhausted operation has been set aside; the FIFO may
                // continue past it. Otherwise it stays at the head.
                if wasSetAside(operationId: operation.id) { continue }
                break
            } catch {
                guard activeAccountId == replayAccountId,
                      activationGeneration == replayGeneration
                else { return responses }
                markFailed(
                    operationId: operation.id,
                    code: "TRANSPORT_ERROR",
                    message: error.localizedDescription
                )
                if wasSetAside(operationId: operation.id) { continue }
                break
            }
            refreshStatus()
        }
        return responses
    }

    private func markFailed(operationId: UUID, code: String, message: String) {
        guard let index = operations.firstIndex(where: { $0.id == operationId }) else { return }
        if Self.connectivityFailureCodes.contains(code) {
            // Never reached the server, so this attempt does not count.
            operations[index].attemptCount = 0
        }
        let exhausted = operations[index].attemptCount >= Self.maxRetryableAttempts
        operations[index].state = exhausted ? .rejected : .failed
        operations[index].lastErrorCode = code
        operations[index].lastErrorMessage = message
        operations[index].updatedAt = Date()
        persist()
        refreshStatus()
    }

    private func wasSetAside(operationId: UUID) -> Bool {
        guard let index = operations.firstIndex(where: { $0.id == operationId }) else { return true }
        return operations[index].state == .rejected
    }

    private func persist() {
        guard let activeAccountId else { return }
        store.save(operations, accountId: activeAccountId)
    }

    private func refreshStatus() {
        let failed = operations.filter { $0.state == .failed }
        let rejected = operations.filter { $0.state == .rejected }
        status = MutationSyncStatus(
            queuedCount: operations.filter { $0.state == .queued || $0.state == .replaying }.count,
            failedCount: failed.count,
            rejectedCount: rejected.count,
            isReplaying: replayInProgress,
            lastMessage: failed.last?.lastErrorMessage ?? rejected.last?.lastErrorMessage
        )
    }

    private static func fingerprint(command: String, payload: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return Data("\(command)|".utf8).base64EncodedString()
            + data.base64EncodedString()
    }
}
