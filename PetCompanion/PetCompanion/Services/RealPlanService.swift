import Foundation
import OSLog
import Supabase

/// Supabase-backed implementation of `PlanService` — Slice A WP-3/WP-4
/// (doc 17). The daily plan itself comes from the `generate-plan` edge
/// function (`supabase/functions/generate-plan`), which runs the
/// recommendation engine (`packages/engine` via `_shared/engine.mjs`) and
/// persists the result (`write_path_persist_plan`); a plain "did anything
/// change" fetch instead reads the already-persisted `plans`/`plan_items`
/// rows directly (RLS "active member read" policies), matching
/// `RealHouseholdService`'s read/write split. Completion, undo, capacity,
/// and quick-add all route through the single write-path edge function via
/// the shared `WritePath` client (`SupabaseCoding.swift`).
///
/// Recommendations carry `occurrence_id == nil` until the caregiver
/// explicitly accepts them. `acceptRecommendation` promotes one to a
/// pending scheduled occurrence; completion remains a separate action.
@MainActor
final class RealPlanService: PlanService {
    private let client: SupabaseClient
    private let decoder = SupabaseCoding.restDecoder
    private let cache: PlanSnapshotCache
    private let operationQueue: OfflineOperationQueue
    private let notifications: any LocalNotificationServicing
    private let logger = Logger(subsystem: "com.nic.petcompanion", category: "plan")

    /// Slice A is single-pet/single-open-day: the last plan fetched or
    /// regenerated is cached here so `completeItem`/`undoCompletion` can
    /// resolve an item's `occurrence_id` without a round trip, and so their
    /// write-path response can be spliced back into the cached occurrences/
    /// dispositions locally (doc 09 §8 "no plan-jumping") instead of forcing
    /// a full regenerate after every action.
    private var cachedSnapshot: PlanSnapshot?

    init(
        client: SupabaseClient,
        operationQueue: OfflineOperationQueue,
        notifications: any LocalNotificationServicing,
        cache: PlanSnapshotCache? = nil
    ) {
        self.client = client
        self.operationQueue = operationQueue
        self.notifications = notifications
        self.cache = cache ?? PlanSnapshotCache()
    }

    // MARK: - PlanService

    func plan(
        forPet petId: UUID,
        on date: Date,
        resectioningCompleted: Bool
    ) async throws -> PlanSnapshot {
        do {
            _ = try await client.auth.session
        } catch {
            throw PlanServiceError.notSignedIn
        }

        do {
            if resectioningCompleted {
                let snapshot = try await regenerate(petId: petId, capacityOverride: nil)
                return await retainAndReconcile(snapshot)
            }
            if let existing = try await readPersistedPlan(petId: petId, date: date) {
                return await retainAndReconcile(existing)
            }
            let snapshot = try await regenerate(petId: petId, capacityOverride: nil)
            return await retainAndReconcile(snapshot)
        } catch {
            logger.error("Plan refresh failed; attempting last-known-good cache: \(error.localizedDescription, privacy: .public)")
            guard let fallback = cache.load(petId: petId) else { throw error }
            cachedSnapshot = fallback
            return fallback
        }
    }

