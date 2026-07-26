import SwiftUI

/// ON-07 — Add your puppy (doc 14 §4).
///
/// Name + exact birth date OR estimated age in weeks (stored as age as of
/// today, doc 10 §8.2), plus the "home yet?" choice with an optional future
/// homecoming date. Validation runs before save with inline explanations
/// (US-023): homecoming ≥ birth when both exact; no future birth date.
/// No health or breed questions here — ever (F03).
struct AddPetView: View {
    let onContinue: () -> Void

    enum BirthKind: Hashable {
        case exact
        case estimated
    }

    enum HomeStatus: Hashable {
        case home
        case comingHome
    }

    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var birthKind: BirthKind = .exact
    @State private var birthDate = Calendar.current.date(byAdding: .weekOfYear, value: -8, to: Date()) ?? Date()
    @State private var estimatedWeeks = 8
    @State private var homeStatus: HomeStatus = .home
    @State private var homecomingDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var isSubmitting = false
    @State private var nameError: String?
    @State private var birthError: String?
    @State private var homecomingError: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.xxl) {
                Text("Tell us about your puppy")
                    .font(Font.pc.title)
                    .foregroundStyle(Color.pc.ink)
                    .accessibilityAddTraits(.isHeader)

                PCLabeledField(label: "Name", errorMessage: nameError) {
                    TextField("Name", text: $name)
                }

                birthSection
                homeSection

                if let errorMessage {
                    PCInlineError(message: errorMessage)
                }

                VStack(spacing: PCSpacing.md) {
                    PrimaryButton(title: "Continue", isLoading: isSubmitting, action: submit)
                    SecondaryButton(title: "Add details later", isDisabled: isSubmitting, action: submit)
                    Text("Photo, breed, and other details can wait — add them any time in Care.")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkTertiary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(PCSpacing.screenMargin)
        }
        .background(Color.pc.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                OnboardingStepLabel(step: 2)
            }
        }
    }

    // MARK: - Birth information

    private var birthSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.xs) {
            Text("Birth date")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)

            PCRadioRow(title: "Exact", isSelected: birthKind == .exact) {
                birthKind = .exact
            }
            if birthKind == .exact {
                DatePicker(
                    "Birth date",
                    selection: $birthDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .padding(.leading, PCSpacing.xxxl)
            }

            PCRadioRow(title: "Not sure — estimate", isSelected: birthKind == .estimated) {
                birthKind = .estimated
            }
            if birthKind == .estimated {
                VStack(alignment: .leading, spacing: PCSpacing.xs) {
                    Stepper(value: $estimatedWeeks, in: 1...52) {
                        Text("about \(estimatedWeeks) weeks old as of today")
                            .font(Font.pc.body)
                            .foregroundStyle(Color.pc.ink)
                    }
                    // Qualified-language preview (US-021).
                    Text("We'll say \u{201C}about \(estimatedWeeks) weeks\u{201D}.")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkTertiary)
                }
                .padding(.leading, PCSpacing.xxxl)
            }

            if let birthError {
                PCInlineError(message: birthError)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Homecoming

    private var homeSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.xs) {
            Text("Is \(name.isEmpty ? "your puppy" : name) home yet?")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)

            PCRadioRow(title: "Home with us", isSelected: homeStatus == .home) {
                homeStatus = .home
            }
            PCRadioRow(title: "Coming home", isSelected: homeStatus == .comingHome) {
                homeStatus = .comingHome
            }
            if homeStatus == .comingHome {
                DatePicker(
                    "Homecoming date",
                    selection: $homecomingDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .padding(.leading, PCSpacing.xxxl)
            }

            if let homecomingError {
                PCInlineError(message: homecomingError)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Validation and save

    private func submit() {
        guard !isSubmitting else { return }
        nameError = nil
        birthError = nil
        homecomingError = nil
        errorMessage = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var firstError: String?

        if trimmedName.isEmpty {
            nameError = "Enter your puppy's name to continue."
            firstError = firstError ?? nameError
        }
        if birthKind == .exact, birthDate > Date() {
            birthError = "Birth date can't be in the future."
            firstError = firstError ?? birthError
        }
        if homeStatus == .comingHome, birthKind == .exact,
           Calendar.current.startOfDay(for: homecomingDate) < Calendar.current.startOfDay(for: birthDate) {
            homecomingError = "Homecoming can't be before the birth date."
            firstError = firstError ?? homecomingError
        }
        if let firstError {
            // Validation announced (ON-07 a11y note).
            AccessibilityNotification.Announcement(firstError).post()
            return
        }

        let birthInfo: BirthInfo = birthKind == .exact
            ? .exact(birthDate: birthDate)
            : .estimated(ageWeeks: estimatedWeeks, asOfDate: Date())
        let homecoming: Date? = homeStatus == .comingHome ? homecomingDate : nil

        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                let pet = try await model.households.createPet(
                    name: trimmedName,
                    birthInfo: birthInfo,
                    homecomingDate: homecoming
                )
                model.activePet = pet
                onContinue()
            } catch {
                errorMessage = error.localizedDescription
                AccessibilityNotification.Announcement(error.localizedDescription).post()
            }
        }
    }
}

#Preview("ON-07 Add pet") {
    NavigationStack {
        AddPetView(onContinue: {})
    }
    .environment(AppModel.mock())
}
