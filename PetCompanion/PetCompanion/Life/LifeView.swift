import SwiftUI

struct LifeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ZStack {
                Color.pc.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: PCSpacing.xl) {
                        EmptyStateView(
                            systemImage: "photo.on.rectangle.angled",
                            message: "\(model.activePet?.name ?? "Your puppy")'s story will collect milestones, photos, and everyday memories here."
                        )

                        VStack(alignment: .leading, spacing: PCSpacing.md) {
                            SectionHeader(title: "First-year moments")
                            LifePromptRow(icon: "house", title: "First day home")
                            LifePromptRow(icon: "figure.pool.swim", title: "First swim")
                            LifePromptRow(icon: "graduationcap", title: "Puppy class graduation")
                        }
                        .padding(.horizontal, PCSpacing.screenMargin)
                    }
                    .padding(.bottom, PCSpacing.huge)
                }
            }
            .navigationTitle("Life")
            .profileEntry()
        }
    }
}

private struct LifePromptRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: PCSpacing.md) {
            Image(systemName: icon)
                .foregroundStyle(Color.pc.accent)
                .frame(width: 28)
            Text(title)
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.ink)
            Spacer()
            Text("Coming later")
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkTertiary)
        }
        .padding(PCSpacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .strokeBorder(Color.pc.border, lineWidth: 1)
        )
    }
}

#Preview("Life timeline") {
    LifeView()
        .environment(AppModel.preview())
}
