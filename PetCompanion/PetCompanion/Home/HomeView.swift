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
    }
}

private struct HomeContentView: View {
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
                .accessibilityLabel("Profile and settings")
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
                    title: group.section.title,
                    trailingLabel: "Adjust",
                    trailingAction: { viewModel.showCapacitySheet = true }
                )
                sectionCards(group.items)
            case .completed:
                SectionHeader(
                    title: "\(group.section.title) (\(group.items.count))",
                    trailingLabel: viewModel.completedExpanded ? "Hide" : "Show",
                    trailingAction: { viewModel.completedExpanded.toggle() }
                )
                if viewModel.completedExpanded {
                    sectionCards(group.items)
                }
            case .today:
                SectionHeader(title: group.section.title)
                ForEach(viewModel.windowGroups(for: group.items), id: \.window) { windowGroup in
                    if let window = windowGroup.window {
                        Text(window.displayName)
                            .font(Font.pc.secondary.weight(.medium))
                            .foregroundStyle(Color.pc.inkSecondary)
                            .padding(.top, PCSpacing.xs)
                    }
                    sectionCards(windowGroup.items)
                }
            default:
                SectionHeader(title: group.section.title)
                sectionCards(group.items)
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

        return PlanItemCard(
            title: item.title,
            meta: viewModel.meta(for: item),
            state: viewModel.cardState(for: item),
            isNeedsAttention: item.section == .needsAttention,
            showsCheckbox: showsCheckbox,
            trailingAffordance: isUnacceptedRecommendation ? "Why this?" : nil,
            onToggleComplete: showsCheckbox ? { viewModel.toggleCompletion(of: item) } : nil,
            onOpen: { viewModel.detailItem = item }
        )
    }

    // MARK: - Empty and loading states

    private var allCaughtUp: some View {
        EmptyStateView(
            systemImage: "checkmark.circle",
            message: "You're all caught up. Add something to the plan or enjoy the day together.",
            accent: .success,
            primaryActionTitle: "Add a task",
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
                .fill(Color.pc.attentionBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.input, style: .continuous)
                .strokeBorder(Color.pc.danger.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var quickAddButton: some View {
        Button {
            viewModel.showAddTask = true
        } label: {
            Label("Add task", systemImage: "plus")
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
        .accessibilityHint("Adds a one-time task to today's plan")
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
