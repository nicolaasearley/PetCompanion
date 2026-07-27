import Foundation
import Supabase

/// Date parsing shared by the `Real*Service` types.
///
/// PostgREST returns two different date shapes: `timestamptz` columns
/// (`created_at`, `joined_at`, …) as full ISO-8601 instants, and plain
/// `date` columns (`pets.birth_date`, `estimated_as_of_date`,
/// `homecoming_date`) as bare `YYYY-MM-DD` strings with no time or zone
/// component. supabase-swift's stock decoder
/// (`Sources/Helpers/Codable.swift` → `JSONDecoder.supabase()`) only
/// parses the timestamp shape — a bare `pets.birth_date` fails to decode
/// against it. This decoder tries both, timestamp shapes first.
enum SupabaseCoding {
    // `nonisolated`: read-only formatters/decoders with no actor-affine
    // state, referenced from default-parameter positions (nonisolated
    // contexts) — see `BackendConfig`'s equivalent note.
    private nonisolated static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// `task_occurrences.due_time` / `plan_items.due_time` are SQL `time`
    /// columns (no date, no zone) — PostgREST serializes them as a bare
    /// `HH:mm:ss` string. Parsed onto today's date purely so it round-trips
    /// through `Date`; every call site that reads it back
    /// (`HomeViewModel.meta`) only ever formats the time-of-day component
    /// (`.formatted(date: .omitted, time: .shortened)`), so the arbitrary
    /// date component is never shown.
    private nonisolated static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // `nonisolated(unsafe)`: `ISO8601DateFormatter` predates `Sendable` and
    // isn't annotated, but these instances are configured once here and
    // only ever used for read-only `.string(from:)`/`.date(from:)` calls
    // afterward — never mutated post-init, so sharing them across
    // isolation domains is safe in practice despite the missing annotation.
    private nonisolated(unsafe) static let fractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let wholeSecondsFormatter = ISO8601DateFormatter()

    /// Decoder for direct table reads (`households`, `pets`,
    /// `household_memberships`) — tries timestamp formats, then falls back
    /// to a bare calendar date.
    nonisolated static let restDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = fractionalSecondsFormatter.date(from: string) {
                return date
            }
            if let date = wholeSecondsFormatter.date(from: string) {
                return date
            }
            if let date = dateOnlyFormatter.date(from: string) {
                return date
            }
            if let date = timeOnlyFormatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format from PostgREST: \(string)"
            )
        }
        return decoder
    }()

    /// `YYYY-MM-DD` for `pets.birth_date` / `estimated_as_of_date` /
    /// `homecoming_date` write-path payload fields (DM §8.2 — calendar
    /// dates, not instants; formatted in the device's current calendar so
    /// the day the caregiver picked in the date picker is the day sent).
    nonisolated static func dateOnlyString(_ date: Date, timeZone: TimeZone = .gmt) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// `recorded_at` on the command envelope (write-path §6/§11).
    nonisolated static func iso8601Now() -> String {
        fractionalSecondsFormatter.string(from: Date())
    }

    nonisolated static func iso8601String(_ date: Date) -> String {
        fractionalSecondsFormatter.string(from: date)
    }
}

// MARK: - Write-path command envelope (supabase/functions/write-path)

/// Mirrors `packages/write-path/src/envelope.ts` `CommandEnvelope`.
struct CommandEnvelope<Payload: Encodable>: Encodable {
    let command: String
    let payload: Payload
    let client_idempotency_key: String
    let recorded_at: String
    let effective_at: String?
}

private struct CommandSuccessBody<Result: Decodable>: Decodable {
    let ok: Bool
    let command: String
    let idempotent_replay: Bool
    let result: Result
}

private struct CommandFailureBody: Decodable {
    let ok: Bool
    let command: String?
    let code: String?
    let message: String?
}

/// Surfaced through the existing inline-error UI via `LocalizedError`
/// (doc 14 ON-06/ON-07 error states) — no UI changes needed.
enum WritePathError: LocalizedError {
    case server(code: String, message: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .server(_, let message):
            message
        case .malformedResponse:
            "Something went wrong. Try again."
        }
    }
}

