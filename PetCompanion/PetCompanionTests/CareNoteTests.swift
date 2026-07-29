import XCTest
@testable import PetCompanion

/// Care notes store behavior (F10 / US-077) including Scenario H photo attach.
///
/// Failures never look like success, queued offline writes are a distinct
/// outcome, and CareNoteError never leaks raw server text.
@MainActor
final class CareNoteTests: XCTestCase {
    private let petId = UUID()

    private func makeStore(service: any CareNoteService) -> CareNoteStore {
        CareNoteStore(service: service, petId: petId, petName: "Maple")
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

    func testCareNoteErrorNeverLeaksServerMessage() {
        let error = CareNoteError(code: "SOME_NEW_CODE", message: "raw postgres detail")
        XCTAssertEqual(error, .unexpected(code: "SOME_NEW_CODE"))
        XCTAssertEqual(error.errorDescription, "Something went wrong. Try again.")
        XCTAssertFalse(error.errorDescription?.contains("postgres") == true)
    }

    func testSchemaCacheMissMapsToCalmCopy() {
        let raw = "Could not find the table 'public.care_notes' in the schema cache"
        XCTAssertTrue(CareNoteError.looksLikeMissingSchema(raw))
        XCTAssertEqual(
            CareNoteError(code: "PGRST205", message: raw),
            .recordsUnavailable
        )
    }

    func testCreateNoteSucceedsAndReloads() async {
        let service = InMemoryCareNoteService()
        let store = makeStore(service: service)

        let saved = await store.create(
            CareNoteDraft(
                kind: .generalNote,
                title: "Soft stool",
                body: "Tried new kibble — monitoring.",
                effectiveDate: Date(),
                provenance: .ownerEntered,
                providerId: nil
            )
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes[0].title, "Soft stool")
        XCTAssertEqual(store.confirmationMessage, "Saved Soft stool.")
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.queuedMessage)
    }

    func testCreateWithoutTitleUsesGenericConfirmation() async {
        let service = InMemoryCareNoteService()
        let store = makeStore(service: service)

        _ = await store.create(
            CareNoteDraft(
                kind: .generalNote,
                title: "  ",
                body: "Observation only",
                effectiveDate: Date(),
                provenance: .ownerEntered,
                providerId: nil
            )
        )

        XCTAssertEqual(store.notes.count, 1)
        XCTAssertNil(store.notes[0].title)
        XCTAssertEqual(store.confirmationMessage, "Saved note.")
    }

    func testCreateDocumentRequiresTitle() async {
        let service = InMemoryCareNoteService()
        let store = makeStore(service: service)

        let saved = await store.create(
            CareNoteDraft(
                kind: .document,
                title: "",
                body: "Clinic paperwork",
                effectiveDate: Date(),
                provenance: .ownerEntered,
                providerId: nil
            )
        )

        XCTAssertFalse(saved)
        XCTAssertEqual(store.errorMessage, CareNoteError.invalidEntry.errorDescription)
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testFailedSaveSurfacesErrorWithoutConfirmation() async {
        let service = FailingCareNoteService()
        service.error = CareNoteError.invalidEntry
        let store = makeStore(service: service)

        let saved = await store.create(CareNoteDraft.blank())

        XCTAssertFalse(saved)
        XCTAssertEqual(store.errorMessage, CareNoteError.invalidEntry.errorDescription)
        XCTAssertNil(store.confirmationMessage)
        assertExactlyOneOutcome(
            error: store.errorMessage,
            queued: store.queuedMessage,
            confirmation: store.confirmationMessage
        )
    }

    func testQueuedWriteIsDistinctFromConfirmedSuccess() async {
        let service = FailingCareNoteService()
        service.error = OfflineMutationError.queued(operationId: UUID())
        let store = makeStore(service: service)

        var draft = CareNoteDraft.blank()
        draft.body = "Queued observation"
        let saved = await store.create(draft)

        XCTAssertTrue(saved, "Queued acceptance is real — the caller may dismiss.")
        XCTAssertNotNil(store.queuedMessage)
        XCTAssertNil(store.confirmationMessage)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.notes.isEmpty, "No optimistic placeholder row.")
    }

