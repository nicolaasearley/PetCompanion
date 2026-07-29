import XCTest
@testable import PetCompanion

@MainActor
final class InfrastructureTests: XCTestCase {
    /// The other selection tests inject `info` directly, so they stayed green
    /// while the real bundle carried no backend keys at all and every build
    /// silently fell back to the compiled-in default. This asserts the delivery
    /// mechanism itself: the keys must actually reach Info.plist, expanded.
    func testBundleActuallyCarriesResolvedBackendKeys() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        for key in ["PC_BACKEND_MODE", "PC_SUPABASE_URL", "PC_SUPABASE_ANON_KEY"] {
            let value = try XCTUnwrap(
                info[key] as? String,
                "\(key) is missing from Info.plist. INFOPLIST_KEY_* does not deliver custom keys; they must come from the base plist named by INFOPLIST_FILE."
            )
            XCTAssertFalse(value.isEmpty, "\(key) resolved to an empty string")
            XCTAssertFalse(
                value.hasPrefix("$("),
                "\(key) was not expanded — its build setting is unset for this configuration"
            )
        }

        // The bundle must resolve to a usable backend, not the invalid state.
        switch BackendSelection.resolve(environment: [:], arguments: ["PetCompanion"], info: info, isDebug: false) {
        case .invalid(let message):
            XCTFail("Bundle configuration is unusable: \(message)")
        case .mock, .local, .hosted:
            break
        }
    }

    func testBundleRegistersPetCompanionURLScheme() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let urlTypes = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(
            schemes.contains(InvitationToken.scheme),
            "BackendInfo.plist must register the same scheme used by invitation and Auth links"
        )
    }

    func testBackendSelectionRequiresHostedCredentials() {
        let selection = BackendSelection.resolve(
            environment: [:],
            arguments: ["PetCompanion"],
            info: ["PC_BACKEND_MODE": "hosted"],
            isDebug: false
        )
        guard case .invalid(let message) = selection else {
            return XCTFail("Expected an invalid hosted configuration")
        }
        XCTAssertTrue(message.contains("missing"))
    }

    func testMockBackendIsOnlySelectedExplicitly() {
        XCTAssertEqual(
            BackendSelection.resolve(
                environment: ["PETCOMPANION_BACKEND": "mock"],
                arguments: ["PetCompanion"],
                info: [:],
                isDebug: true
            ),
            .mock
        )
        guard case .local = BackendSelection.resolve(
            environment: [:],
            arguments: ["PetCompanion"],
            info: [:],
            isDebug: true
        ) else {
            return XCTFail("Debug should default to the real local service")
        }
    }

    func testPendingCommandKeepsKeyUntilSuccessfulRemoval() throws {
        let suiteName = "PendingCommandKeyStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PendingCommandKeyStore(defaults: defaults)
        struct Payload: Encodable { let occurrence_id: UUID }
        let payload = Payload(occurrence_id: UUID())
        let fingerprint = try store.operationFingerprint(command: "complete_occurrence", payload: payload)

        let first = store.idempotencyKey(for: fingerprint)
        XCTAssertEqual(store.idempotencyKey(for: fingerprint), first)
        store.remove(operation: fingerprint)
        XCTAssertNotEqual(store.idempotencyKey(for: fingerprint), first)
    }

    func testPlanCacheReturnsVisiblyStaleSnapshot() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanSnapshotCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PlanSnapshotCache(baseDirectory: directory)
        let petId = UUID()
        let plan = Plan(
            householdId: UUID(),
            petId: petId,
            localDate: Date(),
            timeZoneSnapshot: "America/Toronto",
            stageSnapshot: StageSnapshot(stageKey: "settling_in")
        )
        let item = PlanItem(
            planId: plan.id,
            itemKey: "test",
            kind: .informational,
            title: "Welcome home",
            category: .life,
            obligationClass: .informational,
            section: .today
        )
        cache.store(PlanSnapshot(plan: plan, items: [item], occurrences: [], dispositions: []))

        let cached = cache.load(petId: petId)
        XCTAssertEqual(cached?.items.first?.displayState, .stale)
        XCTAssertNotNil(cached?.servedFromCacheAt)
    }

    func testInterruptedHouseholdSetupResumesAtAddPet() async throws {
        let backend = MockBackend()
        let model = AppModel.mock(backend: backend)
        let user = backend.signIn(email: "nic@example.com")
        _ = backend.createHousehold(
            name: "Earley Household",
            timeZone: "America/Toronto",
            ownerId: user.id
        )

        let destination = try await model.didAuthenticate(user)
        XCTAssertEqual(destination, .addPet)
        XCTAssertNotNil(model.household)
        XCTAssertNil(model.activePet)
    }

    func testRecommendationAcceptancePromotesWithoutCompleting() async throws {
        let backend = MockBackend()
        let seed = backend.seedForPreview(preArrival: false)
        let service = MockPlanService(backend: backend)
        let original = try await service.plan(
            forPet: seed.pet.id,
            on: Date(),
            resectioningCompleted: false
        )
        let recommendation = try XCTUnwrap(
            original.items.first { $0.kind == .recommendation && $0.occurrenceId == nil }
        )
        do {
            _ = try await service.completeItem(
                itemId: recommendation.id,
                petId: seed.pet.id,
                on: Date()
            )
            XCTFail("Completion must not implicitly accept a recommendation")
        } catch PlanServiceError.recommendationNotYetActionable {
            // Expected.
        }

        let accepted = try await service.acceptRecommendation(
            itemId: recommendation.id,
            petId: seed.pet.id,
            on: Date()
        )
        let promoted = try XCTUnwrap(accepted.items.first { $0.id == recommendation.id })
        XCTAssertEqual(promoted.kind, .obligation)
        XCTAssertEqual(accepted.occurrence(for: promoted)?.state, .pending)
    }
}
