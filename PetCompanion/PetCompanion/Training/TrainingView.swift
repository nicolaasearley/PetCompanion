import SwiftUI

struct TrainingSkill: Identifiable, Hashable {
    let id: String
    let name: String
    let group: String
    let stage: DevelopmentStage
    let effort: EffortBand
    let frequency: String
    let prerequisite: String?
    let introduction: String
    let steps: [String]
    let mistakes: [String]
}

enum SeedTrainingCatalogue {
    static let skills: [TrainingSkill] = [
        .init(
            id: "marker_intro",
            name: "Marker word",
            group: "Foundations",
            stage: .settlingIn,
            effort: .tiny,
            frequency: "3–5× per week",
            prerequisite: nil,
            introduction: "Build a clear signal that tells your puppy exactly when they got something right.",
            steps: [
                "Choose one short word, such as “yes.”",
                "Say the word once, then give a small reward.",
                "Repeat five to eight times in a quiet place.",
            ],
            mistakes: ["Giving the reward before the marker", "Changing the marker word"]
        ),
        .init(
            id: "name_response",
            name: "Name response",
            group: "Foundations",
            stage: .settlingIn,
            effort: .tiny,
            frequency: "4–6× per week",
            prerequisite: nil,
            introduction: "Make your puppy's name predict attention and good things.",
            steps: [
                "Wait until your puppy is calmly looking elsewhere.",
                "Say their name once in a warm voice.",
                "Mark and reward the moment they turn toward you.",
            ],
            mistakes: ["Repeating the name", "Using the name for scolding"]
        ),
        .init(
            id: "sit",
            name: "Sit",
            group: "Foundations",
            stage: .foundations,
            effort: .tiny,
            frequency: "3–5× per week",
            prerequisite: "Marker word",
            introduction: "Teach a simple, useful position through short reward-based repetitions.",
            steps: [
                "Hold a reward near the puppy's nose.",
                "Move it slowly up and back until their rear lowers.",
                "Mark, reward, and release before repeating.",
            ],
            mistakes: ["Pushing the puppy's rear down", "Keeping the lure forever"]
        ),
        .init(
            id: "recall",
            name: "Recall foundations",
            group: "Recall and safety",
            stage: .foundations,
            effort: .short,
            frequency: "3–5× per week",
            prerequisite: "Name response",
            introduction: "Start building a joyful response to coming back to you in easy environments.",
            steps: [
                "Begin only a step or two away in a quiet room.",
                "Say the cue once, then move backward invitingly.",
                "Reward generously when your puppy reaches you.",
            ],
            mistakes: ["Repeating the cue", "Calling only to end fun", "Increasing distance too quickly"]
        ),
        .init(
            id: "crate_comfort",
            name: "Crate comfort",
            group: "Calm behavior",
            stage: .settlingIn,
            effort: .short,
            frequency: "Daily at first",
            prerequisite: nil,
            introduction: "Help the crate become a safe, predictable place through choice and rewards.",
            steps: [
                "Leave the door open and reward voluntary investigation.",
                "Feed a few rewards just inside the entrance.",
                "Build duration in seconds while your puppy stays relaxed.",
            ],
            mistakes: ["Using the crate as punishment", "Rushing duration"]
        ),
        .init(
            id: "paw_handling",
            name: "Paw handling",
            group: "Handling and grooming",
            stage: .settlingIn,
            effort: .tiny,
            frequency: "3–4× per week",
            prerequisite: nil,
            introduction: "Pair brief, gentle paw contact with rewards before grooming is necessary.",
            steps: [
                "Touch a shoulder briefly, then reward.",
                "Progress down the leg over several easy sessions.",
                "Release the paw before your puppy pulls away.",
            ],
            mistakes: ["Gripping tightly", "Continuing past discomfort"]
        ),
        .init(
            id: "leave_it",
            name: "Leave it",
            group: "House manners",
            stage: .exploration,
            effort: .short,
            frequency: "2–4× per week",
            prerequisite: "Marker word",
            introduction: "Teach disengagement as a rewarding choice rather than a confrontation.",
            steps: [
                "Close a low-value reward in your fist.",
                "Wait quietly for any move away from your hand.",
                "Mark and reward from your other hand.",
            ],
            mistakes: ["Snatching the item away", "Escalating too quickly"]
        ),
        .init(
            id: "loose_leash",
            name: "Loose-leash foundations",
            group: "Leash skills",
            stage: .exploration,
            effort: .short,
            frequency: "3–4× per week",
            prerequisite: "Harness introduction",
            introduction: "Reward staying near you before distance and distractions make walking harder.",
            steps: [
                "Practice indoors with a comfortable harness and light lead.",
                "Reward one or two steps beside you.",
                "Pause when the lead tightens and continue when it softens.",
            ],
            mistakes: ["Letting pulling work sometimes", "Making early sessions too long"]
        ),
    ]
}

