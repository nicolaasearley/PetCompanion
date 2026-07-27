import Foundation
import Observation
import UserNotifications

struct AppDeepLinkTarget: Codable, Equatable, Hashable, Sendable {
    enum Destination: String, Codable, Sendable {
        case home
        case planner
        case planItem = "plan_item"
    }

    let destination: Destination
    var petId: UUID?
    var planItemId: UUID?
    var localDate: Date?

    init(
        destination: Destination,
        petId: UUID? = nil,
        planItemId: UUID? = nil,
        localDate: Date? = nil
    ) {
        self.destination = destination
        self.petId = petId
        self.planItemId = planItemId
        self.localDate = localDate
    }

    static func planItem(_ itemId: UUID, petId: UUID, date: Date) -> AppDeepLinkTarget {
        AppDeepLinkTarget(
            destination: .planItem,
            petId: petId,
            planItemId: itemId,
            localDate: date
        )
    }

    var notificationUserInfo: [String: String] {
        [
            "destination": destination.rawValue,
            "pet_id": petId?.uuidString ?? "",
            "plan_item_id": planItemId?.uuidString ?? "",
            "local_date": localDate.map(SupabaseCoding.iso8601String) ?? "",
        ]
    }

    init?(notificationUserInfo: [AnyHashable: Any]) {
        guard let rawDestination = notificationUserInfo["destination"] as? String,
              let destination = Destination(rawValue: rawDestination)
        else { return nil }
        self.destination = destination
        petId = nil
        planItemId = nil
        localDate = nil
        if let raw = notificationUserInfo["pet_id"] as? String {
            petId = UUID(uuidString: raw)
        }
        if let raw = notificationUserInfo["plan_item_id"] as? String {
            planItemId = UUID(uuidString: raw)
        }
        if let raw = notificationUserInfo["local_date"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            localDate = formatter.date(from: raw)
        }
    }
}

struct LocalNotificationPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var leadMinutes = 10
    var includeWindowReminders = false
    var quietHoursStart = 21
    var quietHoursEnd = 7

    static let defaults = LocalNotificationPreferences()
}

enum NotificationPermission: String, Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
}

struct LocalNotificationCandidate: Equatable, Identifiable, Sendable {
    let id: String
    let fireDate: Date
    let timeZoneId: String
    let deepLink: AppDeepLinkTarget
}

/// Pure plan-to-reminder selection. Only pending, verified obligations with
/// a meaningful time are candidates; no task title or medical detail enters
/// lock-screen copy.
enum LocalNotificationCandidateBuilder {
    static func candidates(
        snapshot: PlanSnapshot,
        preferences: LocalNotificationPreferences,
        now: Date = Date()
    ) -> [LocalNotificationCandidate] {
        guard preferences.enabled,
              let timeZone = TimeZone(identifier: snapshot.plan.timeZoneSnapshot)
        else { return [] }
        var householdCalendar = Calendar(identifier: .gregorian)
        householdCalendar.timeZone = timeZone
        let horizon = householdCalendar.date(byAdding: .day, value: 7, to: now) ?? now

        return snapshot.items.compactMap { item in
            guard item.kind == .obligation,
                  item.displayState == .normal,
                  let occurrence = snapshot.occurrence(for: item),
                  occurrence.state == .pending
            else { return nil }

            let dueDate: Date?
            switch occurrence.timePolicy {
            case .exactTime:
                guard let dueTime = occurrence.dueTime else { return nil }
                // SQL `time` values are decoded onto an arbitrary device-day;
                // extract only their wall-clock components, then combine them
                // with the household-local due date.
                let deviceCalendar = Calendar.current
                let hour = deviceCalendar.component(.hour, from: dueTime)
                let minute = deviceCalendar.component(.minute, from: dueTime)
                dueDate = householdCalendar.date(
                    bySettingHour: hour,
                    minute: minute,
                    second: 0,
                    of: occurrence.localDueDate
                )
            case .window:
                guard preferences.includeWindowReminders,
                      let window = occurrence.window ?? item.timeWindow
                else { return nil }
                dueDate = householdCalendar.date(
                    bySettingHour: window.notificationHour,
                    minute: 0,
                    second: 0,
                    of: occurrence.localDueDate
                )
            case .anytime:
                return nil
            }

            guard let dueDate,
                  let fireDate = householdCalendar.date(
                    byAdding: .minute,
                    value: -max(0, preferences.leadMinutes),
                    to: dueDate
                  ),
                  fireDate > now,
                  fireDate <= horizon,
                  !isQuietHour(
                    householdCalendar.component(.hour, from: fireDate),
                    start: preferences.quietHoursStart,
                    end: preferences.quietHoursEnd
                  )
            else { return nil }

            return LocalNotificationCandidate(
                id: item.id.uuidString,
                fireDate: fireDate,
                timeZoneId: snapshot.plan.timeZoneSnapshot,
                deepLink: .planItem(
                    item.id,
                    petId: snapshot.plan.petId,
                    date: snapshot.plan.localDate
                )
            )
        }
        .sorted { $0.fireDate < $1.fireDate }
    }

