import SwiftUI

@main
struct PetCompanionApp: App {
    @State private var model = AppModel.mock()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Color.pc.primary)
                .task {
                    // Slice A WP-2: promote mock -> local when the local
                    // Supabase stack answers (doc 17 WP-2). No-op (stays
                    // mock) if `supabase start` isn't running.
                    await model.activateLocalBackendIfReachable()
                    #if DEBUG
                    await IntegrationProbe.runIfRequested(model: model)
                    #endif
                }
        }
    }
}
