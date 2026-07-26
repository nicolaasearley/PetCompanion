import SwiftUI

/// The five fixed top-level destinations — IA §5.2. Labels always visible;
/// active tab = filled icon + `primary` tint; badge-free in MVP (doc 09
/// §7.9). Planner/Training/Care/Life are Slice A placeholder stubs.
struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                HomeView()
            }
            Tab("Planner", systemImage: "calendar") {
                PlaceholderScreen(
                    title: "Planner",
                    systemImage: "calendar",
                    message: "The Planner will show your household's tasks and events by day."
                )
            }
            Tab("Training", systemImage: "graduationcap") {
                PlaceholderScreen(
                    title: "Training",
                    systemImage: "graduationcap",
                    message: "Training will hold the skill catalogue, your goals, and the socialization passport."
                )
            }
            Tab("Care", systemImage: "heart.text.square") {
                PlaceholderScreen(
                    title: "Care",
                    systemImage: "heart.text.square",
                    message: "Care will keep the pet profile, health records, medications, and providers."
                )
            }
            Tab("Life", systemImage: "book") {
                PlaceholderScreen(
                    title: "Life",
                    systemImage: "book",
                    message: "Life will collect milestones, photos, and the story of your time together."
                )
            }
        }
        .tint(Color.pc.primary)
    }
}

/// Placeholder screen for tabs whose content ships in later slices —
/// calm, specific copy naming what would appear (IA §15 empty-state rule),
/// never error styling.
struct PlaceholderScreen: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        NavigationStack {
            ZStack {
                Color.pc.bg.ignoresSafeArea()
                EmptyStateView(systemImage: systemImage, message: message)
            }
            .navigationTitle(title)
        }
    }
}

#Preview("Main tabs") {
    MainTabView()
        .environment(AppModel.preview())
}