    private static func isQuietHour(_ hour: Int, start: Int, end: Int) -> Bool {
        let normalizedStart = min(max(start, 0), 23)
        let normalizedEnd = min(max(end, 0), 23)
        if normalizedStart == normalizedEnd { return false }
        if normalizedStart < normalizedEnd {
            return hour >= normalizedStart && hour < normalizedEnd
        }
        return hour >= normalizedStart || hour < normalizedEnd
    }
}

private extension PlanTimeWindow {
    var notificationHour: Int {
        switch self {
        case .morning: 8
        case .midday: 12
        case .afternoon: 15
        case .evening: 18
        case .anytime: 12
        }
    }
}

struct LocalNotificationRequest: Equatable, Sendable {
    let identifier: String
    let fireDate: Date
    let timeZoneId: String
    let deepLink: AppDeepLinkTarget
}

@MainActor
protocol LocalNotificationCenterClient: AnyObject {
    func permission() async -> NotificationPermission
    func requestAuthorization() async throws -> Bool
    func replacePending(
        namespace: String,
        requests: [LocalNotificationRequest]
    ) async throws
    func removePending(namespace: String) async
}

@MainActor
final class UserNotificationCenterClient: LocalNotificationCenterClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter? = nil) {
        self.center = center ?? .current()
    }

    func permission() async -> NotificationPermission {
        let settings = await center.notificationSettings()
        return switch settings.authorizationStatus {
        case .authorized, .ephemeral: NotificationPermission.authorized
        case .provisional: NotificationPermission.provisional
        case .denied: NotificationPermission.denied
        case .notDetermined: NotificationPermission.notDetermined
        @unknown default: NotificationPermission.denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func replacePending(
        namespace: String,
        requests: [LocalNotificationRequest]
    ) async throws {
        let existing = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: existing.map(\.identifier).filter { $0.hasPrefix(namespace) }
        )

        for request in requests.prefix(48) {
            let content = UNMutableNotificationContent()
            content.title = "PetCompanion"
            content.body = "A plan item is coming up."
            content.sound = .default
            content.userInfo = request.deepLink.notificationUserInfo

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: request.timeZoneId) ?? .current
            var components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: request.fireDate
            )
            components.timeZone = calendar.timeZone
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: components,
                repeats: false
            )
            try await center.add(
                UNNotificationRequest(
                    identifier: request.identifier,
                    content: content,
                    trigger: trigger
                )
            )
        }
    }

    func removePending(namespace: String) async {
        let existing = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: existing.map(\.identifier).filter { $0.hasPrefix(namespace) }
        )
    }
}

@MainActor
protocol LocalNotificationServicing: AnyObject {
    var preferences: LocalNotificationPreferences { get }
    var permission: NotificationPermission { get }
    func activate(accountId: UUID)
    func deactivate()
    func setEnabled(_ enabled: Bool) async -> NotificationPermission
    func updatePreferences(_ preferences: LocalNotificationPreferences) async
    func reconcile(snapshot: PlanSnapshot, now: Date) async
    func cancelPending() async
}

extension LocalNotificationServicing {
    /// Production callers reconcile against the current instant. Tests supply an
    /// explicit `now` so candidate expiry does not depend on the wall clock.
    func reconcile(snapshot: PlanSnapshot) async {
        await reconcile(snapshot: snapshot, now: Date())
    }
}

@MainActor
final class LocalNotificationPreferenceStore {
    private let defaults: UserDefaults
    private let prefix = "petcompanion.local-notifications."
    private let promptKey = "petcompanion.local-notifications.authorization-requested"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasRequestedAuthorization: Bool {
        get { defaults.bool(forKey: promptKey) }
        set { defaults.set(newValue, forKey: promptKey) }
    }

