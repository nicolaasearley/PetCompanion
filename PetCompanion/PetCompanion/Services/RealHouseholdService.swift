import Foundation
import Supabase

/// Supabase-backed implementation of `HouseholdService` — Slice A WP-2
/// (doc 17 WP-2). `create_household` and `create_pet` go through the
/// single write-path edge function with the command envelope
/// (`supabase/functions/write-path/index.ts`); reads are direct
/// RLS-protected PostgREST queries (doc 06 §7 "RLS policies").
@MainActor
final class RealHouseholdService: HouseholdService {
    private let client: SupabaseClient
    private let decoder = SupabaseCoding.restDecoder
    private let operationQueue: OfflineOperationQueue

    init(client: SupabaseClient, operationQueue: OfflineOperationQueue) {
        self.client = client
        self.operationQueue = operationQueue
    }

    // MARK: - Reads

    func currentHousehold() async throws -> Household? {
        _ = try await authenticatedUser()
        // RLS ("households active member read") already scopes this to the
        // caller's active memberships; Slice A is single-household, so the
        // oldest membership is "the" household.
        let response = try await client
            .from("households")
            .select()
            .order("created_at", ascending: true)
            .limit(1)
            .execute()
        let rows = try decoder.decode([Household].self, from: response.data)
        return rows.first
    }

    func members(householdId: UUID) async throws -> [HouseholdMember] {
        let currentUser = try await authenticatedUser()
        struct MembershipRow: Decodable {
            let user_id: UUID
            let role: HouseholdMember.Role
            let status: HouseholdMember.Status
        }
        let response = try await client
            .from("household_memberships")
            .select("user_id, role, status")
            .eq("household_id", value: householdId)
            .execute()
        let rows = try decoder.decode([MembershipRow].self, from: response.data)

        // `user_profiles` RLS is self-only ("user profiles self read", id =
        // auth.uid()) — there is no shared-name view yet (that lands with
        // invitations in Slice B, doc 06 §11). Only the caller's own
        // display name is resolvable here; Slice A households have exactly
        // one active member in practice (create_household only inserts the
        // owner), so this gap doesn't bite until Slice B.
        var selfDisplayName: String?
        struct ProfileRow: Decodable { let display_name: String }
        if let response = try? await client
            .from("user_profiles")
            .select("display_name")
            .eq("id", value: currentUser.id)
            .single()
            .execute(),
           let profile = try? decoder.decode(ProfileRow.self, from: response.data) {
            selfDisplayName = profile.display_name
        }

        return rows.map { row in
            let name = row.user_id == currentUser.id ? (selfDisplayName ?? "Caregiver") : "Caregiver"
            return HouseholdMember(userId: row.user_id, displayName: name, role: row.role, status: row.status)
        }
    }

    func pets(householdId: UUID) async throws -> [Pet] {
        let response = try await client
            .from("pets")
            .select()
            .eq("household_id", value: householdId)
            .eq("status", value: Pet.Status.active.rawValue)
            .order("created_at", ascending: true)
            .execute()
        return try decoder.decode([Pet].self, from: response.data)
    }

    // MARK: - Writes (write-path envelope)

    /// The SDK's synchronous `currentUser` snapshot can briefly lag the
    /// session write performed by `signIn`. Async service boundaries ask
    /// for a validated session instead, which also refreshes expired tokens
    /// before an RLS-protected request.
    private func authenticatedUser() async throws -> User {
        do {
            return try await client.auth.session.user
        } catch {
            throw HouseholdServiceError.notSignedIn
        }
    }

    func createHousehold(name: String, timeZone: String) async throws -> Household {
        struct Payload: Encodable {
            let name: String
            let time_zone: String
        }
        struct CreateHouseholdResult: Decodable {
            struct HouseholdRef: Decodable { let id: UUID }
            let household: HouseholdRef
        }

        let result: CreateHouseholdResult = try await WritePath.sendStable(
            client: client,
            command: "create_household",
            payload: Payload(name: name, time_zone: timeZone),
            queue: operationQueue
        )

        // Re-fetch the authoritative row (status, default_capacity_mode,
        // created_at, created_by) rather than hand-constructing it from the
        // RPC's intentionally-minimal echo.
        let response = try await client
            .from("households")
            .select()
            .eq("id", value: result.household.id)
            .single()
            .execute()
        return try decoder.decode(Household.self, from: response.data)
    }

