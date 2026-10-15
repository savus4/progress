import Foundation
import Testing
import UserNotifications
@testable import progress

@MainActor
struct DailyReminderPersistenceTests {
    @Test("Later reminder edits persist immediately while earlier scheduling is pending", arguments: [true, false])
    func pendingSchedulingDoesNotDelayOrOverwritePreferences(isAuthorized: Bool) async throws {
        let domain = "ReminderPersistenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        defer {
            startedContinuation.finish()
            releaseContinuation.finish()
        }
        var schedulingOrder: [[DateComponents]] = []
        let service = DailyReminderNotificationService(defaults: defaults) { requests in
            schedulingOrder.append(requests.compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents })
            if schedulingOrder.count == 1 {
                startedContinuation.yield(())
                var releaseIterator = release.makeAsyncIterator()
                await releaseIterator.next()
            }
            return requests.isEmpty || isAuthorized
        }
        let first = [DailyReminderTime(hour: 9, minute: 0)]
        let second = [DailyReminderTime(hour: 12, minute: 15)]
        let latest: [DailyReminderTime] = []
        let firstUpdate = service.submitReminderTimes(first)
        var startedIterator = started.makeAsyncIterator()
        try #require(await startedIterator.next() != nil)

        let secondUpdate = service.submitReminderTimes(second)
        // A reopened Settings sheet reads these preferences while the permission
        // request or scheduling work of the previous sheet is still pending.
        #expect(service.loadReminderTimes() == second)
        let latestUpdate = service.submitReminderTimes(latest)
        #expect(service.loadReminderTimes() == latest)
        #expect(schedulingOrder == [first.map(\.triggerDateComponents)])

        releaseContinuation.yield(())
        #expect(await firstUpdate.value == isAuthorized)
        #expect(await secondUpdate.value == isAuthorized)
        #expect(await latestUpdate.value)
        #expect(service.loadReminderTimes() == latest)
        #expect(schedulingOrder == [first, second, latest].map { $0.map(\.triggerDateComponents) })
    }
}
