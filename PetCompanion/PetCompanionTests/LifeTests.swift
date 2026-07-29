import XCTest
@testable import PetCompanion

/// Life milestones store behavior (F12 / US-090 / LF-01–LF-03) including
/// Scenario H photo attach (text survives upload failure).
@MainActor
final class LifeTests: XCTestCase {
    private let petId = UUID()

    private func makeStore(service: any LifeService) -> LifeStore {
        LifeStore(service: service, petId: petId, petName: "Maple")
    }

    private func assertExactlyOneOutcome(
        error: String?,
        queued: String?,
        confirmation: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let set = [error, queued, confirmation].compactMap { $0 }
        XCTAssertEqual(
            set.count, 1,
            "Expected exactly one outcome banner, found \(set.count): \(set)",
            file: file, line: line
        )
    }

    private func sampleJPEG() -> Data {
        // Minimal valid 1x1 JPEG.
        Data(base64Encoded:
            "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAGfAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAQUCf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQMBAT8Bf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQIBAT8Bf//Z"
        )!
    }

    // MARK: - LifeError mapping

    func testLifeErrorNeverLeaksServerMessageForUnknownCodes() {
        let error = LifeError(code: "SOME_NEW_CODE", message: "raw postgres detail")
        XCTAssertEqual(error, .unexpected(code: "SOME_NEW_CODE"))
        XCTAssertEqual(error.errorDescription, "Something went wrong. Try again.")
        XCTAssertFalse(error.errorDescription?.contains("postgres") == true)
    }

    func testLifeErrorMapsRevisionConflict() {
        let error = LifeError(code: "REVISION_CONFLICT", message: "stale")
        XCTAssertEqual(error, .changedElsewhere)
        XCTAssertTrue(error.errorDescription?.contains("changed") == true)
    }

    func testSchemaCacheMissMapsToCalmBackendCopy() {
        let raw = "Could not find the table 'public.milestones' in the schema cache"
        XCTAssertTrue(LifeError.looksLikeMissingSchema(raw))
        XCTAssertEqual(
            LifeError(code: "PGRST205", message: raw),
            .recordsUnavailable
        )
        XCTAssertEqual(
            LifeError.displayMessage(for: LifeServiceError.unavailable(raw)),
            LifeError.recordsUnavailable.errorDescription
        )
    }

    func testLoadSurfacesCalmCopyForSchemaCacheMiss() async {
        let service = FailingLifeService()
        service.loadError = LifeServiceError.unavailable(
            "Could not find the table 'public.milestones' in the schema cache"
        )
        let store = makeStore(service: service)
        await store.load()
        XCTAssertEqual(store.errorMessage, LifeError.recordsUnavailable.errorDescription)
        XCTAssertTrue(store.milestones.isEmpty)
    }

    // MARK: - Create / edit / remove

    func testCreateMilestoneSucceedsAndReloads() async {
        let service = InMemoryLifeService()
        let store = makeStore(service: service)

        let saved = await store.create(
            MilestoneDraft(title: "First day home", effectiveDate: Date(), note: "Welcome")
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(store.milestones.count, 1)
        XCTAssertEqual(store.milestones[0].title, "First day home")
        XCTAssertEqual(store.confirmationMessage, "Saved to Maple's story.")
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.queuedMessage)
    }

