import SwiftUI

/// Buttons — UI Design System doc 09 §7.2.
///
/// Height 50pt, full width in flows, loading state replaces the label with
/// inline progress. Never place two primary buttons on one screen.

struct PrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .font(Font.pc.body.weight(.semibold))
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .tint(Color.pc.onPrimary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: PCMetrics.buttonHeight)
        }
        .buttonStyle(PCFilledButtonStyle())
        .disabled(isDisabled || isLoading)
        .opacity(isDisabled ? 0.5 : 1)
        .accessibilityLabel(isLoading ? "\(title), in progress" : title)
    }
}

struct SecondaryButton: View {
    let title: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Font.pc.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: PCMetrics.buttonHeight)
        }
        .buttonStyle(PCTonalButtonStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }
}

private struct PCFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.pc.onPrimary)
            .background(configuration.isPressed ? Color.pc.primaryPressed : Color.pc.primary)
            .clipShape(RoundedRectangle(cornerRadius: PCRadius.button, style: .continuous))
    }
}

private struct PCTonalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.pc.ink)
            .background(Color.pc.surfaceSubtle.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: PCRadius.button, style: .continuous))
    }
}

#Preview("Buttons") {
    VStack(spacing: PCSpacing.md) {
        PrimaryButton(title: "Get started") {}
        PrimaryButton(title: "Continue", isLoading: true) {}
        SecondaryButton(title: "I have an account") {}
    }
    .padding(PCSpacing.screenMargin)
    .background(Color.pc.bg)
}
