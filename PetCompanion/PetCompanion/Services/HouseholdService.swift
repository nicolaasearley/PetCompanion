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
}
