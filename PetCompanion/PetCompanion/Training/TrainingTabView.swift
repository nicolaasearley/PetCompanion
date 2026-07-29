import SwiftUI

/// The Training tab's content: the skill catalogue plus the entry into the
/// socialization passport (wireframes TR-06 is reached from Training).
///
/// It composes `TrainingView` rather than modifying it, so the two surfaces
/// stay independently owned: the docked entry is a `safeAreaInset` outside
/// `TrainingView`'s own `NavigationStack`, and the passport is presented in a
/// stack of its own.
struct TrainingTabView: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingPassport = false

    var body: some View {
        TrainingView()
            .safeAreaInset(edge: .bottom) {
                if model.activePet != nil {
                    passportEntry
                }
            }
            .sheet(isPresented: $isShowingPassport) {
                if let store = model.makeSocializationStore() {
                    NavigationStack {
                        SocializationPassportView(store: store)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { isShowingPassport = false }
                                }
                            }
                    }
                }
            }
    }

    private var passportEntry: some View {
        Button {
            isShowingPassport = true
        } label: {
            HStack(spacing: PCSpacing.md) {
                Image(systemName: "figure.walk.motion")
                    .foregroundStyle(Color.pc.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Socialization passport")
                        .font(Font.pc.body.weight(.semibold))
                        .foregroundStyle(Color.pc.ink)
                    Text("Gentle, positive, varied")
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.inkSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
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
            .padding(.horizontal, PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.sm)
        }
        .buttonStyle(.plain)
        .background(
            Color.pc.bg
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.pc.border)
                        .frame(height: 1)
                }
        )
        .accessibilityHint("Opens the socialization passport")
    }
}

extension SocializationStore {
    /// Preview and mock-build store, seeded so TR-06's breadth line, the
    /// recent list, and a paused category are all visible without a backend.
    static func preview() -> SocializationStore {
        let calendar = Calendar.current
        func daysAgo(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        }
        let seeded: [SocializationRecord] = [
            .init(
                id: UUID(), experienceContentId: "soc.sounds.vacuum_low",
                label: "Vacuum at low volume/distance", category: .sounds,
                effectiveDate: daysAgo(2), context: "Two rooms away",
                response: .curious, note: nil, revision: 1, recordedByName: "Sarah"
            ),
            .init(
                id: UUID(), experienceContentId: "soc.surfaces.grass",
                label: "Grass", category: .surfaces,
                effectiveDate: daysAgo(4), context: nil,
                response: .relaxed, note: nil, revision: 1, recordedByName: "Nic"
            ),
            .init(
                id: UUID(), experienceContentId: "soc.people.calm_adult_visitor",
                label: "Calm adult visitor", category: .people,
                effectiveDate: daysAgo(9), context: "Sat down before saying hello",
                response: .hesitant, note: nil, revision: 1, recordedByName: "Nic"
            ),
        ]
        return SocializationStore(
            service: InMemorySocializationService(actorName: "You", seeded: seeded),
            petId: UUID(),
            petName: "Maple"
        )
    }
}

#Preview("Training tab") {
    TrainingTabView()
        .environment(AppModel.preview())
}
