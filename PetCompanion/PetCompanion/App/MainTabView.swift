import SwiftUI

/// The five fixed top-level destinations — IA §5.2. Labels always visible;
/// active tab = filled icon + `primary` tint; badge-free in MVP (doc 09
/// §7.9). Each destination now has an honest, useful first surface; record
/// creation remains gated until its owning backend slice exists.
///
/// It is also where a tapped reminder lands, once `AppModel` has resolved it
/// against current state (doc 20 §4.10).
struct MainTabView: View {
    private enum Destination: Hashable {
        case home
        case planner
        case training
        case care
        case life
    }

    @Environment(AppModel.self) private var model
    @State private var planViewModel: HomeViewModel?
    @State private var destination: Destination
    @State private var deepLinkFailure: DeepLinkFailure?

    init() {
        #if DEBUG
        let initial: Destination = ProcessInfo.processInfo.environment["PC_START_TAB"] == "planner"
            ? .planner
            : .home
        #else
        let initial: Destination = .home
        #endif
        _destination = State(initialValue: initial)
    }

    var body: some View {
        Group {
            if let planViewModel {
                TabView(selection: $destination) {
                    Tab("Home", systemImage: "house", value: .home) {
                        HomeView(viewModel: planViewModel)
                    }
                    Tab("Planner", systemImage: "calendar", value: .planner) {
                        PlannerView()
                    }
                    Tab("Training", systemImage: "graduationcap", value: .training) {
                        TrainingTabView()
                    }
                    Tab("Care", systemImage: "heart.text.square", value: .care) {
                        CareView()
                    }
                    Tab("Life", systemImage: "book", value: .life) {
                        LifeView()
                    }
                }
                .tint(Color.pc.primary)
            } else {
                ProgressView("Preparing your plan…")
                    .tint(Color.pc.primary)
            }
        }
        .task {
            if planViewModel == nil {
                planViewModel = HomeViewModel(model: model)
            }
            apply(model.pendingDeepLink)
        }
        .onChange(of: model.pendingDeepLink) { _, link in
            apply(link)
        }
        .sheet(item: $deepLinkFailure) { failure in
            DeepLinkUnavailableView(
                failure: failure,
                onShowToday: { deepLinkFailure = nil },
                onCreateHousehold: {
                    deepLinkFailure = nil
                    model.signOut()
                }
            )
        }
    }

    /// The reminder has already been checked against the plan by the time it
    /// arrives here, so this only places the caregiver — it never decides
    /// whether the target is still real.
    private func apply(_ link: ResolvedDeepLink?) {
        guard let link else { return }
        model.pendingDeepLink = nil
        switch link {
        case .home:
            destination = .home
        case .planner:
            destination = .planner
        case .planItem(let id):
            destination = .home
            planViewModel?.openDetail(itemId: id)
        case .unavailable(let failure):
            destination = .home
            deepLinkFailure = failure
        }
    }
}

#Preview("Main tabs") {
    MainTabView()
        .environment(AppModel.preview())
}
