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
    static let skipAfterPhotoKey = "dailyPhotoRemindersSkipAfterPhoto" // Legacy migration input.
    static let timelinePreferencesKey = "dailyPhotoReminderPreferencesByTimeline"
    static let notificationUserInfoDestinationKey = "destination"
    static let notificationUserInfoSourceKey = "source"
    nonisolated static let notificationUserInfoTimelineIDKey = "timelineID"
    static let notificationCameraDestinationValue = "camera"
    static let notificationSourceValue = "daily-photo-reminder"

    private struct Preferences: Codable, Equatable {
        var times: [DailyReminderTime] = []
        var skipsAfterPhoto = true
    }

    private let reminderTimesKey = "dailyPhotoReminderTimes"
    private let defaults: UserDefaults
    private let scheduleReminders: (@MainActor ([UNNotificationRequest]) async -> Bool)?
    private let removeNotifications: (@MainActor (Set<UUID>) async -> Void)?
    private var reminderUpdateTask: Task<Bool, Never>?
    private var photoContext: NSManagedObjectContext?
    private var observers: [NSObjectProtocol] = []
    private var lastScheduledState: DailyReminderScheduleState?
    private var deletedTimelineIDs: Set<UUID> = []
    // Old queued snapshots stay invalid even if a kept cloud owner later returns.
    private var deletionGenerations: [UUID: Int] = [:]

    convenience init(
        defaults: UserDefaults = .standard,
        context: NSManagedObjectContext? = nil,
        scheduleReminders: (@MainActor ([UNNotificationRequest]) async -> Bool)? = nil
    ) {
        self.init(defaults: defaults, context: context, removeTimelineNotifications: nil, scheduleReminders: scheduleReminders)
    }

    init(
        defaults: UserDefaults = .standard,
        context: NSManagedObjectContext? = nil,
        removeTimelineNotifications: (@MainActor (Set<UUID>) async -> Void)?,
        scheduleReminders: (@MainActor ([UNNotificationRequest]) async -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.photoContext = context
        self.removeNotifications = removeTimelineNotifications
        self.scheduleReminders = scheduleReminders
    }

    var skipsRemindersAfterPhoto: Bool {
        skipsRemindersAfterPhoto(timelineID: TimelineIdentity.defaultID)
    }

    func skipsRemindersAfterPhoto(timelineID: UUID) -> Bool {
        loadPreferences()[timelineID.uuidString]?.skipsAfterPhoto ?? true
    }

    func start(context: NSManagedObjectContext) {
        guard photoContext == nil else { return }
        photoContext = context
        let names: [Notification.Name] = [
            .NSManagedObjectContextDidSave,
            .NSPersistentStoreRemoteChange,
            UIApplication.significantTimeChangeNotification,
            .NSCalendarDayChanged,
            PhotoStorageModeStore.didChangeNotification
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
    func setSkipsRemindersAfterPhoto(_ enabled: Bool, timelineID: UUID = TimelineIdentity.defaultID) -> Task<Bool, Never> {
        guard !deletedTimelineIDs.contains(timelineID) else { return Task { true } }
        var preferences = loadPreferences()
        var preference = preferences[timelineID.uuidString] ?? Preferences()
        preference.skipsAfterPhoto = enabled
        preferences[timelineID.uuidString] = preference
        persistPreferences(preferences)
        return enqueueReminderUpdate(preferences, requestsAuthorization: false)
    }

    @discardableResult
    func refreshReminders() -> Task<Bool, Never> {
        enqueueReminderUpdate(loadPreferences(), requestsAuthorization: false)
    }

    func loadReminderTimes(timelineID: UUID = TimelineIdentity.defaultID) -> [DailyReminderTime] {
        guard !deletedTimelineIDs.contains(timelineID) else { return [] }
        return sanitizeReminderTimes(loadPreferences()[timelineID.uuidString]?.times ?? [])
    }

    @discardableResult
    func submitReminderTimes(_ times: [DailyReminderTime], timelineID: UUID = TimelineIdentity.defaultID) -> Task<Bool, Never> {
        guard !deletedTimelineIDs.contains(timelineID) else { return Task { true } }
        var preferences = loadPreferences()
        var preference = preferences[timelineID.uuidString] ?? Preferences()
        preference.times = sanitizeReminderTimes(times)
        preferences[timelineID.uuidString] = preference
        // Persist immediately, and capture every timeline's settings before queued
        // permission requests or notification updates have a chance to suspend.
        persistPreferences(preferences)
        return enqueueReminderUpdate(preferences, requestsAuthorization: true)
    }

    private func enqueueReminderUpdate(_ preferences: [String: Preferences], requestsAuthorization: Bool,
                                       removingTimelineIDs: Set<UUID> = []) -> Task<Bool, Never> {
        let previousUpdate = reminderUpdateTask
        let generations = deletionGenerations
        let update = Task {
            _ = await previousUpdate?.value
            if !removingTimelineIDs.isEmpty {
                if let removeNotifications {
                    await removeNotifications(removingTimelineIDs)
                } else if scheduleReminders == nil {
                    // A custom scheduling backend supplies its own removal hook.
                    await Self.removeTimelineNotifications(for: removingTimelineIDs)
                }
            }
            return await scheduleReminderNotifications(preferences, requestsAuthorization: requestsAuthorization, generations: generations)
        }
        reminderUpdateTask = update
        return update
    }

    @discardableResult
    func updateReminderTimes(_ times: [DailyReminderTime], timelineID: UUID = TimelineIdentity.defaultID) async -> Bool {
        await submitReminderTimes(times, timelineID: timelineID).value
    }

    @discardableResult
    func removeTimelines(_ ids: Set<UUID>) -> Task<Bool, Never> {
        deletedTimelineIDs.formUnion(ids)
        for id in ids { deletionGenerations[id, default: 0] += 1 }
        var preferences = loadPreferences()
        for id in ids { preferences.removeValue(forKey: id.uuidString) }
        if ids.contains(TimelineIdentity.defaultID) {
            defaults.removeObject(forKey: reminderTimesKey)
            defaults.removeObject(forKey: Self.skipAfterPhotoKey)
        }
        persistPreferences(preferences)
        return enqueueReminderUpdate(preferences, requestsAuthorization: false, removingTimelineIDs: ids)
    }

    private func scheduleReminderNotifications(_ preferences: [String: Preferences], requestsAuthorization: Bool,
                                               generations: [UUID: Int]) async -> Bool {
        do {
            let now = Date()
            let calendar = Calendar.current
            let library = if let photoContext {
                try await TimelineStore.state(in: photoContext)
            } else {
                TimelineLibraryState(timelines: [], deletedIDs: [])
            }
            let metadata = library.timelines
            // A local removal can be replaced by its kept cloud timeline. Its old
            // preferences were erased; future edits may now configure fresh reminders.
            deletedTimelineIDs.subtract(metadata.map(\.id))
            deletedTimelineIDs.formUnion(library.deletedIDs)
            let showsTimelineNames = metadata.count > 1
            var timelines: [DailyReminderTimelineSchedule] = []
            for key in preferences.keys.sorted() {
                guard let timelineID = UUID(uuidString: key), let preference = preferences[key] else { continue }
                guard !deletedTimelineIDs.contains(timelineID),
                      generations[timelineID, default: 0] == deletionGenerations[timelineID, default: 0] else { continue }
                let times = sanitizeReminderTimes(preference.times)
                guard !times.isEmpty else { continue }
                let hasPhotoToday = preference.skipsAfterPhoto
                    ? try await self.hasPhotoToday(now: now, calendar: calendar, timelineID: timelineID)
                    : false
                timelines.append(DailyReminderTimelineSchedule(
                    timelineID: timelineID, times: times,
                    skippedDay: hasPhotoToday ? calendar.startOfDay(for: now) : nil,
                    name: showsTimelineNames ? metadata.first(where: { $0.id == timelineID })?.name : nil
                ))
            }
            let state = DailyReminderScheduleState(timelines: timelines, timeZoneIdentifier: calendar.timeZone.identifier)
            guard state != lastScheduledState else { return true }
            let requests = notificationRequests(for: timelines, now: now, calendar: calendar)
            if let scheduleReminders {
                let succeeded = await scheduleReminders(requests)
                lastScheduledState = succeeded ? state : nil
                return succeeded
            }
            guard !requests.isEmpty else {
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

    /// Preserve indefinite repeats for unfinished timelines, then share the
    /// remaining system slots between completed timelines in fire-date order.
    func notificationRequests(for timelines: [DailyReminderTimelineSchedule], now: Date, calendar: Calendar = .current) -> [UNNotificationRequest] {
        let requests = timelines.flatMap { timeline in
            notificationRequests(for: timeline.times, now: now, calendar: calendar,
                                 skippingToday: timeline.skippedDay != nil, timelineID: timeline.timelineID,
                                 timelineName: timeline.name)
        }
        func fireDate(for request: UNNotificationRequest) -> Date {
            guard let trigger = request.trigger as? UNCalendarNotificationTrigger else { return .distantFuture }
            if trigger.repeats {
                return calendar.nextDate(after: now, matching: trigger.dateComponents, matchingPolicy: .nextTime) ?? .distantFuture
            }
            return calendar.date(from: trigger.dateComponents) ?? .distantFuture
        }
        func ordered(_ lhs: UNNotificationRequest, _ rhs: UNNotificationRequest) -> Bool {
            let lhsDate = fireDate(for: lhs)
            let rhsDate = fireDate(for: rhs)
            return lhsDate == rhsDate ? lhs.identifier < rhs.identifier : lhsDate < rhsDate
        }
        let repeating = requests.filter { $0.trigger?.repeats == true }.sorted(by: ordered)
        let dated = requests.filter { $0.trigger?.repeats != true }.sorted(by: ordered)
        return Array((repeating + dated).prefix(Self.maxPendingReminders))
    }

    func notificationRequests(
        for times: [DailyReminderTime],
        now: Date,
        calendar: Calendar = .current,
        skippingToday: Bool,
        timelineID: UUID = TimelineIdentity.defaultID,
        timelineName: String? = nil
    ) -> [UNNotificationRequest] {
        let times = sanitizeReminderTimes(times)
        guard !times.isEmpty else { return [] }
        let content = UNMutableNotificationContent()
        content.title = timelineName.map { "Time for \($0)" } ?? "Take today's \(Self.appDisplayName) photo"
        content.body = "Open \(Self.appDisplayName) and capture your daily picture."
        content.sound = .default
        content.userInfo = [
            Self.notificationUserInfoDestinationKey: Self.notificationCameraDestinationValue,
            Self.notificationUserInfoSourceKey: Self.notificationSourceValue,
            Self.notificationUserInfoTimelineIDKey: timelineID.uuidString
        ]

        guard skippingToday else {
            return times.enumerated().map { index, time in
                UNNotificationRequest(
                    identifier: reminderIdentifier(for: index, timelineID: timelineID),
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: time.triggerDateComponents, repeats: true)
                )
            }
        }

        var requests: [UNNotificationRequest] = []
        var day = calendar.startOfDay(for: now)
        if skippingToday {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
            day = tomorrow
        }
        while requests.count < Self.maxPendingReminders {
            for time in times {
                guard requests.count < Self.maxPendingReminders else { break }
                guard let date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day), date > now else { continue }
                let components = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
                requests.append(UNNotificationRequest(
                    identifier: reminderIdentifier(for: requests.count, timelineID: timelineID),
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                ))
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }
        return requests
    }

    func shouldSuppressReminder(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let timelineID = timelineID(forReminder: userInfo) else { return false }
        if deletedTimelineIDs.contains(timelineID) { return true }
        if let photoContext, let state = try? await TimelineStore.state(in: photoContext), state.deletedIDs.contains(timelineID) {
            return true
        }
        guard skipsRemindersAfterPhoto(timelineID: timelineID) else { return false }
        return (try? await hasPhotoToday(now: Date(), calendar: .current, timelineID: timelineID)) ?? false
    }

    private func hasPhotoToday(now: Date, calendar: Calendar, timelineID: UUID) async throws -> Bool {
        guard let photoContext else { return false }
        return try await Self.hasPhoto(on: now, calendar: calendar, context: photoContext, timelineID: timelineID)
    }

    static func hasPhoto(on date: Date, calendar: Calendar = .current, context: NSManagedObjectContext, timelineID: UUID = TimelineIdentity.defaultID) async throws -> Bool {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
        return try await context.perform {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "DailyPhoto")
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "captureDate >= %@ AND captureDate < %@", start as NSDate, end as NSDate),
                TimelineIdentity.photoPredicate(for: timelineID)
            ])
            request.fetchLimit = 1
            request.includesPendingChanges = false
            return try context.count(for: request) > 0
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await Self.currentAuthorizationStatus()
    }

    func timelineID(forReminder userInfo: [AnyHashable: Any]) -> UUID? {
        guard isDailyReminderNotification(userInfo: userInfo) else { return nil }
        // Notifications scheduled by older versions belong to the migrated timeline.
        guard let value = userInfo[Self.notificationUserInfoTimelineIDKey] else { return TimelineIdentity.defaultID }
        guard let value = value as? String else { return nil }
        return UUID(uuidString: value)
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

    private func loadPreferences() -> [String: Preferences] {
        if let data = defaults.data(forKey: Self.timelinePreferencesKey),
           let preferences = try? JSONDecoder().decode([String: Preferences].self, from: data) {
            return preferences
        }
        // Keep legacy inputs intact for recovery. Once written, scoped settings
        // always take precedence, so an emptied timeline cannot resurrect them.
        let times = defaults.data(forKey: reminderTimesKey)
            .flatMap { try? JSONDecoder().decode([DailyReminderTime].self, from: $0) } ?? []
        let preferences = [TimelineIdentity.defaultID.uuidString: Preferences(
            times: sanitizeReminderTimes(times),
            skipsAfterPhoto: defaults.object(forKey: Self.skipAfterPhotoKey) as? Bool ?? true
        )]
        persistPreferences(preferences)
        return preferences
    }

    private func persistPreferences(_ preferences: [String: Preferences]) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.timelinePreferencesKey)
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

    private func reminderIdentifier(for index: Int, timelineID: UUID) -> String {
        "daily-photo-reminder-\(timelineID.uuidString)-\(index)"
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

    private func clearReminderNotifications() async {
        await Self.removeReminderNotifications()
    }

    @concurrent
    private static func removeTimelineNotifications(for timelineIDs: Set<UUID>) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        center.removePendingNotificationRequests(withIdentifiers: reminderIdentifiers(for: timelineIDs, in: pending))
        center.removeDeliveredNotifications(withIdentifiers: reminderIdentifiers(for: timelineIDs, in: delivered.map(\.request)))
    }

    nonisolated static func reminderIdentifiers(for timelineIDs: Set<UUID>, in requests: [UNNotificationRequest]) -> [String] {
        requests.filter { reminder($0, belongsTo: timelineIDs) }.map(\.identifier)
    }

    nonisolated private static func reminder(_ request: UNNotificationRequest, belongsTo timelineIDs: Set<UUID>) -> Bool {
        guard request.identifier.hasPrefix("daily-photo-reminder-") else { return false }
        let owner: UUID?
        if let value = request.content.userInfo[notificationUserInfoTimelineIDKey] {
            owner = (value as? String).flatMap(UUID.init(uuidString:))
        } else {
            owner = TimelineIdentity.defaultID
        }
        return owner.map { timelineIDs.contains($0) } ?? false
    }

    @concurrent
    private static func removeReminderNotifications() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        // Includes the legacy identifiers and every timeline, including one whose
        // last reminder was just removed from preferences.
        let identifiers = pending.map(\.identifier).filter { $0.hasPrefix("daily-photo-reminder-") }
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
