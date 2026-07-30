import SwiftUI

/// Switches between the onboarding flow and the main tabs based on the
/// session phase. Transition is a cross-fade, which stays valid under
/// reduced motion (doc 09 §8).
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.passwordRecoveryState != nil {
                SetNewPasswordView()
                    .transition(.opacity)
            } else {
                switch model.backendMode {
                case .resolving:
                    ProgressView("Connecting…")
                        .tint(Color.pc.primary)
                case .unavailable:
                    backendUnavailable
                case .mock, .local, .hosted:
                    switch model.phase {
                    case .onboarding:
                        OnboardingFlowView()
                            .transition(.opacity)
                    case .main:
                        MainTabView()
                            .transition(.opacity)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.phase)
        .animation(.easeInOut(duration: 0.2), value: model.backendMode)
        .animation(.easeInOut(duration: 0.2), value: model.passwordRecoveryState)
        .alert(
            model.appURLNotice?.title ?? "Link unavailable",
            isPresented: Binding(
                get: { model.appURLNotice != nil },
                set: { if !$0 { model.dismissAppURLNotice() } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.dismissAppURLNotice()
            }
        } message: {
            Text(model.appURLNotice?.message ?? "Try again.")
        }
    }

    private var backendUnavailable: some View {
        VStack(spacing: PCSpacing.lg) {
            Image(systemName: "network.slash")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.pc.primary)
                .accessibilityHidden(true)
            Text("Can't connect")
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
            Text(model.backendMessage ?? "Settle couldn't reach its service.")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Try again") {
                Task { await model.activateConfiguredBackend() }
            }
        }
        .padding(PCSpacing.screenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pc.bg.ignoresSafeArea())
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
