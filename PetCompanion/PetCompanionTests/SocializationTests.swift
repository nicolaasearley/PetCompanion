import XCTest
@testable import PetCompanion

/// Coverage for the doc 22 §7 socialization client defects fixed in the
/// 2026-07-29 stabilization pass:
///
///   * a save failure is visible and actionable, and never leaves a stale
///     error sitting alongside a later success;
///   * "Remove from the passport" fails visibly and never removes the wrong
///     record, or a record at all, when the server refuses it;
///   * server codes map to calm copy — `SocializationError` — instead of a
///     raw validation string reaching the UI, and a code the client has no
///     specific copy for still never leaks the server's own text;
///   * a durably queued write (`OfflineMutationError.queued`) reads as
///     neither a confirmed success nor a failure.
///
/// Socialization shipped with no iOS tests at all (doc 22 §7); this file is
/// the first coverage of `SocializationStore`'s failure/recovery behavior.
@MainActor
final class SocializationTests: XCTestCase {
    private func makeDraft() -> SocializationDraft {
        SocializationDraft(
            experience: nil,
            customLabel: "The neighbour's wheelie bin",
            category: .sounds,
            effectiveDate: Date(),
            context: "",
            response: .curious,
            note: ""
        )
    }

    private func makeRecord(label: String, category: SocializationCategory) -> SocializationRecord {
        SocializationRecord(
            id: UUID(),
            experienceContentId: nil,
            label: label,
            category: category,
            effectiveDate: Date(),
            context: nil,
            response: .curious,
            note: nil,
            revision: 1,
            recordedByName: "You"
        )
    }

    private func makeStore(service: any SocializationService) -> SocializationStore {
        SocializationStore(service: service, petId: UUID(), petName: "Fable")
    }

    /// `SocializationStore.perform` must end every attempt with exactly one
    /// of `errorMessage`/`queuedMessage`/`confirmationMessage` set — never
    /// zero (a silent outcome) and never two at once (a contradiction, e.g.
    /// a stale success sitting behind a later error).
    private func assertExactlyOneOutcome(
        _ store: SocializationStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let set = [store.errorMessage, store.queuedMessage, store.confirmationMessage].compactMap { $0 }
        XCTAssertEqual(
            set.count, 1,
            "Expected exactly one outcome banner, found \(set.count): \(set)",
            file: file, line: line
        )
    }

    // MARK: - Failure visibility (doc 22 §7: "the error renders on the screen behind the sheet")

    func testFailedSaveSurfacesAnErrorAndNeverAFalseConfirmation() async {
        let service = FailingSocializationService()
        service.recordError = SocializationError.invalidEntry
        let store = makeStore(service: service)

        let saved = await store.record(makeDraft())

        XCTAssertFalse(saved, "A failed save must not report success to its caller.")
        XCTAssertEqual(store.errorMessage, SocializationError.invalidEntry.errorDescription)
        XCTAssertNil(store.confirmationMessage, "A failure must never also carry a stale or false confirmation.")
    }

    func testRecoveringFromAFailureClearsTheOldErrorAndConfirms() async {
        let service = FailingSocializationService()
        service.recordError = SocializationError.invalidEntry
        let store = makeStore(service: service)

        _ = await store.record(makeDraft())
        XCTAssertNotNil(store.errorMessage)

        service.recordError = nil
        let saved = await store.record(makeDraft())

        XCTAssertTrue(saved)
        XCTAssertNil(
            store.errorMessage,
            "A later successful save must clear the earlier failure, not leave both visible at once."
        )
        XCTAssertNil(store.queuedMessage)
        XCTAssertEqual(store.confirmationMessage, "Saved to \(store.petName)'s passport.")
        assertExactlyOneOutcome(store)
    }

    func testEachAttemptStartsWithoutSaving() async {
        let service = FailingSocializationService()
        let store = makeStore(service: service)
        XCTAssertFalse(store.isSaving)

        _ = await store.record(makeDraft())

        // `perform`'s `defer` must reset `isSaving` on every exit path, or
        // the sheet's Save button would stay disabled after a completed
        // attempt (success or failure) with no way to retry.
        XCTAssertFalse(store.isSaving)
    }

    // MARK: - Server validation strings never reach the UI verbatim (doc 22 §7)

