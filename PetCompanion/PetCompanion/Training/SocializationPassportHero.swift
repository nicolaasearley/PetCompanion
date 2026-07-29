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
/// Deliberately not a full-bleed saturated block: PRODUCT.md's anti-
/// references rule out a "giant saturated block," and doc 09 §2's One
/// Accent Rule means at most one bold color per view. The promotion reads
/// through position (first on screen), a bolder title weight, an
/// explanatory second line neighboring rows don't carry, and a
/// primary-tinted border — the background stays the same paper-white
/// `surface` every other Training card uses.
struct SocializationPassportHero: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: PCSpacing.md) {
                icon
                VStack(alignment: .leading, spacing: PCSpacing.xs) {
                    Text("Socialization passport")
                        .font(Font.pc.body.weight(.semibold))
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.pc.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(PCSpacing.cardPadding)
            .frame(minHeight: PCMetrics.minTouchTarget)
            .background(
                RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                    .fill(Color.pc.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                    .strokeBorder(Color.pc.primary.opacity(0.3), lineWidth: 1.25)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the socialization passport")
    }

    private var icon: some View {
        ZStack {
            Circle().fill(Color.pc.surfaceSubtle)
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.pc.primary)
        }
        .frame(width: 48, height: 48)
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