/// Thin typed client for the single write-path edge function (doc 06 §6:
/// "write-path edge functions called through a thin typed client").
@MainActor
enum WritePath {
    /// Sends one command through the envelope and decodes `result`.
    ///
    /// Idempotency: a fresh `client_idempotency_key` is generated per call.
    /// The full offline operation queue (persisted ops, FIFO replay,
    /// retry) is Slice A WP-5 scope (doc 17 WP-5) — onboarding here is a
    /// direct, one-shot call, but the key still makes a double-tap of
    /// "Continue" safe: the edge function's `command_log` replay path
    /// returns the original result instead of creating a duplicate row.
    static func send<Payload: Encodable, Result: Decodable>(
        client: SupabaseClient,
        command: String,
        payload: Payload,
        idempotencyKey: String = UUID().uuidString,
        decoder: JSONDecoder = SupabaseCoding.restDecoder
    ) async throws -> Result {
        let envelope = CommandEnvelope(
            command: command,
            payload: payload,
            client_idempotency_key: idempotencyKey,
            recorded_at: SupabaseCoding.iso8601Now(),
            effective_at: nil
        )

        do {
            let data: Data = try await client.functions.invoke(
                "write-path",
                options: FunctionInvokeOptions(body: envelope)
            ) { data, _ in data }
            let success = try decoder.decode(CommandSuccessBody<Result>.self, from: data)
            return success.result
        } catch FunctionsError.httpError(_, let data) {
            if let failure = try? decoder.decode(CommandFailureBody.self, from: data),
               let message = failure.message {
                throw WritePathError.server(code: failure.code ?? "COMMAND_FAILED", message: message)
            }
            throw WritePathError.malformedResponse
        }
    }

    /// Retains one idempotency key for the same pending command payload
    /// across transient failures and app relaunches. The key is cleared only
    /// after the server confirms success.
    static func sendStable<Payload: Encodable, Result: Decodable>(
        client: SupabaseClient,
        command: String,
        payload: Payload,
        decoder: JSONDecoder = SupabaseCoding.restDecoder,
        keyStore: PendingCommandKeyStore? = nil,
        queue: OfflineOperationQueue? = nil
    ) async throws -> Result {
        if let queue {
            do {
                let data = try await queue.submit(command: command, payload: payload)
                let success = try decoder.decode(CommandSuccessBody<Result>.self, from: data)
                return success.result
            } catch OfflineMutationError.rejected(_, let code, let message) {
                throw WritePathError.server(code: code, message: message)
            }
        }

        let resolvedKeyStore = keyStore ?? .shared
        let operation = try resolvedKeyStore.operationFingerprint(command: command, payload: payload)
        let key = resolvedKeyStore.idempotencyKey(for: operation)
        do {
            let result: Result = try await send(
                client: client,
                command: command,
                payload: payload,
                idempotencyKey: key,
                decoder: decoder
            )
            resolvedKeyStore.remove(operation: operation)
            return result
        } catch {
            throw error
        }
    }
}

/// Raw replay transport for the disk-backed operation queue. It sends the
/// original idempotency key and timestamps captured when the user acted.
@MainActor
final class SupabaseWritePathTransport: OfflineOperationTransport {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func execute(_ operation: OfflineOperation) async throws -> Data {
        let envelope = CommandEnvelope(
            command: operation.command,
            payload: operation.payload,
            client_idempotency_key: operation.clientIdempotencyKey,
            recorded_at: operation.recordedAt,
            effective_at: operation.effectiveAt
        )
        do {
            let data: Data = try await client.functions.invoke(
                "write-path",
                options: FunctionInvokeOptions(body: envelope)
            ) { data, _ in data }
            struct Acknowledgement: Decodable { let ok: Bool }
            guard let acknowledgement = try? JSONDecoder().decode(Acknowledgement.self, from: data),
                  acknowledgement.ok
            else {
                throw OfflineTransportError.rejected(
                    code: "MALFORMED_RESPONSE",
                    message: "The service returned an unreadable response."
                )
            }
            return data
        } catch FunctionsError.httpError(let status, let data) {
            let failure = try? SupabaseCoding.restDecoder.decode(CommandFailureBody.self, from: data)
            let code = failure?.code ?? "HTTP_\(status)"
            let message = failure?.message ?? "The service couldn't save this change."
            if status == 408 || status == 429 || status >= 500 {
                throw OfflineTransportError.unavailable(code: code, message: message)
            }
            throw OfflineTransportError.rejected(code: code, message: message)
        } catch let error as OfflineTransportError {
            throw error
        } catch {
            throw OfflineTransportError.unavailable(
                code: "NETWORK_UNAVAILABLE",
                message: error.localizedDescription
            )
        }
    }
}

/// Durable bookkeeping for retry-safe command identities. This is the
/// foundation for the full FIFO offline operation queue; it already closes
/// the correctness hole where a network retry generated a new key.
@MainActor
final class PendingCommandKeyStore {
    static let shared = PendingCommandKeyStore()

    private let defaults: UserDefaults
    private let prefix = "petcompanion.pending-command."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func operationFingerprint<Payload: Encodable>(command: String, payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(payload)
        let raw = Data("\(command)|".utf8) + payloadData
        return raw.base64EncodedString()
    }

    func idempotencyKey(for operation: String) -> String {
        let storageKey = prefix + operation
        if let existing = defaults.string(forKey: storageKey) {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: storageKey)
        return created
    }

    func remove(operation: String) {
        defaults.removeObject(forKey: prefix + operation)
    }
}
