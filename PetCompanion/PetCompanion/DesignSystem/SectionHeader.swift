import SwiftUI

/// Section header — UI Design System doc 09 §7.3.
///
/// Small-caps label treatment of `type.heading`, `ink-secondary`, optional
/// trailing action ("Adjust", "Show"). Rendered as a real accessibility
/// heading so screen-reader users can jump between plan sections (IA §16).
struct SectionHeader: View {
    let title: String
    var trailingLabel: String? = nil
    var trailingAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PCSpacing.sm) {
            Text(title.uppercased())
                .font(Font.pc.heading)
                .tracking(0.8)
                .foregroundStyle(Color.pc.inkSecondary)
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
        SectionHeader(title: "Needs attention")
        SectionHeader(title: "Recommended", trailingLabel: "Adjust", trailingAction: {})
        SectionHeader(title: "Completed (2)", trailingLabel: "Show", trailingAction: {})
    }
    .padding(PCSpacing.screenMargin)
    .background(Color.pc.bg)
}
