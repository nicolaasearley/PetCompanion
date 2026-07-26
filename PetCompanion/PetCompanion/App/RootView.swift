import SwiftUI

/// Switches between the onboarding flow and the main tabs based on the
/// session phase. Transition is a cross-fade, which stays valid under
/// reduced motion (doc 09 §8).
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.phase {
            case .onboarding:
                OnboardingFlowView()
                    .transition(.opacity)
            case .main:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.phase)
    }
}

#Preview("Onboarding phase") {
    RootView()
        .environment(AppModel.mock())
        .tint(Color.pc.primary)
}

#Preview("Main phase") {
    RootView()
        .environment(AppModel.preview())
        .tint(Color.pc.primary)
}
