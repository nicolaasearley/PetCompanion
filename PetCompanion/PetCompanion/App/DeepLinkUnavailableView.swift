import SwiftUI

/// What a reminder shows when it cannot open what it pointed at.
///
/// The lost-authorization case is GL-03 (IA §6.8, doc 16 §7): neutral copy
/// with no household data in it, routing to household creation. The other two
/// are not access failures and must not be dressed as one — a task that left
/// the plan is ordinary current state, not an error (IA §15.2).
struct DeepLinkUnavailableView: View {
    let failure: DeepLinkFailure
    let onShowToday: () -> Void
    let onCreateHousehold: () -> Void

    var body: some View {
        ScrollView {
            EmptyStateView(
                systemImage: symbol,
                message: message,
                primaryActionTitle: primaryActionTitle,
                primaryAction: primaryAction
            )
            .frame(maxWidth: .infinity)
        }
        .background(Color.pc.bg.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var symbol: String {
        switch failure {
        case .targetNoLongerInPlan: "calendar.badge.checkmark"
        case .planUnavailable: "wifi.exclamationmark"
        case .noAccess: "lock"
        }
    }

    private var message: String {
        switch failure {
        case .targetNoLongerInPlan:
            "That reminder's task is no longer on the plan. Nothing was changed."
        case .planUnavailable:
            "The plan couldn't be loaded, so Settle didn't open that reminder. Your data has not been changed."
        case .noAccess:
            "You don't have access to this household anymore."
        }
    }

    private var primaryActionTitle: String {
        failure == .noAccess ? "Create a household" : "Show today"
    }

    private var primaryAction: () -> Void {
        failure == .noAccess ? onCreateHousehold : onShowToday
    }
}

#Preview("Deep link — task gone") {
    Color.pc.bg
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            DeepLinkUnavailableView(
                failure: .targetNoLongerInPlan,
                onShowToday: {},
                onCreateHousehold: {}
            )
        }
}

#Preview("GL-03 — no access") {
    Color.pc.bg
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            DeepLinkUnavailableView(
                failure: .noAccess,
                onShowToday: {},
                onCreateHousehold: {}
            )
        }
}
