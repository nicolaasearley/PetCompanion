import Foundation
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
/// Slice A limitation (call out from the work order, not discovered late):
/// recommendation items carry `occurrence_id == nil` until accepted, and
/// there is no accept/promote write-path command yet — that's engine/WP-4
/// server work. `completeItem`/`undoCompletion` on such an item throw
/// `PlanServiceError.recommendationNotYetActionable` (a plain, non-crashing
/// error `HomeViewModel` already surfaces via `errorMessage`) rather than
/// inventing a promotion flow.
@MainActor
final class RealPlanService: PlanService {
    private let client: SupabaseClient
    private let decoder = SupabaseCoding.restDecoder

    /// Slice A is single-pet/single-open-day: the last plan fetched or
    /// regenerated is cached here so `completeItem`/`undoCompletion` can
    /// resolve an item's `occurrence_id` without a round trip, and so their
    /// write-path response can be spliced back into the cached occurrences/
    /// dispositions locally (doc 09 §8 "no plan-jumping") instead of forcing
    /// a full regenerate after every action.
    private var cachedSnapshot: PlanSnapshot?

    init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - PlanService

    func plan(
        forPet petId: UUID,
        on date: Date,
        resectioningCompleted: Bool
    ) async throws -> PlanSnapshot {
        guard client.auth.currentUser != nil else { throw PlanServiceError.notSignedIn }

        if resectioningCompleted {
            // A natural list update: regenerating re-sections completed
            // items into Completed (the engine assigns `section` from each
            // occurrence's current state, `_shared/engine.mjs`).
            let snapshot = try await regenerate(petId: petId, capacityOverride: nil)
            cachedSnapshot = snapshot
            return snapshot
        }

        // A plain fetch never re-sections (doc 09 §8) — read what's already
        // persisted rather than regenerate. Only regenerate when no plan
        // exists yet for this pet/day (first-ever load).
        if let existing = try await readPersistedPlan(petId: petId, date: date) {
            cachedSnapshot = existing
            return existing
        }
        let snapshot = try await regenerate(petId: petId, capacityOverride: nil)
        cachedSnapshot = snapshot
        return snapshot
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

        let result: Result = try await WritePath.send(
            client: client,
            command: "complete_occurrence",
            payload: Payload(occurrence_id: occurrenceId)
        )

        return try applyOccurrenceMutation(
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

        let result: Result = try await WritePath.send(
            client: client,
            command: "undo_completion",
            payload: Payload(occurrence_id: occurrenceId)
        )

        return try applyOccurrenceMutation(
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
    }

    func setCapacity(
        _ mode: CapacityMode,
        scope: CapacityScope,
        petId: UUID,
        on date: Date
    ) async throws -> PlanSnapshot {
        // Residual TODO (see report): `generate-plan` accepts
        // `capacity_override` for one regeneration, but there is no
        // write-path command yet to persist a new household
        // `default_capacity_mode` (it's only set at `create_household`
        // time). `scope` therefore always behaves like `.todayOnly`
        // server-side today, regardless of what the sheet says — the sheet
        // UI itself keeps working (doc 14 HM-04), the "every day" choice
        // just isn't durable yet.
        let snapshot = try await regenerate(petId: petId, capacityOverride: mode)
        cachedSnapshot = snapshot
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

        let _: EmptyResult = try await WritePath.send(
            client: client,
            command: "create_task",
            payload: Payload(
                pet_id: petId,
                title: title,
                local_due_date: SupabaseCoding.dateOnlyString(date),
                time_policy: "anytime",
                assignment: "anyone"
            )
        )

        // `create_task` inserts the occurrence directly; folding it into
        // the visible plan needs the same regeneration a natural list
        // update would trigger.
        let snapshot = try await regenerate(petId: petId, capacityOverride: nil)
        cachedSnapshot = snapshot
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
        let dateString = SupabaseCoding.dateOnlyString(date)
        let planResponse = try await client
            .from("plans")
            .select()
            .eq("pet_id", value: petId)
            .eq("local_date", value: dateString)
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
}
