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

    static let maxRemindersPerDay = 3
    static let notificationUserInfoDestinationKey = "destination"
    static let notificationUserInfoSourceKey = "source"
    static let notificationCameraDestinationValue = "camera"
    static let notificationSourceValue = "daily-photo-reminder"

    private let reminderTimesKey = "dailyPhotoReminderTimes"
    private let center = UNUserNotificationCenter.current()

    private init() {}

    func loadReminderTimes() -> [DailyReminderTime] {
        guard let data = UserDefaults.standard.data(forKey: reminderTimesKey) else {
            return []
        }

        guard let decoded = try? JSONDecoder().decode([DailyReminderTime].self, from: data) else {
            return []
        }

        return sanitizeReminderTimes(decoded)
    }

    @discardableResult
    func updateReminderTimes(_ times: [DailyReminderTime]) async -> Bool {
        let sanitizedTimes = sanitizeReminderTimes(times)
        persistReminderTimes(sanitizedTimes)

        await clearReminderNotifications()

        guard !sanitizedTimes.isEmpty else {
            return true
        }

        do {
            let isAuthorized = try await ensureAuthorization()
            guard isAuthorized else { return false }

            for (index, reminderTime) in sanitizedTimes.enumerated() {
                let content = UNMutableNotificationContent()
                content.title = "Take today's progress photo"
                content.body = "Open the camera and capture your daily picture."
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
        await notificationSettings().authorizationStatus
    }

    func isDailyReminderNotification(userInfo: [AnyHashable: Any]) -> Bool {
        let destination = userInfo[Self.notificationUserInfoDestinationKey] as? String
        let source = userInfo[Self.notificationUserInfoSourceKey] as? String

        return destination == Self.notificationCameraDestinationValue
            && source == Self.notificationSourceValue
    }

    private func persistReminderTimes(_ times: [DailyReminderTime]) {
        guard let data = try? JSONEncoder().encode(times) else { return }
        UserDefaults.standard.set(data, forKey: reminderTimesKey)
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

    private func clearReminderNotifications() async {
        let identifiers = (0..<Self.maxRemindersPerDay).map(reminderIdentifier)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func ensureAuthorization() async throws -> Bool {
        let settings = await notificationSettings()
        switch settings.authorizationStatus {
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

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
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
