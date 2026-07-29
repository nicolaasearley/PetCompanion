import SwiftUI

/// Linear onboarding stack — doc 14 §4. Back never loses entered data
/// within the session (each screen owns its own state while pushed).
/// ON-09 ships in a later slice (doc 17 WP-2).
enum OnboardingRoute: Hashable {
    case createAccount
    case signIn
    case requestPasswordReset
    case createHousehold
    case addPet
    case routineBasics
    case confirmEmail(String)
    /// ON-05. Carries a token when the invitee arrived from a link.
    case reviewInvitation(String?)
}

struct OnboardingFlowView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [OnboardingRoute] = []
    @State private var routingError: String?

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(
                onGetStarted: { path.append(.createAccount) },
                onSignIn: { path.append(.signIn) }
            )
            .navigationDestination(for: OnboardingRoute.self) { route in
                switch route {
                case .createAccount:
                    AuthFormView(
                        mode: .createAccount,
                        onAuthenticated: routeAfterAuth,
                        onConfirmationRequired: { path.append(.confirmEmail($0)) }
                    )
                case .signIn:
                    AuthFormView(
                        mode: .signIn,
                        onAuthenticated: routeAfterAuth,
                        onForgotPassword: { path.append(.requestPasswordReset) }
                    )
                case .requestPasswordReset:
                    RequestPasswordResetView(
                        onBackToSignIn: { path = [.signIn] }
                    )
                case .createHousehold:
                    CreateHouseholdView(
                        onContinue: { path.append(.addPet) },
                        onHasInvitation: { path.append(.reviewInvitation(nil)) }
                    )
                case .reviewInvitation(let token):
                    InvitationReviewView(initialToken: token) { household in
                        Task { apply(await model.joinedHousehold(household)) }
                    }
                case .addPet:
                    AddPetView(onContinue: { path.append(.routineBasics) })
                case .routineBasics:
                    RoutineBasicsView(onFinish: { model.finishOnboarding() })
                case .confirmEmail(let email):
                    EmailConfirmationView(
                        email: email,
                        onSignIn: { path.append(.signIn) }
                    )
                }
            }
        }
        .task {
            if model.consumePasswordRecoverySignInRequest() {
                path = [.signIn]
                return
            }
            guard path.isEmpty, let destination = model.consumePendingOnboardingDestination() else {
                return
            }
            apply(destination)
        }
        .alert(
            "Setup couldn't continue",
            isPresented: Binding(
                get: { routingError != nil },
                set: { if !$0 { routingError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(routingError ?? "Try again.")
        }
    }

    /// ON-02/ON-03 routing: existing household → HM-01; otherwise → ON-06.
    /// (Pending-invitation routing to ON-05 is Slice B.)
    private func routeAfterAuth(_ user: UserAccount) {
        Task {
            do {
                apply(try await model.didAuthenticate(user))
            } catch {
                routingError = error.localizedDescription
            }
        }
    }

    private func apply(_ destination: AppModel.PostAuthDestination) {
        switch destination {
        case .main:
            break
        case .createHousehold:
            path = [.createHousehold]
        case .addPet:
            path = [.addPet]
        case .reviewInvitation(let token):
            path = [.reviewInvitation(token)]
        }
    }
}

struct EmailConfirmationView: View {
    let email: String
    let onSignIn: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.xxl) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Color.pc.primary)
                    .accessibilityHidden(true)
                Text("Check your email")
                    .font(Font.pc.title)
                    .foregroundStyle(Color.pc.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("We sent a confirmation link to \(email). Open it, then return here and sign in.")
                    .font(Font.pc.body)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton(title: "I've confirmed — sign in", action: onSignIn)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PCSpacing.screenMargin)
        }
        .background(Color.pc.bg.ignoresSafeArea())
        .navigationBarBackButtonHidden()
    }
}

/// Shared "Step n of 3" progress affordance shown from ON-06 onward.
struct OnboardingStepLabel: View {
    let step: Int

    var body: some View {
        Text("Step \(step) of 3")
            .font(Font.pc.secondary)
            .foregroundStyle(Color.pc.inkSecondary)
    }
}

#Preview("Onboarding flow") {
    OnboardingFlowView()
        .environment(AppModel.mock())
        .tint(Color.pc.primary)
}
