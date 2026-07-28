import Foundation

/// Household and pet setup boundary — WP-2 commands (`create_household`,
/// `create_pet`, `set_routine_preferences`).
@MainActor
protocol HouseholdService: AnyObject {
    /// The signed-in user's active household, if any.
    func currentHousehold() async throws -> Household?
    /// Idempotent: retrying creation never produces a duplicate membership
    /// (US-010).
    func createHousehold(name: String, timeZone: String) async throws -> Household
    func members(householdId: UUID) async throws -> [HouseholdMember]
    func pets(householdId: UUID) async throws -> [Pet]
    func createPet(
        name: String,
        birthInfo: BirthInfo,
        homecomingDate: Date?
    ) async throws -> Pet
    func saveRoutinePreferences(_ preferences: HouseholdPreference) async throws

    // MARK: - Invitations (E02)

    /// Every invitation the household has ever issued, newest first. Terminal
    /// ones stay visible so "what happened to the link I sent?" has an answer.
    func invitations(householdId: UUID) async throws -> [HouseholdInvitation]
    /// Owner-only (US-011). The token is generated server-side and returned
    /// exactly once, in this result.
    func createInvitation(householdId: UUID, expiresInHours: Int) async throws -> CreatedInvitation
    /// Owner-only. Revoking a pending invitation makes its link dead.
    func revokeInvitation(id: UUID) async throws
    /// Pre-acceptance disclosure: household name, inviter, expiry (ON-05).
    func previewInvitation(token: String) async throws -> InvitationPreview
    /// Creates exactly one active membership, atomically (US-012).
    func acceptInvitation(token: String) async throws -> Household
    func declineInvitation(token: String) async throws
}

extension HouseholdService {
    /// One week is the default invitation lifetime; the server bounds the
    /// range to 1–336 hours.
    func createInvitation(householdId: UUID) async throws -> CreatedInvitation {
        try await createInvitation(householdId: householdId, expiresInHours: 168)
    }
}

enum HouseholdServiceError: LocalizedError {
    case notSignedIn
    case noHousehold
    case invalidPet(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to continue."
        case .noHousehold: "Create your household first."
        case .invalidPet(let message): message
        }
    }
}

@MainActor
final class MockHouseholdService: HouseholdService {
    private let backend: MockBackend

    init(backend: MockBackend) {
        self.backend = backend
    }

    func currentHousehold() async throws -> Household? {
        backend.household
    }

    func createHousehold(name: String, timeZone: String) async throws -> Household {
        guard let userId = backend.currentUserId else {
            throw HouseholdServiceError.notSignedIn
        }
        try? await Task.sleep(for: .milliseconds(400))
        return backend.createHousehold(name: name, timeZone: timeZone, ownerId: userId)
    }

    func members(householdId: UUID) async throws -> [HouseholdMember] {
        backend.members
    }

    func pets(householdId: UUID) async throws -> [Pet] {
        backend.pets
    }

    func createPet(
        name: String,
        birthInfo: BirthInfo,
        homecomingDate: Date?
    ) async throws -> Pet {
        guard backend.household != nil else {
            throw HouseholdServiceError.noHousehold
        }
        // Server-side guard mirroring doc 10 §7.5 validation; the form
        // validates first with inline explanations (US-023).
        if case .exact(let birthDate) = birthInfo {
            let clock = backend.household?.clock ?? HouseholdClock(timeZone: .current)
            if !clock.ordered(birthDate, beforeOrSameAs: Date()) {
                throw HouseholdServiceError.invalidPet("Birth date can't be in the future.")
            }
            if let homecomingDate, !clock.ordered(birthDate, beforeOrSameAs: homecomingDate) {
                throw HouseholdServiceError.invalidPet("Homecoming can't be before the birth date.")
            }
        }
        try? await Task.sleep(for: .milliseconds(400))
        return backend.createPet(name: name, birthInfo: birthInfo, homecomingDate: homecomingDate)
    }

    func saveRoutinePreferences(_ preferences: HouseholdPreference) async throws {
        backend.routinePreferences = preferences
    }

    func invitations(householdId: UUID) async throws -> [HouseholdInvitation] {
        backend.invitations
    }

    func createInvitation(householdId: UUID, expiresInHours: Int) async throws -> CreatedInvitation {
        guard let userId = backend.currentUserId else { throw HouseholdServiceError.notSignedIn }
        guard backend.members.first(where: { $0.userId == userId })?.role == .owner else {
            throw InvitationError.notAllowed
        }
        try? await Task.sleep(for: .milliseconds(300))
        return backend.createInvitation(
            householdId: householdId,
            createdBy: userId,
            expiresInHours: expiresInHours
        )
    }

    func revokeInvitation(id: UUID) async throws {
        try? await Task.sleep(for: .milliseconds(200))
        backend.resolveInvitation(id: id, status: .revoked)
    }

    func previewInvitation(token: String) async throws -> InvitationPreview {
        try? await Task.sleep(for: .milliseconds(300))
        return backend.previewInvitation(token: token)
    }

    func acceptInvitation(token: String) async throws -> Household {
        guard let userId = backend.currentUserId else { throw HouseholdServiceError.notSignedIn }
        try? await Task.sleep(for: .milliseconds(300))
        return try backend.acceptInvitation(token: token, userId: userId)
    }

    func declineInvitation(token: String) async throws {
        try? await Task.sleep(for: .milliseconds(200))
        guard let invitation = backend.invitation(forToken: token) else {
            throw InvitationError.notFound
        }
        backend.resolveInvitation(id: invitation.id, status: .declined)
    }
}
