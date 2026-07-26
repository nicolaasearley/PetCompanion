import SwiftUI
import UIKit

/// Semantic color tokens — UI Design System doc 09 §4.
///
/// This is the ONLY file in the app that may contain raw hex values
/// (design-system validation criterion §12.5). Components must reference
/// `Color.pc.*` names, never literals.
extension Color {
    enum pc {
        /// App background (warm cream).
        static let bg = Color.pcToken(light: 0xFAF7F2, dark: 0x17140F)
        /// Cards, sheets.
        static let surface = Color.pcToken(light: 0xFFFFFF, dark: 0x201C15)
        /// Grouped sections, collapsed areas.
        static let surfaceSubtle = Color.pcToken(light: 0xF1EDE5, dark: 0x2A251C)
        /// Primary text (warm near-black).
        static let ink = Color.pcToken(light: 0x26221C, dark: 0xF3EFE7)
        /// Secondary text, metadata.
        static let inkSecondary = Color.pcToken(light: 0x5C554A, dark: 0xBFB7A8)
        /// Placeholders, disabled text.
        /// Dark value not specified in doc 09 §4.2; the light mid-tone keeps
        /// adequate contrast on the dark background, so it is reused.
        static let inkTertiary = Color.pcToken(light: 0x8A8172, dark: 0x8A8172)
        /// Hairlines, dividers.
        static let border = Color.pcToken(light: 0xE4DED3, dark: 0x3A342A)
        /// Primary actions, active tab, links (deep pine).
        static let primary = Color.pcToken(light: 0x2F5D50, dark: 0x7FB5A4)
        /// Pressed state. Dark value not specified in doc 09 §4.2; derived as
        /// a slightly deepened `primary`.
        static let primaryPressed = Color.pcToken(light: 0x254A40, dark: 0x6BA292)
        /// Text/icons on primary.
        static let onPrimary = Color.pcToken(light: 0xFFFFFF, dark: 0x17140F)
        /// Sparing highlights (honey) — never for text on light backgrounds.
        static let accent = Color.pcToken(light: 0xC9903A, dark: 0xD9A85C)
        /// Needs-attention accents (muted terracotta).
        static let attention = Color.pcToken(light: 0xA6472E, dark: 0xE08A6D)
        /// Needs-attention card tint.
        static let attentionBg = Color.pcToken(light: 0xF9E9E2, dark: 0x3A251D)
        /// Completion confirmations.
        static let success = Color.pcToken(light: 0x3E7A5E, dark: 0x8CC0A6)
        /// Upcoming/informational accents (slate).
        static let info = Color.pcToken(light: 0x4E6E8E, dark: 0x93AEC7)
        /// True failures and destructive actions only.
        static let danger = Color.pcToken(light: 0x9E3B2E, dark: 0xE0796A)
    }
}

private extension Color {
    /// Builds a dynamic color that follows the platform light/dark appearance
    /// (dark mode is platform-following per doc 09 §4.2).
    static func pcToken(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(pcHex: dark)
                : UIColor(pcHex: light)
        })
    }
}

private extension UIColor {
    convenience init(pcHex hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
