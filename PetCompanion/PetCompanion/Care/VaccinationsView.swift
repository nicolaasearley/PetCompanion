import SwiftUI

/// Vaccination history — CA-01 / US-070.
///
/// Owner/vet-entered records only. Next-due is an optional entered fact for
/// display; this surface never computes a schedule or gives dose advice.
struct VaccinationsView: View {
    @Bindable var store: VaccinationStore
    @State private var editor: VaccinationEditorDestination?
    @State private var pendingRemove: VaccinationRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                if let message = store.confirmationMessage {
                    CareOutcomeBanner(message: message, tone: .success) {
                        store.confirmationMessage = nil
                    }
                } else if let message = store.queuedMessage {
                    CareOutcomeBanner(message: message, tone: .queued) {
                        store.queuedMessage = nil
                    }
                } else if let message = store.errorMessage, editor == nil {
                    CareOutcomeBanner(message: message, tone: .error) {
                        store.errorMessage = nil
                    }
                }

                if store.isLoading && store.records.isEmpty {
                    ProgressView("Loading vaccinations…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PCSpacing.xxxl)
                        .accessibilityLabel("Loading vaccinations")
                } else if store.records.isEmpty {
                    EmptyStateView(
                        systemImage: "syringe",
                        message: "No vaccinations recorded yet — add them from your vet’s documents when you’re ready.",
                        primaryActionTitle: "Add a vaccination",
                        primaryAction: { editor = .create }
                    )
                } else {
                    ForEach(store.records) { record in
                        VaccinationCard(
                            record: record,
                            calendar: store.calendar,
                            onEdit: { editor = .edit(record) },
                            onRemove: { pendingRemove = record }
                        )
                    }
                }

                Text("Vaccination history is record-keeping, not a schedule or medical advice. Leave next due blank unless your vet gave a date.")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .background(Color.pc.bg)
        .navigationTitle("Vaccinations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add") { editor = .create }
                    .disabled(store.isSaving)
            }
        }
        .refreshable { await store.load() }
        .task { await store.load() }
        .sheet(item: $editor) { destination in
            VaccinationEditorView(store: store, destination: destination)
        }
        .confirmationDialog(
            "Remove this vaccination?",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let pendingRemove {
                    Task { _ = await store.remove(pendingRemove) }
                }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("The household history keeps this removal in the audit trail.")
        }
    }
}

private struct VaccinationCard: View {
    let record: VaccinationRecord
    let calendar: Calendar
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.vaccineName)
                    .font(Font.pc.body.weight(.semibold))
                    .foregroundStyle(Color.pc.ink)
                Spacer()
                PCChip(text: record.provenance.shortBadge, style: .neutral)
            }

            Text("Given \(CareCoding.displayDate(record.effectiveDate, calendar: calendar))")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)

            if let nextDue = record.nextDueDate {
                Text("Next due \(CareCoding.displayDate(nextDue, calendar: calendar)) (as entered)")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
            }

            if let note = record.note, !note.isEmpty {
                Text(note)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let recordedBy = record.recordedByName, !recordedBy.isEmpty {
                Text("Recorded by \(recordedBy)")
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
            }

            HStack(spacing: PCSpacing.md) {
                Button("Edit", action: onEdit)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.primary)
                    .frame(minHeight: PCMetrics.minTouchTarget)
                Button("Remove", role: .destructive, action: onRemove)
                    .font(Font.pc.secondary)
                    .frame(minHeight: PCMetrics.minTouchTarget)
                Spacer()
            }
        }
        .padding(PCSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .strokeBorder(Color.pc.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

enum VaccinationEditorDestination: Identifiable {
    case create
    case edit(VaccinationRecord)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let record): record.id.uuidString
        }
    }
}

struct VaccinationEditorView: View {
    @Bindable var store: VaccinationStore
    let destination: VaccinationEditorDestination
    @Environment(\.dismiss) private var dismiss

    @State private var draft = VaccinationDraft.blank()
    @State private var validationMessage: String?
    @State private var duplicateMessage: String?
    @State private var acknowledgedDuplicate = false

    private var editing: VaccinationRecord? {
        if case .edit(let record) = destination { return record }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    PCLabeledField(label: "Vaccine name") {
                        TextField("As written on the record", text: $draft.vaccineName)
                    }

                    PCLabeledField(label: "Date given") {
                        DatePicker(
                            "Date given",
                            selection: $draft.effectiveDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: PCSpacing.sm) {
                        Text("Source")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                        ForEach(VaccinationProvenance.allCases) { option in
                            PCRadioRow(
                                title: option.displayName,
                                isSelected: draft.provenance == option
                            ) { draft.provenance = option }
                        }
                    }

                    Toggle("Next due date is known", isOn: $draft.includeNextDue)
                        .font(Font.pc.body)
                        .tint(Color.pc.primary)

                    if draft.includeNextDue {
                        PCLabeledField(label: "Next due (as your vet wrote it)") {
                            DatePicker(
                                "Next due",
                                selection: Binding(
                                    get: { draft.nextDueDate ?? draft.effectiveDate },
                                    set: { draft.nextDueDate = $0 }
                                ),
                                in: draft.effectiveDate...,
                                displayedComponents: .date
                            )
                            .labelsHidden()
                        }
                        Text("Leave this off unless your vet gave an explicit date. Settle never calculates a due date.")
                            .font(Font.pc.caption)
                            .foregroundStyle(Color.pc.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PCLabeledField(label: "Note (optional)") {
                        TextField("Optional note", text: $draft.note, axis: .vertical)
                            .lineLimit(3...6)
                    }

                    if let duplicateMessage {
                        Text(duplicateMessage)
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.attention)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Please confirm: \(duplicateMessage)")
                    }

                    if let message = validationMessage ?? store.errorMessage {
                        PCInlineError(message: message)
                    }

                    PrimaryButton(
                        title: duplicateMessage == nil ? "Save" : "Looks right — save",
                        action: save
                    )
                    .disabled(store.isSaving)

                    Text("Care records are not medical advice. This is a household history of what was recorded.")
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PCSpacing.screenMargin)
                .padding(.bottom, PCSpacing.huge)
            }
            .background(Color.pc.bg)
            .navigationTitle(editing == nil ? "Add vaccination" : "Edit vaccination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.errorMessage = nil
                        dismiss()
                    }
                }
            }
            .onAppear {
                store.errorMessage = nil
                if let editing {
                    draft = VaccinationDraft.from(editing)
                } else {
                    draft = VaccinationDraft.blank(anchorDate: Date())
                }
            }
        }
    }

    private func save() {
        validationMessage = nil
        let name = draft.vaccineName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            validationMessage = "Enter the vaccine name as written."
            return
        }
        if draft.includeNextDue {
            guard let next = draft.nextDueDate else {
                validationMessage = "Add the next due date, or turn the toggle off."
                return
            }
            if next < draft.effectiveDate {
                validationMessage = "Next due can’t be before the date given."
                return
            }
        } else {
            draft.nextDueDate = nil
        }

        if !acknowledgedDuplicate,
           let prompt = store.duplicatePrompt(for: draft, excluding: editing?.id)
        {
            duplicateMessage = prompt
            acknowledgedDuplicate = true
            return
        }

        Task {
            let saved: Bool
            if let editing {
                saved = await store.edit(editing, draft: draft)
            } else {
                saved = await store.record(draft)
            }
            if saved { dismiss() }
        }
    }
}

#Preview("Vaccinations") {
    NavigationStack {
        VaccinationsView(
            store: VaccinationStore(
                service: InMemoryVaccinationService(),
                petId: UUID(),
                petName: "Maple"
            )
        )
    }
}
