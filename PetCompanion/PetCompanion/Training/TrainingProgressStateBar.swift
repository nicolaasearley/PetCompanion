import SwiftUI

/// Honest Training progress affordance (docs/22 §5 item 2 / PRODUCT.md).
///
/// Renders the household's own reported `TrainingProgressState` as a named
/// position on F08's continuum — discrete steps, not a computed completion
/// percentage, and never a session-count ratio. Color only reinforces the
/// filled steps; the state name is always visible text (PRD §13.3 / doc 09).
///
/// F08 lists seven owner-facing labels; the seventh ("Paused") is carried by
/// `TrainingGoal.status` so pausing stays non-destructive. When paused, the
/// title says so while the bar keeps the last reported continuum step.
struct TrainingProgressAffordanceModel: Equatable, Sendable {
    let state: TrainingProgressState
    let isPaused: Bool

    init(state: TrainingProgressState, isPaused: Bool = false) {
        self.state = state
        self.isPaused = isPaused
    }

    init(goal: TrainingGoal) {
        self.state = goal.progressState
        self.isPaused = goal.status == .paused
    }

    /// Visible title — always names the state; color alone is never enough.
    var title: String {
        if isPaused {
            return "Paused · \(state.displayName)"
        }
        return state.displayName
    }

    var stepNumber: Int { state.continuumStep }
    var stepCount: Int { TrainingProgressState.continuumStepCount }

    /// Caption under the bar: owner-reported, not a score or certification.
    var caption: String {
        if isPaused {
            return "Owner-reported · goal paused (progress kept)"
        }
        return "Owner-reported · not a score"
    }

    var accessibilityLabel: String {
        if isPaused {
            return "Owner-reported progress: Paused. Last reported \(state.displayName), step \(stepNumber) of \(stepCount). \(state.explanation)"
        }
        return "Owner-reported progress: \(state.displayName), step \(stepNumber) of \(stepCount). \(state.explanation)"
    }

    /// Explicitly no percentage API — callers must not invent one from
    /// `stepNumber` / `stepCount` for display. The bar is ordinal, not a ratio.
    var rejectsComputedPercentage: Bool { true }
}

/// Compact / expanded variants so TR-01 cards stay calm while TR-03 / TR-05
/// can show the explanation inline.
enum TrainingProgressAffordanceStyle {
    /// Title + segmented steps + caption (Active goals cards).
    case compact
    /// Title + explanation + steps + caption (lesson + progress history).
    case expanded
}

struct TrainingProgressStateBar: View {
    let model: TrainingProgressAffordanceModel
    var style: TrainingProgressAffordanceStyle = .compact

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            Text(model.title)
                .font(Font.pc.body.weight(.semibold))
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)

            if style == .expanded {
                Text(model.state.explanation)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            steps

            Text(model.caption)
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityIdentifier("training-progress-state-bar")
    }

    private var steps: some View {
        HStack(spacing: PCSpacing.xs) {
            ForEach(Array(TrainingProgressState.allCases.enumerated()), id: \.element) { index, step in
                let isReached = index < model.stepNumber
                let isCurrent = index + 1 == model.stepNumber
                Capsule(style: .continuous)
                    .fill(fill(isReached: isReached, isCurrent: isCurrent))
                    .frame(maxWidth: .infinity)
                    .frame(height: isCurrent ? 10 : 6)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                isReached ? Color.clear : Color.pc.border,
                                lineWidth: 1
                            )
                    )
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 10)
        .opacity(model.isPaused ? 0.72 : 1)
        .accessibilityHidden(true)
    }

    private func fill(isReached: Bool, isCurrent: Bool) -> Color {
        guard isReached else { return Color.pc.surfaceSubtle }
        // Current step uses primary; earlier steps use a quieter fill so the
        // named title — not a color ramp — carries meaning.
        if isCurrent { return Color.pc.primary }
        return Color.pc.primary.opacity(0.45)
    }
}

#Preview("Compact · practicing") {
    TrainingProgressStateBar(
        model: TrainingProgressAffordanceModel(state: .practicing),
        style: .compact
    )
    .padding(PCSpacing.screenMargin)
    .background(Color.pc.bg)
}

#Preview("Expanded · paused") {
    TrainingProgressStateBar(
        model: TrainingProgressAffordanceModel(state: .reliableInFamiliarSetting, isPaused: true),
        style: .expanded
    )
    .padding(PCSpacing.screenMargin)
    .background(Color.pc.bg)
}
