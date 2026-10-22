import SwiftUI
import UIKit
import UserNotifications

struct DailyReminderSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    let timelineID: UUID
    @State private var skipsAfterPhoto = true
    @State private var reminderTimes: [DailyReminderTime] = []
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var hasLoadedReminderTimes = false
    @State private var lastSubmittedReminderTimes: [DailyReminderTime]?

    private let notificationService = DailyReminderNotificationService.shared

    init(timelineID: UUID = TimelineIdentity.defaultID) {
        self.timelineID = timelineID
    }

    var body: some View {
        Form {
            Section {
                Toggle("Skip Reminders After Taking a Photo", isOn: $skipsAfterPhoto)
                    .accessibilityIdentifier("skipRemindersAfterPhotoToggle")
            } footer: {
                Text("Once a photo has been saved for today, remaining reminders are skipped until tomorrow. Turn this off to receive every scheduled reminder.")
            }

            Section {
                if reminderTimes.isEmpty {
                    Text("No reminder times configured.")
                        .foregroundStyle(.secondary)
                }

                ForEach($reminderTimes) { $reminder in
                    HStack {
                        DatePicker(
                            "Reminder time",
                            selection: Binding(
                                get: { reminder.dateValue },
                                set: { newDate in
                                    let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                    reminder.hour = components.hour ?? 9
                                    reminder.minute = components.minute ?? 0
                                }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()

                        Spacer()

                        Button(role: .destructive) {
                            reminderTimes.removeAll { $0.id == reminder.id }
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
            } header: {
                Text("Reminder Times")
            } footer: {
                Text("Reminders don’t sync between devices.")
            }
            .animation(.easeInOut(duration: 0.2), value: reminderTimes)

            if authorizationStatus == .denied {
                Section {
                    Text("Notifications Disabled")
                        .foregroundStyle(.secondary)
                    Button("Open System Settings") {
                        openAppSettings()
                    }
                }
            }
        }
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            if !hasLoadedReminderTimes {
                reminderTimes = notificationService.loadReminderTimes(timelineID: timelineID)
                skipsAfterPhoto = notificationService.skipsRemindersAfterPhoto(timelineID: timelineID)
                lastSubmittedReminderTimes = reminderTimes
                hasLoadedReminderTimes = true
            }
            authorizationStatus = await notificationService.authorizationStatus()
        }
        .onChange(of: skipsAfterPhoto) { _, _ in
            guard hasLoadedReminderTimes else { return }
            notificationService.setSkipsRemindersAfterPhoto(skipsAfterPhoto, timelineID: timelineID)
        }
        .onDisappear {
            persistChangesIfNeeded()
        }
    }

    private func addReminder() {
        guard reminderTimes.count < DailyReminderNotificationService.maxRemindersPerDay else { return }
        let defaultHourCandidates = [9, 12, 15, 18, 21, 22, 23]
        guard let hour = defaultHourCandidates.first(where: { hour in
            !reminderTimes.contains { $0.hour == hour && $0.minute == 0 }
        }) else { return }
        reminderTimes.append(DailyReminderTime(hour: hour, minute: 0))
    }

    private func persistChangesIfNeeded() {
        guard hasLoadedReminderTimes, lastSubmittedReminderTimes != reminderTimes else { return }
        lastSubmittedReminderTimes = reminderTimes
        notificationService.submitReminderTimes(reminderTimes, timelineID: timelineID)
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
    }
}
