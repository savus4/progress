import Foundation
import UserNotifications

struct DailyReminderTime: Codable, Identifiable, Hashable {
    let id: UUID
    var hour: Int
    var minute: Int

    init(id: UUID = UUID(), hour: Int, minute: Int) {
        self.id = id
        self.hour = hour
        self.minute = minute
    }

    init(date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        self.id = UUID()
        self.hour = components.hour ?? 9
        self.minute = components.minute ?? 0
    }

    var dateValue: Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    var triggerDateComponents: DateComponents {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return components
    }
}

final class DailyReminderNotificationService {
    static let shared = DailyReminderNotificationService()

    static let maxRemindersPerDay = 7
    static let notificationUserInfoDestinationKey = "destination"
    static let notificationUserInfoSourceKey = "source"
    static let notificationCameraDestinationValue = "camera"
    static let notificationSourceValue = "daily-photo-reminder"

    private let reminderTimesKey = "dailyPhotoReminderTimes"
    private let center = UNUserNotificationCenter.current()
    private let defaults: UserDefaults
    private let scheduleReminders: (@MainActor ([DailyReminderTime]) async -> Bool)?
    private var reminderUpdateTask: Task<Bool, Never>?

    init(
        defaults: UserDefaults = .standard,
        scheduleReminders: (@MainActor ([DailyReminderTime]) async -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.scheduleReminders = scheduleReminders
    }

    func loadReminderTimes() -> [DailyReminderTime] {
        guard let data = defaults.data(forKey: reminderTimesKey) else {
            return []
        }

        guard let decoded = try? JSONDecoder().decode([DailyReminderTime].self, from: data) else {
            return []
        }

        return sanitizeReminderTimes(decoded)
    }

    @discardableResult
    func submitReminderTimes(_ times: [DailyReminderTime]) -> Task<Bool, Never> {
        let sanitizedTimes = sanitizeReminderTimes(times)
        // A newly opened Settings sheet must immediately see the latest edits,
        // even if an earlier permission request or notification update is pending.
        persistReminderTimes(sanitizedTimes)
        let previousUpdate = reminderUpdateTask
        let update = Task {
            _ = await previousUpdate?.value
            return await scheduleReminderNotifications(sanitizedTimes)
        }
        reminderUpdateTask = update
        return update
    }

    @discardableResult
    func updateReminderTimes(_ times: [DailyReminderTime]) async -> Bool {
        await submitReminderTimes(times).value
    }

    private func scheduleReminderNotifications(_ sanitizedTimes: [DailyReminderTime]) async -> Bool {
        if let scheduleReminders {
            return await scheduleReminders(sanitizedTimes)
        }

        await clearReminderNotifications()

        guard !sanitizedTimes.isEmpty else {
            return true
        }

        do {
            let isAuthorized = try await ensureAuthorization()
            guard isAuthorized else { return false }

            for (index, reminderTime) in sanitizedTimes.enumerated() {
                let content = UNMutableNotificationContent()
                content.title = "Take today's \(Self.appDisplayName) photo"
                content.body = "Open \(Self.appDisplayName) and capture your daily picture."
                content.sound = .default
                content.userInfo = [
                    Self.notificationUserInfoDestinationKey: Self.notificationCameraDestinationValue,
                    Self.notificationUserInfoSourceKey: Self.notificationSourceValue
                ]

                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: reminderTime.triggerDateComponents,
                    repeats: true
                )

                let request = UNNotificationRequest(
                    identifier: reminderIdentifier(for: index),
                    content: content,
                    trigger: trigger
                )

                try await add(request: request)
            }

            return true
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await currentAuthorizationStatus()
    }

    func isDailyReminderNotification(userInfo: [AnyHashable: Any]) -> Bool {
        let destination = userInfo[Self.notificationUserInfoDestinationKey] as? String
        let source = userInfo[Self.notificationUserInfoSourceKey] as? String

        return destination == Self.notificationCameraDestinationValue
            && source == Self.notificationSourceValue
    }

    func clearAllDeliveredNotifications() {
        center.removeAllDeliveredNotifications()
    }

    private func persistReminderTimes(_ times: [DailyReminderTime]) {
        guard let data = try? JSONEncoder().encode(times) else { return }
        defaults.set(data, forKey: reminderTimesKey)
    }

    private func sanitizeReminderTimes(_ times: [DailyReminderTime]) -> [DailyReminderTime] {
        var seenClockTimes = Set<String>()
        let sortedTimes = times
            .map { time in
                DailyReminderTime(id: time.id, hour: min(max(time.hour, 0), 23), minute: min(max(time.minute, 0), 59))
            }
            .sorted { lhs, rhs in
                if lhs.hour == rhs.hour {
                    return lhs.minute < rhs.minute
                }
                return lhs.hour < rhs.hour
            }

        var uniqueTimes: [DailyReminderTime] = []
        for time in sortedTimes {
            let key = "\(time.hour):\(time.minute)"
            guard !seenClockTimes.contains(key) else { continue }
            seenClockTimes.insert(key)
            uniqueTimes.append(time)
            if uniqueTimes.count == Self.maxRemindersPerDay {
                break
            }
        }

        return uniqueTimes
    }

    private func reminderIdentifier(for index: Int) -> String {
        "daily-photo-reminder-\(index)"
    }

    private static var appDisplayName: String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }

        if let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.isEmpty {
            return bundleName
        }

        return "Work in Progress"
    }

    private var reminderIdentifiers: [String] {
        (0..<Self.maxRemindersPerDay).map(reminderIdentifier)
    }

    private func clearReminderNotifications() async {
        center.removePendingNotificationRequests(withIdentifiers: reminderIdentifiers)
        clearAllDeliveredNotifications()
    }

    private func ensureAuthorization() async throws -> Bool {
        switch await currentAuthorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return try await requestAuthorization()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func add(request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
