import SwiftUI

/// Empty state — UI Design System doc 09 §7.7.
///
/// Illustration slot (calm, abstract — a symbol placeholder until the
/// illustration pass), one sentence of specific copy, one constructive
/// action. The success variant ("all caught up", US-108) uses the same
/// pattern with a subtle `success` accent. Never error styling.
struct EmptyStateView: View {
    enum Accent {
        case neutral
        case success
    }

    let systemImage: String
    let message: String
    var accent: Accent = .neutral
    var primaryActionTitle: String? = nil
    var primaryAction: (() -> Void)? = nil
    var secondaryActionTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    private var accentColor: Color {
        accent == .success ? Color.pc.success : Color.pc.inkTertiary
    }

    var body: some View {
        VStack(spacing: PCSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.pc.surfaceSubtle)
                    .frame(width: 96, height: 96)
                Image(systemName: systemImage)
                    .font(.system(.largeTitle, weight: .light))
                    .foregroundStyle(accentColor)
            }
            .accessibilityHidden(true)

            Text(message)
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: PCSpacing.sm) {
                if let primaryActionTitle, let primaryAction {
                    PrimaryButton(title: primaryActionTitle, action: primaryAction)
                }
                if let secondaryActionTitle, let secondaryAction {
                    SecondaryButton(title: secondaryActionTitle, action: secondaryAction)
                }
            }
        }
        .padding(PCSpacing.screenMargin)
        .frame(maxWidth: .infinity)
    }
}

#Preview("Empty states") {
    ScrollView {
        VStack(spacing: PCSpacing.betweenSections) {
            EmptyStateView(
                systemImage: "checkmark.circle",
                message: "You're all caught up. Add something to the plan or enjoy the day together.",
                accent: .success,
                primaryActionTitle: "Add a task",
                primaryAction: {},
                secondaryActionTitle: "Browse ideas",
                secondaryAction: {}
            )
            EmptyStateView(
                systemImage: "calendar",
                message: "The Planner will show your household's tasks and events by day."
            )
        }
    }
    .background(Color.pc.bg)
}
