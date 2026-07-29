import Charts
import SwiftUI

/// CA-08 — Weight & growth. Original units preserved; chart is non-clinical.
struct WeightGrowthView: View {
    @Bindable var store: WeightStore
    @State private var editor: WeightEditorDestination?
    @State private var pendingRemove: WeightMeasurement?

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

                if store.isLoading && store.measurements.isEmpty {
                    ProgressView("Loading weights…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PCSpacing.xxxl)
                        .accessibilityLabel("Loading weights")
                } else if store.measurements.isEmpty {
                    EmptyStateView(
                        systemImage: "chart.line.uptrend.xyaxis",
                        message: "No weights yet — add them as you measure \(store.petName).",
                        primaryActionTitle: "Add a weight",
                        primaryAction: { editor = .create }
                    )
                } else {
                    unitToggle
                    chartSection
                    entriesSection
                }
            }
            .padding(PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .background(Color.pc.bg)
        .navigationTitle("Weight & growth")
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
            WeightEditorView(store: store, destination: destination)
        }
        .confirmationDialog(
            "Remove this weight entry?",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let pendingRemove {
                    Task {
                        _ = await store.remove(pendingRemove)
                    }
                }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("The entry stays in household history for audit, but won’t show in the list.")
        }
    }

    private var unitToggle: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            Text("Display unit")
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
            HStack(spacing: PCSpacing.sm) {
                ForEach(WeightUnit.allCases) { unit in
                    PCRadioRow(
                        title: unit.displayName,
                        isSelected: store.displayUnit == unit
                    ) {
                        store.setDisplayUnit(unit)
                    }
                }
            }
            Text("Changes how weights look here. Saved values keep the unit you entered.")
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            SectionHeader(title: "Growth")
            Chart(store.measurements.reversed()) { point in
                LineMark(
                    x: .value("Date", point.effectiveDate),
                    y: .value("Weight", NSDecimalNumber(decimal: point.unit.convert(point.value, to: store.displayUnit)).doubleValue)
                )
                .foregroundStyle(Color.pc.primary)
                .interpolationMethod(.linear)
                PointMark(
                    x: .value("Date", point.effectiveDate),
                    y: .value("Weight", NSDecimalNumber(decimal: point.unit.convert(point.value, to: store.displayUnit)).doubleValue)
                )
                .foregroundStyle(Color.pc.primary)
            }
            .frame(height: 180)
            .accessibilityLabel("Weight over time in \(store.displayUnit.displayName)")
            Text("A simple record of entries — not a clinical assessment.")
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.betweenCards) {
            SectionHeader(title: "Entries")
            ForEach(store.measurements) { measurement in
                WeightEntryRow(
                    measurement: measurement,
                    displayUnit: store.displayUnit,
                    onEdit: { editor = .edit(measurement) },
                    onRemove: { pendingRemove = measurement }
                )
            }
        }
    }
}

private struct WeightEntryRow: View {
    let measurement: WeightMeasurement
    let displayUnit: WeightUnit
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(measurement.displayValue(in: displayUnit))
                    .font(Font.pc.body.weight(.semibold))
                    .foregroundStyle(Color.pc.ink)
                Spacer()
                Text(measurement.effectiveDate.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
            }
            if measurement.unit != displayUnit {
                Text("Entered as \(measurement.displayValue)")
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
            }
            if let note = measurement.note, !note.isEmpty {
                Text(note)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: PCSpacing.md) {
                Button("Edit", action: onEdit)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.primary)
                    .frame(minHeight: PCMetrics.minTouchTarget)
                Button("Remove", role: .destructive, action: onRemove)
                    .font(Font.pc.secondary)
                    .frame(minHeight: PCMetrics.minTouchTarget)
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

enum WeightEditorDestination: Identifiable {
    case create
    case edit(WeightMeasurement)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let measurement): measurement.id.uuidString
        }
    }
}

struct WeightEditorView: View {
    @Bindable var store: WeightStore
    let destination: WeightEditorDestination
    @Environment(\.dismiss) private var dismiss