    func testServerValidationStringsNeverReachTheStoreVerbatim() async {
        let rawServerText = "new row for relation \"socialization_records\" violates check constraint"
        let service = FailingSocializationService()
        // `RealSocializationService` is responsible for translating a raw
        // `WritePathError` into `SocializationError` before it ever reaches
        // the store (see `socializationError(from:)`); this locks in the
        // effect of that translation rather than re-deriving it inline.
        service.recordError = SocializationError(code: "VALIDATION_FAILED", message: rawServerText)
        let store = makeStore(service: service)

        _ = await store.record(makeDraft())

        XCTAssertNotEqual(store.errorMessage, rawServerText)
        XCTAssertEqual(
            store.errorMessage,
            "That entry doesn't look right — check the date and details, and try again."
        )
    }

    func testEveryAnticipatedServerCodeHasCalmCopy() {
        let mapped: [(String, SocializationError)] = [
            ("REVISION_CONFLICT", .changedElsewhere),
            ("FORBIDDEN", .notSignedIn),
            ("VALIDATION_FAILED", .invalidEntry),
        ]
        for (code, expected) in mapped {
            let error = SocializationError(code: code, message: "raw server text")
            XCTAssertEqual(error, expected, code)
            XCTAssertNotEqual(error.errorDescription, "raw server text", code)
            XCTAssertNotNil(error.errorDescription, code)
        }

        // A code the mapping doesn't recognize yet — whether that's a
        // genuinely new server code or internal idempotency machinery like
        // `IDEMPOTENCY_CONFLICT` — must never leak the server's own message.
        // `.unexpected` carries only the code, never the message, so this is
        // structural rather than something a future call site could get
        // wrong: there is no code path back to the raw text.
        let unknown = SocializationError(code: "SOME_FUTURE_CODE", message: "raw server text")
        XCTAssertEqual(unknown, .unexpected(code: "SOME_FUTURE_CODE"))
        XCTAssertEqual(unknown.errorDescription, "Something went wrong. Try again.")
        XCTAssertNotEqual(unknown.errorDescription, "raw server text")

        let idempotency = SocializationError(
            code: "IDEMPOTENCY_CONFLICT",
            message: "idempotency key reused with different command or payload"
        )
        XCTAssertEqual(idempotency, .unexpected(code: "IDEMPOTENCY_CONFLICT"))
        XCTAssertEqual(idempotency.errorDescription, "Something went wrong. Try again.")
        XCTAssertNotEqual(
            idempotency.errorDescription,
            "idempotency key reused with different command or payload"
        )
    }

    /// Distinct from `testServerValidationStringsNeverReachTheStoreVerbatim`:
    /// that test covers a *recognized* code (`VALIDATION_FAILED`) mapping to
    /// its specific copy. This covers a code the client has never heard of —
    /// the exact shape of an unanticipated Postgres/internal failure — going
    /// through the full store round trip, not just the `SocializationError`
    /// initializer in isolation.
    func testUnknownServerCodeNeverReachesErrorMessageVerbatim() async {
        let rawServerText = "duplicate key value violates unique constraint \"socialization_records_pkey\""
        let service = FailingSocializationService()
        service.recordError = SocializationError(code: "AN_UNMAPPED_CODE", message: rawServerText)
        let store = makeStore(service: service)

        let saved = await store.record(makeDraft())

        XCTAssertFalse(saved)
        XCTAssertNotEqual(store.errorMessage, rawServerText)
        XCTAssertEqual(store.errorMessage, "Something went wrong. Try again.")
    }

    // MARK: - Queued/offline writes (doc 22 §7: queued shown as an error, sheet stays open)

    /// A durable queue acceptance must read as neither of the store's other
    /// two outcomes: not `errorMessage` (nothing failed — nothing for the
    /// caregiver to fix or retry), and not `confirmationMessage` (nothing is
    /// server-confirmed yet — that would fabricate a save that hasn't
    /// happened). It still reports success to its caller so the sheet
    /// dismisses, because there is nothing left to correct in it.
    func testQueuedSaveIsDistinctFromBothSuccessAndFailure() async {
        let service = FailingSocializationService()
        service.recordError = OfflineMutationError.queued(operationId: UUID())
        let store = makeStore(service: service)

        let saved = await store.record(makeDraft())

        XCTAssertTrue(saved, "A durable queue acceptance must dismiss the sheet like a success, not block on it like a failure.")
        XCTAssertNil(store.errorMessage, "A queued write is not a failure.")
        XCTAssertNil(store.confirmationMessage, "A queued write must never be represented as a server-confirmed save.")
        XCTAssertEqual(
            store.queuedMessage,
            "Saved on this device. It'll appear in \(store.petName)'s passport once you're back online."
        )
        assertExactlyOneOutcome(store)
    }