struct TrainingView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var fitsStage = true

    private var pet: Pet? { model.activePet }

    private var filteredSkills: [TrainingSkill] {
        SeedTrainingCatalogue.skills.filter { skill in
            let matchesQuery = query.isEmpty
                || skill.name.localizedCaseInsensitiveContains(query)
                || skill.group.localizedCaseInsensitiveContains(query)
            let currentStage = pet?.stage(
                calendar: model.household?.clock.calendar ?? .current
            ) ?? .foundations
            let matchesStage = !fitsStage || stageRank(skill.stage) <= stageRank(currentStage)
            return matchesQuery && matchesStage
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    if let pet {
                        VStack(alignment: .leading, spacing: PCSpacing.xs) {
                            Text("Small sessions, real progress")
                                .font(Font.pc.title)
                                .foregroundStyle(Color.pc.ink)
                            Text(
                                "Ideas that fit \(pet.name)'s "
                                    + "\(pet.stage(calendar: model.household?.clock.calendar ?? .current).displayName.lowercased()) stage."
                            )
                                .font(Font.pc.secondary)
                                .foregroundStyle(Color.pc.inkSecondary)
                        }
                    }

                    Toggle("Show skills for the current stage", isOn: $fitsStage)
                        .font(Font.pc.body)
                        .tint(Color.pc.primary)

                    SectionHeader(title: "Skill catalogue")
                    if filteredSkills.isEmpty {
                        EmptyStateView(
                            systemImage: pet?.isPreArrival(
                                calendar: model.household?.clock.calendar ?? .current
                            ) == true ? "shippingbox" : "magnifyingglass",
                            message: pet?.isPreArrival(
                                calendar: model.household?.clock.calendar ?? .current
                            ) == true
                                ? "Training ideas will begin gently after \(pet?.name ?? "your puppy") comes home."
                                : "No skills match this search and stage filter.",
                            primaryActionTitle: "Show all skills",
                            primaryAction: {
                                query = ""
                                fitsStage = false
                            }
                        )
                    } else {
                        LazyVStack(spacing: PCSpacing.betweenCards) {
                            ForEach(filteredSkills) { skill in
                                NavigationLink(value: skill) {
                                    TrainingSkillRow(skill: skill)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Text("Seed guidance · pending professional review")
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.inkTertiary)
                }
                .padding(PCSpacing.screenMargin)
                .padding(.bottom, PCSpacing.huge)
            }
            .background(Color.pc.bg)
            .navigationTitle("Training")
            .searchable(text: $query, prompt: "Search skills")
            .navigationDestination(for: TrainingSkill.self) { skill in
                TrainingLessonView(skill: skill)
            }
        }
    }

    private func stageRank(_ stage: DevelopmentStage) -> Int {
        DevelopmentStage.allCases.firstIndex(of: stage) ?? 0
    }
}

private struct TrainingSkillRow: View {
    let skill: TrainingSkill

    var body: some View {
        HStack(spacing: PCSpacing.md) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.pc.primary)
                .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
                .background(Circle().fill(Color.pc.surfaceSubtle))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PCSpacing.xs) {
                Text(skill.name)
                    .font(Font.pc.body.weight(.semibold))
                    .foregroundStyle(Color.pc.ink)
                Text("\(skill.group) · \(skill.effort.displayText)")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                if let prerequisite = skill.prerequisite {
                    Text("Needs: \(prerequisite)")
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.inkTertiary)
                }
            }
            Spacer()
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

private struct TrainingLessonView: View {
    let skill: TrainingSkill

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                VStack(alignment: .leading, spacing: PCSpacing.sm) {
                    Text(skill.group)
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                    Text("\(skill.effort.displayText) · \(skill.frequency)")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                    PCChip(text: "Seed content · review pending", style: .info)
                }

                Text(skill.introduction)
                    .font(Font.pc.body)
                    .foregroundStyle(Color.pc.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let prerequisite = skill.prerequisite {
                    VStack(alignment: .leading, spacing: PCSpacing.sm) {
                        SectionHeader(title: "Before you start")
                        Label(
                            "Recommended first: \(prerequisite)",
                            systemImage: "arrow.triangle.branch"
                        )
                            .font(Font.pc.body)
                            .foregroundStyle(Color.pc.ink)
                    }
                }

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

                VStack(alignment: .leading, spacing: PCSpacing.md) {
                    SectionHeader(title: "Common mistakes")
                    ForEach(skill.mistakes, id: \.self) { mistake in
                        Label(mistake, systemImage: "circle.fill")
                            .font(Font.pc.body)
                            .foregroundStyle(Color.pc.ink)
                            .symbolRenderingMode(.monochrome)
                    }
                }

                Text("Keep sessions short and stop while your puppy is still comfortable. This is general training guidance, not veterinary or behavioral diagnosis.")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .padding(PCSpacing.cardPadding)
                    .background(
                        RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                            .fill(Color.pc.surfaceSubtle)
                    )
            }
            .padding(PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .background(Color.pc.bg)
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.large)
    }
}

#Preview("Training catalogue") {
    TrainingView()
        .environment(AppModel.preview())
}
