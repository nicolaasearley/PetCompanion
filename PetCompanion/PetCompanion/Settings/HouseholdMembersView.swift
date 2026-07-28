import SwiftUI

/// ST-04 — Members & invitations (doc 16 §6).
///
/// Active members with their roles, plus every invitation the household has
/// issued and what became of it. Owner-only actions are shown only to owners
/// (F02 role table); a caregiver sees the same facts, read-only.
///
/// Ownership transfer and member removal (US-014/US-015) are not built yet
/// and are therefore absent rather than shown disabled.
struct HouseholdMembersView: View {
    let household: Household

    @Environment(AppModel.self) private var model
    @State private var members: [HouseholdMember] = []
    @State private var invitations: [HouseholdInvitation] = []
    @State private var loadState: LoadState = .loading
    @State private var revokingId: UUID?
    @State private var actionError: String?

    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private var currentUserId: UUID? { model.currentUser?.id }

    private var isOwner: Bool {
        guard let currentUserId else { return false }
        return members.contains { $0.userId == currentUserId && $0.role == .owner && $0.status == .active }
    }

    private var activeMembers: [HouseholdMember] {
        members.filter { $0.status == .active }
    }

    private var pendingInvitations: [HouseholdInvitation] {
        invitations.filter { $0.displayState() == .pending }
    }

