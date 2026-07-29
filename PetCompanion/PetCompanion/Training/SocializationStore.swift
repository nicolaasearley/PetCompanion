import Foundation
import Observation

/// State behind TR-06/TR-07/TR-08.
///
/// The only aggregation it performs is per-category recency and a plain count
/// of recorded experiences in a rolling window. It computes no score, no
/// ratio, no completion percentage, and no "categories covered out of eight" —
/// F09 excludes a universal numeric socialization score, and a fraction with
/// eight in the denominator is exactly that.
@MainActor
@Observable
final class SocializationStore {
    /// TR-06's breadth line reads "N this month", so the window is a month.
    static let breadthWindowDays = 30

    private let service: any SocializationService
    private let calendar: Calendar

    private(set) var records: [SocializationRecord] = []
    private(set) var exclusions: [SocializationExclusion] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    var confirmationMessage: String?
    /// Set instead of `confirmationMessage` when the write only reached the
    /// on-device durable queue (`OfflineMutationError.queued`) — a real
    /// acceptance, never a failure, but not a server-confirmed save either.
    /// `records`/`exclusions` are deliberately left untouched here: the
    /// service has no local/optimistic snapshot to fabricate a placeholder
    /// row from (unlike `RealPlanService`'s queued plan items), so the new
    /// entry only appears once the queue replays and a later `load()` reads
    /// it back for real.
    var queuedMessage: String?

    let petId: UUID
    let petName: String

    init(
        service: any SocializationService,
        petId: UUID,
        petName: String,
        calendar: Calendar = .current
    ) {
        self.service = service
        self.petId = petId
        self.petName = petName
        self.calendar = calendar
    }

    var caution: String { SocializationCatalogue.caution(petName: petName) }

    var activeExclusions: [SocializationExclusion] { exclusions.filter(\.isActive) }

    func excludedCategory(_ category: SocializationCategory) -> SocializationExclusion? {
        activeExclusions.first { $0.category == category }
    }

    func excludedExperience(_ contentId: String) -> SocializationExclusion? {
        activeExclusions.first { $0.experienceContentId == contentId }
    }

    /// Newest first, and capped — TR-06's RECENT list is a glance, not a log.
    func recent(limit: Int = 5) -> [SocializationRecord] {
        Array(records.sorted { $0.effectiveDate > $1.effectiveDate }.prefix(limit))
    }

    func records(in category: SocializationCategory) -> [SocializationRecord] {
        records
            .filter { $0.category == category }
            .sorted { $0.effectiveDate > $1.effectiveDate }
    }

    func lastRecorded(experienceContentId: String) -> Date? {
        records
            .filter { $0.experienceContentId == experienceContentId }
            .map(\.effectiveDate)
            .max()
    }

    var breadth: [SocializationCategoryBreadth] {
        let windowStart = calendar.date(
            byAdding: .day, value: -Self.breadthWindowDays, to: Date()
        ) ?? .distantPast
        return SocializationCategory.allCases.map { category in
            let inCategory = records.filter { $0.category == category }
            let exclusion = excludedCategory(category)
            return SocializationCategoryBreadth(
                category: category,
                recentCount: inCategory.filter { $0.effectiveDate >= windowStart }.count,
                lastDate: inCategory.map(\.effectiveDate).max(),
                isExcluded: exclusion != nil,
                exclusionReason: exclusion?.reason
            )
        }
    }

    // MARK: - Loading and mutation

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let snapshot = try await service.load(petId: petId)
            records = snapshot.records
            exclusions = snapshot.exclusions
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func record(_ draft: SocializationDraft) async -> Bool {
        await perform(
            confirmation: "Saved to \(petName)'s passport.",
            queuedNotice: "Saved on this device. It'll appear in \(petName)'s passport once you're back online."
        ) {
            try await self.service.record(draft, petId: self.petId)
        }
    }

    func editResponse(
        record: SocializationRecord,
        response: SocializationResponse,
        note: String?
    ) async -> Bool {
        await perform(
            confirmation: "Updated.",
            queuedNotice: "Saved on this device. The update will apply once you're back online."
        ) {
            try await self.service.editResponse(
                recordId: record.id,
                expectedRevision: record.revision,
                response: response,
                note: note
            )
        }
    }

