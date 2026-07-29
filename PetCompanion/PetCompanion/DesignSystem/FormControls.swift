import SwiftUI

/// Inputs and radio rows — UI Design System doc 09 §7.6.
///
/// Inputs: 12pt radius, `border` outline, label above, error text below in
/// `danger` with an icon (never color-only). Radio groups have whole-row
/// touch targets (ON-07).

/// Inline validation error: icon + text so the state is never color-only.
struct PCInlineError: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PCSpacing.xs) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
            Text(message)
                .font(Font.pc.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.pc.danger)
        .accessibilityElement(children: .combine)
    }
}

/// Label-above input chrome wrapping any field content.
struct PCLabeledField<Content: View>: View {
    let label: String
    var errorMessage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.xs + 2) {
            Text(label)
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
            content
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.ink)
                .padding(.horizontal, PCSpacing.lg)
                .frame(minHeight: PCMetrics.buttonHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                        .fill(Color.pc.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                        .strokeBorder(
                            errorMessage == nil ? Color.pc.border : Color.pc.danger,
                            lineWidth: 1
                        )
                )
            if let errorMessage {
                PCInlineError(message: errorMessage)
            }
        }
    }
}

/// A single choice in a radio group. Whole row is the target; selection is
/// exposed to assistive tech via the `isSelected` trait.
struct PCRadioRow: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: PCSpacing.md) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.pc.primary : Color.pc.inkTertiary,
                            lineWidth: PCMetrics.iconStroke
                        )
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle()
                            .fill(Color.pc.primary)
                            .frame(width: 12, height: 12)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Font.pc.body)
                        .foregroundStyle(Color.pc.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, PCSpacing.sm + 2)
            .frame(minHeight: PCMetrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview("Form controls") {
    VStack(alignment: .leading, spacing: PCSpacing.xl) {
        PCLabeledField(label: "Household name") {
            TextField("Household name", text: .constant("Earley Household"))
        }
        PCLabeledField(label: "Name", errorMessage: "Enter your puppy's name to continue.") {
            TextField("Name", text: .constant(""))
        }
        VStack(spacing: 0) {
            PCRadioRow(title: "Exact", isSelected: true, action: {})
            PCRadioRow(title: "Not sure — estimate", subtitle: "We'll say \u{201C}about 8 weeks\u{201D}", isSelected: false, action: {})
        }
    }
    .padding(PCSpacing.screenMargin)
    .background(Color.pc.bg)
}
