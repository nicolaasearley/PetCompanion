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
        await perform("Saved to \(petName)'s passport.") {
            try await self.service.record(draft, petId: self.petId)
        }
    }

    func editResponse(
        record: SocializationRecord,
        response: SocializationResponse,
        note: String?
    ) async -> Bool {
        await perform("Updated.") {
            try await self.service.editResponse(
                recordId: record.id,
                expectedRevision: record.revision,
                response: response,
                note: note
            )
        }
    }

    func remove(record: SocializationRecord) async -> Bool {
        await perform("Removed from the passport.") {
            try await self.service.remove(recordId: record.id)
        }
    }

    func exclude(
        category: SocializationCategory? = nil,
        experienceContentId: String? = nil,
        reason: SocializationExclusionReason
    ) async -> Bool {
        await perform("Won't be suggested. You can undo this any time.") {
            try await self.service.setExclusion(
                petId: self.petId,
                category: category,
                experienceContentId: experienceContentId,
                reason: reason
            )
        }
    }

    func clear(exclusion: SocializationExclusion) async -> Bool {
        await perform("Back in the suggestions.") {
            try await self.service.clearExclusion(exclusionId: exclusion.id)
        }
    }

    private func perform(_ confirmation: String, _ work: @escaping () async throws -> Void) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await work()
            await load()
            confirmationMessage = confirmation
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