    func testCreateWithPhotoAttachesAfterTextSave() async {
        let service = InMemoryLifeService()
        let store = makeStore(service: service)
        var draft = MilestoneDraft(title: "First walk", effectiveDate: Date(), note: "")
        draft.photoJPEGData = sampleJPEG()

        let saved = await store.create(draft)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.milestones.count, 1)
        XCTAssertEqual(store.milestones[0].media.count, 1)
        XCTAssertEqual(store.milestones[0].media[0].status, .available)
        XCTAssertEqual(store.confirmationMessage, "Saved to Maple's story.")
    }

    func testPhotoFailureKeepsMilestoneText() async {
        let service = FailingLifeService()
        service.photoUploadFails = true
        let store = makeStore(service: service)
        var draft = MilestoneDraft(title: "First swim", effectiveDate: Date(), note: "cold")
        draft.photoJPEGData = sampleJPEG()

        let saved = await store.create(draft)
        XCTAssertTrue(saved, "Text save must succeed even when photo fails")
        XCTAssertEqual(store.errorMessage, LifeError.photoUploadFailed.errorDescription)
        XCTAssertEqual(store.milestones.count, 1)
        XCTAssertEqual(store.milestones[0].title, "First swim")
    }

    func testFailedCreateSurfacesErrorWithoutConfirmation() async {
        let service = FailingLifeService()
        service.writeError = LifeError.invalidEntry
        let store = makeStore(service: service)

        let saved = await store.create(
            MilestoneDraft(title: "First day home", effectiveDate: Date(), note: "")
        )

        XCTAssertFalse(saved)
        XCTAssertEqual(store.errorMessage, LifeError.invalidEntry.errorDescription)
        XCTAssertNil(store.confirmationMessage)
        assertExactlyOneOutcome(
            error: store.errorMessage,
            queued: store.queuedMessage,
            confirmation: store.confirmationMessage
        )
    }

    func testQueuedWriteIsDistinctFromConfirmedSuccess() async {
        let service = FailingLifeService()
        service.writeError = OfflineMutationError.queued(operationId: UUID())
        let store = makeStore(service: service)

        let saved = await store.create(
            MilestoneDraft(title: "First day home", effectiveDate: Date(), note: "")
        )

        XCTAssertTrue(saved, "Queued acceptance is real — the caller may dismiss.")
        XCTAssertNotNil(store.queuedMessage)
        XCTAssertNil(store.confirmationMessage)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.milestones.isEmpty, "No optimistic placeholder row.")
    }

    func testEditRequiresMatchingRevision() async {
        let service = InMemoryLifeService()
        let existing = Milestone(
            id: UUID(),
            title: "First walk",
            effectiveDate: Date(),
            note: nil,
            mediaRefs: [],
            media: [],
            revision: 2,
            recordedByName: "You"
        )
        service.seed(existing, petId: petId)
        let store = makeStore(service: service)
        await store.load()

        let stale = Milestone(
            id: existing.id,
            title: existing.title,
            effectiveDate: existing.effectiveDate,
            note: existing.note,
            mediaRefs: [],
            media: [],
            revision: 1,
            recordedByName: existing.recordedByName
        )
        let ok = await store.edit(
            stale,
            draft: MilestoneDraft(title: "First long walk", effectiveDate: Date(), note: "")
        )
        XCTAssertFalse(ok)
        XCTAssertEqual(store.errorMessage, LifeError.changedElsewhere.errorDescription)
    }

    func testRemoveClearsFromTimeline() async {
        let service = InMemoryLifeService()
        let existing = Milestone(
            id: UUID(),
            title: "First swim",
            effectiveDate: Date(),
            note: nil,
            mediaRefs: [],
            media: [],
            revision: 1,
            recordedByName: "You"
        )
        service.seed(existing, petId: petId)
        let store = makeStore(service: service)
        await store.load()
        XCTAssertEqual(store.milestones.count, 1)

        let ok = await store.remove(existing)
        XCTAssertTrue(ok)
        XCTAssertTrue(store.milestones.isEmpty)
        XCTAssertEqual(store.confirmationMessage, "Removed from the timeline.")
    }

    func testRemovePhotoDetachesWithoutDroppingMilestone() async {
        let service = InMemoryLifeService()
        let mediaId = UUID()
        let media = MilestoneMedia(
            id: mediaId,
            storageBucket: "household-media",
            storagePath: "x/\(mediaId)",
            mimeType: "image/jpeg",
            byteSize: 12,
            captureTime: nil,
            status: .available
        )
        let existing = Milestone(
            id: UUID(),
            title: "With photo",
            effectiveDate: Date(),
            note: nil,
            mediaRefs: [mediaId],
            media: [media],
            revision: 1,
            recordedByName: "You"
        )
        service.seed(existing, petId: petId)
        let store = makeStore(service: service)
        await store.load()

        let ok = await store.removePhoto(media)
        XCTAssertTrue(ok)
        XCTAssertEqual(store.milestones.count, 1)
        XCTAssertTrue(store.milestones[0].media.isEmpty)
        XCTAssertTrue(store.confirmationMessage?.contains("device") == true)
    }

    func testTimelineSectionsGroupByMonthNewestFirst() async {
        let service = InMemoryLifeService()
        let calendar = Calendar(identifier: .gregorian)
        var jan = DateComponents()
        jan.year = 2026
        jan.month = 1
        jan.day = 15
        var mar = DateComponents()
        mar.year = 2026
        mar.month = 3
        mar.day = 2
        let older = Milestone(
            id: UUID(), title: "January", effectiveDate: calendar.date(from: jan)!,
            note: nil, mediaRefs: [], media: [], revision: 1, recordedByName: nil
        )
        let newer = Milestone(
            id: UUID(), title: "March", effectiveDate: calendar.date(from: mar)!,
            note: nil, mediaRefs: [], media: [], revision: 1, recordedByName: nil
        )
        service.seed(older, petId: petId)
        service.seed(newer, petId: petId)

        let store = LifeStore(
            service: service, petId: petId, petName: "Maple", calendar: calendar
        )
        await store.load()

        XCTAssertEqual(store.milestones.map(\.title), ["March", "January"])
        XCTAssertEqual(store.timelineSections.count, 2)
        XCTAssertEqual(store.timelineSections[0].milestones.map(\.title), ["March"])
        XCTAssertEqual(store.timelineSections[1].milestones.map(\.title), ["January"])
    }

    func testBlankTitleRejectedByInMemoryService() async {
        let service = InMemoryLifeService()
        do {
            _ = try await service.createMilestone(
                MilestoneDraft(title: "   ", effectiveDate: Date(), note: ""),
                petId: petId
            )
            XCTFail("Expected invalidEntry")
        } catch LifeError.invalidEntry {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

@MainActor
private final class FailingLifeService: LifeService {
    var loadError: Error?
    var writeError: Error?
    var photoUploadFails = false
    private var created: [Milestone] = []

    func loadMilestones(petId: UUID) async throws -> [Milestone] {
        if let loadError { throw loadError }
        return created
    }

    func createMilestone(_ draft: MilestoneDraft, petId: UUID) async throws -> UUID {
        if let writeError { throw writeError }
        let id = UUID()
        created.append(
            Milestone(
                id: id,
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                effectiveDate: draft.effectiveDate,
                note: draft.note.isEmpty ? nil : draft.note,
                mediaRefs: [],
                media: [],
                revision: 1,
                recordedByName: nil
            )
        )
        return id
    }

    func editMilestone(
        milestoneId: UUID,
        expectedRevision: Int,
        draft: MilestoneDraft
    ) async throws {
        if let writeError { throw writeError }
    }

    func removeMilestone(milestoneId: UUID) async throws {
        if let writeError { throw writeError }
    }

    func prepareMilestoneMedia(
        milestoneId: UUID,
        mediaId: UUID,
        jpegData: Data,
        captureTime: Date?
    ) async throws -> MilestoneMediaUploadTarget {
        if photoUploadFails {
            throw LifeError.photoUploadFailed
        }
        if let writeError { throw writeError }
        return MilestoneMediaUploadTarget(
            mediaId: mediaId,
            bucket: "household-media",
            path: "x/\(mediaId)",
            upsert: true,
            mimeType: "image/jpeg"
        )
    }

    func uploadMilestoneMedia(_ target: MilestoneMediaUploadTarget, data: Data) async throws {
        if photoUploadFails { throw LifeError.photoUploadFailed }
    }

    func completeMilestoneMedia(mediaId: UUID, byteSize: Int) async throws {
        if photoUploadFails { throw LifeError.photoUploadFailed }
    }

    func failMilestoneMedia(mediaId: UUID) async throws {}

    func removeMilestoneMedia(mediaId: UUID) async throws {
        if let writeError { throw writeError }
    }

    func downloadMilestoneMedia(_ media: MilestoneMedia) async throws -> Data {
        Data()
    }
}
