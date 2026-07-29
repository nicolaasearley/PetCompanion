import SwiftUI

/// Section header — UI Design System doc 09 §7.3.
///
/// Small-caps label treatment of `type.heading`, optional trailing action
/// ("Adjust", "Show"). Rendered as a real accessibility heading so
/// screen-reader users can jump between plan sections (IA §16).
struct SectionHeader: View {
    /// `.attention` reinforces the "Needs attention > Today > Recommended"
    /// hierarchy (doc 09 §3.2) at the one section that outranks everything
    /// else; every other header stays neutral so color still reads as a
    /// single, meaningful accent rather than decoration repeated per section.
    enum Tone {
        case neutral
        case attention
    }

    let title: String
    var tone: Tone = .neutral
    var trailingLabel: String? = nil
    var trailingAction: (() -> Void)? = nil

    private var labelColor: Color {
        tone == .attention ? Color.pc.attention : Color.pc.inkSecondary
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PCSpacing.sm) {
            Text(title.uppercased())
                .font(Font.pc.heading)
                .tracking(0.8)
                .foregroundStyle(labelColor)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(title)
            Spacer(minLength: 0)
            if let trailingLabel, let trailingAction {
                Button(trailingLabel, action: trailingAction)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.primary)
            }
        }
    }
}

#Preview("Section headers") {
    VStack(alignment: .leading, spacing: PCSpacing.xl) {
        SectionHeader(title: "Needs attention", tone: .attention)
        SectionHeader(title: "Recommended", trailingLabel: "Adjust", trailingAction: {})
        SectionHeader(title: "Completed (2)", trailingLabel: "Show", trailingAction: {})
    }
    .padding(PCSpacing.screenMargin)
    .background(Color.pc.bg)
}
