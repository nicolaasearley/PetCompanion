import SwiftUI

/// ST-05 — Invite a caregiver (doc 16 §6, US-011).
///
/// States what a caregiver will be able to see *before* the link exists
/// (US-102), creates a single-use expiring invitation, and shows the link
/// exactly once — because that is exactly how long the server keeps it.
struct InviteCaregiverView: View {
    let household: Household
    var onChange: () -> Void = {}

    @Environment(AppModel.self) private var model
    @State private var created: CreatedInvitation?
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.xxl) {
                Text("Invite a caregiver")
                    .font(Font.pc.title)
                    .foregroundStyle(Color.pc.ink)
                    .accessibilityAddTraits(.isHeader)

                visibilityExplanation

                if let created {
                    issuedLink(created)
                } else {
                    VStack(alignment: .leading, spacing: PCSpacing.md) {
                        Text("The link works once and expires in 7 days. You can revoke it at any time before it's used.")
                            .font(Font.pc.body)
                            .foregroundStyle(Color.pc.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        PrimaryButton(
                            title: "Create invitation",
                            isLoading: isCreating,
                            action: create
                        )
                    }
                }

                if let errorMessage {
                    PCInlineError(message: errorMessage)
                }
            }
            .padding(PCSpacing.screenMargin)
        }
        .background(Color.pc.bg.ignoresSafeArea())
        .navigationTitle("Invite")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var visibilityExplanation: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            Label {
                Text("A caregiver sees everything in \(household.name): every pet, plan, record, and note — and can add and complete items.")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "eye")
                    .foregroundStyle(Color.pc.info)
            }
            Label {
                Text("Only you, as the owner, can invite or remove caregivers.")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "key")
                    .foregroundStyle(Color.pc.info)
            }
        }
        .padding(PCSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pc.surfaceSubtle)
        .clipShape(RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func issuedLink(_ created: CreatedInvitation) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.lg) {
            if let link = created.shareLink {
                VStack(alignment: .leading, spacing: PCSpacing.sm) {
                    Label {
                        Text("Copy this link now — it's shown only once.")
                            .font(Font.pc.body.weight(.medium))
                            .foregroundStyle(Color.pc.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(Color.pc.attention)
                    }
                    .accessibilityElement(children: .combine)

                    Text(link)
                        .font(Font.pc.secondary.monospaced())
                        .foregroundStyle(Color.pc.ink)
                        .textSelection(.enabled)
                        .padding(PCSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.pc.surface)
                        .clipShape(RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                                .strokeBorder(Color.pc.border, lineWidth: 1)
                        )
                        .accessibilityLabel("Invitation link")
                        .accessibilityValue(link)

                    Text("Expires \(created.invitation.expiresAt.formatted(.relative(presentation: .named))). Your partner signs in, then chooses “I have an invitation” and pastes this link.")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ShareLink(item: link) {
                    Text("Share link")
                        .font(Font.pc.body.weight(.semibold))
                        .foregroundStyle(Color.pc.onPrimary)
                        .frame(maxWidth: .infinity, minHeight: PCMetrics.buttonHeight)
                        .background(Color.pc.primary)
                        .clipShape(RoundedRectangle(cornerRadius: PCRadius.button, style: .continuous))
                }
                .accessibilityLabel("Share invitation link")
            } else {
                // The server issues a token exactly once. A retry that the
                // server recognised as the same request cannot reproduce it,
                // and pretending otherwise would leave the owner sharing
                // nothing.
                VStack(alignment: .leading, spacing: PCSpacing.sm) {
                    Label {
                        Text("This invitation was already created, so its link can't be shown again.")
                            .font(Font.pc.body)
                            .foregroundStyle(Color.pc.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Color.pc.info)
                    }
                    .accessibilityElement(children: .combine)
                    Text("Revoke it on the members screen and create a new one.")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                }
            }
        }
    }

    private func create() {
        guard !isCreating else { return }
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                created = try await model.households.createInvitation(householdId: household.id)
                onChange()
                AccessibilityNotification.Announcement("Invitation created").post()
            } catch {
                errorMessage = error.localizedDescription
                AccessibilityNotification.Announcement(error.localizedDescription).post()
            }
        }
    }
}

#Preview("ST-05 Invite") {
    let model = AppModel.preview()
    return NavigationStack {
        InviteCaregiverView(household: model.household!)
    }
    .environment(model)
    .tint(Color.pc.primary)
}
