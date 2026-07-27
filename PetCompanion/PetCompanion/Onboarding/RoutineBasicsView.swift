import SwiftUI

/// ON-08 — Routine basics, optional (doc 14 §4). Broad windows, no exact
/// times. Skipping applies reviewed defaults for the pet's stage (engine
/// §19.3); pre-arrival households see a note that routines activate at
/// homecoming.
struct RoutineBasicsView: View {
    let onFinish: () -> Void

    @Environment(AppModel.self) private var model
    @State private var preferences = HouseholdPreference.reviewedDefaults
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let morningOptions = [TimeBand(startHour: 5, endHour: 8), TimeBand(startHour: 6, endHour: 9), TimeBand(startHour: 7, endHour: 10)]
    private let middayOptions = [TimeBand(startHour: 11, endHour: 13), TimeBand(startHour: 12, endHour: 14)]
    private let eveningOptions = [TimeBand(startHour: 16, endHour: 20), TimeBand(startHour: 17, endHour: 21), TimeBand(startHour: 18, endHour: 22)]
    private let sleepOptions = [TimeBand(startHour: 21, endHour: 5), TimeBand(startHour: 22, endHour: 6), TimeBand(startHour: 23, endHour: 7)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.xxl) {
                Text("When does your day run?")
                    .font(Font.pc.title)
                    .foregroundStyle(Color.pc.ink)
                    .accessibilityAddTraits(.isHeader)

                Text("We use broad windows — no exact times needed.")
                    .font(Font.pc.body)
                    .foregroundStyle(Color.pc.inkSecondary)

                VStack(spacing: PCSpacing.md) {
                    bandRow("Morning", selection: $preferences.morning, options: morningOptions)
                    bandRow("Midday", selection: $preferences.midday, options: middayOptions)
                    bandRow("Evening", selection: $preferences.evening, options: eveningOptions)
                    bandRow("Sleep", selection: $preferences.sleep, options: sleepOptions)

                    HStack {
                        Text("Meals per day")
                            .font(Font.pc.body)
                            .foregroundStyle(Color.pc.ink)
                        Spacer()
                        // Prefilled from the stage-appropriate template.
                        Picker("Meals per day", selection: $preferences.mealsPerDay) {
                            ForEach([2, 3, 4], id: \.self) { count in
                                Text("\(count)").tag(count)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Color.pc.primary)
                    }
                    .padding(.vertical, PCSpacing.xs)
                }

                if let pet = model.activePet, pet.isPreArrival() {
                    Text("These routines switch on when \(pet.name) comes home.")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                }

                if let errorMessage {
                    PCInlineError(message: errorMessage)
                }

                VStack(spacing: PCSpacing.md) {
                    PrimaryButton(title: "Looks right", isLoading: isSubmitting) {
                        save(preferences)
                    }
                    SecondaryButton(title: "Skip — use defaults", isDisabled: isSubmitting) {
                        save(.reviewedDefaults)
                    }
                }
            }
            .padding(PCSpacing.screenMargin)
        }
        .background(Color.pc.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                OnboardingStepLabel(step: 3)
            }
        }
    }

    private func bandRow(_ label: String, selection: Binding<TimeBand>, options: [TimeBand]) -> some View {
        HStack {
            Text(label)
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.ink)
            Spacer()
            Menu {
                ForEach(options, id: \.self) { band in
                    Button(band.displayText) {
                        selection.wrappedValue = band
                    }
                }
            } label: {
                HStack(spacing: PCSpacing.xs) {
                    Text(selection.wrappedValue.displayText)
                        .font(Font.pc.body)
                    Image(systemName: "chevron.down")
                        .font(.footnote)
                }
                .foregroundStyle(Color.pc.primary)
                .padding(.horizontal, PCSpacing.md)
                .frame(minHeight: PCMetrics.minTouchTarget)
            }
            .accessibilityLabel("\(label) window, \(selection.wrappedValue.displayText)")
        }
        .padding(.vertical, PCSpacing.xs)
    }

    private func save(_ prefs: HouseholdPreference) {
        guard !isSubmitting else { return }
        errorMessage = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await model.households.saveRoutinePreferences(prefs)
                onFinish()
            } catch {
                errorMessage = error.localizedDescription
                AccessibilityNotification.Announcement(error.localizedDescription).post()
            }
        }
    }
}

#Preview("ON-08 Routine basics") {
    NavigationStack {
        RoutineBasicsView(onFinish: {})
    }
    .environment(AppModel.mock())
}
