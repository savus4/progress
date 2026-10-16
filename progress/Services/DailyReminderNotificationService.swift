import Foundation
import CoreData
import UIKit
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
    static let maxPendingReminders = 64
    static let skipAfterPhotoKey = "dailyPhotoRemindersSkipAfterPhoto"
    static let notificationUserInfoDestinationKey = "destination"
    static let notificationUserInfoSourceKey = "source"
    static let notificationCameraDestinationValue = "camera"
    static let notificationSourceValue = "daily-photo-reminder"

    private let reminderTimesKey = "dailyPhotoReminderTimes"
    private let defaults: UserDefaults
    private let scheduleReminders: (@MainActor ([UNNotificationRequest]) async -> Bool)?
    private var reminderUpdateTask: Task<Bool, Never>?
    private var photoContext: NSManagedObjectContext?
    private var observers: [NSObjectProtocol] = []
    private var lastScheduledState: DailyReminderScheduleState?

    init(
        defaults: UserDefaults = .standard,
        context: NSManagedObjectContext? = nil,
        scheduleReminders: (@MainActor ([UNNotificationRequest]) async -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.photoContext = context
        self.scheduleReminders = scheduleReminders
    }

    var skipsRemindersAfterPhoto: Bool {
        defaults.object(forKey: Self.skipAfterPhotoKey) as? Bool ?? true
    }

    func start(context: NSManagedObjectContext) {
        guard photoContext == nil else { return }
        photoContext = context
        let names: [Notification.Name] = [
            .NSManagedObjectContextDidSave,
            .NSPersistentStoreRemoteChange,
            UIApplication.significantTimeChangeNotification,
            .NSCalendarDayChanged
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshReminders()
                }
            })
        }
        refreshReminders()
    }

    @discardableResult
    func setSkipsRemindersAfterPhoto(_ enabled: Bool) -> Task<Bool, Never> {
        defaults.set(enabled, forKey: Self.skipAfterPhotoKey)
        return refreshReminders()
    }

    @discardableResult
    func refreshReminders() -> Task<Bool, Never> {
        let times = loadReminderTimes()
        guard !times.isEmpty else { return Task { true } }
        return enqueueReminderUpdate(times, requestsAuthorization: false)
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
        return enqueueReminderUpdate(sanitizedTimes, requestsAuthorization: true)
    }

    private func enqueueReminderUpdate(_ times: [DailyReminderTime], requestsAuthorization: Bool) -> Task<Bool, Never> {
        let previousUpdate = reminderUpdateTask
        let update = Task {
            _ = await previousUpdate?.value
            return await scheduleReminderNotifications(times, requestsAuthorization: requestsAuthorization)
        }
        reminderUpdateTask = update
        return update
    }

    @discardableResult
    func updateReminderTimes(_ times: [DailyReminderTime]) async -> Bool {
        await submitReminderTimes(times).value
    }

    private func scheduleReminderNotifications(_ sanitizedTimes: [DailyReminderTime], requestsAuthorization: Bool) async -> Bool {
        do {
            let now = Date()
            let calendar = Calendar.current
            let skipsAfterPhoto = skipsRemindersAfterPhoto
            let hasPhotoToday = skipsAfterPhoto && !sanitizedTimes.isEmpty
                ? try await self.hasPhotoToday(now: now, calendar: calendar)
                : false
            let state = DailyReminderScheduleState(
                times: sanitizedTimes,
                skippedDay: hasPhotoToday ? calendar.startOfDay(for: now) : nil,
                timeZoneIdentifier: calendar.timeZone.identifier
            )
            guard state != lastScheduledState else { return true }
            let requests = notificationRequests(for: sanitizedTimes, now: now, calendar: calendar, skippingToday: hasPhotoToday)
            if let scheduleReminders {
                let succeeded = await scheduleReminders(requests)
                lastScheduledState = succeeded ? state : nil
                return succeeded
            }
            guard !sanitizedTimes.isEmpty else {
                await clearReminderNotifications()
                lastScheduledState = state
                return true
            }

            let isAuthorized: Bool
            if requestsAuthorization {
                isAuthorized = try await ensureAuthorization()
            } else {
                let status = await Self.currentAuthorizationStatus()
                isAuthorized = status == .authorized || status == .provisional || status == .ephemeral
            }
            guard isAuthorized else { return false }

            await clearReminderNotifications()
            lastScheduledState = nil
            for request in requests {
                guard let trigger = request.trigger as? UNCalendarNotificationTrigger else { return false }
                try await Self.add(
                    identifier: request.identifier,
                    title: request.content.title,
                    body: request.content.body,
                    userInfo: request.content.userInfo as? [String: String] ?? [:],
                    dateComponents: trigger.dateComponents,
                    repeats: trigger.repeats
                )
            }

            lastScheduledState = state
            return true
        } catch {
            return false
        }
    }

    func notificationRequests(
        for times: [DailyReminderTime],
        now: Date,
        calendar: Calendar = .current,
        skippingToday: Bool
    ) -> [UNNotificationRequest] {
        let times = sanitizeReminderTimes(times)
        guard !times.isEmpty else { return [] }
        let content = UNMutableNotificationContent()
        content.title = "Take today's \(Self.appDisplayName) photo"
        content.body = "Open \(Self.appDisplayName) and capture your daily picture."
        content.sound = .default
        content.userInfo = [
            Self.notificationUserInfoDestinationKey: Self.notificationCameraDestinationValue,
            Self.notificationUserInfoSourceKey: Self.notificationSourceValue
        ]

        guard skippingToday else {
            return times.enumerated().map { index, time in
                UNNotificationRequest(
                    identifier: reminderIdentifier(for: index),
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: time.triggerDateComponents, repeats: true)
                )
            }
        }

        var requests: [UNNotificationRequest] = []
        var day = calendar.startOfDay(for: now)
        while requests.count < Self.maxPendingReminders {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
            for time in times {
                guard requests.count < Self.maxPendingReminders else { break }
                guard let date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) else { continue }
                let components = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
                requests.append(UNNotificationRequest(
                    identifier: reminderIdentifier(for: requests.count),
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                ))
            }
        }
        return requests
    }

    func shouldSuppressReminder(userInfo: [AnyHashable: Any]) async -> Bool {
        guard isDailyReminderNotification(userInfo: userInfo), skipsRemindersAfterPhoto else { return false }
        return (try? await hasPhotoToday(now: Date(), calendar: .current)) ?? false
    }

    private func hasPhotoToday(now: Date, calendar: Calendar) async throws -> Bool {
        guard let photoContext else { return false }
        return try await Self.hasPhoto(on: now, calendar: calendar, context: photoContext)
    }

    static func hasPhoto(on date: Date, calendar: Calendar = .current, context: NSManagedObjectContext) async throws -> Bool {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
        return try await context.perform {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "DailyPhoto")
            request.predicate = NSPredicate(format: "captureDate >= %@ AND captureDate < %@", start as NSDate, end as NSDate)
            request.fetchLimit = 1
            request.includesPendingChanges = false
            return try context.count(for: request) > 0
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await Self.currentAuthorizationStatus()
    }

    func isDailyReminderNotification(userInfo: [AnyHashable: Any]) -> Bool {
        let destination = userInfo[Self.notificationUserInfoDestinationKey] as? String
        let source = userInfo[Self.notificationUserInfoSourceKey] as? String

        return destination == Self.notificationCameraDestinationValue
            && source == Self.notificationSourceValue
    }

    func clearAllDeliveredNotifications() {
        Task {
            await Self.removeDeliveredNotifications()
        }
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
        (0..<Self.maxPendingReminders).map(reminderIdentifier)
    }

    private func clearReminderNotifications() async {
        await Self.removeReminderNotifications(withIdentifiers: reminderIdentifiers)
    }

    @concurrent
    private static func removeReminderNotifications(withIdentifiers identifiers: [String]) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeAllDeliveredNotifications()
    }

    @concurrent
    private static func removeDeliveredNotifications() async {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    private func ensureAuthorization() async throws -> Bool {
        switch await Self.currentAuthorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return try await Self.requestAuthorization()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    @concurrent
    private static func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @concurrent
    private static func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    @concurrent
    private static func add(
        identifier: String,
        title: String,
        body: String,
        userInfo: [String: String],
        dateComponents: DateComponents,
        repeats: Bool
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: repeats)
        )
        try await UNUserNotificationCenter.current().add(request)
    }
}