    @State private var valueText = ""
    @State private var unit: WeightUnit = .kg
    @State private var effectiveDate = Date()
    @State private var note = ""
    @State private var validationMessage: String?
    @State private var outlierMessage: String?
    @State private var acknowledgedOutlier = false

    private var editing: WeightMeasurement? {
        if case .edit(let measurement) = destination { return measurement }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    PCLabeledField(label: "Weight") {
                        TextField("0.0", text: $valueText)
                            .keyboardType(.decimalPad)
                    }
                    .accessibilityLabel("Weight value")

                    VStack(alignment: .leading, spacing: PCSpacing.sm) {
                        Text("Unit")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                        ForEach(WeightUnit.allCases) { option in
                            PCRadioRow(
                                title: option.displayName,
                                isSelected: unit == option
                            ) { unit = option }
                        }
                    }

                    PCLabeledField(label: "Date") {
                        DatePicker(
                            "Date",
                            selection: $effectiveDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                    }

                    PCLabeledField(label: "Note (optional)") {
                        TextField("Optional note", text: $note, axis: .vertical)
                            .lineLimit(3...6)
                    }

                    if let outlierMessage {
                        Text(outlierMessage)
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.attention)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Please confirm: \(outlierMessage)")
                    }

                    if let message = validationMessage ?? store.errorMessage {
                        PCInlineError(message: message)
                    }

                    PrimaryButton(
                        title: outlierMessage == nil ? "Save" : "Looks right — save",
                        action: save
                    )
                    .disabled(store.isSaving)

                    Text("Care records are not medical advice. This is a household record of what you measured.")
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PCSpacing.screenMargin)
                .padding(.bottom, PCSpacing.huge)
            }
            .background(Color.pc.bg)
            .navigationTitle(editing == nil ? "Add weight" : "Edit weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.errorMessage = nil
                        dismiss()
                    }
                }
            }
            .onAppear {
                store.errorMessage = nil
                if let editing {
                    valueText = WeightMeasurement.format(editing.value)
                    unit = editing.unit
                    effectiveDate = editing.effectiveDate
                    note = editing.note ?? ""
                } else {
                    unit = store.displayUnit
                }
            }
            .onChange(of: valueText) { _, _ in syncOutlierGate() }
            .onChange(of: unit) { _, _ in syncOutlierGate() }
        }
    }

    private var currentDraft: WeightDraft {
        WeightDraft(
            valueText: valueText,
            unit: unit,
            effectiveDate: effectiveDate,
            note: note
        )
    }

    /// Keep confirm CTA while the draft is still an outlier; clear the gate when
    /// edits bring the value back into the soft check band.
    private func syncOutlierGate() {
        guard acknowledgedOutlier else { return }
        if let prompt = store.outlierPrompt(for: currentDraft) {
            outlierMessage = prompt
        } else {
            outlierMessage = nil
            acknowledgedOutlier = false
        }
    }

    private func save() {
        validationMessage = nil
        guard CareCoding.decimal(from: valueText) != nil else {
            validationMessage = "Enter a weight greater than zero."
            return
        }
        let draft = currentDraft
        if !acknowledgedOutlier, let prompt = store.outlierPrompt(for: draft) {
            outlierMessage = prompt
            acknowledgedOutlier = true
            return
        }
        Task {
            let ok: Bool
            if let editing {
                ok = await store.edit(editing, draft: draft)
            } else {
                ok = await store.record(draft)
            }
            if ok { dismiss() }
        }
    }
}

struct CareOutcomeBanner: View {
    enum Tone { case success, queued, error }

    let message: String
    var tone: Tone
    let dismiss: () -> Void

    private var icon: String {
        switch tone {
        case .success: "checkmark.circle.fill"
        case .queued: "arrow.triangle.2.circlepath"
        case .error: "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        switch tone {
        case .success: Color.pc.success
        case .queued: Color.pc.info
        case .error: Color.pc.danger
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: PCSpacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
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
                .fill(tone == .error ? Color.pc.dangerBg : Color.pc.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .strokeBorder(tone == .error ? Color.pc.danger.opacity(0.35) : Color.pc.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
