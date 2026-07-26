import SwiftUI

/// Typography tokens — UI Design System doc 09 §5.
///
/// Every token maps to a platform text style so all type scales with
/// Dynamic Type for free (US-105). Never use fixed-size fonts in screens.
extension Font {
    enum pc {
        /// 28/34 semibold — greeting, onboarding headlines. Maps to Title 1.
        static let display = Font.title.weight(.semibold)
        /// 22/28 semibold — screen titles. Maps to Title 2.
        static let title = Font.title2.weight(.semibold)
        /// 17/22 semibold — section headers (rendered as a small-caps label
        /// treatment in `SectionHeader`). Maps to Headline.
        static let heading = Font.headline
        /// 16/22 regular — item titles, primary content. Maps to Body.
        static let body = Font.body
        /// 14/20 regular — metadata, attribution, explanations. Maps to Subheadline.
        static let secondary = Font.subheadline
        /// 12/16 medium — badges, chips, timestamps. Maps to Caption.
        static let caption = Font.caption.weight(.medium)
    }
}
