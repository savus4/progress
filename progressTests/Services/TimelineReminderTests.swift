import CoreData
import Foundation
import Testing
import UserNotifications
@testable import progress

@MainActor
struct TimelineReminderTests {
    @Test("Legacy reminder settings migrate only to the original timeline and cleared times stay cleared")
    func legacyPreferencesMigrateOnce() async throws {
        let domain = "TimelineReminderMigration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let legacyTimes = [DailyReminderTime(hour: 18, minute: 15)]
        defaults.set(try JSONEncoder().encode(legacyTimes), forKey: "dailyPhotoReminderTimes")
        defaults.set(false, forKey: DailyReminderNotificationService.skipAfterPhotoKey)
        let otherID = UUID()
        let service = DailyReminderNotificationService(defaults: defaults) { _ in true }

        // Reading another timeline first must not adopt the existing user's settings.
        #expect(service.loadReminderTimes(timelineID: otherID).isEmpty)
        #expect(service.skipsRemindersAfterPhoto(timelineID: otherID))
        #expect(service.loadReminderTimes() == legacyTimes)
        #expect(service.skipsRemindersAfterPhoto == false)
        #expect(defaults.data(forKey: DailyReminderNotificationService.timelinePreferencesKey) != nil)
        #expect(await service.updateReminderTimes([]))

        let reopened = DailyReminderNotificationService(defaults: defaults)
        #expect(reopened.loadReminderTimes().isEmpty)
        #expect(reopened.skipsRemindersAfterPhoto == false)
        // Recovery inputs remain available without overwriting scoped preferences.
        #expect(defaults.data(forKey: "dailyPhotoReminderTimes") != nil)
    }

    @Test("Reminder settings and scheduled identifiers remain independent across timelines")
    func preferencesAreScoped() async throws {
        let domain = "TimelineReminderIsolation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var requests: [UNNotificationRequest] = []
        let service = DailyReminderNotificationService(defaults: defaults) { requests = $0; return true }
        let otherID = UUID()
        let first = [DailyReminderTime(hour: 9, minute: 0)]
        let second = [DailyReminderTime(hour: 18, minute: 0)]
        #expect(await service.updateReminderTimes(first))
        #expect(await service.updateReminderTimes(second, timelineID: otherID))
        #expect(await service.setSkipsRemindersAfterPhoto(false, timelineID: otherID).value)
        #expect(service.loadReminderTimes() == first)
        #expect(service.loadReminderTimes(timelineID: otherID) == second)
        #expect(service.skipsRemindersAfterPhoto)
        #expect(service.skipsRemindersAfterPhoto(timelineID: otherID) == false)
        #expect(Set(requests.compactMap { service.timelineID(forReminder: $0.content.userInfo) }) == [TimelineIdentity.defaultID, otherID])
        #expect(Set(requests.map(\.identifier)).count == requests.count)

        #expect(await service.updateReminderTimes([], timelineID: otherID))
        #expect(requests.count == 1)
        #expect(service.timelineID(forReminder: try #require(requests.first).content.userInfo) == TimelineIdentity.defaultID)
        #expect(await service.updateReminderTimes([]))
        #expect(requests.isEmpty)
    }

