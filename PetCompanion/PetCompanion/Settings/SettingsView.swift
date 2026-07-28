import SwiftUI
import UIKit

/// The first truthful settings surface: device reminder preferences and
/// mutation-sync health. Household/member management follows with the hosted
/// collaboration slice.
struct SettingsView: View {
    /// Screens inside the stack that a caller can open directly. Entry points
    /// outside Home name a destination rather than dropping the caregiver at
    /// the hub to find it again (IA §5.3, §10).
    enum Destination: String, Hashable, Identifiable {
        /// ST-01 — the hub itself.
        case hub
        /// ST-04 — members & invitations.
        case members
        /// Changes the service refused, and the only place to clear them.
        case rejectedChanges

        var id: String { rawValue }

        /// The stack a caller's chosen destination starts on. The hub is the
        /// root, not a pushed screen, so opening it must not leave a back
        /// button pointing at a duplicate of itself.
        static func initialPath(opening destination: Destination) -> [Destination] {
            destination == .hub ? [] : [destination]
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var path: [Destination]
    @State private var preferences = LocalNotificationPreferences.defaults
    @State private var permission = NotificationPermission.notDetermined
    @State private var isUpdatingNotifications = false

    init(opening destination: Destination = .hub) {
        _path = State(initialValue: Destination.initialPath(opening: destination))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                householdSection
                remindersSection
                syncSection
                accountSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.pc.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Destination.self, destination: destination)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                preferences = model.notifications.preferences
                permission = model.notifications.permission
            }
        }
    }

    /// A destination that has lost its household resolves to the hub rather
    /// than to an empty screen: the caregiver may have been removed while the
    /// entry point was on screen (IA §6.8).
    @ViewBuilder
    private func destination(_ destination: Destination) -> some View {
        switch destination {
        case .hub:
            EmptyView()
        case .members:
            if let household = model.household {
                HouseholdMembersView(household: household)
            }
        case .rejectedChanges:
            if let queue = model.mutationQueue {
                RejectedChangesView(queue: queue)
            }
        }
    }

    /// ST-01 hub → ST-04 (doc 16 §6). Hidden until a household exists,
    /// because there is nothing truthful to show before then.
    @ViewBuilder
    private var householdSection: some View {
        if let household = model.household {
            Section {
                LabeledContent("Household", value: household.name)
                NavigationLink("Members & invitations", value: Destination.members)
                    .accessibilityHint("Shows who belongs to this household and any invitations")
            } header: {
                Text("Household")
            } footer: {
                Text("Caregivers share every pet, plan, and record. Completions always show who did them.")
            }
        }
    }

    private var remindersSection: some View {
        Section {
            Toggle("Plan reminders", isOn: enabledBinding)
                .disabled(isUpdatingNotifications)

            if preferences.enabled {
                Picker("Remind me", selection: leadMinutesBinding) {
                    Text("At time").tag(0)
                    Text("10 minutes before").tag(10)
                    Text("15 minutes before").tag(15)
                    Text("30 minutes before").tag(30)
                    Text("1 hour before").tag(60)
                }

                Toggle("Include time windows", isOn: windowReminderBinding)

                DatePicker(
                    "Quiet hours start",
                    selection: quietHourBinding(\.quietHoursStart),
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    "Quiet hours end",
                    selection: quietHourBinding(\.quietHoursEnd),
                    displayedComponents: .hourAndMinute
                )
            }

            if permission == .denied {
                Button("Open notification settings") {
                    guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else {
                        return
                    }
                    openURL(url)
                }
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text(reminderFooter)
        }
    }

    private var syncSection: some View {
        Section {
            if let queue = model.mutationQueue {
                LabeledContent("Status", value: syncStatusText(queue.status))
                if queue.status.pendingCount > 0 {
                    LabeledContent("Waiting to sync", value: "\(queue.status.pendingCount)")
                }
                if queue.status.rejectedCount > 0 {
                    // A refused change is never retried, so a bare count was
                    // a dead end: it could only ever count up. The row is a
                    // way in, and out (doc 09 §15.1).
                    NavigationLink(value: Destination.rejectedChanges) {
                        LabeledContent("Needs review", value: "\(queue.status.rejectedCount)")
                    }
                    .accessibilityHint("Shows changes the household refused, and lets you discard them")
                }
                Button("Try syncing now") {
                    Task { await model.replayOfflineOperations() }
                }
                .disabled(queue.status.isReplaying)
            } else {
                LabeledContent("Status", value: "Demo data")
            }
        } header: {
            Text("Sync")
        } footer: {
            if let queue = model.mutationQueue, queue.status.rejectedCount > 0 {
                Text("Refused changes were never applied. Review them to decide what to do.")
            }
        }
    }

    private var accountSection: some View {
        Section {
            if let displayName = model.currentUser?.displayName {
                LabeledContent("Signed in as", value: displayName)
            }
            Button("Sign out", role: .destructive) {
                dismiss()
                model.signOut()
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Your account is yours alone. Caregivers join a household by invitation, never by sharing a sign-in.")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.enabled },
            set: { enabled in
                isUpdatingNotifications = true
                Task {
                    permission = await model.notifications.setEnabled(enabled)
                    preferences = model.notifications.preferences
                    isUpdatingNotifications = false
                }
            }
        )
    }

    private var leadMinutesBinding: Binding<Int> {
        Binding(
            get: { preferences.leadMinutes },
            set: { value in
                preferences.leadMinutes = value
                savePreferences()
            }
        )
    }

    private var windowReminderBinding: Binding<Bool> {
        Binding(
            get: { preferences.includeWindowReminders },
            set: { value in
                preferences.includeWindowReminders = value
                savePreferences()
            }
        )
    }

    private func quietHourBinding(_ keyPath: WritableKeyPath<LocalNotificationPreferences, Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    from: DateComponents(hour: preferences[keyPath: keyPath])
                ) ?? .now
            },
            set: { value in
                preferences[keyPath: keyPath] = Calendar.current.component(.hour, from: value)
                savePreferences()
            }
        )
    }

    private func savePreferences() {
        let updated = preferences
        Task { await model.notifications.updatePreferences(updated) }
    }

    private var reminderFooter: String {
        switch permission {
        case .notDetermined:
            "PetCompanion asks for notification access only when you enable reminders."
        case .denied:
            "Notifications are blocked in system settings. Your plan and task history still work normally."
        case .authorized, .provisional:
            "Reminder text stays discreet on the lock screen. The shared plan remains the source of truth."
        }
    }

    private func syncStatusText(_ status: MutationSyncStatus) -> String {
        if status.isReplaying { return "Syncing" }
        if status.rejectedCount > 0 { return "Review needed" }
        if status.pendingCount > 0 { return "Waiting for connection" }
        return "Up to date"
    }
}

#Preview {
    SettingsView()
        .environment(AppModel.preview())
        .tint(Color.pc.primary)
}
