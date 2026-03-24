import SwiftUI
import UserNotifications
import UIKit

struct NotificationSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var reminderTimes: [DailyReminderTime] = []
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isSaving = false
    @State private var alertMessage: String?

    private let notificationService = DailyReminderNotificationService.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Daily Photo Reminders") {
                    if reminderTimes.isEmpty {
                        Text("No reminder times configured.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach($reminderTimes) { $reminder in
                        HStack {
                            DatePicker(
                                "",
                                selection: Binding(
                                    get: { reminder.dateValue },
                                    set: { newDate in
                                        reminder = DailyReminderTime(id: reminder.id, date: newDate)
                                    }
                                ),
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()

                            Spacer()

                            Button(role: .destructive) {
                                removeReminder(withID: reminder.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove reminder")
                        }
                    }

                    Button {
                        addReminder()
                    } label: {
                        Label("Add Time", systemImage: "plus.circle")
                    }
                    .disabled(reminderTimes.count >= DailyReminderNotificationService.maxRemindersPerDay)

                    if reminderTimes.count >= DailyReminderNotificationService.maxRemindersPerDay {
                        Text("You can select up to three reminders per day.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Permission") {
                    Text(permissionDescription)
                        .foregroundStyle(.secondary)

                    if authorizationStatus == .denied {
                        Button("Open System Settings") {
                            openAppSettings()
                        }
                    }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            save()
                        }
                    }
                }
            }
            .alert(
                "Notifications",
                isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .task {
                reminderTimes = notificationService.loadReminderTimes()
                authorizationStatus = await notificationService.authorizationStatus()
            }
        }
    }

    private var permissionDescription: String {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "Notifications are enabled."
        case .notDetermined:
            return "Permission will be requested when you save reminders."
        case .denied:
            return "Notifications are turned off for this app. Enable them in Settings."
        @unknown default:
            return "Notification permission status is unavailable."
        }
    }

    private func addReminder() {
        guard reminderTimes.count < DailyReminderNotificationService.maxRemindersPerDay else { return }

        let defaultHourCandidates = [9, 13, 20]
        let index = min(reminderTimes.count, defaultHourCandidates.count - 1)
        let newReminder = DailyReminderTime(hour: defaultHourCandidates[index], minute: 0)
        reminderTimes.append(newReminder)
    }

    private func removeReminder(withID id: UUID) {
        reminderTimes.removeAll { $0.id == id }
    }

    private func save() {
        isSaving = true

        Task {
            let didSchedule = await notificationService.updateReminderTimes(reminderTimes)
            let status = await notificationService.authorizationStatus()

            await MainActor.run {
                authorizationStatus = status
                isSaving = false

                if !didSchedule && !reminderTimes.isEmpty {
                    alertMessage = "Could not schedule reminders. Please allow notifications in Settings."
                    return
                }

                dismiss()
            }
        }
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
    }
}

private extension DailyReminderTime {
    init(id: UUID, date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        self.id = id
        self.hour = components.hour ?? 9
        self.minute = components.minute ?? 0
    }
}
