import SwiftUI

/// Grooming history — CA-01 / US-076.
///
/// Owner-entered records only. Next-due is an optional entered fact for
/// display; this surface never computes a schedule or gives clinical advice.
struct GroomingView: View {
    @Bindable var store: GroomingStore
    @State private var editor: GroomingEditorDestination?
    @State private var pendingRemove: GroomingRecord?

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
                    ProgressView("Loading grooming…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PCSpacing.xxxl)
                        .accessibilityLabel("Loading grooming")
                } else if store.records.isEmpty {
                    EmptyStateView(
                        systemImage: "comb",
                        message: "No grooming recorded yet — log brushing, nails, or a bath when you’re ready.",
                        primaryActionTitle: "Add a grooming entry",
                        primaryAction: { editor = .create }
                    )
                } else {
                    ForEach(store.records) { record in
                        GroomingCard(
                            record: record,
                            calendar: store.calendar,
                            onEdit: { editor = .edit(record) },
                            onRemove: { pendingRemove = record }
                        )
                    }
                }

                Text("Grooming history is record-keeping, not a schedule. Leave next due blank unless you chose a date yourself.")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .background(Color.pc.bg)
        .navigationTitle("Grooming")
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
            GroomingEditorView(store: store, destination: destination)
        }
        .confirmationDialog(
            "Remove this grooming entry?",
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

private struct GroomingCard: View {
    let record: GroomingRecord
    let calendar: Calendar
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Label(record.activityType.displayName, systemImage: record.activityType.systemImage)
                    .font(Font.pc.body.weight(.semibold))
                    .foregroundStyle(Color.pc.ink)
                Spacer()
            }

            Text("Done \(CareCoding.displayDate(record.effectiveDate, calendar: calendar))")
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

enum GroomingEditorDestination: Identifiable {
    case create
    case edit(GroomingRecord)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let record): record.id.uuidString
        }
    }
}

struct GroomingEditorView: View {
    @Bindable var store: GroomingStore
    let destination: GroomingEditorDestination
    @Environment(\.dismiss) private var dismiss

    @State private var draft = GroomingDraft.blank()
    @State private var validationMessage: String?

    private var editing: GroomingRecord? {
        if case .edit(let record) = destination { return record }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    VStack(alignment: .leading, spacing: PCSpacing.sm) {
                        Text("Activity")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                        ForEach(GroomingActivityType.allCases) { option in
                            PCRadioRow(
                                title: option.displayName,
                                isSelected: draft.activityType == option
                            ) { draft.activityType = option }
                        }
                    }

                    PCLabeledField(label: "Date done") {
                        DatePicker(
                            "Date done",
                            selection: $draft.effectiveDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                    }

                    Toggle("Next due date is known", isOn: $draft.includeNextDue)
                        .font(Font.pc.body)
                        .tint(Color.pc.primary)

                    if draft.includeNextDue {
                        PCLabeledField(label: "Next due (as you chose)") {
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
                        Text("Leave this off unless you want a date shown. PetCompanion never calculates a grooming due date.")
                            .font(Font.pc.caption)
                            .foregroundStyle(Color.pc.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PCLabeledField(label: "Note (optional)") {
                        TextField("Optional note", text: $draft.note, axis: .vertical)
                            .lineLimit(3...6)
                    }

                    if let message = validationMessage ?? store.errorMessage {
                        PCInlineError(message: message)
                    }

                    PrimaryButton(title: "Save", action: save)
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
            .navigationTitle(editing == nil ? "Add grooming" : "Edit grooming")
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
                    draft = GroomingDraft.from(editing)
                } else {
                    draft = GroomingDraft.blank(anchorDate: Date())
                }
            }
        }
    }

    private func save() {
        validationMessage = nil
        if draft.includeNextDue {
            guard let next = draft.nextDueDate else {
                validationMessage = "Add the next due date, or turn the toggle off."
                return
            }
            if next < draft.effectiveDate {
                validationMessage = "Next due can’t be before the date done."
                return
            }
        } else {
            draft.nextDueDate = nil
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

#Preview("Grooming") {
    NavigationStack {
        GroomingView(
            store: GroomingStore(
                service: InMemoryGroomingService(),
                petId: UUID(),
                petName: "Maple"
            )
        )
    }
}
