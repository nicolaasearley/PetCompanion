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
                            Task { await store.refreshMonthJumpMarkers(for: store.selectedDate) }
                        } label: {
                            Label(store.monthTitle, systemImage: "chevron.down")
                                .font(Font.pc.secondary.weight(.semibold))
                        }
                        .accessibilityHint("Opens date picker. Filled dots mark days with tasks or events.")
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
            let created = PlannerStore(
                service: service,
                eventService: model.events,
                householdId: model.household?.id
            )
            store = created
            await created.start()
        }
        .onChange(of: model.planState.reconciliationEpoch) { _, epoch in
            guard epoch > 0, let store else { return }
            Task { await store.refreshVisibleWindow() }
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    weekNavigator

                    if store.isStale, let lastVerifiedAt = store.lastVerifiedAt {
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
                    if let error = store.errorMessage, store.hasAgenda {
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
            .onChange(of: store.scrollTargetDate) { _, target in
                guard let target else { return }
                let id = dayScrollID(target)
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .top)
                }
                store.consumeScrollTarget()
            }
        }
        .refreshable {
            await store.refreshFromPull()
        }
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
        .sheet(item: $store.detailEvent) { event in
            PlannerEventDetailSheet(
                event: event,
                showsPetName: store.pets.count > 1,
                calendar: store.calendar
            )
        }
        .sheet(isPresented: $store.showMonthJump) {
            PlannerMonthJumpSheet(
                selectedDate: store.selectedDate,
                calendar: store.calendar,
                contentDates: store.monthJumpContentDates,
                onVisibleMonthChange: { month in
                    Task { await store.refreshMonthJumpMarkers(for: month) }
                }
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

                VStack(spacing: PCSpacing.xs) {
                    Text(store.weekNavigatorTitle)
                        .font(Font.pc.body.weight(.semibold))
                        .foregroundStyle(Color.pc.ink)
                        .accessibilityAddTraits(.isHeader)

                    Button("Today") {
                        store.jumpToToday()
                    }
                    .font(Font.pc.secondary.weight(.semibold))
                    .foregroundStyle(Color.pc.primary)
                    .frame(minHeight: PCMetrics.minTouchTarget)
                    .disabled(store.calendar.isDateInToday(store.selectedDate)
                        && store.isShowingCurrentWeek
                        && store.days.first.map { store.calendar.isDateInToday($0.date) } == true)
                }

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

            // Compact week strip remains a secondary jump affordance; the
            // primary experience is the forward-scrolling day list below.
            HStack(spacing: PCSpacing.xs) {
                ForEach(store.weekDates, id: \.self) { date in
                    dayButton(date)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
    }

    private func dayButton(_ date: Date) -> some View {
        let isSelected = store.calendar.isDate(date, inSameDayAs: store.selectedDate)
        let isToday = store.calendar.isDateInToday(date)
        let weekday = PlannerFormatters.weekdayNarrow(date, calendar: store.calendar)
        let day = store.calendar.component(.day, from: date)
        let hasItems = store.days.contains {
            store.calendar.isDate($0.date, inSameDayAs: date) && $0.hasContent
        }

        return Button {
            store.select(date)
        } label: {
            VStack(spacing: PCSpacing.xs) {
                Text(weekday)
                    .font(Font.pc.caption)
                Text("\(day)")
                    .font(Font.pc.body.weight(.semibold))
                Circle()
                    .fill(hasItems || isToday ? Color.pc.accent : Color.clear)
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
            hasItems ? "Has tasks or events" : nil,
        ].compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder
    private var agendaContent: some View {
        if store.isLoading && !store.hasAgenda {
            loadingAgenda
        } else if store.hasAgenda {
            LazyVStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                ForEach(store.days) { day in
                    daySection(day)
                        .id(dayScrollID(day.date))
                        .onAppear {
                            if day.id == store.days.last?.id {
                                Task { await store.extendForward() }
                            }
                        }
                }

                if store.isExtending {
                    ProgressView()
                        .tint(Color.pc.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PCSpacing.md)
                        .accessibilityLabel("Loading more days")
                }
            }
        } else {
            EmptyStateView(
                systemImage: "wifi.exclamationmark",
                message: store.errorMessage ?? "The agenda couldn't be loaded.",
                primaryActionTitle: "Try again",
                primaryAction: {
                    Task { await store.loadWindow(resetting: true) }
                }
            )
        }
    }

    @ViewBuilder
    private func daySection(_ day: PlannerDayAgenda) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            SectionHeader(title: store.sectionHeading(for: day))

            if let unplanned = day.unplannedDayMessage(today: .now, calendar: store.calendar) {
                unplannedDay(unplanned, on: day.date)
            } else if !day.hasContent {
                emptyDay(on: day)
            } else {
                LazyVStack(spacing: PCSpacing.betweenCards) {
                    ForEach(store.entries(for: day)) { entry in
                        switch entry {
                        case .occurrence(let item):
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
                        case .event(let event):
                            PlannerEventAgendaRow(
                                event: event,
                                calendar: store.calendar,
                                showsPetName: store.pets.count > 1,
                                onOpen: {
                                    store.detailEvent = event
                                }
                            )
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func emptyDay(on day: PlannerDayAgenda) -> some View {
        HStack(alignment: .center, spacing: PCSpacing.md) {
            Text("(no items)")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkTertiary)
            Spacer(minLength: PCSpacing.sm)
            if store.allowsInlineAdd(on: day) {
                Button("Add") {
                    store.newTask(on: day.date)
                }
                .font(Font.pc.secondary.weight(.semibold))
                .foregroundStyle(Color.pc.primary)
                .frame(minHeight: PCMetrics.minTouchTarget)
                .accessibilityLabel("Add a task for \(PlannerFormatters.fullDay(day.date, calendar: store.calendar))")
            }
        }
        .padding(.vertical, PCSpacing.xs)
        .accessibilityElement(children: .contain)
    }

    /// A day with no plan at all. Deliberately not the empty-day row: that
    /// one asserts the day is clear, and this one cannot (IA §15.1). Quick
    /// add is still offered on today/future — the day is unknown, not closed.
    private func unplannedDay(_ message: String, on date: Date) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            Label(message, systemImage: "calendar.badge.questionmark")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.capabilities.contains(.createOneTime),
               PlannerAgendaGrouping.allowsInlineAdd(on: date, today: .now, calendar: store.calendar) {
                SecondaryButton(title: "Add a task") {
                    store.newTask(on: date)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading agenda")
    }

    private func dayScrollID(_ date: Date) -> String {
        let day = store.calendar.startOfDay(for: date)
        return "planner-day-\(day.timeIntervalSince1970)"
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
            .accessibilityLabel(accessibilityRowLabel)
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

    private var accessibilityRowLabel: String {
        var parts = ["Task", item.title, meta]
        if item.state != .pending {
            parts.append(item.state.displayName)
        }
        return parts.joined(separator: ", ")
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

/// US-080 event row — kind glyph + chevron, never a completion checkbox.
private struct PlannerEventAgendaRow: View {
    let event: PlannerAgendaEvent
    let calendar: Calendar
    let showsPetName: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: PCSpacing.md) {
                Image(systemName: event.kind.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.pc.primary)
                    .frame(width: PCMetrics.checkboxSize, height: PCMetrics.checkboxSize)
                    .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
                    .background(
                        RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                            .fill(Color.pc.surfaceSubtle)
                    )
                    .accessibilityHidden(true)
                    .padding(.top, -(PCMetrics.minTouchTarget - PCMetrics.checkboxSize) / 2)
                    .padding(.leading, -(PCMetrics.minTouchTarget - PCMetrics.checkboxSize) / 2)

                VStack(alignment: .leading, spacing: PCSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: PCSpacing.sm) {
                        Text(event.title)
                            .font(Font.pc.body.weight(.medium))
                            .foregroundStyle(Color.pc.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: PCSpacing.sm)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.pc.inkTertiary)
                            .accessibilityHidden(true)
                    }
                    Text(meta)
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                        .multilineTextAlignment(.leading)
                    if let location = event.locationText, !location.isEmpty {
                        Text(location)
                            .font(Font.pc.caption)
                            .foregroundStyle(Color.pc.inkTertiary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRowLabel)
        .accessibilityHint("Opens event details")
        .accessibilityAddTraits(.isButton)
    }

    private var meta: String {
        var pieces = [event.kind.displayName, event.timeSummary]
        if showsPetName {
            pieces.append(event.petName ?? "Whole household")
        }
        return pieces.joined(separator: " · ")
    }

    private var accessibilityRowLabel: String {
        var parts = ["Event", event.title, event.kind.displayName, event.timeSummary]
        if showsPetName {
            parts.append(event.petName ?? "Whole household")
        }
        if let location = event.locationText, !location.isEmpty {
            parts.append(location)
        }
        return parts.joined(separator: ", ")
    }
}

/// Lightweight PL-04-style read-only sheet. Editing stays in Care →
/// Appointments so this slice does not fork the event editor.
private struct PlannerEventDetailSheet: View {
    let event: PlannerAgendaEvent
    let showsPetName: Bool
    let calendar: Calendar

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    HStack(alignment: .top, spacing: PCSpacing.md) {
                        Image(systemName: event.kind.systemImage)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.pc.primary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: PCSpacing.xs) {
                            Text(event.title)
                                .font(Font.pc.title)
                                .foregroundStyle(Color.pc.ink)
                            Text(event.kind.displayName)
                                .font(Font.pc.secondary)
                                .foregroundStyle(Color.pc.inkSecondary)
                        }
                    }

                    detailRow(
                        title: "When",
                        value: whenLine,
                        systemImage: "clock"
                    )
                    if showsPetName {
                        detailRow(
                            title: "Pet",
                            value: event.petName ?? "Whole household",
                            systemImage: "pawprint"
                        )
                    }
                    if let location = event.locationText, !location.isEmpty {
                        detailRow(
                            title: "Where",
                            value: location,
                            systemImage: "mappin.and.ellipse"
                        )
                    }
                    if let notes = event.notes, !notes.isEmpty {
                        detailRow(
                            title: "Notes",
                            value: notes,
                            systemImage: "note.text"
                        )
                    }

                    Text("To edit or cancel, open Care → Appointments & events.")
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PCSpacing.screenMargin)
                .padding(.bottom, PCSpacing.huge)
            }
            .background(Color.pc.bg)
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityElement(children: .contain)
    }

    private var whenLine: String {
        let day = PlannerFormatters.fullDay(event.date, calendar: calendar)
        if event.allDay || event.startTime == nil {
            return "\(day) · All day"
        }
        return "\(day) · \(event.timeSummary)"
    }

    private func detailRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: PCSpacing.md) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.pc.primary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PCSpacing.xs) {
                Text(title)
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
                Text(value)
                    .font(Font.pc.body)
                    .foregroundStyle(Color.pc.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }
}

private struct PlannerMonthJumpSheet: View {
    let calendar: Calendar
    let contentDates: Set<Date>
    let onVisibleMonthChange: (Date) -> Void
    let onSelect: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var visibleMonth: Date

    init(
        selectedDate: Date,
        calendar: Calendar,
        contentDates: Set<Date>,
        onVisibleMonthChange: @escaping (Date) -> Void,
        onSelect: @escaping (Date) -> Void
    ) {
        self.calendar = calendar
        self.contentDates = contentDates
        self.onVisibleMonthChange = onVisibleMonthChange
        self.onSelect = onSelect
        _date = State(initialValue: selectedDate)
        _visibleMonth = State(initialValue: selectedDate)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: PCSpacing.xl) {
                monthHeader
                weekdayHeader
                monthGrid
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)

                Text("A filled dot marks days with tasks or events.")
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)

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
        .onAppear {
            onVisibleMonthChange(visibleMonth)
        }
        .onChange(of: visibleMonth) { _, month in
            onVisibleMonthChange(month)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Jump to date")
        .accessibilityHint("Filled dots mark days with tasks or events")
    }

    private var monthHeader: some View {
        HStack {
            Button {
                shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
            }
            .accessibilityLabel("Previous month")

            Spacer()

            Text(PlannerFormatters.month(visibleMonth, calendar: calendar))
                .font(Font.pc.body.weight(.semibold))
                .foregroundStyle(Color.pc.ink)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button {
                shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
            }
            .accessibilityLabel("Next month")
        }
        .foregroundStyle(Color.pc.primary)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(PlannerAgendaGrouping.monthWeekdaySymbols(calendar: calendar).enumerated()),
                    id: \.offset) { _, symbol in
                Text(symbol)
                    .font(Font.pc.caption.weight(.semibold))
                    .foregroundStyle(Color.pc.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }

    private var monthGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: PCSpacing.xs), count: 7)
        let cells = PlannerAgendaGrouping.monthGridDays(for: visibleMonth, calendar: calendar)
        return LazyVGrid(columns: columns, spacing: PCSpacing.xs) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                if let cell {
                    dayCell(cell)
                } else {
                    Color.clear
                        .frame(minHeight: 44)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: date)
        let isToday = calendar.isDateInToday(day)
        let hasItems = contentDates.contains(calendar.startOfDay(for: day))
        let dayNumber = calendar.component(.day, from: day)

        return Button {
            date = calendar.startOfDay(for: day)
        } label: {
            VStack(spacing: 2) {
                Text("\(dayNumber)")
                    .font(Font.pc.body.weight(isToday || isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.pc.onPrimary : Color.pc.ink)
                // Presence of the marker (not hue alone) signals content;
                // VoiceOver also announces it via accessibilityValue.
                Group {
                    if hasItems {
                        Circle()
                            .fill(isSelected ? Color.pc.onPrimary : Color.pc.accent)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                    } else {
                        Color.clear
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                    .fill(isSelected ? Color.pc.primary : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                    .strokeBorder(
                        isToday && !isSelected ? Color.pc.primary : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PlannerFormatters.fullDay(day, calendar: calendar))
        .accessibilityValue([
            isSelected ? "Selected" : nil,
            isToday ? "Today" : nil,
            hasItems ? "Has tasks or events" : nil,
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func shiftMonth(by value: Int) {
        guard let next = calendar.date(byAdding: .month, value: value, to: visibleMonth) else {
            return
        }
        visibleMonth = next
    }
}

#Preview("Planner agenda") {
    let model = AppModel.preview()
    PlannerView(service: InMemoryPlannerService.preview(model: model))
        .environment(model)
}