    func testPhotoFailureKeepsNoteSaved() async {
        let service = PhotoFailingCareNoteService()
        let store = makeStore(service: service)

        var draft = CareNoteDraft.blank()
        draft.body = "Observation with photo"
        draft.photoJPEGData = Data(repeating: 0xFF, count: 32)

        let saved = await store.create(draft)

        XCTAssertTrue(saved, "Scenario H: text save succeeds even when photo fails.")
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes[0].body, "Observation with photo")
        XCTAssertEqual(store.errorMessage, CareNoteError.photoUploadFailed.errorDescription)
        XCTAssertEqual(
            store.errorMessage,
            "The note was saved, but the attachment didn’t upload. You can try again."
        )
        XCTAssertNil(store.confirmationMessage)
    }

    func testEditBumpsViaServiceAndReloads() async {
        let service = InMemoryCareNoteService()
        let existing = CareNote(
            id: UUID(),
            kind: .generalNote,
            title: "Old",
            body: "First version",
            effectiveDate: Date(),
            provenance: .ownerEntered,
            providerId: nil,
            mediaRefs: [],
            media: [],
            revision: 1,
            recordedByName: "You"
        )
        service.seed(existing, petId: petId)
        let store = makeStore(service: service)
        await store.load()

        var draft = CareNoteDraft.from(existing)
        draft.body = "Updated observation"
        let ok = await store.edit(existing, draft: draft)

        XCTAssertTrue(ok)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes[0].body, "Updated observation")
        XCTAssertEqual(store.notes[0].revision, 2)
    }

    func testRemoveClearsFromList() async {
        let service = InMemoryCareNoteService()
        let existing = CareNote(
            id: UUID(),
            kind: .generalNote,
            title: nil,
            body: "To remove",
            effectiveDate: Date(),
            provenance: .ownerEntered,
            providerId: nil,
            mediaRefs: [],
            media: [],
            revision: 1,
            recordedByName: "You"
        )
        service.seed(existing, petId: petId)
        let store = makeStore(service: service)
        await store.load()
        XCTAssertEqual(store.notes.count, 1)

        let ok = await store.remove(existing)
        XCTAssertTrue(ok)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(store.confirmationMessage, "Removed.")
    }

    func testRemovePhotoDetachesWithoutRemovingNote() async {
        let service = InMemoryCareNoteService()
        let mediaId = UUID()
        let media = CareNoteMedia(
            id: mediaId,
            storageBucket: "household-media",
            storagePath: "h/\(mediaId)",
            mimeType: "image/jpeg",
            byteSize: 100,
            captureTime: nil,
            status: .available
        )
        let existing = CareNote(
            id: UUID(),
            kind: .document,
            title: "Vaccine card",
            body: "From clinic",
            effectiveDate: Date(),
            provenance: .professionalInstruction,
            providerId: nil,
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
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertTrue(store.notes[0].media.isEmpty)
        XCTAssertTrue(store.notes[0].mediaRefs.isEmpty)
        XCTAssertEqual(
            store.confirmationMessage,
            "Attachment removed from this note. The copy on your device is unchanged."
        )
    }

    func testPDFAttachmentSucceedsForDocumentNote() async {
        let service = InMemoryCareNoteService()
        let store = makeStore(service: service)
        let pdf = Data("%PDF-1.4 test".utf8)

        var draft = CareNoteDraft(
            kind: .document,
            title: "Vaccine card",
            body: "From clinic",
            effectiveDate: Date(),
            provenance: .ownerEntered,
            providerId: nil
        )
        draft.pendingAttachment = CareNotePendingAttachment(
            data: pdf,
            mimeType: "application/pdf",
            captureTime: nil,
            displayName: "card.pdf"
        )

        let saved = await store.create(draft)

        XCTAssertTrue(saved)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes[0].media.count, 1)
        XCTAssertEqual(store.notes[0].media[0].mimeType, "application/pdf")
        XCTAssertEqual(store.notes[0].media[0].status, .available)
        XCTAssertEqual(store.confirmationMessage, "Saved Vaccine card.")
        XCTAssertNil(store.errorMessage)
    }

    func testAttachmentLimitsRejectPDFAboveTenMegabytes() async {
        XCTAssertFalse(
            CareNoteAttachmentLimits.isAllowed("application/msword")
        )
        XCTAssertTrue(CareNoteAttachmentLimits.isAllowed("application/pdf"))
        XCTAssertTrue(CareNoteAttachmentLimits.isAllowed("image/jpeg"))
        XCTAssertEqual(CareNoteAttachmentLimits.maxBytes, 10_485_760)
        XCTAssertEqual(
            CareNoteAttachmentLimits.honestSizeCopy,
            "Attachments must be 10 MB or smaller."
        )
    }
}

