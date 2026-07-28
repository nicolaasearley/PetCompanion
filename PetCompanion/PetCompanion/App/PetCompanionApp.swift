import SwiftUI

@main
struct PetCompanionApp: App {
    @State private var model = AppModel.bootstrap()
    @Environment(\.scenePhase) private var scenePhase

    /// Registered during launch, before a tap that woke the app is delivered.
    /// It only buffers targets; resolving one needs a restored session, so
    /// the handler is installed after the backend has been activated.
    private let notificationInbox = NotificationDeepLinkInbox()

    init() {
        notificationInbox.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Color.pc.primary)
                .task {
                    await model.activateConfiguredBackend()
                    notificationInbox.setHandler { target in
                        Task { await model.open(target) }
                    }
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
