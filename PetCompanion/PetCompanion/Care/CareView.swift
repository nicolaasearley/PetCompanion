import SwiftUI

struct CareView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                if let pet = model.activePet {
                    VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                        petCard(pet)

                        VStack(alignment: .leading, spacing: PCSpacing.betweenCards) {
                            SectionHeader(title: "Care records")
                            CareDestinationRow(
                                title: "Vaccinations",
                                subtitle: "Record tracking is planned",
                                systemImage: "syringe"
                            )
                            CareDestinationRow(
                                title: "Weight & growth",
                                subtitle: "Growth entries are planned",
                                systemImage: "chart.line.uptrend.xyaxis"
                            )
                            CareDestinationRow(
                                title: "Grooming",
                                subtitle: "Routine history is planned",
                                systemImage: "comb"
                            )
                            CareDestinationRow(
                                title: "Notes & documents",
                                subtitle: "Secure document storage is planned",
                                systemImage: "doc.text"
                            )
                            CareDestinationRow(
                                title: "Providers",
                                subtitle: "Provider contacts are planned",
                                systemImage: "cross.case"
                            )
                        }

                        Text("Care records are not medical advice. Keep medication and treatment instructions exactly as provided by your veterinarian.")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(PCSpacing.screenMargin)
                    .padding(.bottom, PCSpacing.huge)
                }
            }
            .background(Color.pc.bg)
            .navigationTitle("Care")
        }
    }

    private func petCard(_ pet: Pet) -> some View {
        HStack(spacing: PCSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.pc.surfaceSubtle)
                    .frame(width: 76, height: 76)
                Image(systemName: "dog")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.pc.primary)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PCSpacing.xs) {
                Text(pet.name)
                    .font(Font.pc.title)
                    .foregroundStyle(Color.pc.ink)
                Text(
                    pet.ageAndStageDisplay(
                        calendar: model.household?.clock.calendar ?? .current
                    )
                )
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                if let breed = pet.breedText, !breed.isEmpty {
                    Text(breed)
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                }
            }
            Spacer()
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
        .accessibilityElement(children: .combine)
    }
}

private struct CareDestinationRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: PCSpacing.md) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.pc.primary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PCSpacing.xs) {
                Text(title)
                    .font(Font.pc.body.weight(.semibold))
                    .foregroundStyle(Color.pc.ink)
                Text(subtitle)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
            }
            Spacer()
            PCChip(text: "Planned", style: .neutral)
        }
        .padding(PCSpacing.cardPadding)
        .frame(minHeight: PCMetrics.listRowHeight)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .strokeBorder(Color.pc.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview("Care overview") {
    CareView()
        .environment(AppModel.preview())
}