    /// The same distinction on a different mutation, to confirm `perform`'s
    /// queued handling isn't accidentally specific to `record`.
    func testQueuedRemovalIsDistinctFromBothSuccessAndFailure() async {
        let record = makeRecord(label: "Doorbell", category: .sounds)
        let service = FailingSocializationService(seeded: [record])
        service.removeError = OfflineMutationError.queued(operationId: UUID())
        let store = makeStore(service: service)
        await store.load()

        let removed = await store.remove(record: record)

        XCTAssertTrue(removed)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.confirmationMessage)
        XCTAssertEqual(store.queuedMessage, "Saved on this device. It'll be removed once you're back online.")
        // No local snapshot fabrication either way: `remove` only reloads
        // from the (unreachable) server on a real success, so a queued
        // removal correctly leaves the record visible until sync confirms it.
        XCTAssertEqual(store.records.map(\.id), [record.id])
        assertExactlyOneOutcome(store)
    }

    // MARK: - No stale outcome banner survives a later attempt (parent diff review)
    //
    // `perform` must start every attempt with all three outcome fields
    // cleared and end with exactly one set. These four sequences are the
    // full set of "one outcome followed by a different one" transitions;
    // each asserts both that the earlier field is cleared and that
    // `assertExactlyOneOutcome` holds, so a regression that clears the old
    // field but leaves two set (or none) still fails.

    /// Queued then success: the "queued then success" case. A later
    /// confirmed save must replace, not join, the earlier queued notice.
    func testSuccessAfterAQueuedSaveClearsTheQueuedNotice() async {
        let service = FailingSocializationService()
        service.recordError = OfflineMutationError.queued(operationId: UUID())
        let store = makeStore(service: service)
        _ = await store.record(makeDraft())
        XCTAssertNotNil(store.queuedMessage)

        service.recordError = nil
        let saved = await store.record(makeDraft())

        XCTAssertTrue(saved)
        XCTAssertNil(store.queuedMessage, "A later confirmed save must clear the earlier queued notice.")
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.confirmationMessage, "Saved to \(store.petName)'s passport.")
        assertExactlyOneOutcome(store)
    }

    /// Success then failure: a prior confirmed save must not still be
    /// visible once a later attempt fails outright.
    func testFailureAfterASuccessClearsTheConfirmation() async {
        let service = FailingSocializationService()
        let store = makeStore(service: service)
        _ = await store.record(makeDraft())
        XCTAssertNotNil(store.confirmationMessage)

        service.recordError = SocializationError.invalidEntry
        let saved = await store.record(makeDraft())

        XCTAssertFalse(saved)
        XCTAssertNil(
            store.confirmationMessage,
            "A later failure must clear the earlier success, not leave a confirmed-save banner beside an error."
        )
        XCTAssertNil(store.queuedMessage)
        XCTAssertEqual(store.errorMessage, SocializationError.invalidEntry.errorDescription)
        assertExactlyOneOutcome(store)
    }

    /// Success then queued: a prior confirmed save must not still be
    /// visible once a later attempt only reaches the durable queue —
    /// otherwise the caregiver would see both a "saved" and a "will save
    /// once online" banner claim for two different actions at once.
    func testQueuedAfterASuccessClearsTheConfirmation() async {
        let service = FailingSocializationService()
        let store = makeStore(service: service)
        _ = await store.record(makeDraft())
        XCTAssertNotNil(store.confirmationMessage)

        service.recordError = OfflineMutationError.queued(operationId: UUID())
        let saved = await store.record(makeDraft())

        XCTAssertTrue(saved)
        XCTAssertNil(
            store.confirmationMessage,
            "A later queued acceptance must clear the earlier confirmed success."
        )
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(store.queuedMessage)
        assertExactlyOneOutcome(store)
    }

    /// `load()` sets its own `errorMessage` when the post-write refresh
    /// fails, but the write itself already reached the server successfully
    /// — that confirmation is still true and must win, not coexist with or
    /// be shadowed by the refresh failure (parent diff review).
    func testWriteSuccessSurvivesAFailedRefreshAfterward() async {
        let service = FailingSocializationService()
        service.loadError = SocializationError.unexpected(code: "REFRESH_FAILED")
        let store = makeStore(service: service)

        let saved = await store.record(makeDraft())

        XCTAssertTrue(saved, "The write itself succeeded even though the follow-up refresh of the list failed.")
        XCTAssertEqual(store.confirmationMessage, "Saved to \(store.petName)'s passport.")
        XCTAssertNil(
            store.errorMessage,
            "A refresh failure right after a confirmed write must not surface as a contradictory error."
        )
        XCTAssertNil(store.queuedMessage)
        assertExactlyOneOutcome(store)
    }

    // MARK: - Destructive removal (doc 22 §7: long-press-only, no confirmation, no undo)

    func testRemovingARecordSucceedsAndLeavesUnrelatedRecordsAlone() async {
        let keep = makeRecord(label: "Grass", category: .surfaces)
        let removeMe = makeRecord(label: "Doorbell", category: .sounds)
        let service = FailingSocializationService(seeded: [keep, removeMe])
        let store = makeStore(service: service)
        await store.load()
        XCTAssertEqual(store.records.count, 2)

        let removed = await store.remove(record: removeMe)

        XCTAssertTrue(removed)
        XCTAssertEqual(store.confirmationMessage, "Removed from the passport.")
        XCTAssertEqual(store.records.map(\.id), [keep.id])
    }

    /// The view-level fix (confirmation dialog, no undo) is a UI concern
    /// that XCUITest, not XCTest, can verify. What this layer can measure
    /// is the truthfulness the confirmation ceremony depends on: a refused
    /// removal must surface an error and must not remove anything.
    func testARefusedRemovalIsVisibleAndTheRecordStays() async {
        let record = makeRecord(label: "Doorbell", category: .sounds)
        let service = FailingSocializationService(seeded: [record])
        service.removeError = SocializationError.changedElsewhere
        let store = makeStore(service: service)
        await store.load()

        let removed = await store.remove(record: record)

        XCTAssertFalse(removed)
        XCTAssertEqual(
            store.errorMessage,
            "This record changed since you opened it. Reopen it to see the latest."
        )
        XCTAssertEqual(store.records.count, 1, "A refused removal must not delete anything locally.")
    }
}

