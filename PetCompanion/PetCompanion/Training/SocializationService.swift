import Foundation

/// Reads and writes for the socialization passport (F09).
///
/// Reads go straight to the RLS-protected tables; every mutation goes through
/// the single write-path edge function, as with every other household-owned
/// record in this app.
@MainActor
protocol SocializationService: AnyObject {
    func load(petId: UUID) async throws -> SocializationSnapshot
    func record(_ draft: SocializationDraft, petId: UUID) async throws
    func editResponse(
        recordId: UUID,
        expectedRevision: Int,
        response: SocializationResponse,
        note: String?
    ) async throws
    func remove(recordId: UUID) async throws
    func setExclusion(
        petId: UUID,
        category: SocializationCategory?,
        experienceContentId: String?,
        reason: SocializationExclusionReason
    ) async throws
    func clearExclusion(exclusionId: UUID) async throws
}

struct SocializationSnapshot: Equatable {
    var records: [SocializationRecord] = []
    var exclusions: [SocializationExclusion] = []

    static func == (lhs: SocializationSnapshot, rhs: SocializationSnapshot) -> Bool {
        lhs.records == rhs.records && lhs.exclusions == rhs.exclusions
    }
}

/// TR-08's form, resolved. Exactly one of `experience` / `customLabel` is set.
struct SocializationDraft {
    var experience: SocializationExperience?
    var customLabel: String?
    var category: SocializationCategory
    var effectiveDate: Date
    var context: String
    var response: SocializationResponse
    var note: String
}

enum SocializationServiceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}

/// In-memory implementation for mock builds and previews. It mirrors the
/// server's rules that the UI depends on — a catalogue experience takes its
/// category from the catalogue, removal is a tombstone, and re-marking an
/// already-excluded scope replaces the live decision rather than stacking.
@MainActor
final class InMemorySocializationService: SocializationService {
    private var records: [UUID: SocializationRecord] = [:]
    private var removed: Set<UUID> = []
    private var exclusions: [UUID: SocializationExclusion] = [:]
    private let actorName: String

    init(actorName: String = "You", seeded: [SocializationRecord] = []) {
        self.actorName = actorName
        for record in seeded { records[record.id] = record }
    }

    func load(petId: UUID) async throws -> SocializationSnapshot {
        SocializationSnapshot(
            records: records.values
                .filter { !removed.contains($0.id) }
                .sorted { $0.effectiveDate > $1.effectiveDate },
            exclusions: Array(exclusions.values)
        )
    }

    func record(_ draft: SocializationDraft, petId: UUID) async throws {
        let id = UUID()
        records[id] = SocializationRecord(
            id: id,
            experienceContentId: draft.experience?.contentId,
            label: draft.experience?.label ?? (draft.customLabel ?? ""),
            category: draft.experience?.category ?? draft.category,
            effectiveDate: draft.effectiveDate,
            context: draft.context.isEmpty ? nil : draft.context,
            response: draft.response,
            note: draft.note.isEmpty ? nil : draft.note,
            revision: 1,
            recordedByName: actorName
        )
    }

    func editResponse(
        recordId: UUID,
        expectedRevision: Int,
        response: SocializationResponse,
        note: String?
    ) async throws {
        guard let existing = records[recordId] else {
            throw SocializationServiceError.unavailable("That experience is no longer in the passport.")
        }
        guard existing.revision == expectedRevision else {
            throw SocializationServiceError.unavailable("This record changed since you opened it. Reopen it to see the latest.")
        }
        records[recordId] = SocializationRecord(
            id: existing.id,
            experienceContentId: existing.experienceContentId,
            label: existing.label,
            category: existing.category,
            effectiveDate: existing.effectiveDate,
            context: existing.context,
            response: response,
            note: note,
            revision: existing.revision + 1,
            recordedByName: existing.recordedByName
        )
    }

    func remove(recordId: UUID) async throws {
        removed.insert(recordId)
    }

    func setExclusion(
        petId: UUID,
        category: SocializationCategory?,
        experienceContentId: String?,
        reason: SocializationExclusionReason
    ) async throws {
        if let existing = exclusions.values.first(where: {
            $0.isActive && $0.category == category && $0.experienceContentId == experienceContentId
        }) {
            exclusions[existing.id] = SocializationExclusion(
                id: existing.id,
                category: category,
                experienceContentId: experienceContentId,
                reason: reason,
                isActive: true
            )
            return
        }
        let id = UUID()
        exclusions[id] = SocializationExclusion(
            id: id,
            category: category,
            experienceContentId: experienceContentId,
            reason: reason,
            isActive: true
        )
    }

    func clearExclusion(exclusionId: UUID) async throws {
        guard let existing = exclusions[exclusionId] else { return }
        exclusions[exclusionId] = SocializationExclusion(
            id: existing.id,
            category: existing.category,
            experienceContentId: existing.experienceContentId,
            reason: existing.reason,
            isActive: false
        )
    }
}
