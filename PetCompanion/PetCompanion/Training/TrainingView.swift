import SwiftUI

/// TR-01 — Training overview. Active goals with their owner-reported state
/// and recency, stage-appropriate starters, the catalogue entry point, and
/// recent sessions with attribution.
///
/// Everything here comes from `TrainingService`; there is no on-device
/// catalogue any more, so what a caregiver reads is the reviewed content the
/// backend actually holds (F08 "Identify content source, version, and review
/// status").
struct TrainingView: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel: TrainingViewModel?
    @State private var loggingGoal: TrainingGoal?

    private var pet: Pet? { model.activePet }
    private var calendar: Calendar { model.household?.clock.calendar ?? .current }

    private var stage: DevelopmentStage {
        pet?.stage(calendar: calendar) ?? .foundations
    }

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.pc.bg)
            .navigationTitle("Training")
            .navigationDestination(for: TrainingRoute.self) { route in
                destination(route)
            }
        }
        .task {
            let created = viewModel ?? TrainingViewModel(service: model.training, calendar: calendar)
            viewModel = created
            await created.load(petId: pet?.id)
        }
    }

    @ViewBuilder
    private func content(_ viewModel: TrainingViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                header

                if let message = viewModel.errorMessage {
                    InlineNoticeCard(text: message)
                }

                let active = viewModel.overview.activeGoals
                if !active.isEmpty {
                    SectionHeader(title: "Active goals (\(active.count))")
                    LazyVStack(spacing: PCSpacing.betweenCards) {
                        ForEach(active) { goal in
                            ActiveGoalCard(
                                goal: goal,
                                skill: viewModel.overview.skill(goal.skillRef),
                                calendar: calendar,
                                isBusy: viewModel.busySkillRef == goal.skillRef,
                                onLog: { loggingGoal = goal }
                            )
                        }
                    }
                }

                let paused = viewModel.overview.pausedGoals
                if !paused.isEmpty {
                    SectionHeader(title: "Paused (\(paused.count))")
                    LazyVStack(spacing: PCSpacing.betweenCards) {
                        ForEach(paused) { goal in
                            ActiveGoalCard(
                                goal: goal,
                                skill: viewModel.overview.skill(goal.skillRef),
                                calendar: calendar,
                                isBusy: viewModel.busySkillRef == goal.skillRef,
                                onLog: nil
                            )
                        }
                    }
                }

                suggested(viewModel)

                SectionHeader(title: "Browse")
                NavigationLink(value: TrainingRoute.catalogue) {
                    NavigationRowLabel(title: "Skill catalogue", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.plain)

                recentSessions(viewModel)

                if viewModel.overview.catalogue.isEmpty && !viewModel.isLoading {
                    EmptyStateView(
                        systemImage: "wifi.slash",
                        message: "Training content isn't available right now. Anything you've already logged is still here.",
                        primaryActionTitle: "Try again",
                        primaryAction: { Task { await viewModel.load(petId: pet?.id, force: true) } }
                    )
                }

                Text("Progress states are what you report, not a certification.")
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
            }
            .padding(PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .refreshable { await viewModel.load(petId: pet?.id, force: true) }
        .sheet(item: $loggingGoal) { goal in
            LogTrainingSessionView(
                goal: goal,
                skill: viewModel.overview.skill(goal.skillRef),
                viewModel: viewModel,
                calendar: calendar
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PCSpacing.xs) {
            Text("Small sessions, real progress")
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
            if let pet {
                Text("Ideas that fit \(pet.name)'s \(stage.displayName.lowercased()) stage.")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
            }
        }
    }

    @ViewBuilder
    private func suggested(_ viewModel: TrainingViewModel) -> some View {
        let starters = viewModel.suggestedStarters(stage: stage)
        if !starters.isEmpty {
            SectionHeader(
                title: viewModel.overview.activeGoals.isEmpty ? "Good places to start" : "Suggested next"
            )
            LazyVStack(spacing: PCSpacing.betweenCards) {
                ForEach(starters) { skill in
                    NavigationLink(value: TrainingRoute.lesson(skill.contentId)) {
                        SuggestedSkillCard(skill: skill, stage: stage)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func recentSessions(_ viewModel: TrainingViewModel) -> some View {
        let sessions = Array(viewModel.overview.recentSessions.prefix(5))
        if !sessions.isEmpty {
            SectionHeader(title: "Recent sessions")
            VStack(alignment: .leading, spacing: PCSpacing.sm) {
                ForEach(sessions) { session in
                    SessionRow(
                        session: session,
                        skillTitle: viewModel.overview.skill(session.skillRef)?.title ?? session.skillRef,
                        actorName: viewModel.actorName(session.actorUserId)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: TrainingRoute) -> some View {
        if let viewModel {
            switch route {
            case .catalogue:
                TrainingCatalogueView(viewModel: viewModel, stage: stage)
            case .lesson(let contentId):
                TrainingLessonView(
                    skillRef: contentId,
                    viewModel: viewModel,
                    petId: pet?.id,
                    calendar: calendar
                )
            case .history(let goalId):
                TrainingProgressHistoryView(goalId: goalId, viewModel: viewModel, calendar: calendar)
            }
        }
    }
}

/// Navigation is by content id, not by value: a goal mutated on one screen
/// must not leave a stale copy pushed on the stack.
enum TrainingRoute: Hashable {
    case catalogue
    case lesson(String)
    case history(UUID)
}

// MARK: - Rows and cards

private struct ActiveGoalCard: View {
    let goal: TrainingGoal
    let skill: TrainingSkill?
    let calendar: Calendar
    let isBusy: Bool
    let onLog: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            HStack(spacing: PCSpacing.sm) {
                NavigationLink(value: TrainingRoute.lesson(goal.skillRef)) {
                    VStack(alignment: .leading, spacing: PCSpacing.xs) {
                        Text(skill?.title ?? goal.skillRef)
                            .font(Font.pc.body.weight(.semibold))
                            .foregroundStyle(Color.pc.ink)
                            .multilineTextAlignment(.leading)
                        Text(goal.recencyText(calendar: calendar))
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if goal.status == .paused {
                    PCChip(text: "Paused", style: .neutral)
                }
            }

            if let onLog {
                SecondaryButton(title: "Log session", isDisabled: isBusy, action: onLog)
            }
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

private struct SuggestedSkillCard: View {
    let skill: TrainingSkill
    let stage: DevelopmentStage

    var body: some View {
        HStack(spacing: PCSpacing.md) {
            VStack(alignment: .leading, spacing: PCSpacing.xs) {
                Text("Start \(skill.title)")
                    .font(Font.pc.body.weight(.semibold))
                    .foregroundStyle(Color.pc.ink)
                    .multilineTextAlignment(.leading)
                Text("Fits the \(stage.displayName.lowercased()) stage · prerequisites met")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.pc.inkTertiary)
        }
        .padding(PCSpacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surfaceSubtle)
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens lesson")
    }
}

struct SessionRow: View {
    let session: TrainingSession
    let skillTitle: String
    let actorName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(
                "\(skillTitle) — \(actorName), "
                    + session.effectiveDate.formatted(.dateTime.weekday(.abbreviated).month().day())
            )
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.ink)
            if let note = session.outcomeNote, !note.isEmpty {
                Text(note)
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkSecondary)
            }
            if let state = session.progressStateAfter {
                Text("Marked \(state.displayName.lowercased())")
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct NavigationRowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: PCSpacing.md) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.pc.primary)
                .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
                .background(Circle().fill(Color.pc.surfaceSubtle))
                .accessibilityHidden(true)
            Text(title)
                .font(Font.pc.body.weight(.medium))
                .foregroundStyle(Color.pc.ink)
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
    }
}

/// A failed action says so, in place, without pretending it succeeded.
struct InlineNoticeCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font.pc.secondary)
            .foregroundStyle(Color.pc.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PCSpacing.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                    .fill(Color.pc.surfaceSubtle)
            )
    }
}

#Preview("Training overview") {
    TrainingView()
        .environment(AppModel.preview())
}