    func remove(record: SocializationRecord) async -> Bool {
        await perform(
            confirmation: "Removed from the passport.",
            queuedNotice: "Saved on this device. It'll be removed once you're back online."
        ) {
            try await self.service.remove(recordId: record.id)
        }
    }

    func exclude(
        category: SocializationCategory? = nil,
        experienceContentId: String? = nil,
        reason: SocializationExclusionReason
    ) async -> Bool {
        await perform(
            confirmation: "Won't be suggested. You can undo this any time.",
            queuedNotice: "Saved on this device. This will stop being suggested once you're back online."
        ) {
            try await self.service.setExclusion(
                petId: self.petId,
                category: category,
                experienceContentId: experienceContentId,
                reason: reason
            )
        }
    }

    func clear(exclusion: SocializationExclusion) async -> Bool {
        await perform(
            confirmation: "Back in the suggestions.",
            queuedNotice: "Saved on this device. This will return to suggestions once you're back online."
        ) {
            try await self.service.clearExclusion(exclusionId: exclusion.id)
        }
    }

    /// `confirmation` renders only on a real server acknowledgement;
    /// `queuedNotice` renders when the write only reached the durable
    /// offline queue (`OfflineMutationError.queued`) — still a truthful,
    /// non-losable acceptance the caregiver should see, but never worded or
    /// styled as a confirmed save (doc 22 §7). Both outcomes dismiss the
    /// active sheet, since neither one leaves anything for the caregiver to
    /// retry or fix.
    ///
    /// Every attempt starts with all three outcome fields cleared and ends
    /// with exactly one of them set — never a stale success sitting behind
    /// a later failure or queued notice, and never two contradictory
    /// banners at once. `load()`'s own refresh failure is the one place
    /// this needs care: it sets `errorMessage` on its own, but a write this
    /// method already confirmed with the server is still true even if the
    /// follow-up read of the latest list fails, so that confirmation must
    /// win rather than coexist with (or lose to) `load()`'s error.
    private func perform(
        confirmation: String,
        queuedNotice: String,
        _ work: @escaping () async throws -> Void
    ) async -> Bool {
        isSaving = true
        errorMessage = nil
        queuedMessage = nil
        confirmationMessage = nil
        defer { isSaving = false }
        do {
            try await work()
            await load()
            errorMessage = nil
            confirmationMessage = confirmation
            return true
        } catch OfflineMutationError.queued {
            queuedMessage = queuedNotice
            return true
        } catch {
            errorMessage = displayMessage(for: error)
            return false
        }
    }

    private func displayMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "Something went wrong. Try again."
    }
}

extension SocializationStore {
    /// Preview and mock-build store, seeded so TR-06's breadth line, the
    /// recent list, and a paused category are all visible without a backend.
    /// Previously lived on `TrainingTabView`, which no longer has any
    /// socialization-specific code of its own (2026-07-29 Training
    /// hierarchy update) — this is the type it actually extends.
    static func preview() -> SocializationStore {
        let calendar = Calendar.current
        func daysAgo(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        }
        let seeded: [SocializationRecord] = [
            .init(
                id: UUID(), experienceContentId: "soc.sounds.vacuum_low",
                label: "Vacuum at low volume/distance", category: .sounds,
                effectiveDate: daysAgo(2), context: "Two rooms away",
                response: .curious, note: nil, revision: 1, recordedByName: "Sarah"
            ),
            .init(
                id: UUID(), experienceContentId: "soc.surfaces.grass",
                label: "Grass", category: .surfaces,
                effectiveDate: daysAgo(4), context: nil,
                response: .relaxed, note: nil, revision: 1, recordedByName: "Nic"
            ),
            .init(
                id: UUID(), experienceContentId: "soc.people.calm_adult_visitor",
                label: "Calm adult visitor", category: .people,
                effectiveDate: daysAgo(9), context: "Sat down before saying hello",
                response: .hesitant, note: nil, revision: 1, recordedByName: "Nic"
            ),
        ]
        return SocializationStore(
            service: InMemorySocializationService(actorName: "You", seeded: seeded),
            petId: UUID(),
            petName: "Maple"
        )
    }
}
