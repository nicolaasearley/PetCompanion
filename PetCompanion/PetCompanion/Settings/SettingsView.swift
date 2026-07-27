import SwiftUI
import UIKit

/// The first truthful settings surface: device reminder preferences and
/// mutation-sync health. Household/member management follows with the hosted
/// collaboration slice.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var preferences = LocalNotificationPreferences.defaults
    @State private var permission = NotificationPermission.notDetermined
    @State private var isUpdatingNotifications = false

    var body: some View {
        NavigationStack {
            Form {
                remindersSection
                syncSection
                accountSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.pc.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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
        Section("Sync") {
            if let queue = model.mutationQueue {
                LabeledContent("Status", value: syncStatusText(queue.status))
                if queue.status.pendingCount > 0 {
                    LabeledContent("Waiting to sync", value: "\(queue.status.pendingCount)")
                }
                if queue.status.rejectedCount > 0 {
                    LabeledContent("Needs review", value: "\(queue.status.rejectedCount)")
                }
                Button("Try syncing now") {
                    Task { await model.replayOfflineOperations() }
                }
                .disabled(queue.status.isReplaying)
            } else {
                LabeledContent("Status", value: "Demo data")
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
            Text("Shared household invitations and member roles arrive after the hosted Supabase migration.")
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