    func completeItem(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot {
        let occurrenceId = try resolvedOccurrenceId(forItem: itemId)

        struct Payload: Encodable { let occurrence_id: UUID }
        struct OccurrenceResult: Decodable {
            let id: UUID
            let state: String
            let effective_completion_id: UUID?
        }
        struct DispositionResult: Decodable {
            let id: UUID
            let action: String
            let actor_user_id: UUID
            let recorded_at: Date
            let effective_at: Date
            let superseded: Bool?
        }
        struct Result: Decodable {
            let occurrence: OccurrenceResult
            let disposition: DispositionResult
        }

        let result: Result
        do {
            result = try await WritePath.sendStable(
                client: client,
                command: "complete_occurrence",
                payload: Payload(occurrence_id: occurrenceId),
                queue: operationQueue
            )
        } catch OfflineMutationError.queued(let operationId) {
            let queued = try applyQueuedOccurrenceMutation(
                itemId: itemId,
                occurrenceId: occurrenceId,
                newState: .completed,
                action: .complete,
                operationId: operationId
            )
            await notifications.reconcile(snapshot: queued)
            return queued
        }

        let snapshot = try applyOccurrenceMutation(
            occurrenceId: occurrenceId,
            newState: .completed,
            disposition: Disposition(
                id: result.disposition.id,
                occurrenceId: occurrenceId,
                action: .complete,
                actorUserId: result.disposition.actor_user_id,
                recordedAt: result.disposition.recorded_at,
                effectiveAt: result.disposition.effective_at,
                superseded: result.disposition.superseded ?? false
            )
        )
        cache.store(snapshot)
        await notifications.reconcile(snapshot: snapshot)
        return snapshot
    }

    func acceptRecommendation(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot {
        guard let snapshot = cachedSnapshot,
              let item = snapshot.items.first(where: { $0.id == itemId }),
              item.kind == .recommendation
        else { throw PlanServiceError.itemNotFound }

        if item.occurrenceId != nil {
            return snapshot
        }

        struct Payload: Encodable {
            let plan_item_id: UUID
            let complete: Bool
            let pinned: Bool
        }
        struct Result: Decodable {
            struct PlanItemResult: Decodable {
                let id: UUID
                let occurrence_id: UUID
            }
            let plan_item: PlanItemResult
        }
        do {
            let _: Result = try await WritePath.sendStable(
                client: client,
                command: "accept_recommendation",
                payload: Payload(plan_item_id: itemId, complete: false, pinned: false),
                queue: operationQueue
            )
        } catch OfflineMutationError.queued {
            var queued = snapshot
            guard let index = queued.items.firstIndex(where: { $0.id == itemId }) else {
                throw PlanServiceError.itemNotFound
            }
            queued.items[index].displayState = .queued
            cachedSnapshot = queued
            cache.store(queued)
            await notifications.reconcile(snapshot: queued)
            return queued
        }

        guard let refreshed = try await readPersistedPlan(petId: petId, date: date) else {
            throw PlanServiceError.planNotFound
        }
        cachedSnapshot = refreshed
        cache.store(refreshed)
        await notifications.reconcile(snapshot: refreshed)
        return refreshed
    }

    func undoCompletion(itemId: UUID, petId: UUID, on date: Date) async throws -> PlanSnapshot {
        let occurrenceId = try resolvedOccurrenceId(forItem: itemId)

        struct Payload: Encodable { let occurrence_id: UUID }
        struct DispositionResult: Decodable {
            let id: UUID
            let action: String
            let actor_user_id: UUID
            let recorded_at: Date
            let effective_at: Date
        }
        struct Result: Decodable { let disposition: DispositionResult }

        let result: Result
        do {
            result = try await WritePath.sendStable(
                client: client,
                command: "undo_completion",
                payload: Payload(occurrence_id: occurrenceId),
                queue: operationQueue
            )
        } catch OfflineMutationError.queued(let operationId) {
            let queued = try applyQueuedOccurrenceMutation(
                itemId: itemId,
                occurrenceId: occurrenceId,
                newState: .pending,
                action: .undoComplete,
                operationId: operationId
            )
            await notifications.reconcile(snapshot: queued)
            return queued
        }

        let snapshot = try applyOccurrenceMutation(
            occurrenceId: occurrenceId,
            newState: .pending,
            disposition: Disposition(
                id: result.disposition.id,
                occurrenceId: occurrenceId,
                action: .undoComplete,
                actorUserId: result.disposition.actor_user_id,
                recordedAt: result.disposition.recorded_at,
                effectiveAt: result.disposition.effective_at,
                superseded: false
            )
        )
        cache.store(snapshot)
        await notifications.reconcile(snapshot: snapshot)
        return snapshot
    }

    func setCapacity(
        _ mode: CapacityMode,
        scope: CapacityScope,
        petId: UUID,
        on date: Date
    ) async throws -> PlanSnapshot {
        if scope == .householdDefault {
            guard let householdId = cachedSnapshot?.plan.householdId else {
                throw PlanServiceError.planNotFound
            }
            struct Payload: Encodable {
                let household_id: UUID
                let default_capacity_mode: String
            }
            struct Result: Decodable {
                let household_id: UUID
                let default_capacity_mode: String
            }
            do {
                let _: Result = try await WritePath.sendStable(
                    client: client,
                    command: "set_default_capacity",
                    payload: Payload(
                        household_id: householdId,
                        default_capacity_mode: mode.rawValue
                    ),
                    queue: operationQueue
                )
            } catch OfflineMutationError.queued {
                let queued = try locallyApplyCapacity(mode)
                await notifications.reconcile(snapshot: queued)
                return queued
            }
        }
        let snapshot = try await regenerate(petId: petId, capacityOverride: mode)
        cachedSnapshot = snapshot
        cache.store(snapshot)
        await notifications.reconcile(snapshot: snapshot)
        return snapshot
    }

    func addOneTimeTask(title: String, petId: UUID, on date: Date) async throws -> PlanSnapshot {
        struct Payload: Encodable {
            let pet_id: UUID
            let title: String
            let local_due_date: String
            let time_policy: String
            let assignment: String
        }
        struct EmptyResult: Decodable {}

        let timeZone = cachedSnapshot
            .flatMap { TimeZone(identifier: $0.plan.timeZoneSnapshot) } ?? .gmt
        do {
            let _: EmptyResult = try await WritePath.sendStable(
                client: client,
                command: "create_task",
                payload: Payload(
                    pet_id: petId,
                    title: title,
                    local_due_date: SupabaseCoding.dateOnlyString(date, timeZone: timeZone),
                    time_policy: "anytime",
                    assignment: "anyone"
                ),
                queue: operationQueue
            )
        } catch OfflineMutationError.queued {
            let queued = try locallyAddQueuedTask(title: title, petId: petId, date: date)
            await notifications.reconcile(snapshot: queued)
            return queued
        }

        // `create_task` inserts the occurrence directly; folding it into
        // the visible plan needs the same regeneration a natural list
        // update would trigger.
        let snapshot = try await regenerate(petId: petId, capacityOverride: nil)
        cachedSnapshot = snapshot
        cache.store(snapshot)
        await notifications.reconcile(snapshot: snapshot)
        return snapshot
    }

    // MARK: - generate-plan

    private struct GeneratePlanRequestBody: Encodable {
        let pet_id: UUID
        let capacity_override: String?
    }

    private struct GeneratePlanResultBody: Decodable {
        let plan: Plan
        let items: [PlanItem]
    }

    private struct GeneratePlanSuccessBody: Decodable {
        let ok: Bool
        let result: GeneratePlanResultBody
    }

    private struct GeneratePlanFailureBody: Decodable {
        let ok: Bool
        let code: String?
        let message: String?
    }

    private func regenerate(petId: UUID, capacityOverride: CapacityMode?) async throws -> PlanSnapshot {
        let body = GeneratePlanRequestBody(pet_id: petId, capacity_override: capacityOverride?.rawValue)
        do {
            let data: Data = try await client.functions.invoke(
                "generate-plan",
                options: FunctionInvokeOptions(body: body)
            ) { data, _ in data }
            let success = try decoder.decode(GeneratePlanSuccessBody.self, from: data)
            return try await assembleSnapshot(plan: success.result.plan, items: success.result.items)
        } catch FunctionsError.httpError(_, let data) {
            if let failure = try? decoder.decode(GeneratePlanFailureBody.self, from: data),
               let message = failure.message {
                throw WritePathError.server(code: failure.code ?? "GENERATE_PLAN_FAILED", message: message)
            }
            throw WritePathError.malformedResponse
        }
    }

    // MARK: - Direct reads (RLS "active member read" policies)

    private func readPersistedPlan(petId: UUID, date: Date) async throws -> PlanSnapshot? {
        // Deliberately does NOT filter by an exact `local_date` string built
        // from the device's calendar/time zone: `plans.local_date` is
        // computed server-side from the *household's* `time_zone_snapshot`
        // (`household_current_local_date`, `write_path_generation_context`),
        // which routinely disagrees with the simulator/device's local date
        // (caught in manual verification: a household on `Europe/Stockholm`
        // had `local_date` one calendar day ahead of the host machine). An
        // exact-match filter against a device-local string would silently
        // miss the row and fall through to a full regenerate on every plain
        // fetch — never actually reading, always resectioning. Slice A has
        // no day-close cron (`close_plans_for_date` isn't scheduled yet), so
        // there is at most one meaningfully "current" plan per pet: the
        // latest `open` one.
        let planResponse = try await client
            .from("plans")
            .select()
            .eq("pet_id", value: petId)
            .eq("status", value: Plan.Status.open.rawValue)
            .order("local_date", ascending: false)
            .order("generated_at", ascending: false)
            .limit(1)
            .execute()
        let plans = try decoder.decode([Plan].self, from: planResponse.data)
        guard let plan = plans.first else { return nil }

        let itemsResponse = try await client
            .from("plan_items")
            .select()
            .eq("plan_id", value: plan.id)
            .order("section")
            .order("priority_tier")
            .order("due_time", nullsFirst: false)
            .order("title")
            .order("item_key")
            .execute()
        let items = try decoder.decode([PlanItem].self, from: itemsResponse.data)

        return try await assembleSnapshot(plan: plan, items: items)
    }

    /// Fills out a bare plan+items pair (from either `generate-plan` or a
    /// direct read) with the occurrences and dispositions the UI needs for
    /// completion state and attribution (`PlanSnapshot.occurrence(for:)`,
    /// `effectiveCompletion(for:)`) — neither the edge function nor the
    /// plan_items row itself carries those.
    private func assembleSnapshot(plan: Plan, items: [PlanItem]) async throws -> PlanSnapshot {
        let occurrenceIds = Array(Set(items.compactMap(\.occurrenceId)))
        guard !occurrenceIds.isEmpty else {
            return PlanSnapshot(plan: plan, items: items, occurrences: [], dispositions: [])
        }
        let idStrings = occurrenceIds.map(\.uuidString)

        let occurrencesResponse = try await client
            .from("task_occurrences")
            .select()
            .in("id", values: idStrings)
            .execute()
        let occurrences = try decoder.decode([TaskOccurrence].self, from: occurrencesResponse.data)

        let dispositionsResponse = try await client
            .from("dispositions")
            .select()
            .in("occurrence_id", values: idStrings)
            .order("effective_at")
            .execute()
        let dispositions = try decoder.decode([Disposition].self, from: dispositionsResponse.data)

        return PlanSnapshot(plan: plan, items: items, occurrences: occurrences, dispositions: dispositions)
    }

    // MARK: - Local reconciliation helpers

    private func retainAndReconcile(_ snapshot: PlanSnapshot) async -> PlanSnapshot {
        cachedSnapshot = snapshot
        cache.store(snapshot)
        await notifications.reconcile(snapshot: snapshot)
        return snapshot
    }

    private func resolvedOccurrenceId(forItem itemId: UUID) throws -> UUID {
        guard let snapshot = cachedSnapshot, let item = snapshot.items.first(where: { $0.id == itemId }) else {
            throw PlanServiceError.itemNotFound
        }
        guard let occurrenceId = item.occurrenceId else {
            throw PlanServiceError.recommendationNotYetActionable
        }
        return occurrenceId
    }

    /// Splices a write-path completion/undo response into the cached
    /// snapshot's occurrences and dispositions in place, mirroring exactly
    /// what `write_path_complete_occurrence`/`write_path_undo_completion`
    /// just did server-side (completion-convergence rule, doc 10 §9.4) —
    /// no extra round trip, and no plan-jumping (doc 09 §8): the item's
    /// stored `section` is untouched, only its completion state changes.
    private func applyOccurrenceMutation(
        occurrenceId: UUID,
        newState: TaskOccurrence.State,
        disposition: Disposition
    ) throws -> PlanSnapshot {
        guard var snapshot = cachedSnapshot else { throw PlanServiceError.planNotFound }
        guard let index = snapshot.occurrences.firstIndex(where: { $0.id == occurrenceId }) else {
            throw PlanServiceError.itemNotFound
        }

        snapshot.occurrences[index].state = newState
        snapshot.occurrences[index].revision += 1

        // A completion this call superseded stays the historical record;
        // only demote the *previous* effective completion when this new
        // disposition is itself the winner (the common case — a backdated
        // completion, `superseded == true`, means the earlier one is still
        // effective and must be left alone).
        if disposition.action == .complete, !disposition.superseded {
            for i in snapshot.dispositions.indices
            where snapshot.dispositions[i].occurrenceId == occurrenceId
                && snapshot.dispositions[i].action == .complete
                && !snapshot.dispositions[i].superseded {
                snapshot.dispositions[i].superseded = true
            }
        } else if disposition.action == .undoComplete {
            for i in snapshot.dispositions.indices
            where snapshot.dispositions[i].occurrenceId == occurrenceId
                && snapshot.dispositions[i].action == .complete {
                snapshot.dispositions[i].superseded = true
            }
        }
        snapshot.dispositions.append(disposition)

        cachedSnapshot = snapshot
        return snapshot
    }

    private func applyQueuedOccurrenceMutation(
        itemId: UUID,
        occurrenceId: UUID,
        newState: TaskOccurrence.State,
        action: Disposition.Action,
        operationId: UUID
    ) throws -> PlanSnapshot {
        guard var snapshot = cachedSnapshot,
              let itemIndex = snapshot.items.firstIndex(where: { $0.id == itemId }),
              let occurrenceIndex = snapshot.occurrences.firstIndex(where: { $0.id == occurrenceId })
        else { throw PlanServiceError.itemNotFound }

        snapshot.items[itemIndex].displayState = .queued
        snapshot.occurrences[occurrenceIndex].state = newState
        snapshot.occurrences[occurrenceIndex].revision += 1
        if action == .undoComplete {
            for index in snapshot.dispositions.indices
            where snapshot.dispositions[index].occurrenceId == occurrenceId
                && snapshot.dispositions[index].action == .complete {
                snapshot.dispositions[index].superseded = true
            }
        }
        snapshot.dispositions.append(
            Disposition(
                occurrenceId: occurrenceId,
                action: action,
                actorUserId: client.auth.currentUser?.id ?? UUID(),
                clientIdempotencyKey: operationId.uuidString
            )
        )
        cachedSnapshot = snapshot
        cache.store(snapshot)
        return snapshot
    }

    private func locallyApplyCapacity(_ mode: CapacityMode) throws -> PlanSnapshot {
        guard var snapshot = cachedSnapshot else { throw PlanServiceError.planNotFound }
        snapshot.plan.capacityModeApplied = mode
        let recommendations = snapshot.items.filter {
            $0.kind == .recommendation && $0.occurrenceId == nil
        }
        let visibleIds = Set(
            recommendations
                .sorted { $0.priorityTier < $1.priorityTier }
                .prefix(mode.recommendationBudget)
                .map(\.id)
        )
        snapshot.items.removeAll {
            $0.kind == .recommendation
                && $0.occurrenceId == nil
                && !visibleIds.contains($0.id)
        }
        for index in snapshot.items.indices where snapshot.items[index].kind == .recommendation {
            snapshot.items[index].displayState = .queued
        }
        cachedSnapshot = snapshot
        cache.store(snapshot)
        return snapshot
    }

    private func locallyAddQueuedTask(title: String, petId: UUID, date: Date) throws -> PlanSnapshot {
        guard var snapshot = cachedSnapshot else { throw PlanServiceError.planNotFound }
        let occurrence = TaskOccurrence(
            occurrenceKey: "queued:\(UUID().uuidString)",
            householdId: snapshot.plan.householdId,
            petId: petId,
            localDueDate: date,
            obligationClass: .scheduled,
            origin: .userCreated
        )
        snapshot.occurrences.append(occurrence)
        snapshot.items.append(
            PlanItem(
                planId: snapshot.plan.id,
                itemKey: "queued:\(occurrence.id.uuidString)",
                kind: .obligation,
                occurrenceId: occurrence.id,
                title: title,
                category: .household,
                obligationClass: .scheduled,
                priorityTier: .p2,
                section: .today,
                timeWindow: .anytime,
                displayState: .queued
            )
        )
        cachedSnapshot = snapshot
        cache.store(snapshot)
        return snapshot
    }
}
