import SwiftUI

/// TR-04 — Log session. Date (today by default, back-datable within bounds),
/// optional duration, a free note, and an optional progress-state change.
///
/// The progress picker is deliberately separate and defaults to "leave it as
/// it is": logging a session records practice, and nothing else. Declaring
/// mastery is a second, explicit decision (US-063, US-065).
struct LogTrainingSessionView: View {
    let goal: TrainingGoal
    let skill: TrainingSkill?
    let viewModel: TrainingViewModel
    let calendar: Calendar

    @Environment(\.dismiss) private var dismiss

    @State private var effectiveDate = Date()
    @State private var includeDuration = false
    @State private var durationMinutes = 5
    @State private var outcomeNote = ""
    @State private var changeProgress = false
    @State private var progressState: TrainingProgressState = .practicing
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// The server accepts up to 30 days back and refuses the future; the
    /// picker offers exactly that range so the bound is visible rather than
    /// discovered through an error.
    private var dateRange: ClosedRange<Date> {
        let today = Date()
        let earliest = calendar.date(byAdding: .day, value: -30, to: today) ?? today
        return earliest...today
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Date",
                        selection: $effectiveDate,
                        in: dateRange,
                        displayedComponents: .date
                    )
                    Toggle("Record how long it took", isOn: $includeDuration)
                    if includeDuration {
                        Stepper(
                            "\(durationMinutes) minute\(durationMinutes == 1 ? "" : "s")",
                            value: $durationMinutes,
                            in: 1...60
                        )
                    }
                } header: {
                    Text("Session")
                }

                Section {
                    TextField("How did it go?", text: $outcomeNote, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Whatever you write here is visible to everyone in the household.")
                }

                Section {
                    Toggle("Change the progress state", isOn: $changeProgress)
                    if changeProgress {
                        Picker("Progress", selection: $progressState) {
                            ForEach(TrainingProgressState.allCases, id: \.self) { state in
                                Text(state.displayName).tag(state)
                            }
                        }
                        Text(progressState.explanation)
                            .font(Font.pc.caption)
                            .foregroundStyle(Color.pc.inkSecondary)
                    }
                } header: {
                    Text("Progress")
                } footer: {
                    Text("Progress is what you report, not a certification — one session doesn't decide it.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.ink)
                    }
                }
            }
            .navigationTitle(skill?.title ?? "Log session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let note = outcomeNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = await viewModel.logSession(
            goal: goal,
            effectiveDate: effectiveDate,
            durationMinutes: includeDuration ? durationMinutes : nil,
            outcomeNote: note.isEmpty ? nil : note,
            progressStateAfter: changeProgress ? progressState : nil
        )
        if saved {
            dismiss()
        } else {
            // The sheet stays open with the caregiver's text intact: a failed
            // write must not silently discard what they just described.
            errorMessage = viewModel.errorMessage
        }
    }
}
