import SwiftUI

/// The five fixed top-level destinations — IA §5.2. Labels always visible;
/// active tab = filled icon + `primary` tint; badge-free in MVP (doc 09
/// §7.9). Each destination now has an honest, useful first surface; record
/// creation remains gated until its owning backend slice exists.
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
                        PlannerView(viewModel: planViewModel)
                    }
                    Tab("Training", systemImage: "graduationcap", value: .training) {
                        TrainingView()
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
        }
    }
}

#Preview("Main tabs") {
    MainTabView()
        .environment(AppModel.preview())
}
