import SwiftUI

/// Lightweight item detail sheet — the row-tap target on HM-01. Full
/// HM-02 (source links, notes, snooze/reschedule/skip) ships with WP-5's
/// backend wiring; this sheet carries the stored explanation ("Why this?")
/// and the explicit accept/complete action for recommendations (doc 09
/// §7.1 recommendation variant).
struct PlanItemDetailSheet: View {
    let item: PlanItem
    let meta: String?
    let state: PlanItemCard.CardState
    let allowsCompletion: Bool
    let onToggleComplete: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var isCompleted: Bool {
        if case .completed = state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(Font.pc.title)
                    .foregroundStyle(Color.pc.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                // Explicit close for assistive tech (doc 09 §7.4).
                Button("Close") { dismiss() }
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.primary)
            }

            // Obligation class conveyed by label, never color alone.
            Text("\(item.category.displayName) · \(item.obligationClass.displayName)")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)

            if let meta {
                Text(meta)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
            }

            if case .completed(let attribution) = state, let attribution {
                Text("Completed \(attribution)")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.success)
            }

            if let explanation = item.explanationText {
                VStack(alignment: .leading, spacing: PCSpacing.sm) {
                    Text("Why this?")
                        .font(Font.pc.heading)
                        .foregroundStyle(Color.pc.inkSecondary)
                        .accessibilityAddTraits(.isHeader)
                    Text(explanation)
                        .font(Font.pc.body)
                        .foregroundStyle(Color.pc.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PCSpacing.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                        .fill(Color.pc.surfaceSubtle)
                )
            }

            Spacer(minLength: 0)

            if allowsCompletion {
                PrimaryButton(title: isCompleted ? "Undo completion" : "Mark complete") {
                    onToggleComplete()
                    dismiss()
                }
            }
        }
        .padding(PCSpacing.screenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.pc.surface)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

#Preview("Item detail — recommendation") {
    Color.pc.bg
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            PlanItemDetailSheet(
                item: PlanItem(
                    planId: UUID(),
                    itemKey: "rec:name-response",
                    kind: .recommendation,
                    title: "Practice name response",
                    category: .training,
                    obligationClass: .recommended,
                    section: .recommended,
                    effortBand: .short,
                    explanationText: "Name response is part of Maple's foundations stage, and it hasn't been practiced in the last few days. Takes about 3 minutes."
                ),
                meta: "Training · ~3–5 min",
                state: .normal,
                allowsCompletion: true,
                onToggleComplete: {}
            )
        }
}
