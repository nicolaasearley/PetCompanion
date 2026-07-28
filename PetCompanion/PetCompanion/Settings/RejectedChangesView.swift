import SwiftUI

/// Changes the household service refused, and the only way to clear them.
///
/// A rejected write is terminal: the queue never retries it, so without this
/// screen the "needs review" count in Settings was a badge with nothing
/// behind it and no way down. Doc 09 §15.1 requires a write to resolve to
/// saved, queued, or failed — never ambiguous — and a count the caregiver
/// can neither read nor act on is exactly that ambiguity, just quieter.
///
/// Discarding is destructive and says so before it happens: the change was
/// never applied, nothing will re-send it, and this removes the last record
/// that it was ever attempted (doc 09 §10, §7.4).
struct RejectedChangesView: View {
    let queue: OfflineOperationQueue

    @State private var pendingDiscard: OfflineOperation?

    private var rejected: [OfflineOperation] { queue.rejectedOperations }

    var body: some View {
        Group {
            if rejected.isEmpty {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    message: "Nothing needs review. Every change this device made has been accepted.",
                    accent: .success
                )
                .padding(PCSpacing.screenMargin)
                .frame(maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    Section {
                        ForEach(rejected) { operation in
                            row(operation)
                        }
                    } header: {
                        Text("Not applied")
                    } footer: {
                        Text("These changes were refused by the household and were never saved. They will not be tried again.")
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.pc.bg)
        .navigationTitle("Needs review")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Discard this change?",
            isPresented: discardPrompt,
            titleVisibility: .visible,
            presenting: pendingDiscard
        ) { operation in
            Button("Discard permanently", role: .destructive) {
                queue.discardRejected(operationId: operation.id)
                pendingDiscard = nil
            }
            Button("Keep it", role: .cancel) {
                pendingDiscard = nil
            }
        } message: { operation in
            Text(
                "“\(operation.displayTitle)” was never applied to your household. "
                    + "Discarding removes it from this device for good — the change is lost, "
                    + "and nothing will be sent. To make it, do it again."
            )
        }
    }

    private func row(_ operation: OfflineOperation) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.xs) {
            Text(operation.displayTitle)
                .font(Font.pc.body.weight(.medium))
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)

            // The service's own words. The app does not paraphrase a reason
            // it did not decide (doc 09 §9).
            if let reason = operation.lastErrorMessage, !reason.isEmpty {
                Text(reason)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Attempted \(operation.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkTertiary)

            Button("Discard", role: .destructive) {
                pendingDiscard = operation
            }
            .font(Font.pc.secondary.weight(.semibold))
            .frame(minHeight: PCMetrics.minTouchTarget, alignment: .leading)
            .accessibilityHint("Removes this change permanently without applying it")
        }
        .padding(.vertical, PCSpacing.xs)
        .accessibilityElement(children: .contain)
    }

    private var discardPrompt: Binding<Bool> {
        Binding(
            get: { pendingDiscard != nil },
            set: { presented in
                if !presented { pendingDiscard = nil }
            }
        )
    }
}

#Preview("Nothing refused") {
    NavigationStack {
        RejectedChangesView(
            queue: OfflineOperationQueue(transport: PreviewWritePathTransport())
        )
    }
    .tint(Color.pc.primary)
}

/// Previews render a queue with no account activated, so nothing is ever
/// sent through this.
private final class PreviewWritePathTransport: OfflineOperationTransport {
    func execute(_ operation: OfflineOperation) async throws -> Data {
        throw OfflineTransportError.unavailable(code: "PREVIEW", message: "Preview")
    }
}
