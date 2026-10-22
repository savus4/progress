import CoreData
import Foundation
import Testing
import UserNotifications
@testable import progress

@MainActor
struct TimelineReminderDeletionTests {
    @Test("Deleting reminders drains pending edits and prevents stale snapshots from restoring them",
          .timeLimit(.minutes(1)),
          arguments: [TimelineIdentity.defaultID, UUID(uuidString: "10000000-0000-0000-0000-000000000002")!], [true, false])
    func queuedEditsCannotRestoreDeletedReminders(deletedID: UUID, isAuthorized: Bool) async throws {
        let domain = "TimelineReminderDeletion-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let survivor = UUID()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        defer { startedContinuation.finish(); releaseContinuation.finish() }
        var blocksNextSchedule = false
        var scheduleCount = 0
        var pending: [UNNotificationRequest] = []
        var delivered: [UNNotificationRequest] = []
        var removals: [Set<UUID>] = []
        let service = DailyReminderNotificationService(defaults: defaults, removeTimelineNotifications: { ids in
            removals.append(ids)
            let pendingIDs = Set(DailyReminderNotificationService.reminderIdentifiers(for: ids, in: pending))
            let deliveredIDs = Set(DailyReminderNotificationService.reminderIdentifiers(for: ids, in: delivered))
            pending.removeAll { pendingIDs.contains($0.identifier) }
            delivered.removeAll { deliveredIDs.contains($0.identifier) }
        }) { requests in
            scheduleCount += 1
            let authorized = scheduleCount <= 2 || isAuthorized
            if blocksNextSchedule {
                blocksNextSchedule = false
                startedContinuation.yield(())
                var iterator = release.makeAsyncIterator()
                await iterator.next()
            }
            if authorized { pending = requests }
            return authorized
        }
        let keptTimes = [DailyReminderTime(hour: 12, minute: 0)]
        #expect(await service.updateReminderTimes(keptTimes, timelineID: survivor))
        #expect(await service.updateReminderTimes([DailyReminderTime(hour: 9, minute: 0)], timelineID: deletedID))
        delivered = pending
        blocksNextSchedule = true
        let inFlight = service.submitReminderTimes([DailyReminderTime(hour: 10, minute: 0)], timelineID: deletedID)
        var iterator = started.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        let queued = service.submitReminderTimes([DailyReminderTime(hour: 11, minute: 0)], timelineID: deletedID)
        let deletion = service.removeTimelines([deletedID])
        #expect(service.loadReminderTimes(timelineID: deletedID).isEmpty)
        #expect(await service.updateReminderTimes([DailyReminderTime(hour: 20, minute: 0)], timelineID: deletedID))
        releaseContinuation.yield(())
        _ = await inFlight.value
        _ = await queued.value
        _ = await deletion.value

        #expect(removals == [[deletedID]])
        #expect(service.loadReminderTimes(timelineID: survivor) == keptTimes)
        #expect(pending.count == 1)
        #expect(delivered.count == 1)
        #expect(pending.allSatisfy { service.timelineID(forReminder: $0.content.userInfo) == survivor })
        #expect(delivered.allSatisfy { service.timelineID(forReminder: $0.content.userInfo) == survivor })
        let stalePayload: [AnyHashable: Any] = ["source": "daily-photo-reminder", "destination": "camera", "timelineID": deletedID.uuidString]
        #expect(await service.shouldSuppressReminder(userInfo: stalePayload))
        let reopened = DailyReminderNotificationService(defaults: defaults)
        #expect(reopened.loadReminderTimes(timelineID: deletedID).isEmpty)
        #expect(reopened.loadReminderTimes(timelineID: survivor) == keptTimes)
    }

