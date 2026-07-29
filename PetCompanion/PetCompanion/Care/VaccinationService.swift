import Foundation

/// Reads and writes for vaccination history (F10 / US-070).
///
/// Separate from `CareService` so medications WIP can continue without merge
/// collisions — same isolation pattern as `SocializationService`.
@MainActor
protocol VaccinationService: AnyObject {
    func loadVaccinations(petId: UUID) async throws -> [VaccinationRecord]
    func recordVaccination(_ draft: VaccinationDraft, petId: UUID) async throws
    func editVaccination(
        vaccinationId: UUID,
        expectedRevision: Int,
        draft: VaccinationDraft
    ) async throws
    func removeVaccination(vaccinationId: UUID) async throws
}

enum VaccinationServiceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}

/// In-memory implementation for mock builds and previews.
@MainActor
final class InMemoryVaccinationService: VaccinationService {
    private var records: [UUID: VaccinationRecord] = [:]
    private var petOf: [UUID: UUID] = [:]
    private var removed: Set<UUID> = []
    private let actorName: String

    init(
        actorName: String = "You",
        seeded: [(petId: UUID, record: VaccinationRecord)] = []
    ) {
        self.actorName = actorName
        for entry in seeded {
            records[entry.record.id] = entry.record
            petOf[entry.record.id] = entry.petId
        }
    }

    func seed(_ record: VaccinationRecord, petId: UUID) {
        records[record.id] = record
        petOf[record.id] = petId
    }

    func loadVaccinations(petId: UUID) async throws -> [VaccinationRecord] {
        records.values
            .filter { petOf[$0.id] == petId && !removed.contains($0.id) }
            .sorted {
                if $0.effectiveDate != $1.effectiveDate {
                    return $0.effectiveDate > $1.effectiveDate
                }
                return $0.vaccineName.localizedCaseInsensitiveCompare($1.vaccineName)
                    == .orderedAscending
            }
    }

    func recordVaccination(_ draft: VaccinationDraft, petId: UUID) async throws {
        let name = draft.vaccineName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw VaccinationError.invalidEntry
        }
        let id = UUID()
        records[id] = VaccinationRecord(
            id: id,
            vaccineName: name,
            effectiveDate: draft.effectiveDate,
            nextDueDate: draft.includeNextDue ? draft.nextDueDate : nil,
            provenance: draft.provenance,
            providerId: draft.providerId,
            note: blankToNil(draft.note),
            revision: 1,
            recordedByName: actorName
        )
        petOf[id] = petId
    }

    func editVaccination(
        vaccinationId: UUID,
        expectedRevision: Int,
        draft: VaccinationDraft
    ) async throws {
        guard let existing = records[vaccinationId], !removed.contains(vaccinationId) else {
            throw VaccinationServiceError.unavailable("That vaccination is no longer available.")
        }
        guard existing.revision == expectedRevision else {
            throw VaccinationError.changedElsewhere
        }
        let name = draft.vaccineName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw VaccinationError.invalidEntry
        }
        records[vaccinationId] = VaccinationRecord(
            id: existing.id,
            vaccineName: name,
            effectiveDate: draft.effectiveDate,
            nextDueDate: draft.includeNextDue ? draft.nextDueDate : nil,
            provenance: draft.provenance,
            providerId: draft.providerId,
            note: blankToNil(draft.note),
            revision: existing.revision + 1,
            recordedByName: existing.recordedByName
        )
    }

    func removeVaccination(vaccinationId: UUID) async throws {
        removed.insert(vaccinationId)
    }

    private func blankToNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
