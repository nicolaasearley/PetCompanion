import SwiftUI

/// CA-01 — Care overview. Weight, providers, medications, vaccinations,
/// grooming, notes (with document photo attach), and appointments are live.
struct CareView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.household != nil {
                    VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                        if let pet = model.activePet {
                            petCard(pet)
                        } else {
                            EmptyStateView(
                                systemImage: "pawprint",
                                message: "Add a pet to start weight and other pet-scoped care records."
                            )
                        }

                        VStack(alignment: .leading, spacing: PCSpacing.betweenCards) {
                            SectionHeader(title: "Care records")

                            if let pet = model.activePet {
                                NavigationLink {
                                    if let medsStore = model.makeMedicationsStore() {
                                        MedicationsView(store: medsStore)
                                    }
                                } label: {
                                    CareDestinationRow(
                                        title: "Medications",
                                        subtitle: "Schedules and doses for \(pet.name)",
                                        systemImage: "pills",
                                        status: .available
                                    )
                                }
                                .buttonStyle(.plain)

                                NavigationLink {
                                    if let weightStore = model.makeWeightStore() {
                                        WeightGrowthView(store: weightStore)
                                    }
                                } label: {
                                    CareDestinationRow(
                                        title: "Weight & growth",
                                        subtitle: "Dated entries for \(pet.name)",
                                        systemImage: "chart.line.uptrend.xyaxis",
                                        status: .available
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            NavigationLink {
                                if let eventStore = model.makeEventStore() {
                                    EventsView(store: eventStore)
                                }
                            } label: {
                                CareDestinationRow(
                                    title: "Appointments & events",
                                    subtitle: "Vet visits, classes, and other dates",
                                    systemImage: "calendar",
                                    status: .available
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Add or edit vet appointments and other household events")

                            NavigationLink {
                                if let providersStore = model.makeProvidersStore() {
                                    ProvidersView(store: providersStore)
                                }
                            } label: {
                                CareDestinationRow(
                                    title: "Providers",
                                    subtitle: "Veterinarians and other contacts",
                                    systemImage: "cross.case",
                                    status: .available
                                )
                            }
                            .buttonStyle(.plain)

                            if let pet = model.activePet {
                                NavigationLink {
                                    if let vaccinationsStore = model.makeVaccinationStore() {
                                        VaccinationsView(store: vaccinationsStore)
                                    }
                                } label: {
                                    CareDestinationRow(
                                        title: "Vaccinations",
                                        subtitle: "History for \(pet.name)",
                                        systemImage: "syringe",
                                        status: .available
                                    )
                                }
                                .buttonStyle(.plain)

                                NavigationLink {
                                    if let groomingStore = model.makeGroomingStore() {
                                        GroomingView(store: groomingStore)
                                    }
                                } label: {
                                    CareDestinationRow(
                                        title: "Grooming",
                                        subtitle: "History for \(pet.name)",
                                        systemImage: "comb",
                                        status: .available
                                    )
                                }
                                .buttonStyle(.plain)

                                NavigationLink {
                                    if let notesStore = model.makeCareNoteStore() {
                                        CareNotesView(store: notesStore)
                                    }
                                } label: {
                                    CareDestinationRow(
                                        title: "Notes",
                                        subtitle: "Observations for \(pet.name)",
                                        systemImage: "doc.text",
                                        status: .available
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Text("Care records are not medical advice. Keep medication and treatment instructions exactly as provided by your veterinarian.")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(PCSpacing.screenMargin)
                    .padding(.bottom, PCSpacing.huge)
                } else {
                    EmptyStateView(
                        systemImage: "heart.text.square",
                        message: "Add a pet to start keeping care records for your household."
                    )
                    .padding(.top, PCSpacing.xxxl)
                }
            }
            .background(Color.pc.bg)
            .navigationTitle("Care")
            .profileEntry()
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
    enum Status {
        case available
        case planned
    }

    let title: String
    let subtitle: String
    let systemImage: String
    var status: Status = .planned

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
            if status == .planned {
                PCChip(text: "Planned", style: .neutral)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.pc.inkTertiary)
                    .accessibilityHidden(true)
            }
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
        .accessibilityAddTraits(status == .available ? .isButton : [])
        .accessibilityHint(status == .available ? "Opens \(title)" : "Planned — not available yet")
    }
}

#Preview("Care overview") {
    CareView()
        .environment(AppModel.preview())
}
