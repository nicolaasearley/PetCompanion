import SwiftUI

/// HM-01 — Daily Plan (doc 14 §5). Renders the plan in the fixed engine §6
/// section order with empty sections hidden, plus the pre-arrival variant
/// (countdown header) when the pet's homecoming date is in the future.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel: HomeViewModel?

    init(viewModel: HomeViewModel? = nil) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ZStack {
            Color.pc.bg.ignoresSafeArea()
            if let viewModel {
                HomeContentView(viewModel: viewModel)
            }
        }
        .task {
            if viewModel == nil {
                let created = HomeViewModel(model: model)
                viewModel = created
                await created.loadInitial()
            } else if viewModel?.snapshot == nil {
                await viewModel?.loadInitial()
            } else {
                // Returning to the tab is a natural list update: completed
                // items settle into the Completed section (doc 09 §8).
                await viewModel?.refresh()
            }
        }
        // Realtime publishes into SharedPlanState; this hook covers the case
        // where Home already has a snapshot and Observation alone would not
        // re-run verification/stale bookkeeping after a remote replace.
        .onChange(of: model.planState.reconciliationEpoch) { _, epoch in
            guard epoch > 0, let viewModel, viewModel.snapshot != nil else { return }
            viewModel.acknowledgeRemoteReconciliation()
        }
    }
}

private struct HomeContentView: View {
    @Environment(AppModel.self) private var model
    @Bindable var viewModel: HomeViewModel
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                header

