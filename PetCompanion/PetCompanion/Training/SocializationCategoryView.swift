import SwiftUI

/// TR-07 — one category's experiences.
///
/// Suggested experiences with done-recently marks, an add-custom entry, and
/// the per-experience overflow from the wireframe: "Not available" /
/// "Not right for {name}" / "Pause". Excluded items stay **visible and
/// visibly paused** rather than disappearing, because US-068 requires the
/// choice to be reversible and the reason to be legible.
///
/// The standing vaccination caution renders here as well as on TR-06 — the
/// catalogue requires it on every category.
struct SocializationCategoryView: View {
    @Bindable var store: SocializationStore
    let category: SocializationCategory

    @State private var recordingExperience: SocializationExperience?
    @State private var isRecordingCustom = false
    @State private var pendingExclusion: PendingExclusion?

    private struct PendingExclusion: Identifiable {
        let experience: SocializationExperience
        var id: String { experience.contentId }
    }

    private var categoryExclusion: SocializationExclusion? {
        store.excludedCategory(category)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                // Catalogue §8: rendered on EVERY category, not once per app.
                SocializationCautionCard(text: store.caution)

                if let exclusion = categoryExclusion {
                    categoryPausedCard(exclusion)
                }

                experiencesSection
                customSection
                historySection
            }
            .padding(PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .background(Color.pc.bg)
        .navigationTitle(category.displayName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if categoryExclusion == nil {
                    Menu {
                        ForEach(SocializationExclusionReason.allCases) { reason in
                            Button(reason.displayName(petName: store.petName)) {
                                Task { await store.exclude(category: category, reason: reason) }
                            }
                        }
                    } label: {
                        Label("Category options", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $recordingExperience) { experience in
            RecordSocializationView(store: store, category: category, experience: experience)
        }
        .sheet(isPresented: $isRecordingCustom) {
            RecordSocializationView(store: store, category: category, experience: nil)
        }
        .confirmationDialog(
            pendingExclusion.map { "Stop suggesting \($0.experience.label)?" } ?? "",
            isPresented: Binding(
                get: { pendingExclusion != nil },
                set: { if !$0 { pendingExclusion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = pendingExclusion {
                ForEach(SocializationExclusionReason.allCases) { reason in
                    Button(reason.displayName(petName: store.petName)) {
                        Task {
                            await store.exclude(
                                experienceContentId: pending.experience.contentId,
                                reason: reason
                            )
                            pendingExclusion = nil
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingExclusion = nil }
        } message: {
            Text("Past records stay in the passport, and you can undo this any time.")
        }
        .overlay(alignment: .bottom) {
            if let message = store.errorMessage {
                SocializationBanner(message: message, isError: true) { store.errorMessage = nil }
            } else if let message = store.confirmationMessage {
                SocializationBanner(message: message, isError: false) { store.confirmationMessage = nil }
            }
        }
    }

    private func categoryPausedCard(_ exclusion: SocializationExclusion) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            Text("\(exclusion.reason.shortLabel) — this category isn't being suggested.")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can still record experiences here, and nothing already recorded is affected.")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecondaryButton(title: "Suggest this category again") {
                Task { await store.clear(exclusion: exclusion) }
            }
        }
        .padding(PCSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surfaceSubtle)
        )
    }

    private var experiencesSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            SectionHeader(title: "Ideas")
            VStack(spacing: PCSpacing.betweenCards) {
                ForEach(SocializationCatalogue.experiences(in: category)) { experience in
                    ExperienceRow(
                        experience: experience,
                        lastRecorded: store.lastRecorded(experienceContentId: experience.contentId),
                        exclusion: store.excludedExperience(experience.contentId),
                        petName: store.petName,
                        onRecord: { recordingExperience = experience },
                        onPause: { pendingExclusion = PendingExclusion(experience: experience) },
                        onResume: { exclusion in
                            Task { await store.clear(exclusion: exclusion) }
                        }
                    )
                }
            }
        }
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            SecondaryButton(title: "Add your own \(category.displayName.lowercased()) experience") {
                isRecordingCustom = true
            }
            Text("Anything \(store.petName) met that isn't listed — the passport is a record of real life, not a fixed list.")
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var historySection: some View {
        let recorded = store.records(in: category)
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            SectionHeader(title: "Recorded")
            if recorded.isEmpty {
                Text("Nothing recorded in this category yet.")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
            } else {
                VStack(spacing: PCSpacing.betweenCards) {
                    ForEach(recorded) { record in
                        SocializationRecordRow(record: record)
                            .contextMenu {
                                Button("Remove from the passport", role: .destructive) {
                                    Task { await store.remove(record: record) }
                                }
                            }
                    }
                }
            }
        }
    }
}

private struct ExperienceRow: View {
    let experience: SocializationExperience
    let lastRecorded: Date?
    let exclusion: SocializationExclusion?
    let petName: String
    let onRecord: () -> Void
    let onPause: () -> Void
    let onResume: (SocializationExclusion) -> Void

    private var doneRecentlyText: String? {
        guard let lastRecorded else { return nil }
        return "Recorded \(lastRecorded.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: PCSpacing.md) {
            Image(systemName: lastRecorded == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(lastRecorded == nil ? Color.pc.inkTertiary : Color.pc.success)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PCSpacing.xs) {
                Text(experience.label)
                    .font(Font.pc.body)
                    .foregroundStyle(exclusion == nil ? Color.pc.ink : Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let exclusion {
                    PCChip(text: exclusion.reason.shortLabel, icon: "pause.circle", style: .neutral)
                } else if let doneRecentlyText {
                    Text(doneRecentlyText)
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.inkTertiary)
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button("Record this", action: onRecord)
                if let exclusion {
                    Button("Suggest this again") { onResume(exclusion) }
                } else {
                    Button("Stop suggesting this…", action: onPause)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Color.pc.primary)
                    .frame(width: PCMetrics.minTouchTarget, height: PCMetrics.minTouchTarget)
            }
            .accessibilityLabel("Options for \(experience.label)")
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
}

#Preview("Category experiences") {
    NavigationStack {
        SocializationCategoryView(store: .preview(), category: .sounds)
    }
}
