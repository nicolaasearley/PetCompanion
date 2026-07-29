import SwiftUI

/// CA-06 / CA-07 — Medication schedules. Dose text is shown verbatim; next-due
/// copy restates the owner-entered schedule only (docs/13 Accepted).
struct MedicationsView: View {
    @Bindable var store: MedicationsStore
    @State private var editor: MedicationEditorDestination?
    @State private var detail: MedicationSchedule?
    @State private var pendingArchive: MedicationSchedule?
    @State private var completeTarget: MedicationSchedule?
    @State private var acknowledgeRecent = false

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
                } else if let message = store.errorMessage, editor == nil, completeTarget == nil {
                    CareOutcomeBanner(message: message, tone: .error) {
                        store.errorMessage = nil
                    }
                }

                if store.isLoading && store.schedules.isEmpty {
                    ProgressView("Loading medications…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PCSpacing.xxxl)
                        .accessibilityLabel("Loading medications")
                } else if store.schedules.isEmpty {
                    EmptyStateView(
                        systemImage: "pills",
                        message: "No medication schedules yet — add them exactly as your vet wrote them.",
                        primaryActionTitle: "Add a medication",
                        primaryAction: { editor = .create }
                    )
                } else {
                    ForEach(store.schedules) { schedule in
                        Button {
                            detail = schedule
                        } label: {
                            MedicationScheduleRow(
                                schedule: schedule,
                                petName: store.petName,
                                calendar: store.calendar
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Medications are record-keeping, not medical advice. Never double, skip, or change a dose based on this app.")
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .background(Color.pc.bg)
        .navigationTitle("Medications")
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
            MedicationEditorView(store: store, destination: destination)
        }
        .navigationDestination(item: $detail) { schedule in
            if let live = store.schedules.first(where: { $0.id == schedule.id }) ?? detail {
                MedicationDetailView(
                    store: store,
                    schedule: live,
                    onEdit: { editor = .edit(live) },
                    onArchive: { pendingArchive = live },
                    onComplete: {
                        acknowledgeRecent = false
                        store.recentCompletionNotice = nil
                        completeTarget = live
                    }
                )
            }
        }
        .confirmationDialog(
            "Archive this schedule?",
            isPresented: Binding(
                get: { pendingArchive != nil },
                set: { if !$0 { pendingArchive = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                if let pendingArchive {
                    Task {
                        _ = await store.archive(pendingArchive)
                        detail = nil
                    }
                }
                pendingArchive = nil
            }
            Button("Cancel", role: .cancel) { pendingArchive = nil }
        } message: {
            Text("Stops future reminders and keeps history. This is not medical advice about stopping treatment.")
        }
        .sheet(item: $completeTarget) { schedule in
            MedicationCompleteConfirmView(
                store: store,
                schedule: schedule,
                acknowledgeRecent: $acknowledgeRecent
            )
        }
    }
}

private struct MedicationScheduleRow: View {
    let schedule: MedicationSchedule
    let petName: String
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(schedule.medicationName)
                    .font(Font.pc.body.weight(.semibold))
                    .foregroundStyle(Color.pc.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.pc.inkTertiary)
                    .accessibilityHidden(true)
            }
            if let dose = schedule.doseText {
                Text("Dose: “\(dose)”")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
            }
            Text(schedule.recurrence.summary)
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
            if let next = schedule.nextDue {
                Text(next.dueSummary(relativeTo: Date(), calendar: calendar))
                    .font(Font.pc.secondary.weight(.medium))
                    .foregroundStyle(Color.pc.ink)
            }
            if let last = schedule.lastCompletion {
                Text(last.attribution)
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
            }
        }
        .padding(PCSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: PCMetrics.listRowHeight)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .strokeBorder(Color.pc.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens \(schedule.medicationName) for \(petName)")
    }
}

struct MedicationDetailView: View {
    @Bindable var store: MedicationsStore
    let schedule: MedicationSchedule
    let onEdit: () -> Void
    let onArchive: () -> Void
    let onComplete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                VStack(alignment: .leading, spacing: PCSpacing.sm) {
                    Text("For \(store.petName)")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                    Text(schedule.medicationName)
                        .font(Font.pc.title)
                        .foregroundStyle(Color.pc.ink)
                    Text(schedule.provenance.displayName)
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                    Text("Shown exactly as entered")
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.inkTertiary)
                }

                if let dose = schedule.doseText {
                    detailBlock(title: "Dose", value: "“\(dose)”")
                }
                if let instructions = schedule.instructionsText {
                    detailBlock(title: "Instructions", value: instructions)
                }
                detailBlock(title: "Schedule", value: schedule.recurrence.summary)

                if let last = schedule.lastCompletion {
                    detailBlock(title: "Last given", value: last.attribution)
                } else {
                    detailBlock(title: "Last given", value: "Not recorded yet")
                }

                if let next = schedule.nextDue {
                    detailBlock(
                        title: "Next due",
                        value: next.dueSummary(relativeTo: Date(), calendar: store.calendar)
                    )
                }

                if !schedule.changeHistory.isEmpty {
                    VStack(alignment: .leading, spacing: PCSpacing.sm) {
                        SectionHeader(title: "Change history")
                        ForEach(schedule.changeHistory.prefix(8)) { entry in
                            Text("\(CareCoding.displayDate(entry.occurredAt)) — \(entry.summaryLabel)\(entry.actorName.map { " by \($0)" } ?? "")")
                                .font(Font.pc.secondary)
                                .foregroundStyle(Color.pc.inkSecondary)
                        }
                    }
                }

                if schedule.nextDue != nil {
                    PrimaryButton(title: "Record as given", isDisabled: store.isSaving, action: onComplete)
                }

                Button("Edit schedule", action: onEdit)
                    .font(Font.pc.body)
                    .foregroundStyle(Color.pc.primary)
                    .frame(minHeight: PCMetrics.minTouchTarget)

                Button("Archive schedule", role: .destructive, action: onArchive)
                    .font(Font.pc.body)
                    .frame(minHeight: PCMetrics.minTouchTarget)

                Text("This app never suggests doubling, skipping, or changing a dose.")
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .background(Color.pc.bg)
        .navigationTitle("Medication")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.xs) {
            Text(title)
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkTertiary)
            Text(value)
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MedicationCompleteConfirmView: View {
    @Bindable var store: MedicationsStore
    let schedule: MedicationSchedule
    @Binding var acknowledgeRecent: Bool
    @Environment(\.dismiss) private var dismiss

    private var needsExtraConfirm: Bool {
        store.recentCompletionNotice != nil
            || schedule.lastCompletion?.isRecentPartnerCompletion(
                currentUserId: store.currentUserId
            ) == true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    Text("Confirm for \(store.petName)")
                        .font(Font.pc.title)
                        .foregroundStyle(Color.pc.ink)

                    confirmRow(label: "Pet", value: store.petName)
                    confirmRow(label: "Medication", value: schedule.medicationName)
                    if let dose = schedule.doseText {
                        confirmRow(label: "Dose", value: "“\(dose)”")
                    } else {
                        confirmRow(label: "Dose", value: "Not entered")
                    }
                    if let next = schedule.nextDue {
                        confirmRow(
                            label: "Due",
                            value: next.dueSummary(relativeTo: Date(), calendar: store.calendar)
                        )
                    }
                    if let last = schedule.lastCompletion {
                        confirmRow(label: "Latest recorded", value: last.attribution)
                    } else {
                        confirmRow(label: "Latest recorded", value: "None yet")
                    }

                    if let notice = store.recentCompletionNotice {
                        Text(notice)
                            .font(Font.pc.secondary.weight(.semibold))
                            .foregroundStyle(Color.pc.ink)
                            .padding(PCSpacing.cardPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                                    .fill(Color.pc.surfaceSubtle)
                            )
                    } else if needsExtraConfirm, let last = schedule.lastCompletion {
                        Text("\(last.attribution). Confirm you still want to record another dose.")
                            .font(Font.pc.secondary.weight(.semibold))
                            .foregroundStyle(Color.pc.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if needsExtraConfirm {
                        Toggle("I understand another caregiver recently recorded this", isOn: $acknowledgeRecent)
                            .font(Font.pc.secondary)
                    }

                    if let message = store.errorMessage {
                        Text(message)
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.danger)
                    }

                    Text("This does not advise doubling, skipping, or changing a dose.")
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PCSpacing.screenMargin)
            }
            .background(Color.pc.bg)
            .navigationTitle("Record dose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record") {
                        Task {
                            let ok = await store.complete(
                                schedule,
                                acknowledgedRecentCompletion: needsExtraConfirm ? acknowledgeRecent : false
                            )
                            if ok { dismiss() }
                        }
                    }
                    .disabled(store.isSaving || (needsExtraConfirm && !acknowledgeRecent))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func confirmRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.xs) {
            Text(label)
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkTertiary)
            Text(value)
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum MedicationEditorDestination: Identifiable {
    case create
    case edit(MedicationSchedule)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let schedule): schedule.id.uuidString
        }
    }
}

