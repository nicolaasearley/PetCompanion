import SwiftUI

/// TR-06 — Socialization passport overview.
///
/// Two content-safety rules govern this screen and are not negotiable by
/// layout:
///
///   1. **No score, ever.** Category cards carry a recent-breadth line
///      ("4 this month") and a last-seen date. There is no progress bar, no
///      ring, no "3 of 8 categories", no percentage — F09 excludes a
///      universal numeric socialization score, and a denominator of eight
///      would be one (wireframes TR-06, open question 3).
///   2. **The vaccination caution renders on every category**, so it is
///      stated here on the overview and again on every TR-07 detail. It is
///      never collapsed behind a disclosure and never shown only once.
struct SocializationPassportView: View {
    @State private var store: SocializationStore
    @State private var recordingFor: SocializationCategory?

    init(store: SocializationStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                header

                SocializationCautionCard(text: store.caution)

                VStack(alignment: .leading, spacing: PCSpacing.md) {
                    SectionHeader(title: "Categories")
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: PCSpacing.betweenCards),
                            GridItem(.flexible(), spacing: PCSpacing.betweenCards),
                        ],
                        spacing: PCSpacing.betweenCards
                    ) {
                        ForEach(store.breadth) { breadth in
                            NavigationLink(value: breadth.category) {
                                SocializationCategoryCard(breadth: breadth)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                recentSection

                Text("Seed guidance · pending professional review")
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
            }
            .padding(PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .background(Color.pc.bg)
        .navigationTitle("Socialization")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    recordingFor = nil
                    isRecording = true
                } label: {
                    Label("Record an experience", systemImage: "plus")
                }
            }
        }
        .navigationDestination(for: SocializationCategory.self) { category in
            SocializationCategoryView(store: store, category: category)
        }
        .sheet(isPresented: $isRecording) {
            RecordSocializationView(store: store, category: recordingFor, experience: nil)
        }
        .task { await store.load() }
        .refreshable { await store.load() }
        .overlay(alignment: .bottom) { statusBanner }
    }

    @State private var isRecording = false

    private var header: some View {
        VStack(alignment: .leading, spacing: PCSpacing.xs) {
            Text(SocializationCatalogue.framing)
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "A passport of what \(store.petName) has met — not a checklist to finish. "
                    + "One calm, positive experience is plenty."
            )
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            SectionHeader(title: "Recent")
            if store.isLoading && store.records.isEmpty {
                ProgressView().tint(Color.pc.primary)
            } else if store.records.isEmpty {
                EmptyStateView(
                    systemImage: "sparkles",
                    message: "Nothing recorded yet. Add an experience as it happens — a doorbell, a wobbly cushion, a calm visitor.",
                    primaryActionTitle: "Record an experience",
                    primaryAction: {
                        recordingFor = nil
                        isRecording = true
                    }
                )
            } else {
                VStack(spacing: PCSpacing.betweenCards) {
                    ForEach(store.recent()) { record in
                        SocializationRecordRow(record: record)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = store.errorMessage {
            SocializationBanner(message: message, isError: true) { store.errorMessage = nil }
        } else if let message = store.confirmationMessage {
            SocializationBanner(message: message, isError: false) { store.confirmationMessage = nil }
        }
    }
}

/// Catalogue §8's standing caution. It is `.info`, never `.attention`: it
/// points the caregiver at their own vet rather than making a health claim,
/// and it explicitly names the two things that still count before
/// vaccinations are finished.
struct SocializationCautionCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: PCSpacing.md) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.pc.info)
                .accessibilityHidden(true)
            Text(text)
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PCSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surfaceSubtle)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct SocializationCategoryCard: View {
    let breadth: SocializationCategoryBreadth

    /// Plain language, no number-out-of-number. "None yet" is a neutral
    /// statement of fact, not a gap to close.
    private var breadthLine: String {
        if breadth.isExcluded {
            return breadth.exclusionReason?.shortLabel ?? "Paused"
        }
        switch breadth.recentCount {
        case 0: return "None this month"
        case 1: return "1 this month"
        default: return "\(breadth.recentCount) this month"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            Image(systemName: breadth.category.systemImage)
                .font(.title3)
                .foregroundStyle(breadth.isExcluded ? Color.pc.inkTertiary : Color.pc.primary)
                .accessibilityHidden(true)
            Text(breadth.category.displayName)
                .font(Font.pc.body.weight(.semibold))
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(breadthLine)
                .font(Font.pc.secondary)
                .foregroundStyle(breadth.isExcluded ? Color.pc.inkTertiary : Color.pc.inkSecondary)
            if breadth.isExcluded {
                PCChip(text: "Paused", icon: "pause.circle", style: .neutral)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .padding(PCSpacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .strokeBorder(Color.pc.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(breadth.category.displayName), \(breadthLine)")
        .accessibilityHint("Opens this category")
    }
}

struct SocializationRecordRow: View {
    let record: SocializationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.xs) {
            Text(record.label)
                .font(Font.pc.body.weight(.semibold))
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
            if let context = record.context, !context.isEmpty {
                Text(context)
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PCSpacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .strokeBorder(Color.pc.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.label). \(subtitle)")
    }

    /// "Curious · Tue" — the response is stated as the owner's own report and
    /// carries no interpretation.
    private var subtitle: String {
        var parts = [record.response.displayName, record.effectiveDate.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))]
        if let name = record.recordedByName, !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }
}

struct SocializationBanner: View {
    let message: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: PCSpacing.sm) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.pc.danger : Color.pc.success)
                .accessibilityHidden(true)
            Text(message)
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss", action: dismiss)
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.primary)
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
        .padding(.horizontal, PCSpacing.screenMargin)
        .padding(.bottom, PCSpacing.lg)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Socialization passport") {
    NavigationStack {
        SocializationPassportView(store: .preview())
    }
}
