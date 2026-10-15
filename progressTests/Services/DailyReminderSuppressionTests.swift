import CoreData
import Foundation
import Testing
import UserNotifications
@testable import progress

@MainActor
struct DailyReminderSuppressionTests {
    @Test("Skipping after a photo defaults on and an opt-out survives reopening")
    func suppressionPreferencePersists() async throws {
        let domain = "ReminderSuppressionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var schedulingCount = 0
        let service = DailyReminderNotificationService(defaults: defaults) { _ in
            schedulingCount += 1
            return true
        }
        #expect(service.skipsRemindersAfterPhoto)

        let disabledUpdate = service.setSkipsRemindersAfterPhoto(false)
        #expect(!service.skipsRemindersAfterPhoto)
        #expect(!DailyReminderNotificationService(defaults: defaults).skipsRemindersAfterPhoto)
        #expect(await disabledUpdate.value)

        #expect(await service.setSkipsRemindersAfterPhoto(true).value)
        #expect(DailyReminderNotificationService(defaults: defaults).skipsRemindersAfterPhoto)
        #expect(schedulingCount == 0)
    }

    @Test("A completed day queues only tomorrow and later, keeping all reminder times")
    func completedDaySkipsRemainingReminders() throws {
        let calendar = try calendar(timeZone: "Europe/Berlin")
        let now = try date(2026, 10, 15, 10, calendar: calendar)
        let service = DailyReminderNotificationService()
        let times = [DailyReminderTime(hour: 9, minute: 15), DailyReminderTime(hour: 18, minute: 30)]
        let requests = service.notificationRequests(for: times, now: now, calendar: calendar, skippingToday: true)

        #expect(requests.count == DailyReminderNotificationService.maxPendingReminders)
        #expect(Set(requests.map(\.identifier)).count == requests.count)
        let triggers = try requests.map { try #require($0.trigger as? UNCalendarNotificationTrigger) }
        let dates = try triggers.map { try #require(calendar.date(from: $0.dateComponents)) }
        let tomorrow = try date(2026, 10, 16, calendar: calendar)
        #expect(dates.allSatisfy { $0 >= tomorrow })
        #expect(dates == dates.sorted())
        #expect(try dates[0] == date(2026, 10, 16, 9, 15, calendar: calendar))
        #expect(try dates[1] == date(2026, 10, 16, 18, 30, calendar: calendar))
        #expect(triggers.allSatisfy { !$0.repeats })
        #expect(requests.allSatisfy { service.isDailyReminderNotification(userInfo: $0.content.userInfo) })
    }

    @Test("Seven times per day fit the notification limit without losing tomorrow's slots")
    func maximumReminderTimesFitLimit() throws {
        let calendar = try calendar(timeZone: "UTC")
        let now = try date(2026, 12, 31, 23, 59, calendar: calendar)
        let times = [9, 12, 15, 18, 21, 22, 23].map { DailyReminderTime(hour: $0, minute: 0) }
        let service = DailyReminderNotificationService()
        let requests = service.notificationRequests(for: times, now: now, calendar: calendar, skippingToday: true)
        let triggers = try requests.map { try #require($0.trigger as? UNCalendarNotificationTrigger) }

        #expect(triggers.count == 64)
        #expect(triggers.prefix(7).allSatisfy { $0.dateComponents.year == 2027 && $0.dateComponents.month == 1 && $0.dateComponents.day == 1 })
        #expect(triggers.prefix(7).map(\.dateComponents.hour) == times.map { Optional($0.hour) })
        #expect(service.notificationRequests(for: [], now: now, calendar: calendar, skippingToday: true).isEmpty)
    }

    @Test("Tomorrow follows local calendar days over daylight saving changes", arguments: [3, 10])
    func suppressionHandlesDaylightSaving(month: Int) throws {
        let calendar = try calendar(timeZone: "Europe/Berlin")
        let day = month == 3 ? 28 : 24
        let now = try date(2026, month, day, 23, calendar: calendar)
        let requests = DailyReminderNotificationService().notificationRequests(
            for: [DailyReminderTime(hour: 9, minute: 0)], now: now, calendar: calendar, skippingToday: true
        )
        let trigger = try #require(requests.first?.trigger as? UNCalendarNotificationTrigger)
        let nextDate = try #require(calendar.date(from: trigger.dateComponents))

        #expect(try nextDate == date(2026, month, day + 1, 9, calendar: calendar))
        #expect(trigger.dateComponents.timeZone == calendar.timeZone)
    }

    @Test("Uncompleted days and opt-outs retain indefinite daily repeats")
    func normalScheduleStillRepeats() throws {
        let calendar = try calendar(timeZone: "UTC")
        let now = try date(2026, 10, 15, 10, calendar: calendar)
        let requests = DailyReminderNotificationService().notificationRequests(
            for: [DailyReminderTime(hour: 18, minute: 30)], now: now, calendar: calendar, skippingToday: false
        )
        let trigger = try #require(requests.first?.trigger as? UNCalendarNotificationTrigger)

        #expect(requests.count == 1)
        #expect(trigger.repeats)
        #expect(trigger.dateComponents.hour == 18)
        #expect(trigger.dateComponents.minute == 30)
        #expect(trigger.dateComponents.day == nil)
    }

    @Test("Only saved photos captured within the local day count")
    func savedPhotoDetectionUsesCaptureDate() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let calendar = try calendar(timeZone: "Europe/Berlin")
        let today = try date(2026, 10, 15, 12, calendar: calendar)
        let start = calendar.startOfDay(for: today)
        let tomorrow = try date(2026, 10, 16, calendar: calendar)
        let oldImport = DailyPhoto(context: context)
        oldImport.captureDate = start.addingTimeInterval(-1)
        oldImport.createdAt = today
        let futurePhoto = DailyPhoto(context: context)
        futurePhoto.captureDate = tomorrow
        try context.save()
        #expect(try await !DailyReminderNotificationService.hasPhoto(on: today, calendar: calendar, context: context))

        let photo = DailyPhoto(context: context)
        photo.captureDate = start
        #expect(try await !DailyReminderNotificationService.hasPhoto(on: today, calendar: calendar, context: context))
        try context.save()
        #expect(try await DailyReminderNotificationService.hasPhoto(on: today, calendar: calendar, context: context))

        context.delete(photo)
        try context.save()
        #expect(try await !DailyReminderNotificationService.hasPhoto(on: today, calendar: calendar, context: context))
    }

    @Test("Saving today's photo removes today's requests and opting out restores repeats immediately")
    func photoAndPreferenceChangesUpdateScheduledRequests() async throws {
        let domain = "ReminderSchedulingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        var scheduledRequests: [UNNotificationRequest] = []
        let service = DailyReminderNotificationService(defaults: defaults, context: context) { requests in
            scheduledRequests = requests
            return true
        }
        let times = [DailyReminderTime(hour: 9, minute: 0), DailyReminderTime(hour: 23, minute: 59)]
        #expect(await service.updateReminderTimes(times))
        #expect(scheduledRequests.count == 2)
        #expect(scheduledRequests.allSatisfy { $0.trigger?.repeats == true })

        let photo = DailyPhoto(context: context)
        photo.captureDate = Date()
        #expect(await service.refreshReminders().value)
        #expect(scheduledRequests.count == 2)
        try context.save()
        #expect(await service.refreshReminders().value)
        let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())))
        let nextDates = try scheduledRequests.map { request in
            let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
            #expect(!trigger.repeats)
            return try #require(Calendar.current.date(from: trigger.dateComponents))
        }
        #expect(nextDates.count == 64)
        #expect(nextDates.allSatisfy { $0 >= tomorrow })

        #expect(await service.setSkipsRemindersAfterPhoto(false).value)
        #expect(scheduledRequests.count == 2)
        #expect(scheduledRequests.allSatisfy { $0.trigger?.repeats == true })
        #expect(await service.setSkipsRemindersAfterPhoto(true).value)
        #expect(scheduledRequests.count == 64)

        context.delete(photo)
        try context.save()
        #expect(await service.refreshReminders().value)
        #expect(scheduledRequests.count == 2)
        #expect(scheduledRequests.allSatisfy { $0.trigger?.repeats == true })

        #expect(await service.updateReminderTimes([]))
        #expect(scheduledRequests.isEmpty)
    }

    private func calendar(timeZone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: timeZone))
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, calendar: Calendar) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
    }
}
