import Foundation

/// Typed accessors for user-facing copy in `Localization/Localizable.xcstrings`.
///
/// **Pattern for new strings**
/// 1. Add a stable key to the String Catalog (`tab.home`, `home.all_caught_up.message`, …).
/// 2. Expose it here under the closest feature namespace.
/// 3. Reference `PCL10n…` at the call site instead of a raw literal.
///
/// English is the source language. Additional locales belong in the catalog only —
/// do not sprinkle translated literals through Swift. Most of the app is still
/// English-only until a feature slice is deliberately migrated.
enum PCL10n {
    enum Tab {
        static let home = String(localized: "tab.home")
        static let planner = String(localized: "tab.planner")
        static let training = String(localized: "tab.training")
        static let care = String(localized: "tab.care")
        static let life = String(localized: "tab.life")
    }

    enum Shell {
        static let preparingPlan = String(localized: "shell.preparing_plan")
    }

    enum Home {
        static let allCaughtUpMessage = String(localized: "home.all_caught_up.message")
        static let allCaughtUpAddTask = String(localized: "home.all_caught_up.add_task")
        static let profileSettingsAccessibility = String(localized: "home.profile_settings.accessibility")
        static let quickAddTitle = String(localized: "home.quick_add.title")
        static let quickAddAccessibilityHint = String(localized: "home.quick_add.accessibility_hint")
    }
}
