import SwiftUI

/// TR-02 — Skill catalogue. Grouped by the F08 groups, searchable, with a
/// "fits current stage" toggle that defaults on.
///
/// A skill with an unmet prerequisite stays viewable and says what is missing;
/// only starting it is disabled (US-060 "Unmet prerequisites are clear",
/// F08 "Content with unmet prerequisites is not presented as ready to
/// practice"). Browsing never schedules anything.
struct TrainingCatalogueView: View {
    let viewModel: TrainingViewModel
    let stage: DevelopmentStage

    @State private var query = ""
    @State private var fitsStageOnly = true

    private var groups: [(name: String, skills: [TrainingSkill])] {
        let matches = viewModel.skills(matching: query, stage: stage, fitsStageOnly: fitsStageOnly)
        return Dictionary(grouping: matches, by: \.skillGroup)
            .map { (name: $0.key, skills: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                Toggle("Show skills that fit the current stage", isOn: $fitsStageOnly)
                    .font(Font.pc.body)
                    .tint(Color.pc.primary)

                if groups.isEmpty {
                    EmptyStateView(
                        systemImage: "magnifyingglass",
                        message: "No skills match this search and stage filter.",
                        primaryActionTitle: "Show all skills",
                        primaryAction: {
                            query = ""
                            fitsStageOnly = false
                        }
                    )
                } else {
                    ForEach(groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: PCSpacing.md) {
                            SectionHeader(title: group.name)
                            LazyVStack(spacing: PCSpacing.betweenCards) {
                                ForEach(group.skills) { skill in
                                    NavigationLink(value: TrainingRoute.lesson(skill.contentId)) {
                                        CatalogueSkillRow(
                                            skill: skill,
                                            stage: stage,
                                            goal: viewModel.overview.goal(forSkill: skill.contentId),
                                            unmet: viewModel.overview.unmetPrerequisites(for: skill)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .background(Color.pc.bg)
        .navigationTitle("Skills")
        .searchable(text: $query, prompt: "Search skills")
    }
}

private struct CatalogueSkillRow: View {
    let skill: TrainingSkill
    let stage: DevelopmentStage
    let goal: TrainingGoal?
    let unmet: [TrainingSkill]

    private var fitsStage: Bool {
        TrainingViewModel.rank(skill.stageGuidance) <= TrainingViewModel.rank(stage)
    }

    var body: some View {
        HStack(spacing: PCSpacing.md) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.pc.primary)
                .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
                .background(Circle().fill(Color.pc.surfaceSubtle))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PCSpacing.xs) {
                Text(skill.title)
                    .font(Font.pc.body.weight(.semibold))
                    .foregroundStyle(Color.pc.ink)
                    .multilineTextAlignment(.leading)
                Text("\(skill.effortBand.displayText) · \(skill.frequencyDisplayText)")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)

                HStack(spacing: PCSpacing.xs) {
                    if let goal {
                        // Name the owner-reported state — never a completion %.
                        PCChip(
                            text: goal.status == .paused
                                ? "Paused · \(goal.progressState.displayName)"
                                : goal.progressState.displayName,
                            style: goal.status == .paused ? .neutral : .success
                        )
                    }
                    PCChip(
                        text: fitsStage ? "Fits now" : skill.stageGuidance.displayName,
                        style: fitsStage ? .info : .neutral
                    )
                }

                if !unmet.isEmpty {
                    Text("Needs: \(unmet.map(\.title).joined(separator: ", "))")
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.inkTertiary)
                }
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
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens lesson")
    }
}
