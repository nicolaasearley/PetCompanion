import XCTest
@testable import PetCompanion

/// E02 shared care: the invitation instrument and the states ON-05/ST-04
/// have to tell the truth about.
@MainActor
final class InvitationTests: XCTestCase {
    func testPastedLinkOrBareCodeYieldsTheSameToken() {
        let token = String(repeating: "a1b2c3d4", count: 8)
        XCTAssertEqual(token.count, InvitationToken.length)

        XCTAssertEqual(InvitationToken.extract(from: InvitationToken.link(for: token)), token)
        XCTAssertEqual(InvitationToken.extract(from: token), token)
        XCTAssertEqual(
            InvitationToken.extract(from: "Join us!\n\(InvitationToken.link(for: token))\nSee you soon"),
            token
        )
        XCTAssertEqual(InvitationToken.extract(from: token.uppercased()), token)
    }

    func testAnythingThatIsNotATokenIsRejectedRatherThanGuessed() {
        XCTAssertNil(InvitationToken.extract(from: ""))
        XCTAssertNil(InvitationToken.extract(from: "petcompanion://invitation/abc123"))
        // 63 and 65 hex characters are both wrong, and a truncated paste must
        // not be silently accepted.
        XCTAssertNil(InvitationToken.extract(from: String(repeating: "f", count: 63)))
        XCTAssertNil(InvitationToken.extract(from: String(repeating: "f", count: 65)))
        XCTAssertNil(InvitationToken.extract(from: String(repeating: "z", count: 64)))
    }

    func testPendingInvitationPastItsExpiryReadsAsExpired() {
        let invitation = HouseholdInvitation(
            householdId: UUID(),
            createdBy: UUID(),
            expiresAt: Date().addingTimeInterval(-60),
            status: .pending
        )
        XCTAssertEqual(invitation.displayState(), .expired)
        XCTAssertEqual(
            HouseholdMembersView.detailText(invitation),
            "This link expired and can no longer be used."
        )

        let live = HouseholdInvitation(
            householdId: UUID(),
            createdBy: UUID(),
            expiresAt: Date().addingTimeInterval(3600),
            status: .pending
        )
        XCTAssertEqual(live.displayState(), .pending)
        XCTAssertEqual(
            HouseholdMembersView.stateLabel(live.displayState()),
            "Waiting to be accepted"
        )
    }

    func testInvitationIsSingleUseAndAcceptanceCreatesOneMembership() async throws {
        let backend = MockBackend()
        let owner = backend.signIn(email: "nic@example.com")
        let household = backend.createHousehold(
            name: "Earley Household",
            timeZone: "America/Toronto",
            ownerId: owner.id
        )
        let service = MockHouseholdService(backend: backend)

        let created = try await service.createInvitation(householdId: household.id)
        let token = try XCTUnwrap(created.token)
        XCTAssertEqual(created.shareLink, InvitationToken.link(for: token))

        let invitee = backend.signIn(email: "kim@example.com")
        let preview = try await service.previewInvitation(token: token)
        XCTAssertEqual(preview.state, .valid)
        XCTAssertEqual(preview.householdName, "Earley Household")
        XCTAssertEqual(preview.inviterDisplayName, "Nic")

        let joined = try await service.acceptInvitation(token: token)
        XCTAssertEqual(joined.id, household.id)
        let members = try await service.members(householdId: household.id)
        XCTAssertEqual(members.filter { $0.userId == invitee.id }.count, 1)

        // The same link a second time, from a third account.
        _ = backend.signIn(email: "sam@example.com")
        do {
            _ = try await service.acceptInvitation(token: token)
            XCTFail("A single-use invitation must not be accepted twice")
        } catch let error as InvitationError {
            guard case .alreadyResolved = error else {
                return XCTFail("Expected an already-used explanation, got \(error)")
            }
        }
    }

    func testDecliningGrantsNothingAndExplainsItself() async throws {
        let backend = MockBackend()
        let owner = backend.signIn(email: "nic@example.com")
        let household = backend.createHousehold(
            name: "Earley Household",
            timeZone: "America/Toronto",
            ownerId: owner.id
        )
        let service = MockHouseholdService(backend: backend)
        let token = try XCTUnwrap(try await service.createInvitation(householdId: household.id).token)

        let invitee = backend.signIn(email: "kim@example.com")
        try await service.declineInvitation(token: token)

        let members = try await service.members(householdId: household.id)
        XCTAssertFalse(members.contains { $0.userId == invitee.id })
        let preview = try await service.previewInvitation(token: token)
        XCTAssertEqual(preview.state, .declined)
        XCTAssertFalse(preview.isAcceptable)
    }

    func testRevokedInvitationCannotBeAccepted() async throws {
        let backend = MockBackend()
        let owner = backend.signIn(email: "nic@example.com")
        let household = backend.createHousehold(
            name: "Earley Household",
            timeZone: "America/Toronto",
            ownerId: owner.id
        )
        let service = MockHouseholdService(backend: backend)
        let created = try await service.createInvitation(householdId: household.id)
        let token = try XCTUnwrap(created.token)

        try await service.revokeInvitation(id: created.invitation.id)
        _ = backend.signIn(email: "kim@example.com")

        let preview = try await service.previewInvitation(token: token)
        XCTAssertEqual(preview.state, .revoked)
        do {
            _ = try await service.acceptInvitation(token: token)
            XCTFail("A revoked invitation must not be acceptable")
        } catch is InvitationError {
            // Expected.
        }
    }

    func testEveryServerOutcomeHasItsOwnExplanation() {
        let mapped: [(String, InvitationError)] = [
            ("INVITATION_NOT_FOUND", .notFound),
            ("INVITATION_EXPIRED", .expired),
            ("ALREADY_A_MEMBER", .alreadyMember),
            ("HOUSEHOLD_CLOSED", .householdClosed),
            ("SINGLE_HOUSEHOLD_LIMIT", .otherHousehold),
            ("FORBIDDEN", .notAllowed),
        ]
        for (code, expected) in mapped {
            XCTAssertEqual(InvitationError(code: code, message: "server text"), expected, code)
            XCTAssertNotNil(InvitationError(code: code, message: "server text").errorDescription)
        }
        XCTAssertEqual(
            InvitationError(code: "COMMAND_FAILED", message: "server text"),
            .server("server text")
        )

        // Every unusable preview state must have distinct, non-empty copy:
        // an unexplained state is the failure mode this screen exists to
        // avoid (US-012).
        let states: [InvitationPreview.State] = [
            .valid, .expired, .revoked, .declined, .alreadyUsed, .acceptedByYou,
            .alreadyMember, .householdClosed, .otherHousehold, .notFound,
        ]
        let headlines = states.map(InvitationReviewView.headline(for:))
        let explanations = states.map(InvitationReviewView.explanation(for:))
        XCTAssertEqual(Set(headlines).count, states.count)
        XCTAssertEqual(Set(explanations).count, states.count)
        XCTAssertFalse(explanations.contains { $0.isEmpty })
    }
}
