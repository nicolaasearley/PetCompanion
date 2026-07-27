import SwiftUI

@main
struct PetCompanionApp: App {
    @State private var model = AppModel.bootstrap()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Color.pc.primary)
                .task {
                    await model.activateConfiguredBackend()
                    #if DEBUG
                    await IntegrationProbe.runIfRequested(model: model)
                    await IntegrationProbe.runPlanProbeIfRequested(model: model)
                    await IntegrationProbe.runPlannerProbeIfRequested(model: model)
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.replayOfflineOperations() }
                }
        }
    }
}