    func createPet(
        name: String,
        birthInfo: BirthInfo,
        homecomingDate: Date?
    ) async throws -> Pet {
        guard let household = try await currentHousehold() else {
            throw HouseholdServiceError.noHousehold
        }

        // Mirrors the mock's client-side pre-check (US-023); the write
        // path re-validates server-side regardless (Scenario F).
        if case .exact(let birthDate) = birthInfo {
            let clock = household.clock
            if !clock.ordered(birthDate, beforeOrSameAs: Date()) {
                throw HouseholdServiceError.invalidPet("Birth date can't be in the future.")
            }
            if let homecomingDate, !clock.ordered(birthDate, beforeOrSameAs: homecomingDate) {
                throw HouseholdServiceError.invalidPet("Homecoming can't be before the birth date.")
            }
        }

        struct Payload: Encodable {
            let household_id: UUID
            let name: String
            let birth_date_kind: String
            let birth_date: String?
            let estimated_age_weeks: Int?
            let estimated_as_of_date: String?
            let homecoming_date: String?
        }
        struct CreatePetResult: Decodable {
            struct PetRef: Decodable { let id: UUID }
            let pet: PetRef
        }

        let payload: Payload
        let householdTimeZone = TimeZone(identifier: household.timeZone) ?? .gmt
        switch birthInfo {
        case .exact(let birthDate):
            payload = Payload(
                household_id: household.id,
                name: name,
                birth_date_kind: "exact",
                birth_date: SupabaseCoding.dateOnlyString(birthDate, timeZone: householdTimeZone),
                estimated_age_weeks: nil,
                estimated_as_of_date: nil,
                homecoming_date: homecomingDate.map {
                    SupabaseCoding.dateOnlyString($0, timeZone: householdTimeZone)
                }
            )
        case .estimated(let ageWeeks, let asOfDate):
            payload = Payload(
                household_id: household.id,
                name: name,
                birth_date_kind: "estimated",
                birth_date: nil,
                estimated_age_weeks: ageWeeks,
                estimated_as_of_date: SupabaseCoding.dateOnlyString(asOfDate, timeZone: householdTimeZone),
                homecoming_date: homecomingDate.map {
                    SupabaseCoding.dateOnlyString($0, timeZone: householdTimeZone)
                }
            )
        case .unknown:
            payload = Payload(
                household_id: household.id,
                name: name,
                birth_date_kind: "unknown",
                birth_date: nil,
                estimated_age_weeks: nil,
                estimated_as_of_date: nil,
                homecoming_date: homecomingDate.map {
                    SupabaseCoding.dateOnlyString($0, timeZone: householdTimeZone)
                }
            )
        }

        do {
            let result: CreatePetResult = try await WritePath.sendStable(
                client: client,
                command: "create_pet",
                payload: payload,
                queue: operationQueue
            )
            let response = try await client
                .from("pets")
                .select()
                .eq("id", value: result.pet.id)
                .single()
                .execute()
            return try decoder.decode(Pet.self, from: response.data)
        } catch WritePathError.server(let code, let message) {
            // Surface validation failures the way the mock's inline error
            // does (US-023) instead of a generic server-error string.
            if code == "VALIDATION_FAILED" || code == "BAD_REQUEST" {
                throw HouseholdServiceError.invalidPet(message)
            }
            throw WritePathError.server(code: code, message: message)
        }
    }

    func saveRoutinePreferences(_ preferences: HouseholdPreference) async throws {
        // NB: `set_routine_preferences` started Slice A as a server-side
        // stub (write-path `stubbedCommands`, 501 NOT_IMPLEMENTED) per doc
        // 17 WP-1, but `write_path_set_routine_preferences`
        // (`supabase/migrations/202607260002_slice_a_write_commands.sql`)
        // landed while this file was being written, so it's wired for
        // real. `routine_windows` has no fixed server-side shape beyond
        // "a JSON object" (`assertSetRoutinePreferencesPayload`), so
        // `HouseholdPreference`'s own snake_case `Encodable` is sent as-is
        // rather than inventing a parallel shape.
        guard let household = try await currentHousehold() else {
            throw HouseholdServiceError.noHousehold
        }
        struct Payload: Encodable {
            let household_id: UUID
            let routine_windows: HouseholdPreference
        }
        struct EmptyResult: Decodable {}
        do {
            let _: EmptyResult = try await WritePath.sendStable(
                client: client,
                command: "set_routine_preferences",
                payload: Payload(household_id: household.id, routine_windows: preferences),
                queue: operationQueue
            )
        } catch OfflineMutationError.queued {
            // Preferences have no server-generated identity and are safe to
            // consider locally saved while their exact command waits.
            return
        }
    }
}
