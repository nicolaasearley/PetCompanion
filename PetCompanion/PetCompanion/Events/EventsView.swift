import SwiftUI

/// Lightweight Appointments & events list — F11 foundation without touching
/// Planner agenda WIP. Primary entry is Care → Appointments & events;
/// Settings keeps a secondary household link.
struct EventsView: View {
    @Bindable var store: EventStore
    @State private var editor: EventEditorDestination?
    @State private var pendingCancel: HouseholdEvent?
    @State private var pendingArchive: HouseholdEvent?

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

                if store.isLoading && store.events.isEmpty {
                    ProgressView("Loading appointments…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PCSpacing.xxxl)
                        .accessibilityLabel("Loading appointments")
                } else if store.events.isEmpty {
                    EmptyStateView(
                        systemImage: "calendar",
                        message: "No appointments yet — add a vet visit, class, or other household event when you’re ready.",
                        primaryActionTitle: "Add an event",
                        primaryAction: { editor = .create }
                    )
                } else {
                    if !store.upcoming.isEmpty {
                        VStack(alignment: .leading, spacing: PCSpacing.betweenCards) {
                            SectionHeader(title: "Coming up")
                            ForEach(store.upcoming) { event in
                                EventCard(
                                    event: event,
                                    petName: store.petName(for: event),
                                    onEdit: { editor = .edit(event) },
                                    onCancel: { pendingCancel = event },
                                    onArchive: { pendingArchive = event }
                                )
                            }
                        }
                    }

                    if !store.pastOrCancelled.isEmpty {
                        VStack(alignment: .leading, spacing: PCSpacing.betweenCards) {
                            SectionHeader(title: "Past & cancelled")
                            ForEach(store.pastOrCancelled) { event in
                                EventCard(
                                    event: event,
                                    petName: store.petName(for: event),
                                    onEdit: event.isCancelled ? nil : { editor = .edit(event) },
                                    onCancel: nil,
                                    onArchive: { pendingArchive = event }
                                )
                            }
                        }
                    }
                }

                Text("Events appear on the daily plan when they’re coming up. Reminder delivery is configured in Settings.")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .background(Color.pc.bg)
        .navigationTitle("Appointments & events")
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
            EventEditorView(store: store, destination: destination)
        }
        .confirmationDialog(
            "Cancel this event?",
            isPresented: Binding(
                get: { pendingCancel != nil },
                set: { if !$0 { pendingCancel = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Cancel event", role: .destructive) {
                if let pendingCancel {
                    Task { _ = await store.cancel(pendingCancel) }
                }
                pendingCancel = nil
            }
            Button("Keep", role: .cancel) { pendingCancel = nil }
        } message: {
            Text("The event stays in the list as cancelled. You can remove it later.")
        }
        .confirmationDialog(
            "Remove this event?",
            isPresented: Binding(
                get: { pendingArchive != nil },
                set: { if !$0 { pendingArchive = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let pendingArchive {
                    Task { _ = await store.archive(pendingArchive) }
                }
                pendingArchive = nil
            }
            Button("Keep", role: .cancel) { pendingArchive = nil }
        } message: {
            Text("It won’t appear in Appointments anymore.")
        }
    }
}

private struct EventCard: View {
    let event: HouseholdEvent
    let petName: String?
    var onEdit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onArchive: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            HStack(alignment: .top, spacing: PCSpacing.md) {
                Image(systemName: event.kind.systemImage)
                    .foregroundStyle(Color.pc.primary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PCSpacing.xs) {
                    Text(event.title)
                        .font(Font.pc.body.weight(.semibold))
                        .foregroundStyle(event.isCancelled ? Color.pc.inkTertiary : Color.pc.ink)
                        .strikethrough(event.isCancelled)
                    Text(event.kind.displayName)
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                    Text(event.whenSummary)
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                    if let petName {
                        Text(petName)
                            .font(Font.pc.caption)
                            .foregroundStyle(Color.pc.inkTertiary)
                    } else {
                        Text("Whole household")
                            .font(Font.pc.caption)
                            .foregroundStyle(Color.pc.inkTertiary)
                    }
                }
                Spacer()
                if event.isCancelled {
                    PCChip(text: "Cancelled", style: .neutral)
                }
            }

            if let location = event.locationText, !location.isEmpty {
                Text(location)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notes = event.notes, !notes.isEmpty {
                Text(notes)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: PCSpacing.md) {
                if let onEdit {
                    Button("Edit", action: onEdit)
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.primary)
                        .frame(minHeight: PCMetrics.minTouchTarget)
                }
                if let onCancel {
                    Button("Cancel event", role: .destructive, action: onCancel)
                        .font(Font.pc.secondary)
                        .frame(minHeight: PCMetrics.minTouchTarget)
                }
                if let onArchive {
                    Button("Remove", role: .destructive, action: onArchive)
                        .font(Font.pc.secondary)
                        .frame(minHeight: PCMetrics.minTouchTarget)
                }
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

enum EventEditorDestination: Identifiable {
    case create
    case edit(HouseholdEvent)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let event): event.id.uuidString
        }
    }
}

struct EventEditorView: View {
    @Bindable var store: EventStore
    let destination: EventEditorDestination
    @Environment(\.dismiss) private var dismiss

    @State private var draft = EventDraft()
    @State private var validationMessage: String?

    private var editing: HouseholdEvent? {
        if case .edit(let event) = destination { return event }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    if let validationMessage {
                        CareOutcomeBanner(message: validationMessage, tone: .error) {
                            self.validationMessage = nil
                        }
                    }

                    PCLabeledField(label: "Title") {
                        TextField("Appointment title", text: $draft.title)
                            .textInputAutocapitalization(.sentences)
                    }

                    VStack(alignment: .leading, spacing: PCSpacing.sm) {
                        Text("Kind")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                        Picker("Kind", selection: $draft.kind) {
                            ForEach(EventKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Event kind")
                    }

                    if !store.pets.isEmpty {
                        VStack(alignment: .leading, spacing: PCSpacing.sm) {
                            Text("Pet")
                                .font(Font.pc.secondary)
                                .foregroundStyle(Color.pc.inkSecondary)
                            Picker(
                                "Pet",
                                selection: Binding(
                                    get: { draft.petId?.uuidString ?? "household" },
                                    set: { value in
                                        draft.petId = value == "household" ? nil : UUID(uuidString: value)
                                    }
                                )
                            ) {
                                Text("Whole household").tag("household")
                                ForEach(store.pets, id: \.id) { pet in
                                    Text(pet.name).tag(pet.id.uuidString)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    DatePicker(
                        "Date",
                        selection: $draft.startDate,
                        displayedComponents: .date
                    )
                    .environment(\.calendar, store.calendar)

                    Toggle("All day", isOn: $draft.allDay)

                    if !draft.allDay {
                        DatePicker(
                            "Time",
                            selection: $draft.startTime,
                            displayedComponents: .hourAndMinute
                        )
                        .environment(\.calendar, store.calendar)
                    }

                    PCLabeledField(label: "Location") {
                        TextField("Clinic or place (optional)", text: $draft.locationText)
                    }

                    PCLabeledField(label: "Notes") {
                        TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                            .lineLimit(3...6)
                    }

                    VStack(alignment: .leading, spacing: PCSpacing.sm) {
                        Text("Reminders")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                        ForEach(EventDraft.reminderOptions, id: \.minutes) { option in
                            Toggle(option.label, isOn: binding(for: option.minutes))
                        }
                    }
                }
                .padding(PCSpacing.screenMargin)
                .padding(.bottom, PCSpacing.huge)
            }
            .background(Color.pc.bg)
            .navigationTitle(editing == nil ? "New event" : "Edit event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(store.isSaving)
                }
            }
            .onAppear { seedDraft() }
        }
    }

    private func binding(for minutes: Int) -> Binding<Bool> {
        Binding(
            get: { draft.reminderLeadMinutes.contains(minutes) },
            set: { enabled in
                if enabled {
                    if !draft.reminderLeadMinutes.contains(minutes) {
                        draft.reminderLeadMinutes.append(minutes)
                        draft.reminderLeadMinutes.sort()
                    }
                } else {
                    draft.reminderLeadMinutes.removeAll { $0 == minutes }
                }
            }
        )
    }

    private func seedDraft() {
        guard let editing else {
            if draft.petId == nil, store.pets.count == 1 {
                draft.petId = store.pets[0].id
            }
            return
        }
        draft.title = editing.title
        draft.kind = editing.kind
        draft.petId = editing.petId
        draft.startDate = editing.startDate
        draft.allDay = editing.allDay
        draft.locationText = editing.locationText ?? ""
        draft.notes = editing.notes ?? ""
        draft.reminderLeadMinutes = editing.reminderLeadMinutes
        if let startTime = editing.startTime {
            let parts = startTime.split(separator: ":")
            if parts.count >= 2,
               let hour = Int(parts[0]),
               let minute = Int(parts[1]),
               let date = store.calendar.date(
                   bySettingHour: hour, minute: minute, second: 0, of: editing.startDate
               )
            {
                draft.startTime = date
            }
        }
    }

    private func save() async {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            validationMessage = "Add a title."
            return
        }
        let ok: Bool
        if let editing {
            ok = await store.edit(editing, draft: draft)
        } else {
            ok = await store.create(draft)
        }
        if ok { dismiss() }
        else if let message = store.errorMessage {
            validationMessage = message
        }
    }
}

#Preview("Events list") {
    NavigationStack {
        EventsView(
            store: EventStore(
                service: InMemoryEventService(seeded: [
                    HouseholdEvent(
                        id: UUID(),
                        householdId: UUID(),
                        petId: nil,
                        kind: .vetAppointment,
                        title: "Vet checkup",
                        startDate: Calendar.current.date(byAdding: .day, value: 2, to: Date())!,
                        startTime: "14:00",
                        endTime: nil,
                        allDay: false,
                        locationText: "Maple Vet",
                        providerId: nil,
                        notes: "Bring records",
                        reminderLeadMinutes: [60, 1440],
                        status: .confirmed,
                        revision: 1
                    ),
                ]),
                householdId: UUID(),
                pets: [(UUID(), "Maple")]
            )
        )
    }
}