                if let snapshot = viewModel.snapshot {
                    if let errorMessage = viewModel.errorMessage {
                        errorBanner(errorMessage)
                    }
                    if let undoBanner = viewModel.undoBanner {
                        undoBannerView(undoBanner)
                    }
                    if !viewModel.upcomingCare.isEmpty {
                        upcomingCareSection
                    }
                    if snapshot.isEmpty {
                        allCaughtUp
                    } else {
                        ForEach(snapshot.orderedSections) { group in
                            sectionView(group)
                        }
                    }
                } else if viewModel.isLoading {
                    loadingSkeleton
                } else if viewModel.hasInitialLoadFailure {
                    loadFailure
                }
            }
            .padding(.horizontal, PCSpacing.screenMargin)
            .padding(.top, PCSpacing.lg)
            .padding(.bottom, PCSpacing.huge)
        }
        .refreshable {
            await viewModel.refresh()
        }
        .sheet(isPresented: $viewModel.showCapacitySheet) {
            CapacitySheet(currentMode: viewModel.capacityMode) { mode, scope in
                viewModel.applyCapacity(mode, scope: scope)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $viewModel.detailItem) { item in
            let isUnacceptedRecommendation = item.kind == .recommendation
                && item.occurrenceId == nil
            PlanItemDetailSheet(
                item: item,
                meta: viewModel.meta(for: item),
                state: viewModel.cardState(for: item),
                primaryActionTitle: isUnacceptedRecommendation ? "Add to today" : nil,
                allowsCompletion: item.section != .comingUp && !isUnacceptedRecommendation,
                onPrimaryAction: isUnacceptedRecommendation
                    ? { try await viewModel.acceptRecommendation(item) }
                    : nil,
                onToggleComplete: { viewModel.toggleCompletion(of: item) }
            )
        }
        .sheet(item: $viewModel.careDestination) { destination in
            NavigationStack {
                switch destination {
                case .medications:
                    if let store = model.makeMedicationsStore() {
                        MedicationsView(store: store)
                    } else {
                        Text("Medications aren't available right now.")
                            .padding()
                    }
                case .appointments:
                    if let store = model.makeEventStore() {
                        EventsView(store: store)
                    } else {
                        Text("Appointments aren't available right now.")
                            .padding()
                    }
                }
            }
            .environment(model)
        }
        .alert("Add a task", isPresented: $viewModel.showAddTask) {
            TextField("What needs doing?", text: $viewModel.newTaskTitle)
            Button("Add") { viewModel.addTask() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It joins today's plan for \(viewModel.pet?.name ?? "your puppy").")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                quickAddButton
            }
            .padding(.horizontal, PCSpacing.screenMargin)
            .padding(.vertical, PCSpacing.sm)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            HStack(spacing: PCSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.pc.surfaceSubtle)
                        .frame(width: 36, height: 36)
                    Image(systemName: "pawprint")
                        .font(.footnote)
                        .foregroundStyle(Color.pc.primary)
                }
                .accessibilityHidden(true)

                Text(viewModel.pet?.name ?? "")
                    .font(Font.pc.body.weight(.semibold))
                    .foregroundStyle(Color.pc.ink)

                if let pet = viewModel.pet,
                   !pet.isPreArrival(calendar: viewModel.householdCalendar) {
                    // Stage chip; opens HM-06 in a later slice.
                    PCChip(text: viewModel.petAgeAndStage ?? "")
                }

                Spacer()

                if viewModel.capacityMode != .normal {
                    PCChip(text: viewModel.capacityMode.displayName, style: .info) {
                        viewModel.showCapacitySheet = true
                    }
                }

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.title3)
                        .foregroundStyle(Color.pc.inkSecondary)
                        .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
                }
                .accessibilityLabel(PCL10n.Home.profileSettingsAccessibility)
            }

            if viewModel.pet != nil, let days = viewModel.daysUntilHomecoming {
                // Pre-arrival variant: countdown replaces the age/stage line.
                Text(days == 1 ? "Coming home tomorrow" : "Coming home in \(days) days")
                    .font(Font.pc.display)
                    .foregroundStyle(Color.pc.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Getting ready together")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
            } else {
                Text(viewModel.greetingName.map { "\(viewModel.greeting), \($0)" } ?? viewModel.greeting)
                    .font(Font.pc.display)
                    .foregroundStyle(Color.pc.ink)
                    .accessibilityAddTraits(.isHeader)
            }

            SyncStatusLine(status: viewModel.syncStatus)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionView(_ group: PlanSectionGroup) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.betweenCards) {
            switch group.section {
            case .recommended:
                SectionHeader(
                    title: "\(group.section.title) (\(group.items.count))",
                    trailingLabel: viewModel.recommendedExpanded ? "Hide" : "Show",
                    trailingAction: { viewModel.recommendedExpanded.toggle() }
                )
                if viewModel.recommendedExpanded {
                    sectionCards(group.items)
                }
            case .comingUp:
                SectionHeader(
                    title: "\(group.section.title) (\(group.items.count))",
                    trailingLabel: viewModel.comingUpExpanded ? "Hide" : "Show",
                    trailingAction: { viewModel.comingUpExpanded.toggle() }
                )
                if viewModel.comingUpExpanded {
                    sectionCards(group.items)
                }
            case .completed:
                SectionHeader(
                    title: "\(group.section.title) (\(group.items.count))",
                    trailingLabel: viewModel.completedExpanded ? "Hide" : "Show",
                    trailingAction: { viewModel.completedExpanded.toggle() }
                )
                if viewModel.completedExpanded {
                    sectionCards(group.items)
                }
            case .needsAttention:
                // Visual weight follows the plan hierarchy — this section
                // outranks everything else (doc 09 §3.2), so its header
                // alone carries the attention tone.
                SectionHeader(title: group.section.title, tone: .attention)
                sectionCards(group.items)
            case .today:
                SectionHeader(
                    title: group.section.title,
                    trailingLabel: "Capacity",
                    trailingAction: { viewModel.showCapacitySheet = true }
                )
                ForEach(viewModel.windowGroups(for: group.items), id: \.window) { windowGroup in
                    if let window = windowGroup.window {
                        Text(window.displayName)
                            .font(Font.pc.secondary.weight(.medium))
                            .foregroundStyle(Color.pc.inkSecondary)
                            .padding(.top, PCSpacing.xs)
                    }
                    sectionCards(windowGroup.items)
                }
            }
        }
    }

    private func sectionCards(_ items: [PlanItem]) -> some View {
        VStack(spacing: PCSpacing.betweenCards) {
            ForEach(items) { item in
                planItemCard(item)
            }
        }
    }

    private func planItemCard(_ item: PlanItem) -> some View {
        // Recommendation cards never show a checkbox pre-accepted;
        // accepting is explicit via the detail sheet (doc 09 §7.1).
        let isUnacceptedRecommendation = item.kind == .recommendation && item.occurrenceId == nil
        let showsCheckbox = item.kind != .upcomingPreview
            && item.kind != .informational
            && !isUnacceptedRecommendation
        let isCompleted = viewModel.snapshot?.isCompleted(item) == true
        let trailing: String? = {
            if isUnacceptedRecommendation { return "Why this?" }
            if isCompleted { return "Undo" }
            return nil
        }()

        return PlanItemCard(
            title: item.title,
            meta: viewModel.meta(for: item),
            state: viewModel.cardState(for: item),
            isNeedsAttention: item.section == .needsAttention,
            categorySystemImage: item.category.systemImage,
            showsCheckbox: showsCheckbox,
            trailingAffordance: trailing,
            onToggleComplete: showsCheckbox ? { viewModel.toggleCompletion(of: item) } : nil,
            onOpen: { viewModel.detailItem = item },
            onTrailingAction: isCompleted ? { viewModel.toggleCompletion(of: item) } : nil
        )
    }

    private var upcomingCareSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.betweenCards) {
            HStack {
                SectionHeader(title: "Upcoming care")
                Spacer(minLength: 0)
            }
            ForEach(viewModel.upcomingCare) { item in
                Button {
                    viewModel.openUpcomingCare(item)
                } label: {
                    HStack(spacing: PCSpacing.md) {
                        Image(systemName: item.kind == .medication ? "pills" : "calendar")
                            .foregroundStyle(Color.pc.primary)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: PCSpacing.xs) {
                            Text(item.title)
                                .font(Font.pc.body)
                                .foregroundStyle(Color.pc.ink)
                                .multilineTextAlignment(.leading)
                            Text(item.subtitle)
                                .font(Font.pc.secondary)
                                .foregroundStyle(Color.pc.inkSecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.pc.inkTertiary)
                            .accessibilityHidden(true)
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
                .buttonStyle(.plain)
                .accessibilityHint("Opens \(item.kind == .medication ? "medications" : "appointments")")
            }
        }
    }

    // MARK: - Empty and loading states

    private var allCaughtUp: some View {
        EmptyStateView(
            systemImage: "checkmark.circle",
            message: PCL10n.Home.allCaughtUpMessage,
            accent: .success,
            primaryActionTitle: PCL10n.Home.allCaughtUpAddTask,
            primaryAction: { viewModel.showAddTask = true }
        )
        .padding(.top, PCSpacing.huge)
    }

    private var loadingSkeleton: some View {
        VStack(spacing: PCSpacing.betweenCards) {
            ForEach(0..<3, id: \.self) { _ in
                PlanItemCard(title: "Loading plan item", meta: "Loading")
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading today's plan")
    }

    private var loadFailure: some View {
        EmptyStateView(
            systemImage: "wifi.exclamationmark",
            message: viewModel.errorMessage
                ?? "Today's plan couldn't be loaded. Your data has not been changed.",
            primaryActionTitle: "Try again",
            primaryAction: { viewModel.retryInitialLoad() }
        )
        .padding(.top, PCSpacing.xl)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: PCSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.pc.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PCSpacing.sm)
            Button {
                viewModel.clearError()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.pc.inkSecondary)
            .accessibilityLabel("Dismiss error")
        }
        .padding(PCSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                .fill(Color.pc.dangerBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                .strokeBorder(Color.pc.danger.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func undoBannerView(_ banner: HomeViewModel.UndoBanner) -> some View {
        HStack(alignment: .center, spacing: PCSpacing.md) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Color.pc.success)
                .accessibilityHidden(true)
            Text("\(banner.title) completed")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PCSpacing.sm)
            Button("Undo") {
                viewModel.undoFromBanner()
            }
            .font(Font.pc.secondary.weight(.semibold))
            .foregroundStyle(Color.pc.primary)
            .frame(minHeight: PCMetrics.minTouchTarget)
            .accessibilityLabel("Undo \(banner.title)")
            Button {
                viewModel.dismissUndoBanner()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.pc.inkSecondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(PCSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                .fill(Color.pc.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                .strokeBorder(Color.pc.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var quickAddButton: some View {
        Button {
            viewModel.showAddTask = true
        } label: {
            Label(PCL10n.Home.quickAddTitle, systemImage: "plus")
                .font(Font.pc.body.weight(.semibold))
                .foregroundStyle(Color.pc.onPrimary)
                .padding(.horizontal, PCSpacing.lg)
                .frame(minHeight: 50)
                .background(
                    Capsule().fill(Color.pc.primary)
                        .shadow(color: Color.pc.ink.opacity(0.14), radius: 12, y: 5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityHint(PCL10n.Home.quickAddAccessibilityHint)
    }
}

#Preview("HM-01 Normal day") {
    MainTabView()
        .environment(AppModel.preview())
        .tint(Color.pc.primary)
}

#Preview("HM-01 Pre-arrival") {
    MainTabView()
        .environment(AppModel.preview(preArrival: true))
        .tint(Color.pc.primary)
}
