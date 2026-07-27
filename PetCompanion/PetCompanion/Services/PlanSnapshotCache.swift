import Foundation

/// Durable last-known-good plan cache. A transient outage can therefore
/// show the household's most recent plan in a visibly stale, read-only
/// state instead of a blank screen.
@MainActor
final class PlanSnapshotCache {
    private let directory: URL?
    private let encoder: JSONEncoder

    init(baseDirectory: URL? = nil) {
        directory = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("PetCompanion/PlanCache", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    func store(_ snapshot: PlanSnapshot) {
        guard let url = fileURL(for: snapshot.plan.petId) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            // Cache failure never invalidates an authoritative response.
        }
    }

    func load(petId: UUID) -> PlanSnapshot? {
        guard let url = fileURL(for: petId),
              let data = try? Data(contentsOf: url),
              var snapshot = try? SupabaseCoding.restDecoder.decode(PlanSnapshot.self, from: data),
              snapshot.plan.petId == petId
        else { return nil }
        for index in snapshot.items.indices {
            snapshot.items[index].displayState = .stale
        }
        snapshot.servedFromCacheAt = .now
        return snapshot
    }

    private func fileURL(for petId: UUID) -> URL? {
        directory?.appendingPathComponent("\(petId.uuidString).json")
    }
}