    private var resolvedInvitations: [HouseholdInvitation] {
        invitations.filter { $0.displayState() != .pending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                switch loadState {
                case .loading:
                    loadingSection
                case .failed(let message):
                    failureSection(message)
                case .loaded:
                    membersSection
                    invitationsSection
                    if isOwner {
                        NavigationLink {
                            InviteCaregiverView(household: household, onChange: reload)
                        } label: {
                            Text("Invite a caregiver")
                                .font(Font.pc.body.weight(.semibold))
                                .foregroundStyle(Color.pc.onPrimary)
                                .frame(maxWidth: .infinity, minHeight: PCMetrics.buttonHeight)
                                .background(Color.pc.primary)
                                .clipShape(RoundedRectangle(cornerRadius: PCRadius.button, style: .continuous))
                        }
                        .accessibilityHint("Creates a single-use invitation link")
                    } else {
                        Text("Only the household owner can invite or revoke caregivers.")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(PCSpacing.screenMargin)
        }
        .background(Color.pc.bg.ignoresSafeArea())
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Sections

    private var loadingSection: some View {
        HStack(spacing: PCSpacing.md) {
            ProgressView()
            Text("Loading members…")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func failureSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.lg) {
            PCInlineError(message: message)
            SecondaryButton(title: "Try again") {
                Task { await load() }
            }
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            SectionHeader(title: "Household members")
            VStack(spacing: 0) {
                ForEach(activeMembers) { member in
                    memberRow(member)
                    if member.id != activeMembers.last?.id {
                        Divider().overlay(Color.pc.border)
                    }
                }
            }
            .padding(PCSpacing.cardPadding)
            .background(Color.pc.surface)
            .clipShape(RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                    .strokeBorder(Color.pc.border, lineWidth: 1)
            )

            Text("Everyone here sees the same pets, plans, and records, and every completion shows who did it.")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func memberRow(_ member: HouseholdMember) -> some View {
        HStack(spacing: PCSpacing.md) {
            Image(systemName: member.role == .owner ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                .font(.title3)
                .foregroundStyle(Color.pc.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(Font.pc.body)
                    .foregroundStyle(Color.pc.ink)
                Text(member.role == .owner ? "Owner" : "Caregiver")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
            }
            Spacer(minLength: 0)
            if member.userId == currentUserId {
                PCChip(text: "You")
            }
        }
        .frame(minHeight: PCMetrics.minTouchTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            member.userId == currentUserId
                ? "\(member.displayName), \(member.role == .owner ? "owner" : "caregiver"), you"
                : "\(member.displayName), \(member.role == .owner ? "owner" : "caregiver")"
        )
    }

    @ViewBuilder
    private var invitationsSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            SectionHeader(title: "Invitations")
            if invitations.isEmpty {
                Text("No invitations yet.")
                    .font(Font.pc.body)
                    .foregroundStyle(Color.pc.inkSecondary)
            } else {
                if !pendingInvitations.isEmpty {
                    VStack(spacing: PCSpacing.betweenCards) {
                        ForEach(pendingInvitations) { invitation in
                            invitationCard(invitation)
                        }
                    }
                }
                if !resolvedInvitations.isEmpty {
                    VStack(spacing: PCSpacing.betweenCards) {
                        ForEach(resolvedInvitations) { invitation in
                            invitationCard(invitation)
                        }
                    }
                }
            }
            if let actionError {
                PCInlineError(message: actionError)
            }
        }
    }

    private func invitationCard(_ invitation: HouseholdInvitation) -> some View {
        let state = invitation.displayState()
        return VStack(alignment: .leading, spacing: PCSpacing.sm) {
            HStack(spacing: PCSpacing.sm) {
                PCChip(
                    text: Self.stateLabel(state),
                    icon: Self.stateSymbol(state),
                    style: Self.stateStyle(state)
                )
                Spacer(minLength: 0)
                Text(invitation.createdAt, format: .dateTime.day().month().year())
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
            }
            Text(Self.detailText(invitation))
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if isOwner, state == .pending {
                Button {
                    Task { await revoke(invitation) }
                } label: {
                    HStack(spacing: PCSpacing.xs) {
                        if revokingId == invitation.id {
                            ProgressView()
                        }
                        Text("Revoke")
                            .font(Font.pc.body.weight(.medium))
                    }
                    .frame(minHeight: PCMetrics.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.pc.danger)
                .disabled(revokingId != nil)
                .accessibilityLabel("Revoke this invitation")
                .accessibilityHint("The link stops working immediately")
            }
        }
        .padding(PCSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pc.surface)
        .clipShape(RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .strokeBorder(Color.pc.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    // MARK: - Copy

    static func stateLabel(_ state: HouseholdInvitation.DisplayState) -> String {
        switch state {
        case .pending: "Waiting to be accepted"
        case .expired: "Expired"
        case .accepted: "Accepted"
        case .declined: "Declined"
        case .revoked: "Revoked"
        }
    }

    private static func stateSymbol(_ state: HouseholdInvitation.DisplayState) -> String {
        switch state {
        case .pending: "hourglass"
        case .expired: "clock.badge.xmark"
        case .accepted: "checkmark.circle"
        case .declined: "xmark.circle"
        case .revoked: "slash.circle"
        }
    }

    private static func stateStyle(_ state: HouseholdInvitation.DisplayState) -> PCChip.Style {
        switch state {
        case .pending: .info
        case .expired, .declined, .revoked: .neutral
        case .accepted: .success
        }
    }

    static func detailText(_ invitation: HouseholdInvitation, now: Date = Date()) -> String {
        switch invitation.displayState(now: now) {
        case .pending:
            "Single-use link, expires \(invitation.expiresAt.formatted(.relative(presentation: .named)))."
        case .expired:
            "This link expired and can no longer be used."
        case .accepted:
            "This caregiver joined the household."
        case .declined:
            "The person you invited declined."
        case .revoked:
            "You revoked this link before it was used."
        }
    }

    // MARK: - Actions

    private func reload() {
        Task { await load() }
    }

    private func load() async {
        actionError = nil
        do {
            members = try await model.households.members(householdId: household.id)
            invitations = try await model.households.invitations(householdId: household.id)
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func revoke(_ invitation: HouseholdInvitation) async {
        revokingId = invitation.id
        actionError = nil
        defer { revokingId = nil }
        do {
            try await model.households.revokeInvitation(id: invitation.id)
            AccessibilityNotification.Announcement("Invitation revoked").post()
            await load()
        } catch {
            actionError = error.localizedDescription
            AccessibilityNotification.Announcement(error.localizedDescription).post()
        }
    }
}

#Preview("ST-04 Members") {
    let model = AppModel.preview()
    return NavigationStack {
        HouseholdMembersView(household: model.household!)
    }
    .environment(model)
    .tint(Color.pc.primary)
}
