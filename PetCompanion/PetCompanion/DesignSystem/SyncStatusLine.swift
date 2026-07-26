import SwiftUI

/// Sync state of the data shown on a screen (doc 09 §7.8, US-106).
enum SyncStatus: Equatable {
    /// Everything verified — the line renders nothing. Silence is the
    /// normal state.
    case current
    /// State cannot be verified; show when it was last synchronized.
    case stale(lastSynced: Date)
    /// Local changes are queued for synchronization.
    case queued(count: Int)
}

/// Sync/status line — UI Design System doc 09 §7.8.
///
/// A single `type.caption` line in the header region. It appears only when
/// state is stale or queued; never a blocking banner.
struct SyncStatusLine: View {
    let status: SyncStatus

    var body: some View {
        switch status {
        case .current:
            EmptyView()
        case .stale(let lastSynced):
            line("Showing last synced plan — \(lastSynced.formatted(date: .omitted, time: .shortened))")
        case .queued(let count):
            line(count == 1 ? "1 change queued" : "\(count) changes queued")
        }
    }

    private func line(_ text: String) -> some View {
        HStack(spacing: PCSpacing.xs) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
            Text(text)
                .font(Font.pc.caption)
        }
        .foregroundStyle(Color.pc.inkTertiary)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Sync status") {
    VStack(alignment: .leading, spacing: PCSpacing.md) {
        SyncStatusLine(status: .current) // renders nothing
        SyncStatusLine(status: .stale(lastSynced: .now))
        SyncStatusLine(status: .queued(count: 2))
    }
    .padding(PCSpacing.screenMargin)
    .background(Color.pc.bg)
}