struct MedicationEditorView: View {
    @Bindable var store: MedicationsStore
    let destination: MedicationEditorDestination
    @Environment(\.dismiss) private var dismiss

    @State private var draft = MedicationDraft.blank()
    @State private var validationMessage: String?

    private var editing: MedicationSchedule? {
        if case .edit(let schedule) = destination { return schedule }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    PCLabeledField(label: "Medication name") {
                        TextField("As written", text: $draft.medicationName)
                            .textInputAutocapitalization(.sentences)
                    }
                    PCLabeledField(label: "Dose (exactly as your vet wrote it)") {
                        TextField("e.g. 1 tablet", text: $draft.doseText)
                            .textInputAutocapitalization(.never)
                    }
                    PCLabeledField(label: "Instructions (optional)") {
                        TextField("Optional notes", text: $draft.instructionsText, axis: .vertical)
                            .lineLimit(3...6)
                    }

                    VStack(alignment: .leading, spacing: PCSpacing.sm) {
                        Text("Source")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                        ForEach(MedicationProvenance.allCases) { provenance in
                            PCRadioRow(
                                title: provenance.displayName,
                                isSelected: draft.provenance == provenance
                            ) {
                                draft.provenance = provenance
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: PCSpacing.sm) {
                        Text("Schedule")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                        ForEach(MedicationRecurrenceType.allCases) { type in
                            PCRadioRow(
                                title: type.displayName,
                                isSelected: draft.recurrenceType == type
                            ) {
                                draft.recurrenceType = type
                            }
                        }
                    }

                    DatePicker(
                        draft.recurrenceType == .once ? "Due date" : "First / next due date",
                        selection: $draft.anchorDate,
                        displayedComponents: .date
                    )

                    if draft.recurrenceType == .everyNDays
                        || draft.recurrenceType == .intervalAfterCompletion
                    {
                        PCLabeledField(label: "Interval (days)") {
                            TextField("Days", value: $draft.intervalDays, format: .number)
                                .keyboardType(.numberPad)
                        }
                    }

                    VStack(alignment: .leading, spacing: PCSpacing.sm) {
                        Text("Time")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                        ForEach(MedicationTimePolicy.allCases) { policy in
                            PCRadioRow(
                                title: policy.displayName,
                                isSelected: draft.timePolicy == policy
                            ) {
                                draft.timePolicy = policy
                            }
                        }
                    }

                    if draft.timePolicy == .window {
                        ForEach(MedicationWindowRef.allCases) { window in
                            PCRadioRow(
                                title: window.displayName,
                                isSelected: draft.windowRef == window
                            ) {
                                draft.windowRef = window
                            }
                        }
                    } else if draft.timePolicy == .exactTime {
                        DatePicker("Exact time", selection: $draft.exactTime, displayedComponents: .hourAndMinute)
                    }

                    Text("Unsupported clinical patterns aren’t approximated — pick a supported schedule or enter a single due date.")
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let validationMessage {
                        Text(validationMessage)
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.danger)
                    }
                    if let message = store.errorMessage {
                        Text(message)
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.danger)
                    }
                }
                .padding(PCSpacing.screenMargin)
            }
            .background(Color.pc.bg)
            .navigationTitle(editing == nil ? "Add medication" : "Edit medication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(store.isSaving)
                }
            }
            .onAppear {
                if let editing {
                    draft = MedicationDraft.from(editing, calendar: store.calendar)
                } else {
                    draft = MedicationDraft.blank(anchorDate: Date())
                }
            }
        }
    }

    private func save() async {
        validationMessage = nil
        store.errorMessage = nil
        guard draft.validatedRecurrence(calendar: store.calendar) != nil else {
            validationMessage = "Check the name and schedule details."
            return
        }
        let ok: Bool
        if let editing {
            ok = await store.edit(editing, draft: draft)
        } else {
            ok = await store.create(draft)
        }
        if ok { dismiss() }
    }
}
