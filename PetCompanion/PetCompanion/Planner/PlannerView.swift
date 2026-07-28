import SwiftUI

/// PL-01 — an agenda-first household Planner. The view depends on a
/// Planner-specific service so current PlanService compatibility and the full
/// Slice B adapter can coexist without UI forks.
struct PlannerView: View {
    @Environment(AppModel.self) private var model
    @State private var store: PlannerStore?

    private let injectedService: (any PlannerService)?

    init(service: (any PlannerService)? = nil) {
        injectedService = service
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.pc.bg.ignoresSafeArea()
                if let store {
                    PlannerContentView(store: store)
                } else {
                    loadingState
                }
            }
            .navigationTitle("Planner")
            .profileEntry()
            .toolbar {
                if let store {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            store.showMonthJump = true
                        } label: {
                            Label(store.monthTitle, systemImage: "chevron.down")
                                .font(Font.pc.secondary.weight(.semibold))
                        }
                        .accessibilityHint("Opens date picker")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            store.newTask()
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
                        }
                        .disabled(!store.capabilities.contains(.createOneTime))
                        .accessibilityLabel("Add a task")
                    }
                }
            }
        }
        .task {
            guard store == nil else { return }
            let service = injectedService
                ?? model.planner
                ?? PlanServicePlannerAdapter(model: model)
            let created = PlannerStore(service: service)
            store = created
            await created.start()
        }
    }

    private var loadingState: some View {
        VStack(spacing: PCSpacing.md) {
            ProgressView()
                .tint(Color.pc.primary)
            Text("Preparing your Planner…")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PlannerContentView: View {
    @Bindable var store: PlannerStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                weekNavigator

                if store.isStale, let lastVerifiedAt = store.agenda?.lastVerifiedAt {
                    SyncStatusLine(status: .stale(lastSynced: lastVerifiedAt))
                }

                if let confirmation = store.confirmationMessage {
                    statusBanner(
                        confirmation,
                        systemImage: "checkmark.circle",
                        color: Color.pc.success,
                        dismiss: store.clearConfirmation
                    )
                }
                if let error = store.errorMessage, store.agenda != nil {
                    statusBanner(
                        error,
                        systemImage: "exclamationmark.triangle",
                        color: Color.pc.danger,
                        dismiss: store.clearError
                    )
                }

                agendaContent
            }
            .padding(.horizontal, PCSpacing.screenMargin)
            .padding(.top, PCSpacing.md)
            .padding(.bottom, PCSpacing.huge)
        }
        .refreshable { await store.loadSelectedDay() }
        .sheet(item: $store.editorRoute) { route in
            if let context = store.context {
                PlannerTaskEditor(
                    context: context,
                    route: route,
                    isWorking: store.isSaving
                ) { draft, scope in
                    try await store.save(draft, scope: scope)
                }
            }
        }
        .sheet(item: $store.detailItem) { item in
            if let context = store.context {
                PlannerTaskDetail(
                    item: item,
                    context: context,
                    assignmentName: store.assignmentName(for: item.assignment),
                    onEdit: {
                        Task { @MainActor in
                            await Task.yield()
                            store.edit(item)
                        }
                    },
                    loadHistory: {
                        try await store.history(for: item)
                    },
                    onAction: { action in
                        try await store.perform(action, on: item)
                    }
                )
            }
        }
        .sheet(isPresented: $store.showMonthJump) {
            PlannerMonthJumpSheet(
                selectedDate: store.selectedDate,
                calendar: store.calendar
            ) { date in
                store.select(date)
            }
        }
    }

    private var weekNavigator: some View {
        VStack(spacing: PCSpacing.md) {
            HStack {
                Button {
                    store.moveWeek(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
                }
                .accessibilityLabel("Previous week")

                Spacer()

                Button("Today") {
                    store.jumpToToday()
                }
                .font(Font.pc.secondary.weight(.semibold))
                .foregroundStyle(Color.pc.primary)
                .frame(minHeight: PCMetrics.minTouchTarget)
                .disabled(store.calendar.isDateInToday(store.selectedDate))

                Spacer()

                Button {
                    store.moveWeek(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
                }
                .accessibilityLabel("Next week")
            }
            .foregroundStyle(Color.pc.primary)

            HStack(spacing: PCSpacing.xs) {
                ForEach(store.weekDates, id: \.self) { date in
                    dayButton(date)
                }
            }
            // Seven compact day controls must remain legible as a set. The
            // surrounding agenda continues to scale through the full
            // accessibility range, while VoiceOver exposes each control's
            // complete date.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
    }

    private func dayButton(_ date: Date) -> some View {
        let isSelected = store.calendar.isDate(date, inSameDayAs: store.selectedDate)
        let isToday = store.calendar.isDateInToday(date)
        let weekday = PlannerFormatters.weekdayNarrow(date, calendar: store.calendar)
        let day = store.calendar.component(.day, from: date)

        return Button {
            store.select(date)
        } label: {
            VStack(spacing: PCSpacing.xs) {
                Text(weekday)
                    .font(Font.pc.caption)
                Text("\(day)")
                    .font(Font.pc.body.weight(.semibold))
                Circle()
                    .fill(isToday ? Color.pc.accent : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .foregroundStyle(isSelected ? Color.pc.onPrimary : Color.pc.ink)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(
                RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                    .fill(isSelected ? Color.pc.primary : Color.pc.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                    .strokeBorder(isSelected ? Color.pc.primary : Color.pc.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PlannerFormatters.fullDay(date, calendar: store.calendar))
        .accessibilityValue([
            isSelected ? "Selected" : nil,
            isToday ? "Today" : nil,
        ].compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder
    private var agendaContent: some View {
        if store.isLoading {
            loadingAgenda
        } else if let agenda = store.agenda {
            VStack(alignment: .leading, spacing: PCSpacing.md) {
                VStack(alignment: .leading, spacing: PCSpacing.xs) {
                    Text(store.selectedDayTitle)
                        .font(Font.pc.title)
                        .foregroundStyle(Color.pc.ink)
                        .accessibilityAddTraits(.isHeader)
                    if store.selectedDayTitle != store.selectedDaySubtitle {
                        Text(store.selectedDaySubtitle)
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                    }
                }

                if let unplanned = agenda.unplannedDayMessage(
                    today: .now,
                    calendar: store.calendar
                ) {
                    unplannedDay(unplanned)
                } else if agenda.items.isEmpty {
                    emptyDay
                } else {
                    LazyVStack(spacing: PCSpacing.betweenCards) {
                        ForEach(agenda.items) { item in
                            PlannerAgendaRow(
                                item: item,
                                calendar: store.calendar,
                                showsPetName: store.pets.count > 1,
                                canToggleCompletion: canToggle(item),
                                onToggleCompletion: {
                                    toggleCompletion(item)
                                },
                                onOpen: {
                                    store.detailItem = item
                                }
                            )
                        }
                    }
                }
            }
        } else {
            EmptyStateView(
                systemImage: "wifi.exclamationmark",
                message: store.errorMessage ?? "The agenda couldn't be loaded.",
                primaryActionTitle: "Try again",
                primaryAction: {
                    Task { await store.loadSelectedDay() }
                }
            )
        }
    }

    private var emptyDay: some View {
        dayCard(
            message: "Nothing is scheduled for this day.",
            systemImage: "calendar.badge.checkmark"
        )
    }

    /// A day with no plan at all. Deliberately not the empty-day card: that
    /// one asserts the day is clear, and this one cannot (IA §15.1). Quick
    /// add is still offered — the day is unknown, not closed.
    private func unplannedDay(_ message: String) -> some View {
        dayCard(message: message, systemImage: "calendar.badge.questionmark")
    }

    private func dayCard(message: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.lg) {
            Label(message, systemImage: systemImage)
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.capabilities.contains(.createOneTime) {
                SecondaryButton(title: "Add a task") {
                    store.newTask()
                }
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
    }

    private var loadingAgenda: some View {
        VStack(spacing: PCSpacing.betweenCards) {
            ForEach(0..<3, id: \.self) { _ in
                PlanItemCard(title: "Loading agenda item", meta: "Loading")
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading agenda")
    }

    private func canToggle(_ item: PlannerAgendaItem) -> Bool {
        switch item.state {
        case .pending:
            return store.capabilities.contains(.complete)
        case .completed:
            return store.capabilities.contains(.undoComplete)
        case .skipped, .cancelled, .expired, .queued, .stale:
            return false
        }
    }

    private func toggleCompletion(_ item: PlannerAgendaItem) {
        let action: PlannerTaskAction = item.state == .completed ? .undoComplete : .complete
        Task {
            do {
                try await store.perform(action, on: item)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func statusBanner(
        _ message: String,
        systemImage: String,
        color: Color,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: PCSpacing.md) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(message)
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PCSpacing.sm)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.pc.inkSecondary)
            .accessibilityLabel("Dismiss message")
        }
        .padding(PCSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                .fill(Color.pc.surfaceSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                .strokeBorder(Color.pc.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

private struct PlannerAgendaRow: View {
    let item: PlannerAgendaItem
    let calendar: Calendar
    let showsPetName: Bool
    let canToggleCompletion: Bool
    let onToggleCompletion: () -> Void
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isComplete: Bool { item.state == .completed }

    var body: some View {
        HStack(alignment: .top, spacing: PCSpacing.md) {
            Button(action: onToggleCompletion) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isComplete ? Color.pc.success : Color.pc.inkTertiary,
                            lineWidth: PCMetrics.iconStroke
                        )
                    if isComplete {
                        Circle().fill(Color.pc.success)
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Color.pc.onPrimary)
                            .transition(reduceMotion ? .identity : .scale.combined(with: .opacity))
                    }
                }
                .frame(width: PCMetrics.checkboxSize, height: PCMetrics.checkboxSize)
                .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canToggleCompletion)
            .accessibilityLabel(isComplete
                ? "Undo completion for \(item.title)"
                : "Mark \(item.title) complete")
            .padding(.top, -(PCMetrics.minTouchTarget - PCMetrics.checkboxSize) / 2)
            .padding(.leading, -(PCMetrics.minTouchTarget - PCMetrics.checkboxSize) / 2)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: PCSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: PCSpacing.sm) {
                        Text(item.title)
                            .font(Font.pc.body.weight(.medium))
                            .foregroundStyle(Color.pc.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: PCSpacing.sm)
                        stateChip
                    }
                    Text(meta)
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                        .multilineTextAlignment(.leading)
                    if let attribution = item.completionAttribution, isComplete {
                        Text(attribution)
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.success)
                    }
                    if let snoozedUntil = item.snoozedUntil {
                        Label(
                            "Snoozed until \(PlannerFormatters.time(snoozedUntil, calendar: calendar))",
                            systemImage: "clock"
                        )
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.info)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens task details and history")
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
        .opacity(item.state == .cancelled || item.state == .expired ? 0.62 : 1)
    }

    @ViewBuilder
    private var stateChip: some View {
        switch item.state {
        case .pending:
            EmptyView()
        case .completed:
            PCChip(text: "completed", icon: "checkmark", style: .success)
        case .skipped:
            PCChip(text: "skipped", icon: "forward", style: .neutral)
        case .cancelled:
            PCChip(text: "cancelled", icon: "xmark", style: .neutral)
        case .expired:
            PCChip(text: "expired", icon: "clock", style: .neutral)
        case .queued:
            PCChip(text: "queued", icon: "arrow.triangle.2.circlepath", style: .info)
        case .stale:
            PCChip(text: "last synced", icon: "clock.arrow.circlepath", style: .info)
        }
    }

    private var meta: String {
        var pieces = [item.time.summary(calendar: calendar)]
        if showsPetName {
            pieces.append(item.petName)
        }
        if item.isRecurring {
            pieces.append("Repeats")
        }
        return pieces.joined(separator: " · ")
    }
}

private struct PlannerMonthJumpSheet: View {
    let calendar: Calendar
    let onSelect: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(
        selectedDate: Date,
        calendar: Calendar,
        onSelect: @escaping (Date) -> Void
    ) {
        self.calendar = calendar
        self.onSelect = onSelect
        _date = State(initialValue: selectedDate)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: PCSpacing.xl) {
                DatePicker(
                    "Choose a date",
                    selection: $date,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(Color.pc.primary)

                PrimaryButton(title: "Show date") {
                    onSelect(date)
                    dismiss()
                }
            }
            .padding(PCSpacing.screenMargin)
            .background(Color.pc.bg)
            .navigationTitle("Jump to date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
    }
}

#Preview("Planner agenda") {
    let model = AppModel.preview()
    PlannerView(service: InMemoryPlannerService.preview(model: model))
        .environment(model)
}
