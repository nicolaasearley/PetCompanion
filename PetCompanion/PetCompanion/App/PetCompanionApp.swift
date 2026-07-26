import SwiftUI

@main
struct PetCompanionApp: App {
    @State private var model = AppModel.mock()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Color.pc.primary)
        }
    }
}
