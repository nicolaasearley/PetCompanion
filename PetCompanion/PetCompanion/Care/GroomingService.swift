import Foundation

/// Reads and writes for grooming history (F10 / US-076).
///
/// Separate from `CareService` so Vaccinations / Notes WIP can continue without
/// merge collisions — same isolation pattern as `VaccinationService`.
@MainActor
protocol GroomingService: AnyObject {
    func loadGrooming(petId: UUID) async throws -> [GroomingRecord]
    func recordGrooming(_ draft: GroomingDraft, petId: UUID) async throws
    func editGrooming(
        groomingId: UUID,
        expectedRevision: Int,
        draft: GroomingDraft
    ) async throws
    func removeGrooming(groomingId: UUID) async throws
}

enum GroomingServiceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}

/// In-memory implementation for mock builds and previews.
@MainActor
final class InMemoryGroomingService: GroomingService {
    private var records: [UUID: GroomingRecord] = [:]
    private var petOf: [UUID: UUID] = [:]
    private var removed: Set<UUID> = []
    private let actorName: String

    init(
        actorName: String = "You",
        seeded: [(petId: UUID, record: GroomingRecord)] = []
    ) {
        self.actorName = actorName
        for entry in seeded {
            records[entry.record.id] = entry.record
            petOf[entry.record.id] = entry.petId
        }
    }

    func seed(_ record: GroomingRecord, petId: UUID) {
        records[record.id] = record
        petOf[record.id] = petId
    }

    func loadGrooming(petId: UUID) async throws -> [GroomingRecord] {
        records.values
            .filter { petOf[$0.id] == petId && !removed.contains($0.id) }
            .sorted {
                if $0.effectiveDate != $1.effectiveDate {
                    return $0.effectiveDate > $1.effectiveDate
                }
                return $0.activityType.displayName.localizedCaseInsensitiveCompare(
                    $1.activityType.displayName
                ) == .orderedAscending
            }
    }

    func recordGrooming(_ draft: GroomingDraft, petId: UUID) async throws {
        let id = UUID()
        records[id] = GroomingRecord(
            id: id,
            activityType: draft.activityType,
            effectiveDate: draft.effectiveDate,
            nextDueDate: draft.includeNextDue ? draft.nextDueDate : nil,
            note: blankToNil(draft.note),
            revision: 1,
            recordedByName: actorName
        )
        petOf[id] = petId
    }

    func editGrooming(
        groomingId: UUID,
        expectedRevision: Int,
        draft: GroomingDraft
    ) async throws {
        guard let existing = records[groomingId], !removed.contains(groomingId) else {
            throw GroomingServiceError.unavailable("That grooming entry is no longer available.")
        }
        guard existing.revision == expectedRevision else {
            throw GroomingError.changedElsewhere
        }
        records[groomingId] = GroomingRecord(
            id: existing.id,
            activityType: draft.activityType,
            effectiveDate: draft.effectiveDate,
            nextDueDate: draft.includeNextDue ? draft.nextDueDate : nil,
            note: blankToNil(draft.note),
            revision: existing.revision + 1,
            recordedByName: existing.recordedByName
        )
    }

    func removeGrooming(groomingId: UUID) async throws {
        removed.insert(groomingId)
    }

    private func blankToNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
