import Foundation

/// An individual caregiver's identity — Data Model doc 10 §7.1.
/// One human, one account; never shared.
struct UserAccount: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var status: Status

    enum Status: String, Codable, Sendable {
        case active
        case deletionPending = "deletion_pending"
        case deleted
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case status
    }

    init(id: UUID = UUID(), displayName: String, status: Status = .active) {
        self.id = id
        self.displayName = displayName
        self.status = status
    }
}
