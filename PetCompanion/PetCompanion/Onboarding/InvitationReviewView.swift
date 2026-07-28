import SwiftUI

/// ON-05 — Invitation review (doc 14 §4, US-012).
///
/// Shows the household name, the inviter's display name, and the expiry —
/// the only three things the server will disclose before acceptance — then
/// accepts or declines. Every unusable state (expired, revoked, already
/// used, already a member) gets its own explanation with no household data
/// and no blame styling.
struct InvitationReviewView: View {
    /// Prefilled when the invitee arrived from a link; nil when they came in
    /// through "I have an invitation" and still have to paste it.
    var initialToken: String?
    var onJoined: (Household) -> Void

    @Environment(AppModel.self) private var model
    @State private var pastedText = ""
    @State private var token: String?
    @State private var phase: Phase = .entry
    @State private var preview: InvitationPreview?
    @State private var errorMessage: String?

    private enum Phase: Equatable {
        case entry
        case loading
        case reviewing
        case working
        case declined
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.xxl) {
                switch phase {
                case .entry:
                    entrySection
                case .loading:
                    loadingSection
                case .reviewing:
                    if let preview {
                        reviewSection(preview)
                    }
                case .working:
                    loadingSection
                case .declined:
                    declinedSection
                }

                if let errorMessage {
                    PCInlineError(message: errorMessage)
                }
            }
            .padding(PCSpacing.screenMargin)
        }
        .background(Color.pc.bg.ignoresSafeArea())
        .navigationTitle("Invitation")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let initialToken, token == nil {
                await load(token: initialToken)
            }
        }
    }

    // MARK: - Sections

    private var entrySection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.xl) {
            Text("Join a household")
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
                .accessibilityAddTraits(.isHeader)

            Text("Paste the invitation link the household owner sent you. We'll show you which household it's for before you join anything.")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            PCLabeledField(label: "Invitation link") {
                TextField("petcompanion://invitation/…", text: $pastedText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...3)
            }

            PrimaryButton(title: "Continue", isLoading: phase == .loading) {
                guard let parsed = InvitationToken.extract(from: pastedText) else {
                    setError("That doesn't look like an invitation link. Paste the whole link you were sent.")
                    return
                }
                Task { await load(token: parsed) }
            }
        }
    }

    private var loadingSection: some View {
        HStack(spacing: PCSpacing.md) {
            ProgressView()
            Text(phase == .working ? "Joining…" : "Checking this invitation…")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func reviewSection(_ preview: InvitationPreview) -> some View {
        if preview.isAcceptable {
            acceptableSection(preview)
        } else {
            unusableSection(preview)
        }
    }

    private func acceptableSection(_ preview: InvitationPreview) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.xxl) {
            Text("You're invited")
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: PCSpacing.sm) {
                Image(systemName: "house")
                    .font(.title2)
                    .foregroundStyle(Color.pc.primary)
                    .accessibilityHidden(true)
                Text(preview.householdName ?? "A household")
                    .font(Font.pc.heading)
                    .foregroundStyle(Color.pc.ink)
                if let inviter = preview.inviterDisplayName {
                    Text("Invited by \(inviter)")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                }
                if let expiresAt = preview.expiresAt {
                    Text("Expires \(expiresAt.formatted(.relative(presentation: .named)))")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
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
            .accessibilityElement(children: .combine)

            Text("You'll see and share this household's pets, plans, and records. Everything you complete will show your name.")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: PCSpacing.md) {
                PrimaryButton(title: "Accept invitation", isLoading: phase == .working) {
                    Task { await accept() }
                }
                SecondaryButton(title: "Decline", isDisabled: phase == .working) {
                    Task { await decline() }
                }
            }
        }
    }

    private func unusableSection(_ preview: InvitationPreview) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.xl) {
            Image(systemName: Self.symbol(for: preview.state))
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.pc.inkSecondary)
                .accessibilityHidden(true)
            Text(Self.headline(for: preview.state))
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
                .accessibilityAddTraits(.isHeader)
            Text(Self.explanation(for: preview.state))
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecondaryButton(title: "Use a different link") {
                reset()
            }
        }
    }

    private var declinedSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.xl) {
            Image(systemName: "hand.wave")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.pc.inkSecondary)
                .accessibilityHidden(true)
            Text("Invitation declined")
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Nothing was shared with you, and the household owner can send a new invitation if you change your mind.")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecondaryButton(title: "Use a different link") {
                reset()
            }
        }
    }

    // MARK: - Copy for unusable states

    static func headline(for state: InvitationPreview.State) -> String {
        switch state {
        case .valid: "You're invited"
        case .expired: "This invitation expired"
        case .revoked: "This invitation was revoked"
        case .declined: "This invitation was declined"
        case .alreadyUsed: "This invitation was already used"
        case .acceptedByYou: "You already joined"
        case .alreadyMember: "You're already a member"
        case .householdClosed: "This household is closed"
        case .otherHousehold: "You're already in a household"
        case .notFound: "We couldn't find this invitation"
        }
    }

    static func explanation(for state: InvitationPreview.State) -> String {
        switch state {
        case .valid:
            "Review the household below before joining."
        case .expired:
            "Invitation links stop working after their expiry date. Ask the household owner for a new one."
        case .revoked:
            "The household owner cancelled this link. Ask them for a new one."
        case .declined:
            "This invitation was declined. Ask the household owner for a new one."
        case .alreadyUsed:
            "Each invitation link works once, and this one has been used. Ask the household owner for a new one."
        case .acceptedByYou:
            "You've already accepted this invitation with this account."
        case .alreadyMember:
            "You already belong to this household, so there's nothing to accept."
        case .householdClosed:
            "The owner closed this household, so invitations to it no longer work."
        case .otherHousehold:
            "PetCompanion supports one household per account in this release. Leaving a household isn't available yet, so use a different account for this invitation."
        case .notFound:
            "That link doesn't match an invitation. Check you pasted all of it, or ask for a new one."
        }
    }

    private static func symbol(for state: InvitationPreview.State) -> String {
        switch state {
        case .valid: "house"
        case .expired: "clock.badge.xmark"
        case .revoked, .declined, .alreadyUsed: "slash.circle"
        case .acceptedByYou, .alreadyMember: "checkmark.circle"
        case .householdClosed: "lock"
        case .otherHousehold: "person.2"
        case .notFound: "questionmark.circle"
        }
    }

    // MARK: - Actions

    private func reset() {
        token = nil
        preview = nil
        pastedText = ""
        errorMessage = nil
        phase = .entry
    }

    private func setError(_ message: String) {
        errorMessage = message
        AccessibilityNotification.Announcement(message).post()
    }

    private func load(token candidate: String) async {
        errorMessage = nil
        phase = .loading
        do {
            let result = try await model.households.previewInvitation(token: candidate)
            token = candidate
            preview = result
            phase = .reviewing
            AccessibilityNotification.Announcement(
                result.isAcceptable
                    ? "Invitation to \(result.householdName ?? "a household")"
                    : Self.headline(for: result.state)
            ).post()
        } catch {
            phase = .entry
            setError(error.localizedDescription)
        }
    }

    private func accept() async {
        guard let token else { return }
        errorMessage = nil
        phase = .working
        do {
            let household = try await model.households.acceptInvitation(token: token)
            onJoined(household)
        } catch {
            phase = .reviewing
            setError(error.localizedDescription)
            // The server is authoritative about why acceptance failed, so
            // re-read the state rather than leaving a stale "Accept" button.
            if let refreshed = try? await model.households.previewInvitation(token: token) {
                preview = refreshed
            }
        }
    }

    private func decline() async {
        guard let token else { return }
        errorMessage = nil
        phase = .working
        do {
            try await model.households.declineInvitation(token: token)
            phase = .declined
            AccessibilityNotification.Announcement("Invitation declined").post()
        } catch {
            phase = .reviewing
            setError(error.localizedDescription)
        }
    }
}

#Preview("ON-05 Invitation review") {
    NavigationStack {
        InvitationReviewView(onJoined: { _ in })
    }
    .environment(AppModel.mock())
    .tint(Color.pc.primary)
}
