import SwiftUI

/// The Training screen's promoted entry point into the socialization
/// passport (owner-directed hierarchy update, 2026-07-29 — supersedes doc 16
/// TR-01's "Socialization ›" row filed under BROWSE). It is the first thing
/// on the screen; Active goals, Suggested, and Browse all follow it.
///
/// `TrainingView` has no loaded `SocializationStore` of its own, and loading
/// one solely to decorate this tile would be a network call spent purely on
/// appearance rather than a caregiver action — so the second line is the
/// passport's own stable, already-approved purpose copy (doc 16 TR-06)
/// rather than a fabricated "current state." There is nothing dishonest
/// about that: the line describes what the passport *is*, not a live
/// reading of it.
///
/// Presence comes from scale and a soft warm wash — not a saturated brand
/// block (PRODUCT.md anti-references + doc 09 One Accent Rule). Background
/// stays within the cream/pine family; one primary-tinted border is the
/// single bold color cue.
struct SocializationPassportHero: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: PCSpacing.md) {
                HStack(alignment: .top, spacing: PCSpacing.md) {
                    icon
                    VStack(alignment: .leading, spacing: PCSpacing.sm) {
                        Text("Socialization passport")
                            .font(Font.pc.display)
                            .foregroundStyle(Color.pc.ink)
                            .multilineTextAlignment(.leading)
                        Text("Gentle, positive, varied — quality beats quantity.")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.pc.primary)
                        .padding(.top, PCSpacing.xs)
                        .accessibilityHidden(true)
                }
            }
            .padding(PCSpacing.lg)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                    .fill(heroBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                    .strokeBorder(Color.pc.primary.opacity(0.35), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the socialization passport")
    }

    private var heroBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.pc.surfaceSubtle,
                Color.pc.attentionBg.opacity(0.55),
                Color.pc.surface,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var icon: some View {
        ZStack {
            Circle().fill(Color.pc.surface)
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.pc.primary)
        }
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
    }
}

#Preview("Socialization passport hero") {
    VStack(spacing: PCSpacing.betweenCards) {
        SocializationPassportHero(action: {})
    }
    .padding(PCSpacing.screenMargin)
    .background(Color.pc.bg)
}
