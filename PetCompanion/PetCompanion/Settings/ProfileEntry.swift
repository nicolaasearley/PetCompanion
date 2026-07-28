import SwiftUI

/// The Profile & Settings entry every top-level surface owes the caregiver.
///
/// IA §5.3 asks for two shapes of the same thing: the avatar button in the
/// Home header, and "a header overflow on other tabs". Home already had the
/// avatar, so Settings was reachable from exactly one of five destinations —
/// and everything behind it (ST-04 members & invitations, ST-06 notification
/// preferences, sign out) required returning to Home first. A sixth tab is
/// explicitly ruled out by §5.2, so the overflow is the route.
///
/// The overflow lists the hub plus the household, because ST-04 is now a real
/// destination rather than a promise. Everything else lives one screen deeper
/// inside the hub, which is where the IA puts it.
struct ProfileEntry: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var route: SettingsView.Destination?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            route = .hub
                        } label: {
                            Label("Profile & settings", systemImage: "person.crop.circle")
                        }
                        if model.household != nil {
                            Button {
                                route = .members
                            } label: {
                                Label("Members & invitations", systemImage: "person.2")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(
                                width: PCMetrics.minTouchTarget,
                                height: PCMetrics.minTouchTarget
                            )
                    }
                    .accessibilityLabel("Profile and settings")
                }
            }
            .sheet(item: $route) { destination in
                SettingsView(opening: destination)
            }
    }
}

extension View {
    /// Adds the header overflow entry to Profile & Settings (IA §5.3). Apply
    /// it inside the surface's own `NavigationStack`, alongside its
    /// `navigationTitle` — a toolbar contributed from outside the stack
    /// belongs to the enclosing container, not to this header.
    func profileEntry() -> some View {
        modifier(ProfileEntry())
    }
}
