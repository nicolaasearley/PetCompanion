import Foundation
import UserNotifications

/// Where a tapped reminder lands once the app has looked at the current state
/// of its target.
///
/// A local notification is convenience delivery, never the source of truth
/// (doc 20 §4.10): it was scheduled against a plan that may have changed
/// hours ago, so nothing is presented until the occurrence has been resolved
/// again. A target that is still on the plan opens with whatever state it has
/// now — completed included (IA §10). One that is gone, or that cannot be
/// read, says so plainly instead of opening a stale card (IA §9, §15.1).
enum ResolvedDeepLink: Equatable {
    case home
    /// Slice B never schedules a dated Planner reminder, so the tab opens on
    /// its usual day rather than carrying a date the app cannot verify.
    case planner
    case planItem(id: UUID)
    case unavailable(DeepLinkFailure)
}

/// Why a reminder could not open its target. The three cases stay distinct
/// because their honest copy differs: a missing task is not an outage, and an
/// outage is not a lost household (IA §15.1).
enum DeepLinkFailure: String, Equatable, Identifiable {
    /// The plan was read, but the reminder's item is no longer part of it —
    /// cancelled, rescheduled away, or regenerated out.
    case targetNoLongerInPlan
    /// The plan itself could not be read right now. Nothing is claimed about
    /// the item or the household.
    case planUnavailable
    /// Authorization is gone — GL-03 (IA §6.8, doc 16 §7).
    case noAccess

    var id: String { rawValue }
}

/// Pure resolution of a tapped reminder against freshly read state, kept
/// separate from delivery so "never open something stale" is testable without
/// a notification centre or a network.
enum NotificationDeepLinkResolver {
    static func resolve(
        _ target: AppDeepLinkTarget,
        against snapshot: PlanSnapshot?
    ) -> ResolvedDeepLink {
        switch target.destination {
        case .home:
            return .home
        case .planner:
            return .planner
        case .planItem:
            guard let snapshot else { return .unavailable(.planUnavailable) }
            guard let planItemId = target.planItemId else { return .home }
            // A cache-served plan cannot confirm what the occurrence looks
            // like now, and a reminder must not open a card that implies it
            // can. Home carries the last-synchronized indicator, so the tap
            // lands there instead of on an unverifiable detail sheet.
            if snapshot.servedFromCacheAt != nil { return .home }
            if let petId = target.petId, snapshot.plan.petId != petId {
                return .unavailable(.targetNoLongerInPlan)
            }
            guard snapshot.items.contains(where: { $0.id == planItemId }) else {
                return .unavailable(.targetNoLongerInPlan)
            }
            return .planItem(id: planItemId)
        }
    }

    /// Why a failed plan read could not open the reminder's target.
    ///
    /// The distinction that matters is between an outage and a fact. A day
    /// the engine never planned — a reminder tapped long after its day
    /// elapsed, now that plan reads are genuinely date-scoped — is not a
    /// service failure, and copy claiming one would tell the caregiver to
    /// retry something that will never succeed (IA §15.1).
    static func failure(for error: Error) -> DeepLinkFailure {
        switch error {
        case PlanServiceError.notSignedIn: .noAccess
        case PlanServiceError.noPlanForDay: .targetNoLongerInPlan
        default: .planUnavailable
        }
    }
}

/// Receives notification taps and holds them until the app can resolve them.
///
/// A response can arrive before any app state exists — a cold launch straight
/// from the lock screen — so the decoded target is buffered rather than
/// dropped. The delegate itself decides nothing about navigation; it only
/// hands over what the notification claimed.
@MainActor
final class NotificationDeepLinkInbox: NSObject, UNUserNotificationCenterDelegate {
    private var buffered: [AppDeepLinkTarget] = []
    private var handler: ((AppDeepLinkTarget) -> Void)?

    /// Registered at launch so a tap that woke the app is not delivered
    /// before anything is listening for it.
    func register(with center: UNUserNotificationCenter = .current()) {
        center.delegate = self
    }

    /// Installed once the session is restored; anything buffered during
    /// launch is delivered immediately afterwards.
    func setHandler(_ handler: @escaping (AppDeepLinkTarget) -> Void) {
        self.handler = handler
        let pending = buffered
        buffered = []
        for target in pending {
            handler(target)
        }
    }

    func receive(_ target: AppDeepLinkTarget) {
        guard let handler else {
            buffered.append(target)
            return
        }
        handler(target)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let target = AppDeepLinkTarget(
            notificationUserInfo: response.notification.request.content.userInfo
        ) else { return }
        await receive(target)
    }

    /// A reminder that fires while the app is open is still worth showing:
    /// suppressing it silently would make the reminder preference untrue.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
