import SwiftUI

/// TR-03 — Skill lesson. Steps, effort, frequency, prerequisites, safety
/// notes, common mistakes, and the goal action for this skill.
///
/// The lesson is fully usable without media (US-062), the content version and
/// review status are always shown (F08), and starting is idempotent — the
/// button reads "Start this goal" only while there is no goal to start.
struct TrainingLessonView: View {
    let skillRef: String
    let viewModel: TrainingViewModel
    let petId: UUID?
    let calendar: Calendar

    @State private var isLoggingSession = false
    @State private var confirmingRetire = false

    private var skill: TrainingSkill? { viewModel.overview.skill(skillRef) }
    private var goal: TrainingGoal? { viewModel.overview.goal(forSkill: skillRef) }
    private var unmet: [TrainingSkill] {
        skill.map { viewModel.overview.unmetPrerequisites(for: $0) } ?? []
    }

    var body: some View {
        ScrollView {
            if let skill {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    summary(skill)
                    if let message = viewModel.errorMessage {
                        InlineNoticeCard(text: message)
                    }
                    prerequisites(skill)
                    if let safety = skill.safetyNotes, !safety.isEmpty {
                        VStack(alignment: .leading, spacing: PCSpacing.sm) {
                            SectionHeader(title: "Before you start")
                            Text(safety)
                                .font(Font.pc.body)
                                .foregroundStyle(Color.pc.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    steps(skill)
                    mistakes(skill)
                    goalActions(skill)
                    footer(skill)
                }
                .padding(PCSpacing.screenMargin)
                .padding(.bottom, PCSpacing.huge)
            } else {
                EmptyStateView(
                    systemImage: "questionmark.circle",
                    message: "This lesson isn't available right now."
                )
                .padding(PCSpacing.screenMargin)
            }
        }
        .background(Color.pc.bg)
        .navigationTitle(skill?.title ?? "Skill")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $isLoggingSession) {
            if let goal {
                LogTrainingSessionView(
                    goal: goal,
                    skill: skill,
                    viewModel: viewModel,
                    calendar: calendar
                )
            }
        }
        .confirmationDialog(
            "Retire this goal?",
            isPresented: $confirmingRetire,
            titleVisibility: .visible
        ) {
            Button("Retire goal", role: .destructive) {
                if let goal { Task { await viewModel.retire(goal) } }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Your logged sessions stay. You can start this skill again later.")
        }
    }

    private func summary(_ skill: TrainingSkill) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            Text(skill.skillGroup)
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
            Text("\(skill.effortBand.displayText) · \(skill.frequencyDisplayText)")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
            PCChip(text: skill.reviewStatus.badgeText, style: .info)
            if let promise = skill.promise, !promise.isEmpty {
                Text(promise)
                    .font(Font.pc.body)
                    .foregroundStyle(Color.pc.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func prerequisites(_ skill: TrainingSkill) -> some View {
        if !skill.prerequisiteSkillRefs.isEmpty {
            VStack(alignment: .leading, spacing: PCSpacing.sm) {
                SectionHeader(title: "Prerequisites")
                ForEach(skill.prerequisiteSkillRefs, id: \.self) { ref in
                    let met = !unmet.contains { $0.contentId == ref }
                    let title = viewModel.overview.skill(ref)?.title ?? ref
                    Label(title, systemImage: met ? "checkmark.circle.fill" : "circle")
                        .font(Font.pc.body)
                        .foregroundStyle(met ? Color.pc.ink : Color.pc.inkSecondary)
                }
            }
        }
    }

    private func steps(_ skill: TrainingSkill) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            SectionHeader(title: "Steps")
            ForEach(Array(skill.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: PCSpacing.md) {
                    Text("\(index + 1)")
                        .font(Font.pc.caption.weight(.semibold))
                        .foregroundStyle(Color.pc.onPrimary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.pc.primary))
                    Text(step)
                        .font(Font.pc.body)
                        .foregroundStyle(Color.pc.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func mistakes(_ skill: TrainingSkill) -> some View {
        if !skill.commonMistakes.isEmpty {
            VStack(alignment: .leading, spacing: PCSpacing.md) {
                SectionHeader(title: "Common mistakes")
                ForEach(skill.commonMistakes, id: \.self) { mistake in
                    Label(mistake, systemImage: "circle.fill")
                        .font(Font.pc.body)
                        .foregroundStyle(Color.pc.ink)
                        .symbolRenderingMode(.monochrome)
                }
            }
        }
    }

    @ViewBuilder
    private func goalActions(_ skill: TrainingSkill) -> some View {
        let isBusy = viewModel.busySkillRef == skill.contentId
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            if let goal {
                Text(goal.recencyText(calendar: calendar))
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)

                TrainingProgressStateBar(
                    model: TrainingProgressAffordanceModel(goal: goal),
                    style: .expanded
                )

                switch goal.status {
                case .active:
                    PrimaryButton(title: "Log session", isLoading: false, isDisabled: isBusy) {
                        isLoggingSession = true
                    }
                    SecondaryButton(title: "Pause this goal", isDisabled: isBusy) {
                        Task { await viewModel.pause(goal) }
                    }
                case .paused:
                    PrimaryButton(title: "Resume", isLoading: isBusy, isDisabled: false) {
                        Task { await viewModel.resume(goal) }
                    }
                case .retired:
                    EmptyView()
                }

                NavigationLink(value: TrainingRoute.history(goal.id)) {
                    NavigationRowLabel(title: "Progress and sessions", systemImage: "chart.line.uptrend.xyaxis")
                }
                .buttonStyle(.plain)

                Button("Retire this goal") { confirmingRetire = true }
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
            } else if unmet.isEmpty {
                PrimaryButton(title: "Start this goal", isLoading: isBusy, isDisabled: false) {
                    Task { await viewModel.start(skill: skill, petId: petId) }
                }
            } else {
                // Not "ready to practice" is stated, and the control is
                // disabled rather than hidden, so the path forward is visible.
                PrimaryButton(title: "Start this goal", isLoading: false, isDisabled: true) {}
                Text("Start \(unmet.map(\.title).joined(separator: " and ")) first.")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
            }
        }
    }

    private func footer(_ skill: TrainingSkill) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            Text("Keep sessions short and stop while your puppy is still comfortable. This is general training guidance, not veterinary or behavioral diagnosis.")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
            // F08: the content source and version stay identifiable.
            Text("\(skill.contentId) · version \(skill.version)")
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkTertiary)
        }
        .padding(PCSpacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surfaceSubtle)
        )
    }
}
