import SwiftUI

/// Plan item card — UI Design System doc 09 §7.1. The product's centerpiece.
///
/// Anatomy: complete control (28pt circle, 44pt touch target) · title
/// (`type.body`) · meta line (`type.secondary`) · optional trailing
/// affordance ("Why this? ›").
///
/// Accessibility: the checkbox and the row are two separate accessible
/// targets (doc 14 HM-01 a11y note); state is never conveyed by color alone
/// (labels and icons always accompany it).
struct PlanItemCard: View {
    enum CardState: Equatable {
        case normal
        /// Checkmark draw + settle (~200 ms); reduced motion makes it an
        /// instant state change (doc 09 §8).
        case completing
        /// Title stays full-contrast, check filled `success`, meta shows
        /// attribution. No strikethrough — completion is an achievement,
        /// not a deletion.
        case completed(attribution: String?)
        /// Offline-queued action awaiting sync (US-058).
        case queued
        case disabled
    }

    let title: String
    var meta: String? = nil
    var state: CardState = .normal
    /// Needs-attention variant: `attention-bg` tint, `attention` leading
    /// icon, 4pt leading bar. Orthogonal to `state`.
    var isNeedsAttention: Bool = false
    /// Recommendation cards never show a checkbox pre-accepted; their
    /// primary tap opens the explanation. Accepting is explicit.
    var showsCheckbox: Bool = true
    /// e.g. "Why this?" or "Open" — rendered with a trailing chevron.
    var trailingAffordance: String? = nil
    var onToggleComplete: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isChecked: Bool {
        switch state {
        case .completing, .completed: true
        default: false
        }
    }

    private var isDisabled: Bool { state == .disabled }

    var body: some View {
        HStack(alignment: .top, spacing: PCSpacing.md) {
            if showsCheckbox {
                checkbox
            }
            rowContent
        }
        .padding(PCSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(isNeedsAttention ? Color.pc.attentionBg : Color.pc.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .strokeBorder(Color.pc.border, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if isNeedsAttention {
                UnevenRoundedRectangle(
                    topLeadingRadius: PCRadius.card,
                    bottomLeadingRadius: PCRadius.card
                )
                .fill(Color.pc.attention)
                .frame(width: 4)
            }
        }
        .opacity(isDisabled ? 0.55 : 1)
    }

    // MARK: - Complete control

    private var checkbox: some View {
        Button {
            onToggleComplete?()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(
                        isChecked ? Color.pc.success : Color.pc.inkTertiary,
                        lineWidth: PCMetrics.iconStroke
                    )
                if isChecked {
                    Circle()
                        .fill(Color.pc.success)
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.pc.onPrimary)
                        .transition(reduceMotion ? .identity : .scale.combined(with: .opacity))
                }
            }
            .frame(width: PCMetrics.checkboxSize, height: PCMetrics.checkboxSize)
            .animation(reduceMotion ? nil : .spring(duration: 0.2), value: isChecked)
            .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || onToggleComplete == nil)
        .accessibilityLabel(checkboxAccessibilityLabel)
        // Compensate the 44pt target so the visual circle aligns with the title.
        .padding(.top, -(PCMetrics.minTouchTarget - PCMetrics.checkboxSize) / 2)
        .padding(.leading, -(PCMetrics.minTouchTarget - PCMetrics.checkboxSize) / 2)
    }

    private var checkboxAccessibilityLabel: String {
        switch state {
        case .completed(let attribution):
            if let attribution {
                "\(title) completed, \(attribution). Double tap to undo."
            } else {
                "\(title) completed. Double tap to undo."
            }
        case .completing:
            "\(title) completing"
        default:
            "Mark \(title) complete"
        }
    }

    // MARK: - Row

    private var rowContent: some View {
        Button {
            onOpen?()
        } label: {
            VStack(alignment: .leading, spacing: PCSpacing.xs) {
                HStack(spacing: PCSpacing.sm) {
                    if isNeedsAttention {
                        Image(systemName: "exclamationmark.circle")
                            .font(Font.pc.body)
                            .foregroundStyle(Color.pc.attention)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(Font.pc.body)
                        .foregroundStyle(isDisabled ? Color.pc.inkTertiary : Color.pc.ink)
                        .multilineTextAlignment(.leading)
                }
                if let metaLine {
                    Text(metaLine)
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
                if state == .queued {
                    PCChip(text: "queued", icon: "arrow.triangle.2.circlepath", style: .info)
                }
                if let trailingAffordance {
                    Text("\(trailingAffordance) ›")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || onOpen == nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint(onOpen == nil ? "" : "Opens details")
    }

    /// Completed cards show attribution in the meta position.
    private var metaLine: String? {
        if case .completed(let attribution) = state, let attribution {
            return attribution
        }
        return meta
    }
}

#Preview("Plan item card states") {
    ScrollView {
        VStack(spacing: PCSpacing.betweenCards) {
            PlanItemCard(
                title: "Potty routine",
                onToggleComplete: {},
                onOpen: {}
            )
            PlanItemCard(
                title: "Breakfast",
                state: .completed(attribution: "by Sarah, 7:42 AM"),
                onToggleComplete: {},
                onOpen: {}
            )
            PlanItemCard(
                title: "Evening meal",
                state: .queued,
                onToggleComplete: {},
                onOpen: {}
            )
            PlanItemCard(
                title: "Medication · was 8:00 AM",
                meta: "From Maple's care record",
                isNeedsAttention: true,
                showsCheckbox: false,
                trailingAffordance: "Open",
                onOpen: {}
            )
            PlanItemCard(
                title: "Practice name response",
                meta: "Training · ~3–5 min",
                showsCheckbox: false,
                trailingAffordance: "Why this?",
                onOpen: {}
            )
            PlanItemCard(
                title: "Stale item",
                meta: "Waiting for sync",
                state: .disabled
            )
        }
        .padding(PCSpacing.screenMargin)
    }
    .background(Color.pc.bg)
}
