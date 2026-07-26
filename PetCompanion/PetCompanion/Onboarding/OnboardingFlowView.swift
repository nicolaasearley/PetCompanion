import SwiftUI

/// Linear onboarding stack — doc 14 §4. Back never loses entered data
/// within the session (each screen owns its own state while pushed).
/// ON-04/ON-05/ON-09 ship in later slices (doc 17 WP-2).
enum OnboardingRoute: Hashable {
    case createAccount
    case signIn
    case createHousehold
    case addPet
    case routineBasics
}

struct OnboardingFlowView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [OnboardingRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(
                onGetStarted: { path.append(.createAccount) },
                onSignIn: { path.append(.signIn) }
            )
            .navigationDestination(for: OnboardingRoute.self) { route in
                switch route {
                case .createAccount:
                    AuthFormView(mode: .createAccount, onAuthenticated: routeAfterAuth)
                case .signIn:
                    AuthFormView(mode: .signIn, onAuthenticated: routeAfterAuth)
                case .createHousehold:
                    CreateHouseholdView(onContinue: { path.append(.addPet) })
                case .addPet:
                    AddPetView(onContinue: { path.append(.routineBasics) })
                case .routineBasics:
                    RoutineBasicsView(onFinish: { model.finishOnboarding() })
                }
            }
        }
    }

    /// ON-02/ON-03 routing: existing household → HM-01; otherwise → ON-06.
    /// (Pending-invitation routing to ON-05 is Slice B.)
    private func routeAfterAuth(_ user: UserAccount) {
        Task {
            let destination = await model.didAuthenticate(user)
            if destination == .createHousehold {
                path.append(.createHousehold)
            }
            // .main: RootView switches to the tabs automatically.
        }
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
