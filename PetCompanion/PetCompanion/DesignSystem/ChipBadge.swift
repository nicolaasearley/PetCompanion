import SwiftUI

/// Chips and badges — UI Design System doc 09 §7.5.
///
/// Capacity pill ("Busy day"), provenance badges, "queued", effort band.
/// `type.caption`, `surface-subtle` background, full (capsule) radius.
/// Badges are informative and never look tappable unless they are — pass
/// `action` only when the chip really navigates.
struct PCChip: View {
    enum Style {
        case neutral
        case info
        case attention
        case success
        case accent

        var foreground: Color {
            switch self {
            case .neutral: Color.pc.inkSecondary
            case .info: Color.pc.info
            case .attention: Color.pc.attention
            case .success: Color.pc.success
            case .accent: Color.pc.accent
            }
        }
    }

    let text: String
    var icon: String? = nil
    var style: Style = .neutral
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: PCSpacing.xs) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(text)
                .font(Font.pc.caption)
        }
        .foregroundStyle(style.foreground)
        .padding(.horizontal, PCSpacing.md)
        .padding(.vertical, PCSpacing.xs + 1)
        .background(Color.pc.surfaceSubtle)
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
    }
}

#Preview("Chips") {
    VStack(spacing: PCSpacing.md) {
        PCChip(text: "Busy day")
        PCChip(text: "queued", icon: "arrow.triangle.2.circlepath", style: .info)
        PCChip(text: "Owner-entered", style: .neutral)
        PCChip(text: "~3–5 min")
        PCChip(text: "12 wks · Foundations", style: .neutral, action: {})
    }
    .padding(PCSpacing.screenMargin)
    .background(Color.pc.bg)
}