@MainActor
private final class FailingCareNoteService: CareNoteService {
    var error: Error = CareNoteError.unexpected(code: "TEST")

    func loadNotes(petId: UUID) async throws -> [CareNote] {
        throw error
    }

    func createNote(_ draft: CareNoteDraft, petId: UUID) async throws -> UUID {
        throw error
    }

    func editNote(
        noteId: UUID,
        expectedRevision: Int,
        draft: CareNoteDraft
    ) async throws {
        throw error
    }

    func removeNote(noteId: UUID) async throws {
        throw error
    }

    func prepareCareNoteMedia(
        noteId: UUID,
        mediaId: UUID,
        data: Data,
        mimeType: String,
        captureTime: Date?
    ) async throws -> CareNoteMediaUploadTarget {
        throw error
    }

    func uploadCareNoteMedia(_ target: CareNoteMediaUploadTarget, data: Data) async throws {
        throw error
    }

    func completeCareNoteMedia(mediaId: UUID, byteSize: Int) async throws {
        throw error
    }

    func failCareNoteMedia(mediaId: UUID) async throws {}

    func removeCareNoteMedia(mediaId: UUID) async throws {
        throw error
    }

    func downloadCareNoteMedia(_ media: CareNoteMedia) async throws -> Data {
        throw error
    }
}

/// Text create succeeds; photo prepare/upload fails (Scenario H).
@MainActor
private final class PhotoFailingCareNoteService: CareNoteService {
    private let inner = InMemoryCareNoteService()

    func loadNotes(petId: UUID) async throws -> [CareNote] {
        try await inner.loadNotes(petId: petId)
    }

    func createNote(_ draft: CareNoteDraft, petId: UUID) async throws -> UUID {
        try await inner.createNote(draft, petId: petId)
    }

    func editNote(
        noteId: UUID,
        expectedRevision: Int,
        draft: CareNoteDraft
    ) async throws {
        try await inner.editNote(noteId: noteId, expectedRevision: expectedRevision, draft: draft)
    }

    func removeNote(noteId: UUID) async throws {
        try await inner.removeNote(noteId: noteId)
    }

    func prepareCareNoteMedia(
        noteId: UUID,
        mediaId: UUID,
        data: Data,
        mimeType: String,
        captureTime: Date?
    ) async throws -> CareNoteMediaUploadTarget {
        throw CareNoteError.photoUploadFailed
    }

    func uploadCareNoteMedia(_ target: CareNoteMediaUploadTarget, data: Data) async throws {
        throw CareNoteError.photoUploadFailed
    }

    func completeCareNoteMedia(mediaId: UUID, byteSize: Int) async throws {
        throw CareNoteError.photoUploadFailed
    }

    func failCareNoteMedia(mediaId: UUID) async throws {}

    func removeCareNoteMedia(mediaId: UUID) async throws {
        try await inner.removeCareNoteMedia(mediaId: mediaId)
    }

    func downloadCareNoteMedia(_ media: CareNoteMedia) async throws -> Data {
        try await inner.downloadCareNoteMedia(media)
    }
}
