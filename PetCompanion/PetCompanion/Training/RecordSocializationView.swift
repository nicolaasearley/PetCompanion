import SwiftUI

/// TR-08 — record an experience.
///
/// The response picker is the whole reason this screen needs care. The five
/// words are the owner's report of what they saw, and the app must not turn
/// them into a finding. So:
///
///   * the picker is labelled "How did it go, in your words?" and captioned
///     as owner-reported, not assessed;
///   * choosing "hesitant" or "fearful" shows the catalogue's own next-time
///     note — more distance, a softer version, **not** more repetitions — and
///     nothing that names or grades a behaviour;
///   * there is no severity ordering, no colour ramp from good to bad, and no
///     score. All five options are presented identically.
struct RecordSocializationView: View {
    @Bindable var store: SocializationStore
    let category: SocializationCategory?
    let experience: SocializationExperience?

    @Environment(\.dismiss) private var dismiss

    @State private var selectedCategory: SocializationCategory
    @State private var customLabel = ""
    @State private var effectiveDate = Date()
    @State private var context = ""
    @State private var response: SocializationResponse = .curious
    @State private var note = ""
    @State private var validationMessage: String?

    init(store: SocializationStore, category: SocializationCategory?, experience: SocializationExperience?) {
        self.store = store
        self.category = category
        self.experience = experience
        _selectedCategory = State(
            initialValue: experience?.category ?? category ?? .people
        )
    }

    private var isCustom: Bool { experience == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    SocializationCautionCard(text: store.caution)

                    experienceSection
                    dateSection
                    responseSection
                    notesSection

                    // Local validation and a save failure share one slot: both
                    // mean "fix this before it can save," and doc 22 §7's
                    // defect was exactly this message rendering on the
                    // screen *behind* this sheet instead of here.
                    if let message = validationMessage ?? store.errorMessage {
                        PCInlineError(message: message)
                    }

                    PrimaryButton(title: "Save to the passport", action: save)
                        .disabled(store.isSaving)

                    Text("Recorded by you, for your household. This is a record of what happened — not an assessment of \(store.petName).")
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PCSpacing.screenMargin)
                .padding(.bottom, PCSpacing.huge)
            }
            .background(Color.pc.bg)
            .navigationTitle("Record an experience")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.errorMessage = nil
                        dismiss()
                    }
                }
            }
        }
        // A stale failure from an unrelated earlier action (removing a
        // record, pausing a category) must not appear to belong to a sheet
        // that just opened.
        .onAppear { store.errorMessage = nil }
    }

    @ViewBuilder
    private var experienceSection: some View {
        if let experience {
            PCLabeledField(label: "Experience") {
                Text(experience.label)
            }
            .accessibilityLabel("Experience: \(experience.label)")
        } else {
            VStack(alignment: .leading, spacing: PCSpacing.lg) {
                PCLabeledField(label: "What did \(store.petName) meet?") {
                    TextField("For example, the neighbour's wheelie bin", text: $customLabel)
                }
                PCLabeledField(label: "Category") {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(SocializationCategory.allCases) { category in
                            Text(category.displayName).tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.pc.primary)
                }
            }
        }
    }

    private var dateSection: some View {
        PCLabeledField(label: "When") {
            DatePicker(
                "When",
                selection: $effectiveDate,
                in: ...Date(),
                displayedComponents: .date
            )
            .labelsHidden()
            .tint(Color.pc.primary)
        }
    }

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            SectionHeader(title: "How did it go, in your words?")
            VStack(spacing: 0) {
                ForEach(SocializationResponse.allCases) { option in
                    PCRadioRow(
                        title: option.displayName,
                        isSelected: response == option,
                        action: { response = option }
                    )
                }
            }
            // The standing catalogue §8 note, shown only once a hesitant or
            // fearful response is chosen — and phrased entirely as what to do
            // next time, never as what the response means.
            if let guidance = response.guidance {
                HStack(alignment: .top, spacing: PCSpacing.sm) {
                    Image(systemName: "leaf")
                        .foregroundStyle(Color.pc.success)
                        .accessibilityHidden(true)
                    Text(guidance)
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PCSpacing.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                        .fill(Color.pc.surfaceSubtle)
                )
                .accessibilityElement(children: .combine)
            }
            Text("Your own observation. PetCompanion doesn't interpret it or grade it.")
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.lg) {
            PCLabeledField(label: "Where or how (optional)") {
                TextField("For example, two rooms away with the door open", text: $context)
            }
            PCLabeledField(label: "Note (optional)") {
                TextField("Anything you want to remember", text: $note)
            }
        }
    }

    private func save() {
        let trimmedLabel = customLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCustom && trimmedLabel.isEmpty {
            validationMessage = "Add a few words about what \(store.petName) met."
            return
        }
        validationMessage = nil

        let draft = SocializationDraft(
            experience: experience,
            customLabel: isCustom ? trimmedLabel : nil,
            category: experience?.category ?? selectedCategory,
            effectiveDate: effectiveDate,
            context: context.trimmingCharacters(in: .whitespacesAndNewlines),
            response: response,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        Task {
            if await store.record(draft) { dismiss() }
        }
    }
}

#Preview("Record an experience") {
    RecordSocializationView(
        store: .preview(),
        category: .sounds,
        experience: SocializationCatalogue.experience(contentId: "soc.sounds.doorbell")
    )
}
