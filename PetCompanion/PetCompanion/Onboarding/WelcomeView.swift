import SwiftUI

/// ON-01 — Welcome (doc 14 §4).
struct WelcomeView: View {
    let onGetStarted: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Brand-mark placeholder; no announced role (ON-01 a11y note).
            ZStack {
                Circle()
                    .fill(Color.pc.surfaceSubtle)
                    .frame(width: 96, height: 96)
                Image(systemName: "pawprint")
                    .font(.system(.largeTitle, weight: .light))
                    .foregroundStyle(Color.pc.primary)
            }
            .accessibilityHidden(true)
            .padding(.bottom, PCSpacing.xxxl)

            Text("Raising a puppy,\none day at a time.")
                .font(Font.pc.display)
                .foregroundStyle(Color.pc.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text("A shared daily plan for your household — what matters today, what's done, what's next.")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, PCSpacing.lg)

            Spacer()

            VStack(spacing: PCSpacing.md) {
                PrimaryButton(title: "Get started", action: onGetStarted)
                SecondaryButton(title: "I have an account", action: onSignIn)
            }

            Text("Joining someone? Open your invitation link.")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, PCSpacing.xl)
        }
        .padding(.horizontal, PCSpacing.screenMargin)
        .padding(.bottom, PCSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pc.bg.ignoresSafeArea())
        .toolbarVisibility(.hidden, for: .navigationBar)
    }
}

#Preview("ON-01 Welcome") {
    NavigationStack {
        WelcomeView(onGetStarted: {}, onSignIn: {})
    }
}
