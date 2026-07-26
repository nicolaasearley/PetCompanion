import Foundation

/// Spacing scale (4pt base) — UI Design System doc 09 §6.
enum PCSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
    static let huge: CGFloat = 48

    /// Screen margins.
    static let screenMargin: CGFloat = 20
    /// Card interior padding.
    static let cardPadding: CGFloat = 16
    /// Vertical space between cards.
    static let betweenCards: CGFloat = 12
    /// Vertical space between plan sections (spacious per direction).
    static let betweenSections: CGFloat = 32
}

/// Shape radii — doc 09 §6. Chips and badges use `Capsule` (full radius).
enum PCRadius {
    static let card: CGFloat = 16
    static let sheet: CGFloat = 16
    static let button: CGFloat = 12
    static let input: CGFloat = 12
}

/// Fixed control metrics — doc 09 §6–§7.
enum PCMetrics {
    /// Button height (§7.2).
    static let buttonHeight: CGFloat = 50
    /// Plan-item complete control circle (§7.1).
    static let checkboxSize: CGFloat = 28
    /// Minimum touch target for the complete control (§7.1).
    static let minTouchTarget: CGFloat = 44
    /// Standard navigation list row (§7.6).
    static let listRowHeight: CGFloat = 56
    /// Icon stroke weight (§6).
    static let iconStroke: CGFloat = 1.8
}
