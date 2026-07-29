import SwiftUI

struct PlannerTaskDetail: View {
    let item: PlannerAgendaItem
    let context: PlannerContext
    let assignmentName: String
    let onEdit: () -> Void
    let loadHistory: () async throws -> [PlannerHistoryEntry]
    let onAction: (PlannerTaskAction) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var history: [PlannerHistoryEntry] = []
    @State private var isLoadingHistory = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showSkipChoices = false
    @State private var showSnooze = false
    @State private var showReschedule = false
    @State private var showCancel = false

    private var capabilities: PlannerCapabilities { context.capabilities }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    summary
                    if let errorMessage {
                        PCInlineError(message: errorMessage)
                    }
                    primaryAction
                    availableActions
                    historySection
                }
                .padding(PCSpacing.screenMargin)
                .padding(.bottom, PCSpacing.huge)
            }
            .background(Color.pc.bg)
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isWorking)
                }
                if canEdit {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") {
                            dismiss()
                            onEdit()
                        }
                        .disabled(isWorking)
                    }
                }
            }
            .task { await refreshHistory() }
            .confirmationDialog(
                "Skip this task?",
                isPresented: $showSkipChoices,
                titleVisibility: .visible
            ) {
                Button("Not relevant today") {
                    run(.skip(reason: "Not relevant today"))
                }
                Button("Already done") {
                    run(.skip(reason: "Already did this"))
                }
                Button("Too busy today") {
                    run(.skip(reason: "Too busy"))
                }
                Button("Skip without a reason") {
                    run(.skip(reason: nil))
                }
                Button("Keep task", role: .cancel) {}
            } message: {
                Text(item.obligationClass == .required
                    ? "This task is marked required. Skipping is recorded in the household history."
                    : "Skipped tasks remain in history and do not carry over.")
            }
            .confirmationDialog(
                "Cancel this task?",
                isPresented: $showCancel,
                titleVisibility: .visible
            ) {
                if item.isRecurring {
                    Button("This occurrence only", role: .destructive) {
                        run(.cancel(scope: .occurrenceOnly))
                    }
                    Button("This and future", role: .destructive) {
                        run(.cancel(scope: .thisAndFuture))
                    }
                } else {
                    Button("Cancel task", role: .destructive) {
                        run(.cancel(scope: .occurrenceOnly))
                    }
                }
                Button("Keep task", role: .cancel) {}
            } message: {
                Text("The task stays in household history. Completed history is never deleted.")
            }
            .sheet(isPresented: $showSnooze) {
                PlannerSnoozeSheet(
                    item: item,
                    calendar: context.calendar
                ) { date in
                    try await onAction(.snooze(until: date))
                    dismiss()
                }
            }
            .sheet(isPresented: $showReschedule) {
                PlannerRescheduleSheet(
                    item: item,
                    calendar: context.calendar
                ) { date, time, scope in
                    try await onAction(.reschedule(to: date, time: time, scope: scope))
                    dismiss()
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
        .environment(\.calendar, context.calendar)
        .environment(\.timeZone, context.calendar.timeZone)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.state.displayName)
                    .font(Font.pc.secondary.weight(.semibold))
                    .foregroundStyle(statusColor)
                Spacer()
                if item.state == .queued {
                    PCChip(text: "queued", icon: "arrow.triangle.2.circlepath", style: .info)
                } else if item.state == .stale {
                    PCChip(text: "last synced", icon: "clock.arrow.circlepath", style: .info)
                }
            }

            detailRow(
                icon: "calendar",
                label: "When",
                value: "\(PlannerFormatters.fullDay(item.date, calendar: context.calendar)) · \(item.time.summary(calendar: context.calendar))"
            )
            detailRow(icon: "pawprint", label: "Pet", value: item.petName)
            detailRow(
                icon: "arrow.trianglehead.2.clockwise.rotate.90",
                label: "Repeat",
                value: item.recurrence.summary(starting: item.date, calendar: context.calendar)
            )
            detailRow(icon: "person", label: "For", value: assignmentName)

            if item.reminder != .none {
                detailRow(icon: "bell", label: "Reminder", value: item.reminder.displayName)
            }
            if let snoozedUntil = item.snoozedUntil {
                detailRow(
                    icon: "clock",
                    label: "Snoozed until",
                    value: PlannerFormatters.time(snoozedUntil, calendar: context.calendar)
                )
            }
            if !item.notes.isEmpty {
                Divider().overlay(Color.pc.border)
                Text(item.notes)
                    .font(Font.pc.body)
                    .foregroundStyle(Color.pc.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PCSpacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .strokeBorder(Color.pc.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch item.state {
        case .pending:
            if capabilities.contains(.complete) {
                PrimaryButton(title: "Mark complete", isLoading: isWorking) {
                    run(.complete)
                }
            }
        case .completed:
            if capabilities.contains(.undoComplete) {
                SecondaryButton(title: "Undo completion", isDisabled: isWorking) {
                    run(.undoComplete)
                }
            }
        case .skipped:
            if capabilities.contains(.undoSkip) {
                SecondaryButton(title: "Undo skip", isDisabled: isWorking) {
                    run(.undoSkip)
                }
            }
        case .cancelled, .expired, .queued, .stale:
            EmptyView()
        }
    }

    private var availableActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasSecondaryActions {
                SectionHeader(title: "More actions")
                    .padding(.bottom, PCSpacing.sm)
            }
            if canSnooze {
                actionRow(title: "Snooze within today", icon: "clock.arrow.circlepath") {
                    showSnooze = true
                }
            }
            if canReschedule {
                actionRow(title: "Reschedule", icon: "calendar.badge.clock") {
                    showReschedule = true
                }
            }
            if canSkip {
                actionRow(title: "Skip for today", icon: "forward") {
                    showSkipChoices = true
                }
            }
            if canCancel {
                actionRow(title: item.isRecurring ? "Cancel task or routine" : "Cancel task", icon: "xmark.circle", destructive: true) {
                    showCancel = true
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            SectionHeader(title: "History")
            if isLoadingHistory {
                HStack(spacing: PCSpacing.sm) {
                    ProgressView()
                    Text("Loading history…")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                }
                .frame(minHeight: PCMetrics.minTouchTarget)
            } else if !capabilities.contains(.history) {
                Text("History will appear when Planner sync is connected.")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
            } else if history.isEmpty {
                Text("No changes recorded yet.")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
            } else {
                ForEach(history) { entry in
                    HStack(alignment: .top, spacing: PCSpacing.md) {
                        Image(systemName: historyIcon(for: entry.action))
                            .foregroundStyle(Color.pc.inkSecondary)
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: PCSpacing.xs) {
                            Text(entry.actionText)
                                .font(Font.pc.body.weight(.medium))
                                .foregroundStyle(Color.pc.ink)
                            Text(historyMeta(entry))
                                .font(Font.pc.secondary)
                                .foregroundStyle(Color.pc.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if entry.isQueued {
                            PCChip(text: "queued", style: .info)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PCSpacing.md) {
            Image(systemName: icon)
                .foregroundStyle(Color.pc.inkSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkSecondary)
                Text(value)
                    .font(Font.pc.body)
                    .foregroundStyle(Color.pc.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func actionRow(
        title: String,
        icon: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: PCSpacing.md) {
                Image(systemName: icon)
                    .frame(width: 24)
                Text(title)
                    .font(Font.pc.body)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(destructive ? Color.pc.danger : Color.pc.ink)
            .frame(minHeight: PCMetrics.listRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .overlay(alignment: .bottom) {
            Divider().overlay(Color.pc.border)
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .completed: .pc.success
        case .cancelled, .expired: .pc.inkSecondary
        case .queued, .stale: .pc.info
        case .pending, .skipped: .pc.inkSecondary
        }
    }

    private var canEdit: Bool {
        item.state == .pending
            && (capabilities.contains(.editOccurrence)
                || (item.isRecurring && capabilities.contains(.editSeries)))
    }

    private var canSnooze: Bool {
        item.state == .pending
            && context.calendar.isDateInToday(item.date)
            && capabilities.contains(.snooze)
    }

    private var canReschedule: Bool {
        item.state == .pending && capabilities.contains(.reschedule)
    }

    private var canSkip: Bool {
        item.state == .pending && capabilities.contains(.skip)
    }

    private var canCancel: Bool {
        item.state == .pending && capabilities.contains(.cancel)
    }

    private var hasSecondaryActions: Bool {
        canSnooze || canReschedule || canSkip || canCancel
    }

    private func run(_ action: PlannerTaskAction) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await onAction(action)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshHistory() async {
        guard capabilities.contains(.history) else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            history = try await loadHistory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func historyMeta(_ entry: PlannerHistoryEntry) -> String {
        var pieces = [
            "by \(entry.actorName)",
            "\(PlannerFormatters.day(entry.effectiveAt, calendar: context.calendar)) \(PlannerFormatters.time(entry.effectiveAt, calendar: context.calendar))",
        ]
        if let detail = entry.detail, !detail.isEmpty {
            pieces.append(detail)
        }
        return pieces.joined(separator: " · ")
    }

    private func historyIcon(for action: Disposition.Action) -> String {
        switch action {
        case .complete: "checkmark.circle"
        case .undoComplete, .undoSkip: "arrow.uturn.backward.circle"
        case .skip: "forward.circle"
        case .snooze: "clock"
        case .reschedule: "calendar.badge.clock"
        case .cancel, .dismissRequired: "xmark.circle"
        }
    }
}

private struct PlannerSnoozeSheet: View {
    let item: PlannerAgendaItem
    let calendar: Calendar
    let onSave: (Date) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        item: PlannerAgendaItem,
        calendar: Calendar,
        onSave: @escaping (Date) async throws -> Void
    ) {
        self.item = item
        self.calendar = calendar
        self.onSave = onSave
        let suggested = calendar.date(byAdding: .hour, value: 1, to: .now) ?? .now
        _selectedDate = State(initialValue: suggested)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    Text("Snooze changes reminder emphasis only. The task stays due today and remains visible to the household.")
                        .font(Font.pc.body)
                        .foregroundStyle(Color.pc.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    PCLabeledField(label: "Remind me at") {
                        DatePicker(
                            "Snooze until",
                            selection: $selectedDate,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                    }

                    if let errorMessage {
                        PCInlineError(message: errorMessage)
                    }

                    PrimaryButton(title: "Snooze", isLoading: isSaving) {
                        save()
                    }
                }
                .padding(PCSpacing.screenMargin)
            }
            .background(Color.pc.bg)
            .navigationTitle("Snooze")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .presentationDetents([.medium, .large])
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
    }

    private func save() {
        guard selectedDate > Date(), calendar.isDateInToday(selectedDate) else {
            errorMessage = "Choose a time later today."
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await onSave(selectedDate)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PlannerRescheduleSheet: View {
    let item: PlannerAgendaItem
    let calendar: Calendar
    let onSave: (Date, PlannerTimeSelection, PlannerEditScope) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var time: PlannerTimeSelection
    @State private var scope: PlannerEditScope = .occurrenceOnly
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        item: PlannerAgendaItem,
        calendar: Calendar,
        onSave: @escaping (Date, PlannerTimeSelection, PlannerEditScope) async throws -> Void
    ) {
        self.item = item
        self.calendar = calendar
        self.onSave = onSave
        _date = State(initialValue: item.date)
        _time = State(initialValue: item.time)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    PCLabeledField(label: "New date") {
                        DatePicker("New date", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: PCSpacing.md) {
                        PCLabeledField(label: "Time") {
                            Picker("Time", selection: timeModeBinding) {
                                Text("Anytime").tag(RescheduleTimeMode.anytime)
                                Text("Window").tag(RescheduleTimeMode.window)
                                Text("Exact").tag(RescheduleTimeMode.exact)
                            }
                            .pickerStyle(.segmented)
                        }

                        switch time {
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

                    if item.isRecurring {
                        VStack(alignment: .leading, spacing: PCSpacing.sm) {
                            SectionHeader(title: "Apply change to")
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

                    Text(scope.explanation)
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let errorMessage {
                        PCInlineError(message: errorMessage)
                    }

                    PrimaryButton(title: "Reschedule", isLoading: isSaving) {
                        save()
                    }
                }
                .padding(PCSpacing.screenMargin)
            }
            .background(Color.pc.bg)
            .navigationTitle("Reschedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .presentationDetents([.medium, .large])
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
    }

    private var timeModeBinding: Binding<RescheduleTimeMode> {
        Binding(
            get: {
                switch time {
                case .anytime: .anytime
                case .window: .window
                case .exact: .exact
                }
            },
            set: { mode in
                switch mode {
                case .anytime:
                    time = .anytime
                case .window:
                    time = .window(.morning)
                case .exact:
                    time = .exact(
                        calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
                    )
                }
            }
        )
    }

    private func windowBinding(_ fallback: PlanTimeWindow) -> Binding<PlanTimeWindow> {
        Binding(
            get: {
                if case .window(let window) = time { return window }
                return fallback
            },
            set: { time = .window($0) }
        )
    }

    private func exactTimeBinding(_ fallback: Date) -> Binding<Date> {
        Binding(
            get: {
                if case .exact(let selected) = time { return selected }
                return fallback
            },
            set: { time = .exact($0) }
        )
    }

    private func save() {
        guard calendar.startOfDay(for: date) >= calendar.startOfDay(for: .now) else {
            errorMessage = "Choose today or a future date."
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await onSave(date, time, scope)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum RescheduleTimeMode: Hashable {
    case anytime, window, exact
}