    @Test("Reminder removal includes legacy Default requests and leaves unrelated notifications alone")
    func legacyAndScopedRequestsAreRemovedSelectively() throws {
        let service = DailyReminderNotificationService()
        let other = UUID()
        let schedules = [TimelineIdentity.defaultID, other].map {
            DailyReminderTimelineSchedule(timelineID: $0, times: [DailyReminderTime(hour: 9, minute: 0)], skippedDay: nil)
        }
        let modern = service.notificationRequests(for: schedules, now: Date(), calendar: .current)
        let content = UNMutableNotificationContent()
        content.userInfo = ["source": "daily-photo-reminder", "destination": "camera"]
        let legacy = UNNotificationRequest(identifier: "daily-photo-reminder-0", content: content, trigger: nil)
        let unrelated = UNNotificationRequest(identifier: "unrelated-notification", content: content, trigger: nil)
        let requests = modern + [legacy, unrelated]
        let defaultRequest = try #require(modern.first { service.timelineID(forReminder: $0.content.userInfo) == TimelineIdentity.defaultID })
        let otherRequest = try #require(modern.first { service.timelineID(forReminder: $0.content.userInfo) == other })
        #expect(Set(DailyReminderNotificationService.reminderIdentifiers(for: [TimelineIdentity.defaultID], in: requests)) == [legacy.identifier, defaultRequest.identifier])
        #expect(DailyReminderNotificationService.reminderIdentifiers(for: [other], in: requests) == [otherRequest.identifier])
    }

    @Test("Timeline deletion waits for notification cleanup to complete", .timeLimit(.minutes(1)))
    func deletionWaitsForNotificationRemoval() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        let id = try await TimelineStore.create(name: "Removed", in: context)
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        defer { startedContinuation.finish(); releaseContinuation.finish() }
        let reminders = DailyReminderNotificationService(defaults: library.defaults, context: context, removeTimelineNotifications: { _ in
            startedContinuation.yield(())
            var iterator = release.makeAsyncIterator()
            await iterator.next()
        }) { _ in true }
        #expect(await reminders.updateReminderTimes([DailyReminderTime(hour: 9, minute: 0)], timelineID: id))
        let deletion = TimelineDeletionService(photos: PhotoStorageService(cloudKitService: library.cloud,
                                                                          remoteAssetDeletionService: library.remoteAssetDeletions), reminders: reminders,
                                               guideDefaults: library.defaults, guideCloudStore: nil,
                                               automaticallyReconciles: false)
        var didFinish = false
        let task = Task {
            try await deletion.delete(id: id, in: context)
            didFinish = true
        }
        var iterator = started.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        #expect(didFinish == false)
        #expect(reminders.loadReminderTimes(timelineID: id).isEmpty)
        releaseContinuation.yield(())
        try await task.value
        #expect(didFinish)
    }

    @Test("A synced timeline deletion clears this device's reminders and preserves its other timeline")
    func syncedDeletionClearsLocalReminders() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        let id = try await TimelineStore.create(name: "Deleted elsewhere", in: context)
        var scheduled: [UNNotificationRequest] = []
        var removed = Set<UUID>()
        let reminders = DailyReminderNotificationService(defaults: library.defaults, context: context,
                                                         removeTimelineNotifications: { removed.formUnion($0) }) { scheduled = $0; return true }
        let keptTimes = [DailyReminderTime(hour: 9, minute: 0)]
        #expect(await reminders.updateReminderTimes(keptTimes))
        #expect(await reminders.updateReminderTimes([DailyReminderTime(hour: 18, minute: 0)], timelineID: id))
        // A tombstone arriving from another device goes through the same worker.
        try await TimelineStore.markDeleted(id: id, in: context)
        let deletion = TimelineDeletionService(photos: PhotoStorageService(cloudKitService: library.cloud,
                                                                          remoteAssetDeletionService: library.remoteAssetDeletions), reminders: reminders,
                                               guideDefaults: library.defaults, guideCloudStore: nil,
                                               automaticallyReconciles: false)
        try await deletion.reconcile(in: context)
        #expect(removed == [id])
        #expect(reminders.loadReminderTimes(timelineID: id).isEmpty)
        #expect(scheduled.count == 1)
        #expect(reminders.timelineID(forReminder: try #require(scheduled.first).content.userInfo) == TimelineIdentity.defaultID)
        let reopened = DailyReminderNotificationService(defaults: library.defaults)
        #expect(reopened.loadReminderTimes(timelineID: id).isEmpty)
        #expect(reopened.loadReminderTimes() == keptTimes)
    }
}
