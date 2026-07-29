import Foundation
import XCTest
@testable import PetCompanion

@MainActor
final class PlanRealtimeReconciliationTests: XCTestCase {
    func testMockBridgeStartStopNeverCrashes() async {
        let bridge = NoOpPlanRealtimeBridge()
        var refreshCount = 0
        let reconciler = PlanRealtimeReconciler(
            bridge: bridge,
            debounceNanoseconds: 1_000_000
        ) {
            refreshCount += 1
        }

        reconciler.start(householdId: UUID())
        await Task.yield()
        XCTAssertTrue(reconciler.isActive)
        reconciler.requestRefresh()
        await waitUntil(timeout: 1.0) { refreshCount >= 1 }
        reconciler.stop()
        XCTAssertFalse(reconciler.isActive)
        XCTAssertEqual(refreshCount, 1)
    }

    func testDebounceCoalescesRapidChangesIntoOneRefresh() async {
        let bridge = ControllablePlanRealtimeBridge()
        var refreshCount = 0
        let reconciler = PlanRealtimeReconciler(
            bridge: bridge,
            debounceNanoseconds: 50_000_000
        ) {
            refreshCount += 1
        }

        reconciler.start(householdId: UUID())
        await waitUntil(timeout: 1.0) { bridge.connectedHouseholdId != nil }

        bridge.emitChange()
        bridge.emitChange()
        bridge.emitChange()
        await waitUntil(timeout: 1.0) { refreshCount >= 1 }
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(refreshCount, 1)
    }

    func testStopUnsubscribesBridge() async {
        let bridge = ControllablePlanRealtimeBridge()
        let reconciler = PlanRealtimeReconciler(
            bridge: bridge,
            debounceNanoseconds: 1_000_000
        ) {}

        let householdId = UUID()
        reconciler.start(householdId: householdId)
        await waitUntil(timeout: 1.0) { bridge.connectedHouseholdId == householdId }
        XCTAssertEqual(bridge.connectCount, 1)

        reconciler.stop()
        await waitUntil(timeout: 1.0) {
            bridge.disconnectCount >= 1 && bridge.connectedHouseholdId == nil
        }
        XCTAssertNil(bridge.connectedHouseholdId)
        XCTAssertFalse(reconciler.isActive)
    }

    func testSignOutStopsRealtimeSubscription() async {
        let model = AppModel.preview()
        let bridge = ControllablePlanRealtimeBridge()
        let reconciler = PlanRealtimeReconciler(
            bridge: bridge,
            debounceNanoseconds: 1_000_000
        ) { [weak model] in
            await model?.reconcilePlanFromRemote()
        }
        model.installPlanRealtimeForTesting(reconciler)
        model.syncPlanRealtimeLifecycle()
        await waitUntil(timeout: 1.0) { bridge.connectedHouseholdId != nil }
        XCTAssertTrue(reconciler.isActive)

        model.signOut()
        await waitUntil(timeout: 1.0) { bridge.disconnectCount >= 1 }
        XCTAssertFalse(reconciler.isActive)
        XCTAssertEqual(model.planState.reconciliationEpoch, 0)
        XCTAssertNil(model.planState.snapshot)
    }

    func testRemoteChangePublishesServerSnapshotAndBumpsEpoch() async throws {
        let model = AppModel.preview()
        let petId = try XCTUnwrap(model.activePet?.id)
        let before = try await model.plans.plan(
            forPet: petId,
            on: Date(),
            resectioningCompleted: false
        )
        model.planState.snapshot = before
        let epochBefore = model.planState.reconciliationEpoch

        let bridge = ControllablePlanRealtimeBridge()
        let reconciler = PlanRealtimeReconciler(
            bridge: bridge,
            debounceNanoseconds: 10_000_000
        ) { [weak model] in
            await model?.reconcilePlanFromRemote()
        }
        model.installPlanRealtimeForTesting(reconciler)
        model.syncPlanRealtimeLifecycle()
        await waitUntil(timeout: 1.0) { bridge.connectedHouseholdId != nil }

        bridge.emitChange()
        await waitUntil(timeout: 1.0) {
            model.planState.reconciliationEpoch > epochBefore
        }

        XCTAssertNotNil(model.planState.snapshot)
        XCTAssertNil(model.planState.snapshot?.servedFromCacheAt)
        XCTAssertGreaterThan(model.planState.reconciliationEpoch, epochBefore)
    }