    @Test("Queued edits capture each timeline's settings before earlier scheduling finishes")
    func queuedEditsPreserveTimelineSnapshots() async throws {
        let domain = "TimelineReminderQueue-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        defer { startedContinuation.finish(); releaseContinuation.finish() }
        var scheduledTimelines: [Set<String>] = []
        let service = DailyReminderNotificationService(defaults: defaults) { requests in
            scheduledTimelines.append(Set(requests.compactMap { $0.content.userInfo[DailyReminderNotificationService.notificationUserInfoTimelineIDKey] as? String }))
            if scheduledTimelines.count == 1 {
                startedContinuation.yield(())
                var iterator = release.makeAsyncIterator()
                await iterator.next()
            }
            return true
        }
        let otherID = UUID()
        let first = service.submitReminderTimes([DailyReminderTime(hour: 9, minute: 0)])
        var iterator = started.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        let second = service.submitReminderTimes([DailyReminderTime(hour: 18, minute: 0)], timelineID: otherID)
        let third = service.submitReminderTimes([])
        #expect(service.loadReminderTimes().isEmpty)
        #expect(service.loadReminderTimes(timelineID: otherID).count == 1)
        releaseContinuation.yield(())
        #expect(await first.value)
        #expect(await second.value)
        #expect(await third.value)
        #expect(scheduledTimelines == [
            [TimelineIdentity.defaultID.uuidString],
            [TimelineIdentity.defaultID.uuidString, otherID.uuidString],
            [otherID.uuidString]
        ])
    }

    @Test("Indefinite repeats reserve slots while completed timelines share the remaining upcoming budget")
    func pendingBudgetIsGlobal() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 10)))
        let repeatingID = UUID()
        let completedID = UUID()
        let timelines = [
            DailyReminderTimelineSchedule(timelineID: TimelineIdentity.defaultID, times: [DailyReminderTime(hour: 18, minute: 0)], skippedDay: calendar.startOfDay(for: now)),
            DailyReminderTimelineSchedule(timelineID: completedID, times: [DailyReminderTime(hour: 9, minute: 0)], skippedDay: calendar.startOfDay(for: now)),
            DailyReminderTimelineSchedule(timelineID: repeatingID, times: [DailyReminderTime(hour: 12, minute: 0)], skippedDay: nil)
        ]
        let service = DailyReminderNotificationService()
        let requests = service.notificationRequests(for: timelines, now: now, calendar: calendar)
        let repeating = requests.filter { $0.trigger?.repeats == true }
        let dated = requests.filter { $0.trigger?.repeats == false }
        let dates = try dated.map { request in
            let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
            return try #require(calendar.date(from: trigger.dateComponents))
        }
        #expect(requests.count == DailyReminderNotificationService.maxPendingReminders)
        #expect(repeating.count == 1)
        #expect(service.timelineID(forReminder: try #require(repeating.first).content.userInfo) == repeatingID)
        #expect(dated.count == 63)
        #expect(dates == dates.sorted())
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        #expect(dates.allSatisfy { $0 >= tomorrow })
        #expect(Set(dated.compactMap { service.timelineID(forReminder: $0.content.userInfo) }) == [TimelineIdentity.defaultID, completedID])
        #expect(service.timelineID(forReminder: try #require(dated.first).content.userInfo) == completedID)
        #expect(Set(requests.map(\.identifier)).count == requests.count)

        let unfinished = timelines.map { DailyReminderTimelineSchedule(timelineID: $0.timelineID, times: $0.times, skippedDay: nil) }
        let indefinite = service.notificationRequests(for: unfinished, now: now, calendar: calendar)
        #expect(indefinite.count == 3)
        #expect(indefinite.allSatisfy { $0.trigger?.repeats == true })
    }

    @Test("An over-capacity repeating schedule selects the nearest slots deterministically")
    func excessRepeatsRespectSystemLimit() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 10)))
        let times = [9, 12, 15, 18, 21, 22, 23].map { DailyReminderTime(hour: $0, minute: 0) }
        let timelines = (0..<10).map { _ in DailyReminderTimelineSchedule(timelineID: UUID(), times: times, skippedDay: nil) }
        let service = DailyReminderNotificationService()
        let requests = service.notificationRequests(for: timelines, now: now, calendar: calendar)
        let reversed = service.notificationRequests(for: Array(timelines.reversed()), now: now, calendar: calendar)
        #expect(requests.count == DailyReminderNotificationService.maxPendingReminders)
        #expect(requests.allSatisfy { $0.trigger?.repeats == true })
        #expect(requests.map(\.identifier) == reversed.map(\.identifier))
        // Noon is the next slot, while this morning's 09:00 repeats tomorrow.
        let firstTrigger = try #require(requests.first?.trigger as? UNCalendarNotificationTrigger)
        #expect(firstTrigger.dateComponents.hour == 12)
    }

    @Test("A photo suppresses only reminders for its own timeline, including legacy notification payloads")
    func suppressionUsesNotificationTimeline() async throws {
        let domain = "TimelineReminderSuppression-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let otherID = UUID()
        let photo = DailyPhoto(context: context)
        photo.timelineID = otherID
        photo.captureDate = Date()
        try context.save()
        let service = DailyReminderNotificationService(defaults: defaults, context: context) { _ in true }
        let otherRequest = try #require(service.notificationRequests(for: [DailyReminderTime(hour: 9, minute: 0)], now: Date(), skippingToday: false, timelineID: otherID).first)
        let legacyPayload: [AnyHashable: Any] = [
            DailyReminderNotificationService.notificationUserInfoSourceKey: DailyReminderNotificationService.notificationSourceValue,
            DailyReminderNotificationService.notificationUserInfoDestinationKey: DailyReminderNotificationService.notificationCameraDestinationValue
        ]
        #expect(await service.shouldSuppressReminder(userInfo: otherRequest.content.userInfo))
        #expect(await service.shouldSuppressReminder(userInfo: legacyPayload) == false)
        #expect(service.timelineID(forReminder: legacyPayload) == TimelineIdentity.defaultID)
        var invalidPayload = legacyPayload
        invalidPayload[DailyReminderNotificationService.notificationUserInfoTimelineIDKey] = "invalid"
        #expect(service.timelineID(forReminder: invalidPayload) == nil)
        #expect(await service.shouldSuppressReminder(userInfo: invalidPayload) == false)
        #expect(await service.setSkipsRemindersAfterPhoto(false, timelineID: otherID).value)
        #expect(await service.shouldSuppressReminder(userInfo: otherRequest.content.userInfo) == false)

        let legacyPhoto = DailyPhoto(context: context)
        legacyPhoto.timelineID = nil
        legacyPhoto.captureDate = Date()
        try context.save()
        #expect(await service.shouldSuppressReminder(userInfo: legacyPayload))
    }

    @Test("Notification navigation preserves the requested timeline until consumed")
    func navigationCarriesTimeline() {
        let coordinator = NotificationNavigationCoordinator.shared
        let timelineID = UUID()
        coordinator.requestCameraOpenFromNotification(timelineID: timelineID)
        #expect(coordinator.cameraOpenRequestTimelineID == timelineID)
        #expect(coordinator.cameraOpenRequestToken != nil)
        coordinator.consumeCameraOpenRequest()
        #expect(coordinator.cameraOpenRequestTimelineID == nil)
        #expect(coordinator.cameraOpenRequestToken == nil)
    }
}