    func load(accountId: UUID) -> LocalNotificationPreferences {
        guard let data = defaults.data(forKey: prefix + accountId.uuidString),
              let value = try? JSONDecoder().decode(LocalNotificationPreferences.self, from: data)
        else { return .defaults }
        return value
    }

    func save(_ preferences: LocalNotificationPreferences, accountId: UUID) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: prefix + accountId.uuidString)
    }
}

/// Local-only notification coordinator. It never requests permission on app
/// launch: the prompt appears solely after an explicit enable action, once.
@MainActor
@Observable
final class LocalNotificationService: LocalNotificationServicing {
    private let center: any LocalNotificationCenterClient
    private let store: LocalNotificationPreferenceStore
    private(set) var preferences = LocalNotificationPreferences.defaults
    private(set) var permission = NotificationPermission.notDetermined
    private var activeAccountId: UUID?
    private var lastSnapshot: PlanSnapshot?

    init(
        center: any LocalNotificationCenterClient,
        store: LocalNotificationPreferenceStore? = nil
    ) {
        self.center = center
        self.store = store ?? LocalNotificationPreferenceStore()
    }

    static func live() -> LocalNotificationService {
        LocalNotificationService(center: UserNotificationCenterClient())
    }

    func activate(accountId: UUID) {
        guard activeAccountId != accountId else { return }
        if let previousAccountId = activeAccountId {
            let previousNamespace = Self.namespace(accountId: previousAccountId)
            Task { await center.removePending(namespace: previousNamespace) }
        }
        activeAccountId = accountId
        preferences = store.load(accountId: accountId)
        lastSnapshot = nil
        Task { permission = await center.permission() }
    }

    func deactivate() {
        let namespace = activeAccountId.map { Self.namespace(accountId: $0) }
        activeAccountId = nil
        lastSnapshot = nil
        preferences = .defaults
        if let namespace {
            Task { await center.removePending(namespace: namespace) }
        }
    }

    func setEnabled(_ enabled: Bool) async -> NotificationPermission {
        guard let accountId = activeAccountId else { return permission }
        if !enabled {
            preferences.enabled = false
            store.save(preferences, accountId: accountId)
            await cancelPending()
            return permission
        }

        permission = await center.permission()
        if permission == .notDetermined, !store.hasRequestedAuthorization {
            store.hasRequestedAuthorization = true
            do {
                _ = try await center.requestAuthorization()
            } catch {
                // The center's authoritative setting below decides state.
            }
            permission = await center.permission()
        }

        preferences.enabled = permission == .authorized || permission == .provisional
        store.save(preferences, accountId: accountId)
        if preferences.enabled, let lastSnapshot {
            await reconcile(snapshot: lastSnapshot)
        } else if !preferences.enabled {
            await cancelPending()
        }
        return permission
    }

    func updatePreferences(_ updated: LocalNotificationPreferences) async {
        guard let accountId = activeAccountId else { return }
        preferences = updated
        store.save(updated, accountId: accountId)
        if let lastSnapshot {
            await reconcile(snapshot: lastSnapshot)
        }
    }

    func reconcile(snapshot: PlanSnapshot, now: Date) async {
        lastSnapshot = snapshot
        guard let accountId = activeAccountId else { return }
        permission = await center.permission()
        let namespace = Self.namespace(accountId: accountId)
        guard preferences.enabled,
              permission == .authorized || permission == .provisional
        else {
            await center.removePending(namespace: namespace)
            return
        }

        let requests = LocalNotificationCandidateBuilder.candidates(
            snapshot: snapshot,
            preferences: preferences,
            now: now
        ).map { candidate in
            LocalNotificationRequest(
                identifier: namespace + candidate.id,
                fireDate: candidate.fireDate,
                timeZoneId: candidate.timeZoneId,
                deepLink: candidate.deepLink
            )
        }
        do {
            try await center.replacePending(namespace: namespace, requests: requests)
        } catch {
            // Scheduling failure does not change server data or pretend a
            // reminder exists. A later plan refresh retries reconciliation.
        }
    }

    func cancelPending() async {
        guard let activeAccountId else { return }
        await center.removePending(namespace: Self.namespace(accountId: activeAccountId))
    }

    private static func namespace(accountId: UUID) -> String {
        "pc.local.\(accountId.uuidString)."
    }
}
