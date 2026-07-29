import Foundation
import OSLog

#if canImport(Supabase)
import Supabase
#endif

/// Household-scoped plan change signals for multi-device reconciliation.
/// Bridges are injectable so unit tests never need a live Realtime socket.
@MainActor
protocol PlanRealtimeBridging: AnyObject {
    /// Begin listening for plan-relevant row changes for `householdId`.
    /// Replaces any prior subscription. `onChange` is always invoked on the
    /// main actor and must stay cheap — the reconciler debounces work.
    func connect(householdId: UUID, onChange: @escaping @MainActor () -> Void) async
    func disconnect() async
}

/// Auth-lifecycle façade used by `AppModel`. Mock builds install a no-op
/// bridge; real backends subscribe to dispositions / occurrences / plans.
@MainActor
protocol PlanRealtimeReconciling: AnyObject {
    var isActive: Bool { get }
    func start(householdId: UUID)
    func stop()
    /// Foreground / reconnect safety: truthful refresh without waiting for
    /// a Realtime event (SDK reconnects the channel; this covers missed
    /// payloads while suspended).
    func requestRefresh()
}

/// Default no-op bridge for mock / preview builds — connect never crashes.
@MainActor
final class NoOpPlanRealtimeBridge: PlanRealtimeBridging {
    func connect(householdId: UUID, onChange: @escaping @MainActor () -> Void) async {}
    func disconnect() async {}
}

/// Test double that records connect/disconnect and can emit synthetic changes.
@MainActor
final class ControllablePlanRealtimeBridge: PlanRealtimeBridging {
    private(set) var connectedHouseholdId: UUID?
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private var onChange: (@MainActor () -> Void)?

    func connect(householdId: UUID, onChange: @escaping @MainActor () -> Void) async {
        connectedHouseholdId = householdId
        self.onChange = onChange
        connectCount += 1
    }

    func disconnect() async {
        connectedHouseholdId = nil
        onChange = nil
        disconnectCount += 1
    }

    func emitChange() {
        onChange?()
    }
}

/// Debounces Realtime (or synthetic) change signals into truthful plan
/// refreshes. Does not invent cross-device merges — it only schedules the
/// caller-supplied refresh, which must re-read server state.
@MainActor
final class PlanRealtimeReconciler: PlanRealtimeReconciling {
    private let bridge: any PlanRealtimeBridging
    private let onRefresh: @MainActor () async -> Void
    private let debounceNanoseconds: UInt64
    private let logger = Logger(subsystem: "com.nic.petcompanion", category: "plan-realtime")

    private(set) var isActive = false
    private var activeHouseholdId: UUID?
    private var generation = 0
    private var connectTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var isRefreshing = false
    private var pendingRefresh = false

    init(
        bridge: any PlanRealtimeBridging,
        debounceNanoseconds: UInt64 = 400_000_000,
        onRefresh: @escaping @MainActor () async -> Void
    ) {
        self.bridge = bridge
        self.debounceNanoseconds = debounceNanoseconds
        self.onRefresh = onRefresh
    }

    func start(householdId: UUID) {
        if isActive, activeHouseholdId == householdId { return }
        generation += 1
        let gen = generation
        isActive = true
        activeHouseholdId = householdId
        debounceTask?.cancel()
        debounceTask = nil
        pendingRefresh = false
        let target = householdId
        // Serialize bridge work on `connectTask`. Every continuation checks
        // `generation` so a cancelled stop/start cannot clobber a newer one.
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, self.generation == gen else { return }
            await self.bridge.disconnect()
            guard !Task.isCancelled,
                  self.generation == gen,
                  self.isActive,
                  self.activeHouseholdId == target
            else { return }
            await self.bridge.connect(householdId: target) { [weak self] in
                self?.scheduleRefresh()
            }
            guard !Task.isCancelled,
                  self.generation == gen,
                  self.isActive,
                  self.activeHouseholdId == target
            else {
                // Only tear down if we still own this generation — a newer
                // start/stop already replaced the bridge subscription.
                if self.generation == gen {
                    await self.bridge.disconnect()
                }
                return
            }
            self.logger.debug("Plan realtime subscribed for household \(target.uuidString, privacy: .public)")
        }
    }

    func stop() {
        generation += 1
        let gen = generation
        isActive = false
        activeHouseholdId = nil
        debounceTask?.cancel()
        debounceTask = nil
        pendingRefresh = false
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            guard self.generation == gen else { return }
            await self.bridge.disconnect()
        }
    }

    func requestRefresh() {
        guard isActive else { return }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self.performRefresh()
        }
    }

    private func performRefresh() async {
        if isRefreshing {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if pendingRefresh {
                pendingRefresh = false
                scheduleRefresh()
            }
        }
        await onRefresh()
    }
}

#if canImport(Supabase)
/// Supabase Realtime postgres_changes on the tables Home/Planner already read.
/// Filters by `household_id` (defense-in-depth; RLS still gates payloads).
@MainActor
final class SupabasePlanRealtimeBridge: PlanRealtimeBridging {
    private let client: SupabaseClient
    private let logger = Logger(subsystem: "com.nic.petcompanion", category: "plan-realtime")
    private var channel: RealtimeChannelV2?
    private var tokens: [RealtimeSubscription] = []

    init(client: SupabaseClient) {
        self.client = client
    }

    func connect(householdId: UUID, onChange: @escaping @MainActor () -> Void) async {
        await disconnect()

        let channel = client.channel("plan-household-\(householdId.uuidString.lowercased())")
        let filter: RealtimePostgresFilter = .eq("household_id", value: householdId)
        let tables = ["dispositions", "task_occurrences", "plans"]

        var retained: [RealtimeSubscription] = []
        for table in tables {
            let token = channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: table,
                filter: filter
            ) { _ in
                Task { @MainActor in
                    onChange()
                }
            }
            retained.append(token)
        }

        do {
            try await channel.subscribeWithError()
            self.channel = channel
            self.tokens = retained
        } catch {
            logger.error(
                "Plan realtime subscribe failed: \(error.localizedDescription, privacy: .public)"
            )
            retained.removeAll()
            await client.removeChannel(channel)
            self.channel = nil
            self.tokens = []
        }
    }

    func disconnect() async {
        tokens.removeAll()
        if let channel {
            await client.removeChannel(channel)
            self.channel = nil
        }
    }
}
#endif
