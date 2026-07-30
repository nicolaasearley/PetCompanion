import Foundation

/// The single-use, expiring instrument for adding a caregiver without
/// sharing credentials — Data Model doc 10 §7.4 (US-011, US-012).
///
/// The share token itself is never modeled here: the server stores only its
/// hash and returns the plaintext exactly once, in the creation response
/// (`CreatedInvitation.token`).
struct HouseholdInvitation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var householdId: UUID
    var createdBy: UUID
    var roleGranted: HouseholdMember.Role
    var expiresAt: Date
    var status: Status
    var acceptedBy: UUID?
    var resolvedAt: Date?
    var createdAt: Date

    /// `pending` → exactly one of the terminal states (doc 10 §7.4).
    enum Status: String, Codable, Sendable {
        case pending, accepted, declined, revoked, expired
    }

    enum CodingKeys: String, CodingKey {
        case id, status
        case householdId = "household_id"
        case createdBy = "created_by"
        case roleGranted = "role_granted"
        case expiresAt = "expires_at"
        case acceptedBy = "accepted_by"
        case resolvedAt = "resolved_at"
        case createdAt = "created_at"
    }

    init(
        id: UUID = UUID(),
        householdId: UUID,
        createdBy: UUID,
        roleGranted: HouseholdMember.Role = .caregiver,
        expiresAt: Date,
        status: Status = .pending,
        acceptedBy: UUID? = nil,
        resolvedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.householdId = householdId
        self.createdBy = createdBy
        self.roleGranted = roleGranted
        self.expiresAt = expiresAt
        self.status = status
        self.acceptedBy = acceptedBy
        self.resolvedAt = resolvedAt
        self.createdAt = createdAt
    }

    /// What the owner is actually looking at. There is no scheduled job that
    /// retires lapsed invitations, so a row can still read `pending` after
    /// its expiry; showing it as live would be a lie. The server applies the
    /// same rule when the token is presented.
    enum DisplayState: Equatable, Sendable {
        case pending
        case expired
        case accepted
        case declined
        case revoked
    }

    func displayState(now: Date = Date()) -> DisplayState {
        switch status {
        case .accepted: .accepted
        case .declined: .declined
        case .revoked: .revoked
        case .expired: .expired
        case .pending: expiresAt <= now ? .expired : .pending
        }
    }
}

/// The one and only moment the plaintext share token exists client-side.
///
/// `token` is nil when the server recognised the request as a replay of an
/// earlier creation: the token was issued once and is unrecoverable, so the
/// honest move is to revoke and invite again rather than pretend.
struct CreatedInvitation: Equatable, Sendable {
    var invitation: HouseholdInvitation
    var householdName: String
    var token: String?

    /// The shareable link. Kept in one place so the invitee-side parser and
    /// this stay in step.
    var shareLink: String? {
        token.map { InvitationToken.link(for: $0) }
    }
}

/// What an invitee may see before accepting — household name, inviter
/// display name, and expiry, and nothing else (doc 10 §7.4).
struct InvitationPreview: Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// Ready to accept.
        case valid
        /// Terminal outcomes, each explained in its own words (US-012).
        case expired
        case revoked
        case declined
        case alreadyUsed = "already_used"
        case acceptedByYou = "accepted_by_you"
        case alreadyMember = "already_member"
        case householdClosed = "household_closed"
        /// This account is already active in a different household.
        case otherHousehold = "other_household"
        /// The link does not match any invitation. No household detail is
        /// returned in this case, by design.
        case notFound = "not_found"
    }

    var state: State
    var householdName: String?
    var inviterDisplayName: String?
    var expiresAt: Date?

    var isAcceptable: Bool { state == .valid }
}

/// Parsing and formatting of the share token.
///
/// The server issues 64 lowercase hex characters. Owners share a link, but
/// invitees paste all sorts of things (the link, the link with tracking
/// junk, the bare code), so the parser looks for the token shape anywhere in
/// the pasted text rather than insisting on an exact URL.
enum InvitationToken {
    static let scheme = "petcompanion"
    static let length = 64

    static func link(for token: String) -> String {
        "\(scheme)://invitation/\(token)"
    }

    /// Returns the token contained in `text`, or nil when there is none.
    static func extract(from text: String) -> String? {
        let lowered = text.lowercased()
        var current = ""
        var candidates: [String] = []
        for character in lowered {
            if character.isHexDigit && character.isASCII {
                current.append(character)
            } else {
                candidates.append(current)
                current = ""
            }
        }
        candidates.append(current)
        return candidates.first { $0.count == length }
    }
}

/// Every way an invitation action can fail, in the invitee's or owner's
/// terms. Each case maps to a distinct server code so the UI never has to
/// guess (or blame the user for) a state the server already knows.
enum InvitationError: LocalizedError, Equatable {
    case notFound
    case expired
    case alreadyResolved(String)
    case alreadyMember
    case householdClosed
    case otherHousehold
    case notAllowed
    case offline
    case server(String)

    init(code: String, message: String) {
        switch code {
        case "INVITATION_NOT_FOUND": self = .notFound
        case "INVITATION_EXPIRED": self = .expired
        case "INVITATION_ALREADY_RESOLVED": self = .alreadyResolved(message)
        case "ALREADY_A_MEMBER": self = .alreadyMember
        case "HOUSEHOLD_CLOSED": self = .householdClosed
        case "SINGLE_HOUSEHOLD_LIMIT": self = .otherHousehold
        case "FORBIDDEN": self = .notAllowed
        default: self = .server(message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notFound:
            "This invitation link isn't valid. Ask for a new one."
        case .expired:
            "This invitation has expired. Ask for a new one."
        case .alreadyResolved(let message):
            message.isEmpty ? "This invitation has already been used." : message
        case .alreadyMember:
            "You're already a member of this household."
        case .householdClosed:
            "This household has been closed."
        case .otherHousehold:
            "Settle supports one household per account in this release."
        case .notAllowed:
            "Only the household owner can do this."
        case .offline:
            "You need a connection to do this. Nothing was changed."
        case .server(let message):
            message
        }
    }
}
