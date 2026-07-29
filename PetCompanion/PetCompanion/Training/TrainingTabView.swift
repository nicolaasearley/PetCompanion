import SwiftUI

/// The Training tab's root content.
///
/// This used to also own a docked `safeAreaInset` row and the socialization
/// passport's sheet state, presented below `TrainingView`'s own content —
/// the passport's only entry point on the tab. The owner's updated Training
/// hierarchy (2026-07-29) promotes that entry point to a hero tile inside
/// `TrainingView` itself (`SocializationPassportHero`, first thing on the
/// screen, ahead of Active goals/Suggested/Browse), so `TrainingView` now
/// owns that state and sheet directly and there is nothing left for this
/// wrapper to add. It stays as a thin pass-through so `MainTabView`'s tab
/// wiring doesn't need to change.
struct TrainingTabView: View {
    var body: some View {
        TrainingView()
    }
}

#Preview("Training tab") {
    TrainingTabView()
        .environment(AppModel.preview())
}
