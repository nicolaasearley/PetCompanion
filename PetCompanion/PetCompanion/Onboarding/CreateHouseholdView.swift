import SwiftUI

/// ON-06 — Create household (doc 14 §4): name (prefilled suggestion,
/// editable) + time zone (detected default, explicit and confirmable,
/// US-010). Creation retry is idempotent server-side.
struct CreateHouseholdView: View {
    let onContinue: () -> Void
    /// ON-05 entry for someone who was invited instead of starting a
    /// household of their own (doc 14 §17.2).
    var onHasInvitation: (() -> Void)?

    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var timeZoneID = TimeZone.current.identifier
    @State private var isSubmitting = false
    @State private var nameError: String?
    @State private var errorMessage: String?
    @State private var showTimeZonePicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.xxl) {
                Text("Name your household")
                    .font(Font.pc.title)
                    .foregroundStyle(Color.pc.ink)
                    .accessibilityAddTraits(.isHeader)

                PCLabeledField(label: "Household name", errorMessage: nameError) {
                    TextField("Household name", text: $name)
                }

                VStack(alignment: .leading, spacing: PCSpacing.xs + 2) {
                    Text("Time zone")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                    Button {
                        showTimeZonePicker = true
                    } label: {
                        HStack {
                            Text(timeZoneID)
                                .font(Font.pc.body)
                                .foregroundStyle(Color.pc.ink)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.footnote)
                                .foregroundStyle(Color.pc.inkSecondary)
                        }
                        .padding(.horizontal, PCSpacing.lg)
                        .frame(minHeight: PCMetrics.buttonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                                .fill(Color.pc.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                                .strokeBorder(Color.pc.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Time zone, \(timeZoneID)")
                    .accessibilityHint("Opens the time zone list")

                    Text("Plans and reminders use this time zone.")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkTertiary)
                }

                if let errorMessage {
                    PCInlineError(message: errorMessage)
                }

                PrimaryButton(title: "Continue", isLoading: isSubmitting, action: submit)

                if let onHasInvitation {
                    VStack(alignment: .leading, spacing: PCSpacing.sm) {
                        Text("Joining someone else's household?")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                        SecondaryButton(title: "I have an invitation", action: onHasInvitation)
                    }
                }
            }
            .padding(PCSpacing.screenMargin)
        }
        .background(Color.pc.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                OnboardingStepLabel(step: 1)
            }
        }
        .sheet(isPresented: $showTimeZonePicker) {
            TimeZonePickerView(selection: $timeZoneID)
        }
        .task {
            if name.isEmpty, let displayName = model.currentUser?.displayName {
                name = "\(displayName)'s Household"
            }
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameError = "Give your household a name to continue."
            AccessibilityNotification.Announcement("Give your household a name to continue.").post()
            return
        }
        nameError = nil
        errorMessage = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                let household = try await model.households.createHousehold(
                    name: trimmed,
                    timeZone: timeZoneID
                )
                model.household = household
                onContinue()
            } catch {
                errorMessage = error.localizedDescription
                AccessibilityNotification.Announcement(error.localizedDescription).post()
            }
        }
    }
}

/// Searchable IANA time-zone list, presented from ON-06.
struct TimeZonePickerView: View {
    @Binding var selection: String
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.self) { identifier in
                Button {
                    selection = identifier
                    dismiss()
                } label: {
                    HStack {
                        Text(identifier)
                            .font(Font.pc.body)
                            .foregroundStyle(Color.pc.ink)
                        Spacer()
                        if identifier == selection {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.pc.primary)
                        }
                    }
                }
                .accessibilityAddTraits(identifier == selection ? [.isSelected] : [])
            }
            .searchable(text: $query, prompt: "Search time zones")
            .navigationTitle("Time zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

#Preview("ON-06 Create household") {
    NavigationStack {
        CreateHouseholdView(onContinue: {})
    }
    .environment(AppModel.mock())
}
