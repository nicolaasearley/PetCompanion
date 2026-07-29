import SwiftUI

/// HM-04 — Capacity sheet (doc 14 §5). Normal / Busy / Essentials only,
/// applied to just today or as the household default. Required and
/// scheduled items are visibly unaffected; Custom mode is intentionally
/// absent (IA §18.2).
struct CapacitySheet: View {
    let currentMode: CapacityMode
    let onApply: (CapacityMode, CapacityScope) -> Void

    @State private var mode: CapacityMode
    @State private var scope: CapacityScope = .todayOnly
    @Environment(\.dismiss) private var dismiss

    init(currentMode: CapacityMode, onApply: @escaping (CapacityMode, CapacityScope) -> Void) {
        self.currentMode = currentMode
        self.onApply = onApply
        _mode = State(initialValue: currentMode)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.xl) {
                HStack {
                    Text("How much can today hold?")
                        .font(Font.pc.title)
                        .foregroundStyle(Color.pc.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    // Explicit close for assistive tech (doc 09 §7.4).
                    Button("Close") { dismiss() }
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.primary)
                }

                VStack(spacing: 0) {
                    PCRadioRow(
                        title: "Normal",
                        subtitle: "Up to 3 ideas",
                        isSelected: mode == .normal
                    ) { mode = .normal }
                    PCRadioRow(
                        title: "Busy",
                        subtitle: "1 short idea",
                        isSelected: mode == .busy
                    ) { mode = .busy }
                    PCRadioRow(
                        title: "Essentials only",
                        subtitle: "Just the must-dos",
                        isSelected: mode == .essentialsOnly
                    ) { mode = .essentialsOnly }
                }

                Text("Apply to")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)

                VStack(spacing: 0) {
                    PCRadioRow(
                        title: "Just today",
                        isSelected: scope == .todayOnly
                    ) { scope = .todayOnly }
                    PCRadioRow(
                        title: "Every day (default)",
                        isSelected: scope == .householdDefault
                    ) { scope = .householdDefault }
                }
            }
            .padding(PCSpacing.screenMargin)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.pc.surface)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.pc.border)
                    .frame(height: 1)
                PrimaryButton(title: "Apply") {
                    onApply(mode, scope)
                    dismiss()
                }
                .padding(.horizontal, PCSpacing.screenMargin)
                .padding(.top, PCSpacing.md)
                .padding(.bottom, PCSpacing.sm)
            }
            .background(Color.pc.surface)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview("HM-04 Capacity sheet") {
    Color.pc.bg
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            CapacitySheet(currentMode: .normal) { _, _ in }
        }
}