    func testForegroundRefreshIsNoOpWhenInactive() async {
        let bridge = ControllablePlanRealtimeBridge()
        var refreshCount = 0
        let reconciler = PlanRealtimeReconciler(
            bridge: bridge,
            debounceNanoseconds: 1_000_000
        ) {
            refreshCount += 1
        }
        XCTAssertFalse(reconciler.isActive)
        reconciler.requestRefresh()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(refreshCount, 0)
    }

    func testCacheServedSnapshotDoesNotOverwriteLivePlan() async throws {
        let seed = AppModel.preview()
        let petId = try XCTUnwrap(seed.activePet?.id)
        var live = try await seed.plans.plan(
            forPet: petId,
            on: Date(),
            resectioningCompleted: false
        )
        live.servedFromCacheAt = nil

        let cachedService = CacheOnlyPlanService(snapshot: live)
        let model = AppModel(
            auth: seed.auth,
            households: seed.households,
            plans: cachedService,
            training: seed.training
        )
        model.currentUser = seed.currentUser
        model.household = seed.household
        model.activePet = seed.activePet
        model.phase = .main
        model.planState.snapshot = live
        let epochBefore = model.planState.reconciliationEpoch

        await model.reconcilePlanFromRemote()

        XCTAssertNil(model.planState.snapshot?.servedFromCacheAt)
        XCTAssertEqual(model.planState.snapshot?.plan.id, live.plan.id)
        XCTAssertGreaterThan(model.planState.reconciliationEpoch, epochBefore)
    }

    func testSyncLifecycleStartsOnlyInMainWithHousehold() async {
        let model = AppModel.mock()
        let bridge = ControllablePlanRealtimeBridge()
        let reconciler = PlanRealtimeReconciler(
            bridge: bridge,
            debounceNanoseconds: 1_000_000
        ) {}
        model.installPlanRealtimeForTesting(reconciler)

        model.phase = .onboarding
        model.household = nil
        model.syncPlanRealtimeLifecycle()
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(reconciler.isActive)
        XCTAssertNil(bridge.connectedHouseholdId)

        let preview = AppModel.preview()
        model.phase = .main
        model.household = preview.household
        model.syncPlanRealtimeLifecycle()
        await waitUntil(timeout: 1.0) { bridge.connectedHouseholdId != nil }
        XCTAssertTrue(reconciler.isActive)
        XCTAssertEqual(bridge.connectedHouseholdId, preview.household?.id)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Plan service that always returns a cache-marked copy of a fixed snapshot.
@MainActor
private final class CacheOnlyPlanService: PlanService {
    private let base: PlanSnapshot

    init(snapshot: PlanSnapshot) {
        var copy = snapshot
        copy.servedFromCacheAt = .now
        self.base = copy
    }

    func plan(
        forPet petId: UUID,
        on date: Date,
        resectioningCompleted: Bool
    ) async throws -> PlanSnapshot {
        var copy = base
        copy.servedFromCacheAt = .now
        return copy
    }

    func completeItem(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot {
        throw PlanServiceError.itemNotFound
    }

    func acceptRecommendation(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot {
        throw PlanServiceError.itemNotFound
    }

    func undoCompletion(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot {
        throw PlanServiceError.itemNotFound
    }

    func setCapacity(
        _ mode: CapacityMode,
        scope: CapacityScope,
        petId: UUID,
        on date: Date
    ) async throws -> PlanSnapshot {
        throw PlanServiceError.planNotFound
    }

    func addOneTimeTask(title: String, petId: UUID, on date: Date) async throws -> PlanSnapshot {
        throw PlanServiceError.planNotFound
    }
}
