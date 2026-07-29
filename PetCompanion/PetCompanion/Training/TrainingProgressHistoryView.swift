import SwiftUI

/// TR-05 — Progress history. Read-only: the current owner-reported state with
/// its attribution, the explicit picker for changing it, and every logged
/// session with who recorded it.
///
/// The states are explained rather than ranked, and the screen says plainly
/// that this is not a certification (US-065).
struct TrainingProgressHistoryView: View {
    let goalId: UUID
    let viewModel: TrainingViewModel
    let calendar: Calendar

    @State private var isChangingProgress = false

    private var goal: TrainingGoal? {
        viewModel.overview.goals.first { $0.id == goalId }
    }

    var body: some View {
        ScrollView {
            if let goal {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    currentState(goal)
                    if let message = viewModel.errorMessage {
                        InlineNoticeCard(text: message)
                    }
                    sessions(goal)
                }
                .padding(PCSpacing.screenMargin)
                .padding(.bottom, PCSpacing.huge)
            } else {
                EmptyStateView(
                    systemImage: "questionmark.circle",
                    message: "This goal is no longer active."
                )
                .padding(PCSpacing.screenMargin)
            }
        }
        .background(Color.pc.bg)
        .navigationTitle("Progress")
        .sheet(isPresented: $isChangingProgress) {
            if let goal {
                ProgressPickerSheet(goal: goal, viewModel: viewModel)
            }
        }
    }

    private func currentState(_ goal: TrainingGoal) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            SectionHeader(title: "Where you are")

            // Discrete owner-reported continuum — rejects Module Completion %
            // (docs/22 §5.2 / PRODUCT.md unexplained-scores ban).
            TrainingProgressStateBar(
                model: TrainingProgressAffordanceModel(goal: goal),
                style: .expanded
            )

            if let updatedAt = goal.progressStateUpdatedAt {
                Text(
                    "Set by \(viewModel.actorName(goal.progressStateUpdatedBy)) on "
                        + updatedAt.formatted(.dateTime.month().day())
                )
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
            } else {
                Text("Nobody has reported progress yet.")
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
            }

            SecondaryButton(
                title: "Change progress state",
                isDisabled: viewModel.busySkillRef == goal.skillRef
            ) {
                isChangingProgress = true
            }

            Text("These states are what your household reports. They are not a certification, and nothing here is inferred from how often you log sessions.")
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func sessions(_ goal: TrainingGoal) -> some View {
        let sessions = viewModel.overview.sessions(forGoal: goal.id)
        SectionHeader(title: "Sessions (\(sessions.count))")
        if sessions.isEmpty {
            Text("No sessions logged yet.")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
        } else {
            VStack(alignment: .leading, spacing: PCSpacing.md) {
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            session.effectiveDate.formatted(.dateTime.weekday(.wide).month().day())
                                + " · " + viewModel.actorName(session.actorUserId)
                        )
                            .font(Font.pc.body.weight(.medium))
                            .foregroundStyle(Color.pc.ink)
                        if let duration = session.durationMinutes {
                            Text("\(duration) minute\(duration == 1 ? "" : "s")")
                                .font(Font.pc.caption)
                                .foregroundStyle(Color.pc.inkSecondary)
                        }
                        if let note = session.outcomeNote, !note.isEmpty {
                            Text(note)
                                .font(Font.pc.secondary)
                                .foregroundStyle(Color.pc.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let state = session.progressStateAfter {
                            Text("Progress set to \(state.displayName.lowercased())")
                                .font(Font.pc.caption)
                                .foregroundStyle(Color.pc.inkTertiary)
                        }
                        // The version the caregiver actually followed (DM §12.3).
                        Text("Followed \(session.skillRef) v\(session.skillVersion)")
                            .font(Font.pc.caption)
                            .foregroundStyle(Color.pc.inkTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct ProgressPickerSheet: View {
    let goal: TrainingGoal
    let viewModel: TrainingViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var selection: TrainingProgressState

    init(goal: TrainingGoal, viewModel: TrainingViewModel) {
        self.goal = goal
        self.viewModel = viewModel
        _selection = State(initialValue: goal.progressState)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(TrainingProgressState.allCases, id: \.self) { state in
                        Button {
                            selection = state
                        } label: {
                            HStack(alignment: .top, spacing: PCSpacing.md) {
                                Image(systemName: selection == state ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(Color.pc.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(state.displayName)
                                        .font(Font.pc.body)
                                        .foregroundStyle(Color.pc.ink)
                                    Text(state.explanation)
                                        .font(Font.pc.caption)
                                        .foregroundStyle(Color.pc.inkSecondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("You're reporting what you see. Pausing the goal is a separate action and never changes this.")
                }
            }
            .navigationTitle("Progress state")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await viewModel.updateProgress(goal, to: selection)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
