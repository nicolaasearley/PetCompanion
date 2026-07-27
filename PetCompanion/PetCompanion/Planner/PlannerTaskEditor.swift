import SwiftUI

struct PlannerTaskEditor: View {
    let context: PlannerContext
    let initialRoute: PlannerEditorRoute
    let isWorkingOutside: Bool
    let onSave: (PlannerTaskDraft, PlannerEditScope?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlannerTaskDraft
    @State private var scope: PlannerEditScope?
    @State private var pattern: RepeatPattern
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        context: PlannerContext,
        route: PlannerEditorRoute,
        isWorking: Bool,
        onSave: @escaping (PlannerTaskDraft, PlannerEditScope?) async throws -> Void
    ) {
        self.context = context
        initialRoute = route
        isWorkingOutside = isWorking
        self.onSave = onSave
        _draft = State(initialValue: route.draft)
        _scope = State(initialValue: route.scope)
        _pattern = State(initialValue: RepeatPattern(recurrence: route.draft.recurrence))
    }

    private var isWorking: Bool { isSaving || isWorkingOutside }
    private var supportsRichFields: Bool { context.capabilities.contains(.richTaskFields) }
    private var supportsNotes: Bool { context.capabilities.contains(.taskNotes) }
    private var supportsRecurrence: Bool { context.capabilities.contains(.createRecurring) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    identitySection
                    scheduleSection
                    if supportsRichFields {
                        assignmentAndReminderSection
                    }
                    if supportsNotes {
                        notesSection
                    } else {
                        if !supportsRichFields {
                            compatibilityNote
                        }
                    }
                    if draft.isEditingRecurringTask {
                        editScopeSection
                    }
                    if let errorMessage {
                        PCInlineError(message: errorMessage)
                    }
                }
                .padding(PCSpacing.screenMargin)
                .padding(.bottom, PCSpacing.huge)
            }
            .background(Color.pc.bg)
            .navigationTitle(draft.isEditing ? "Edit task" : "New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isWorking {
                            ProgressView()
                                .accessibilityLabel("Saving task")
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isWorking || currentValidation != nil)
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
        .environment(\.calendar, context.calendar)
        .environment(\.timeZone, context.calendar.timeZone)
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.lg) {
            PCLabeledField(label: "Title", errorMessage: titleError) {
                TextField("What needs doing?", text: $draft.title)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .accessibilityHint("Required")
            }

            if context.pets.count > 1 {
                PCLabeledField(label: "Pet") {
                    Picker("Pet", selection: $draft.petId) {
                        Text("Choose a pet").tag(Optional<UUID>.none)
                        ForEach(context.pets) { pet in
                            Text(pet.name).tag(Optional(pet.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.lg) {
            SectionHeader(title: "Schedule")

            PCLabeledField(label: "Date") {
                DatePicker(
                    "Date",
                    selection: $draft.date,
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .accessibilityLabel("Task date")
            }

            if supportsRichFields {
                timingControls
            }

            if supportsRecurrence {
                repeatControls
            } else {
                PCLabeledField(label: "Repeat") {
                    Text("Does not repeat")
                        .foregroundStyle(Color.pc.ink)
                }
            }

            recurrenceSummary
        }
    }

    private var timingControls: some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            PCLabeledField(label: "Time") {
                Picker("Time", selection: timeModeBinding) {
                    Text("Anytime").tag(TimeMode.anytime)
                    Text("Window").tag(TimeMode.window)
                    Text("Exact").tag(TimeMode.exact)
                }
                .pickerStyle(.segmented)
            }

            switch draft.time {
            case .window(let selected):
                PCLabeledField(label: "Window") {
                    Picker("Window", selection: windowBinding(selected)) {
                        ForEach(PlanTimeWindow.allCases, id: \.self) { window in
                            Text(window.displayName).tag(window)
                        }
                    }
                    .pickerStyle(.menu)
                }
            case .exact(let selected):
                PCLabeledField(label: "Exact time") {
                    DatePicker(
                        "Exact time",
                        selection: exactTimeBinding(selected),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                }
            case .anytime:
                EmptyView()
            }
        }
    }

    private var repeatControls: some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            PCLabeledField(label: "Repeat") {
                Picker("Repeat", selection: $pattern) {
                    ForEach(RepeatPattern.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: pattern) { _, newValue in
                    apply(newValue)
                }
            }

            switch draft.recurrence {
            case .selectedWeekdays(let selection):
                weekdayChooser(selection: selection)
            case .everyNDays(let interval):
                PCLabeledField(label: "Interval") {
                    Stepper(
                        "Every \(interval) days",
                        value: everyNDaysBinding,
                        in: 2...30
                    )
                }
            case .monthlySafe(let day):
                PCLabeledField(label: "Day of month") {
                    Stepper(
                        "Day \(day)",
                        value: monthlyDayBinding,
                        in: 1...31
                    )
                }
            case .once, .daily:
                EmptyView()
            }
        }
    }

    private func weekdayChooser(selection: Set<PlannerWeekday>) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            Text("Days")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)

            Grid(horizontalSpacing: PCSpacing.sm, verticalSpacing: PCSpacing.sm) {
                GridRow {
                    ForEach(Array(orderedWeekdays.prefix(4))) { weekday in
                        weekdayButton(weekday, selected: selection.contains(weekday))
                    }
                }
                GridRow {
                    ForEach(Array(orderedWeekdays.suffix(3))) { weekday in
                        weekdayButton(weekday, selected: selection.contains(weekday))
                    }
                    Color.clear
                        .frame(minWidth: PCMetrics.minTouchTarget, minHeight: PCMetrics.minTouchTarget)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)

            if selection.isEmpty {
                PCInlineError(message: "Choose at least one weekday.")
            }
        }
    }

    private func weekdayButton(_ weekday: PlannerWeekday, selected: Bool) -> some View {
        Button {
            var selection: Set<PlannerWeekday>
            if case .selectedWeekdays(let current) = draft.recurrence {
                selection = current
            } else {
                selection = []
            }
            if selected {
                selection.remove(weekday)
            } else {
                selection.insert(weekday)
            }
            draft.recurrence = .selectedWeekdays(selection)
        } label: {
            Text(weekday.displayName(calendar: context.calendar, width: .narrow))
                .font(Font.pc.body.weight(.semibold))
                .foregroundStyle(selected ? Color.pc.onPrimary : Color.pc.ink)
                .frame(maxWidth: .infinity, minHeight: PCMetrics.minTouchTarget)
                .background(
                    RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                        .fill(selected ? Color.pc.primary : Color.pc.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                        .strokeBorder(selected ? Color.pc.primary : Color.pc.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(weekday.displayName(calendar: context.calendar))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var recurrenceSummary: some View {
        VStack(alignment: .leading, spacing: PCSpacing.xs) {
            Label("Schedule summary", systemImage: "calendar")
                .font(Font.pc.secondary.weight(.semibold))
                .foregroundStyle(Color.pc.inkSecondary)
            Text(draft.recurrence.summary(starting: draft.date, calendar: context.calendar))
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Time: \(draft.time.summary(calendar: context.calendar))")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
        }
        .padding(PCSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surfaceSubtle)
        )
        .accessibilityElement(children: .combine)
    }

    private var assignmentAndReminderSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.lg) {
            SectionHeader(title: "Household")

            PCLabeledField(label: "For") {
                Picker("For", selection: $draft.assignment) {
                    ForEach(context.members) { member in
                        Text(member.name).tag(member.kind)
                    }
                }
                .pickerStyle(.menu)
            }

            PCLabeledField(label: "Reminder") {
                Picker("Reminder", selection: $draft.reminder) {
                    ForEach(allowedReminders) { reminder in
                        Text(reminder.displayName).tag(reminder)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            Text("Notes")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
            TextField("Optional household context", text: $draft.notes, axis: .vertical)
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.ink)
                .lineLimit(3...8)
                .padding(PCSpacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                        .fill(Color.pc.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                        .strokeBorder(Color.pc.border, lineWidth: 1)
                )
        }
    }

    private var editScopeSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            SectionHeader(title: "Apply changes to")
            ForEach(PlannerEditScope.allCases) { option in
                PCRadioRow(
                    title: option.displayName,
                    subtitle: option.explanation,
                    isSelected: scope == option
                ) {
                    scope = option
                }
            }
        }
    }

    private var compatibilityNote: some View {
        Label(
            "This connected build can save a dated, anytime task. Time, assignment, reminders, and recurring routines will unlock when Planner sync is connected.",
            systemImage: "info.circle"
        )
        .font(Font.pc.secondary)
        .foregroundStyle(Color.pc.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(PCSpacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surfaceSubtle)
        )
    }

    private var titleError: String? {
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.title.isEmpty
            ? "Enter a task title."
            : nil
    }

    private var currentValidation: String? {
        if draft.isEditingRecurringTask && scope == nil {
            return "Choose how broadly to apply this change."
        }
        return draft.validationMessage(calendar: context.calendar, today: .now)
    }

    private var orderedWeekdays: [PlannerWeekday] {
        PlannerWeekday.allCases.sorted {
            (($0.rawValue - context.calendar.firstWeekday + 7) % 7)
                < (($1.rawValue - context.calendar.firstWeekday + 7) % 7)
        }
    }

    private var allowedReminders: [PlannerReminder] {
        switch draft.time {
        case .anytime:
            [.none]
        case .window:
            [.none, .atWindow]
        case .exact:
            [.none, .atTime, .fifteenMinutesBefore, .oneHourBefore]
        }
    }

    private var timeModeBinding: Binding<TimeMode> {
        Binding(
            get: {
                switch draft.time {
                case .anytime: .anytime
                case .window: .window
                case .exact: .exact
                }
            },
            set: { mode in
                switch mode {
                case .anytime:
                    draft.time = .anytime
                    draft.reminder = .none
                case .window:
                    draft.time = .window(.morning)
                    draft.reminder = .none
                case .exact:
                    draft.time = .exact(defaultExactTime)
                    draft.reminder = .none
                }
            }
        )
    }

    private func windowBinding(_ fallback: PlanTimeWindow) -> Binding<PlanTimeWindow> {
        Binding(
            get: {
                if case .window(let window) = draft.time { return window }
                return fallback
            },
            set: { draft.time = .window($0) }
        )
    }

    private func exactTimeBinding(_ fallback: Date) -> Binding<Date> {
        Binding(
            get: {
                if case .exact(let time) = draft.time { return time }
                return fallback
            },
            set: { draft.time = .exact($0) }
        )
    }

    private var everyNDaysBinding: Binding<Int> {
        Binding(
            get: {
                if case .everyNDays(let interval) = draft.recurrence { return interval }
                return 2
            },
            set: { draft.recurrence = .everyNDays($0) }
        )
    }

    private var monthlyDayBinding: Binding<Int> {
        Binding(
            get: {
                if case .monthlySafe(let day) = draft.recurrence { return day }
                return context.calendar.component(.day, from: draft.date)
            },
            set: { draft.recurrence = .monthlySafe(day: $0) }
        )
    }

    private var defaultExactTime: Date {
        context.calendar.date(
            bySettingHour: 9,
            minute: 0,
            second: 0,
            of: draft.date
        ) ?? draft.date
    }

    private func apply(_ pattern: RepeatPattern) {
        switch pattern {
        case .once:
            draft.recurrence = .once
        case .daily:
            draft.recurrence = .daily
        case .selectedWeekdays:
            let currentWeekday = PlannerWeekday(
                rawValue: context.calendar.component(.weekday, from: draft.date)
            ) ?? .monday
            draft.recurrence = .selectedWeekdays([currentWeekday])
        case .everyNDays:
            draft.recurrence = .everyNDays(3)
        case .monthly:
            draft.recurrence = .monthlySafe(
                day: context.calendar.component(.day, from: draft.date)
            )
        }
    }

    private func save() {
        guard let validation = currentValidation else {
            errorMessage = nil
            isSaving = true
            Task {
                defer { isSaving = false }
                do {
                    try await onSave(draft, scope)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        errorMessage = validation
    }
}

private enum TimeMode: String, Hashable {
    case anytime, window, exact
}

private enum RepeatPattern: String, CaseIterable, Identifiable {
    case once, daily, selectedWeekdays, everyNDays, monthly

    var id: String { rawValue }

    init(recurrence: PlannerRecurrence) {
        self = switch recurrence {
        case .once: .once
        case .daily: .daily
        case .selectedWeekdays: .selectedWeekdays
        case .everyNDays: .everyNDays
        case .monthlySafe: .monthly
        }
    }

    var displayName: String {
        switch self {
        case .once: "Does not repeat"
        case .daily: "Every day"
        case .selectedWeekdays: "Selected weekdays"
        case .everyNDays: "Every few days"
        case .monthly: "Monthly"
        }
    }
}