/// A minimal, fully in-memory `SocializationService` double whose write
/// methods can be told to fail on demand. `InMemorySocializationService`
/// (used by previews) always succeeds, so it cannot exercise the
/// failure/recovery paths this file tests.
@MainActor
private final class FailingSocializationService: SocializationService {
    var recordError: Error?
    var removeError: Error?
    /// Fails the read that `SocializationStore.load()` performs — including
    /// the one `perform` runs right after a successful write — independent
    /// of whether the write itself succeeded.
    var loadError: Error?

    private var records: [UUID: SocializationRecord] = [:]

    init(seeded: [SocializationRecord] = []) {
        for record in seeded { records[record.id] = record }
    }

    func load(petId: UUID) async throws -> SocializationSnapshot {
        if let loadError { throw loadError }
        return SocializationSnapshot(
            records: records.values.sorted { $0.effectiveDate > $1.effectiveDate },
            exclusions: []
        )
    }

    func record(_ draft: SocializationDraft, petId: UUID) async throws {
        if let recordError { throw recordError }
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
            recordedByName: "You"
        )
    }

    func editResponse(
        recordId: UUID,
        expectedRevision: Int,
        response: SocializationResponse,
        note: String?
    ) async throws {}

    func remove(recordId: UUID) async throws {
        if let removeError { throw removeError }
        records.removeValue(forKey: recordId)
    }

    func setExclusion(
        petId: UUID,
        category: SocializationCategory?,
        experienceContentId: String?,
        reason: SocializationExclusionReason
    ) async throws {}

    func clearExclusion(exclusionId: UUID) async throws {}
}
