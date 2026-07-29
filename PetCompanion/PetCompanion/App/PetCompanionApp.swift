import SwiftUI
import UIKit

final class PetCompanionAppDelegate: NSObject, UIApplicationDelegate {
    weak var pushRegistration: (any RemotePushRegistering)?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        pushRegistration?.didReceiveDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        pushRegistration?.didFailToRegister(error: error)
    }
}

@main
struct PetCompanionApp: App {
    @UIApplicationDelegateAdaptor(PetCompanionAppDelegate.self) private var appDelegate
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
                    appDelegate.pushRegistration = model.pushRegistration
                    await model.activateConfiguredBackend()
                    // Backend activation may replace the push registration
                    // instance with the live write-path transport.
                    appDelegate.pushRegistration = model.pushRegistration
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
                    Task {
                        await model.replayOfflineOperations()
                        await model.pushRegistration.refreshRegistration()
                        model.refreshPlanAfterForeground()
                        await model.refreshEventRemindersAfterForeground()
                    }
                }
                .onOpenURL { url in
                    Task { await model.open(url) }
                }
        }
    }
}
