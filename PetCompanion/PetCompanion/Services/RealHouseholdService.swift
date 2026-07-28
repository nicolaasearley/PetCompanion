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
        _ = try await authenticatedUser()
        // `user_profiles` RLS is self-only, so a membership join could never
        // resolve a second caregiver's name and every non-self member
        // rendered as the literal string "Caregiver". `household_member_
        // profiles` (migration 20260728000200) exposes exactly the fields
        // DM §7.1 permits co-members to see — display name and role — scoped
        // by `is_active_household_member` inside the view.
        struct MemberRow: Decodable {
            let user_id: UUID
            let role: String
            let status: String
            let display_name: String
            let user_status: String
        }
        let response = try await client
            .from("household_member_profiles")
            .select("user_id, role, status, display_name, user_status")
            .eq("household_id", value: householdId)
            .order("joined_at", ascending: true)
            .execute()
        let rows = try decoder.decode([MemberRow].self, from: response.data)

        return rows.map { row in
            HouseholdMember(
                userId: row.user_id,
                // A deleted account keeps its attribution but loses its name
                // (DM §7.1): show the neutral former-member label rather than
                // a stale personal name.
                displayName: row.user_status == "deleted" ? "Former member" : row.display_name,
                // `household_role` reserves two roles with no MVP behavior;
                // they cannot be granted, and treating an unexpected value as
                // the least-privileged known role keeps the list rendering.
                role: HouseholdMember.Role(rawValue: row.role) ?? .caregiver,
                status: HouseholdMember.Status(rawValue: row.status) ?? .active
            )
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

    // MARK: - Invitations (E02)

    /// Invitation commands deliberately bypass the offline queue. A queued
    /// `create_invitation` would surface its one-time token minutes later
    /// (or never), and a queued acceptance would leave the invitee staring
    /// at a household they may not have joined. These need a live answer, so
    /// a failure is reported as a failure.
    func invitations(householdId: UUID) async throws -> [HouseholdInvitation] {
        _ = try await authenticatedUser()
        // Explicit column list: `token_hash` is not granted to clients
        // (migration 20260728000200), so `select()` would be denied outright.
        let response = try await client
            .from("household_invitations")
            .select("id, household_id, created_by, role_granted, expires_at, status, accepted_by, resolved_at, created_at")
            .eq("household_id", value: householdId)
            .order("created_at", ascending: false)
            .execute()
        return try decoder.decode([HouseholdInvitation].self, from: response.data)
    }

    func createInvitation(householdId: UUID, expiresInHours: Int) async throws -> CreatedInvitation {
        struct Payload: Encodable {
            let household_id: UUID
            let invitation_id: UUID
            let expires_in_hours: Int
        }
        struct Result: Decodable {
            struct Invitation: Decodable {
                let id: UUID
                let household_id: UUID
                let household_name: String
                let created_by: UUID
                let status: HouseholdInvitation.Status
                let expires_at: Date
            }
            let invitation: Invitation
            let token: String?
        }

        do {
            let result: Result = try await WritePath.send(
                client: client,
                command: "create_invitation",
                payload: Payload(
                    household_id: householdId,
                    invitation_id: UUID(),
                    expires_in_hours: expiresInHours
                )
            )
            return CreatedInvitation(
                invitation: HouseholdInvitation(
                    id: result.invitation.id,
                    householdId: result.invitation.household_id,
                    createdBy: result.invitation.created_by,
                    expiresAt: result.invitation.expires_at,
                    status: result.invitation.status
                ),
                householdName: result.invitation.household_name,
                token: result.token
            )
        } catch let error as WritePathError {
            throw Self.invitationError(from: error)
        }
    }

    func revokeInvitation(id: UUID) async throws {
        struct Payload: Encodable { let invitation_id: UUID }
        struct EmptyResult: Decodable {}
        do {
            let _: EmptyResult = try await WritePath.send(
                client: client,
                command: "revoke_invitation",
                payload: Payload(invitation_id: id)
            )
        } catch let error as WritePathError {
            throw Self.invitationError(from: error)
        }
    }

    func previewInvitation(token: String) async throws -> InvitationPreview {
        _ = try await authenticatedUser()
        struct PreviewRow: Decodable {
            let status: InvitationPreview.State
            let household_name: String?
            let inviter_display_name: String?
            let expires_at: Date?
        }
        let response = try await client
            .rpc("invitation_preview", params: ["token_input": token])
            .execute()
        let row = try decoder.decode(PreviewRow.self, from: response.data)
        return InvitationPreview(
            state: row.status,
            householdName: row.household_name,
            inviterDisplayName: row.inviter_display_name,
            expiresAt: row.expires_at
        )
    }

    func acceptInvitation(token: String) async throws -> Household {
        struct Payload: Encodable { let token: String }
        struct Result: Decodable {
            struct HouseholdRef: Decodable { let id: UUID }
            let household: HouseholdRef
        }
        do {
            let result: Result = try await WritePath.send(
                client: client,
                command: "accept_invitation",
                payload: Payload(token: token)
            )
            // Re-read the authoritative row now that membership exists, so
            // the caller gets the same shape as `currentHousehold()`.
            let response = try await client
                .from("households")
                .select()
                .eq("id", value: result.household.id)
                .single()
                .execute()
            return try decoder.decode(Household.self, from: response.data)
        } catch let error as WritePathError {
            throw Self.invitationError(from: error)
        }
    }

    func declineInvitation(token: String) async throws {
        struct Payload: Encodable { let token: String }
        struct EmptyResult: Decodable {}
        do {
            let _: EmptyResult = try await WritePath.send(
                client: client,
                command: "decline_invitation",
                payload: Payload(token: token)
            )
        } catch let error as WritePathError {
            throw Self.invitationError(from: error)
        }
    }

    /// The write path answers with a distinct code per invitation outcome so
    /// the UI can explain exactly what happened (US-012).
    private static func invitationError(from error: WritePathError) -> Error {
        switch error {
        case .server(let code, let message):
            InvitationError(code: code, message: message)
        case .malformedResponse:
            InvitationError.server(error.localizedDescription)
        }
    }
}
