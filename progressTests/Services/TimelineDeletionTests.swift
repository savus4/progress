import CloudKit
import CoreData
import Foundation
import Testing
import UIKit
import UserNotifications
@testable import progress

@MainActor
struct TimelineDeletionTests {
    @Test("The only timeline can be renamed but cannot be deleted")
    func lastTimelineIsProtected() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        try await TimelineStore.rename(id: TimelineIdentity.defaultID, to: "Me", in: context)
        await #expect(throws: TimelineOperationError.self) {
            try await TimelineStore.markDeleted(id: TimelineIdentity.defaultID, in: context)
        }
        let state = try await TimelineStore.state(in: context)
        #expect(state.timelines.map(\.name) == ["Me"])
        #expect(state.deletedIDs.isEmpty)
    }

    @Test("Deleting Default removes only its photos, reminders, guides, and upload ownership")
    func deletingDefaultPreservesSurvivor() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        let survivor = try await TimelineStore.create(name: "Alex", in: context)
        let doomed = addPhoto(owner: nil, name: "default.jpg", in: context)
        let kept = addPhoto(owner: survivor, name: "alex.jpg", in: context)
        let doomedID = try #require(doomed.id)
        let keptID = try #require(kept.id)
        try context.save()
        _ = try library.cloud.stageAssetData(Data([1]), named: "default.jpg")
        _ = try library.cloud.stageAssetData(Data([2]), named: "alex.jpg")
        try library.cloud.uploadStateStore.register(LocalPhotoUpload(
            photoID: doomedID, stillAssetName: "default.jpg", livePhotoImageAssetName: nil,
            videoAssetName: nil, createdAt: Date()
        ))
        let guide = AlignmentGuideStore(localDefaults: library.defaults, ubiquitousStore: nil)
        guide.eyeLinePosition = 0.4
        let otherGuide = AlignmentGuideStore(timelineID: survivor, localDefaults: library.defaults, ubiquitousStore: nil)
        otherGuide.eyeLinePosition = 0.3
        let otherGuideBytes = library.defaults.data(forKey: AlignmentGuideStore.storageKey(for: survivor))
        var scheduled: [UNNotificationRequest] = []
        let reminders = DailyReminderNotificationService(defaults: library.defaults, context: context) { scheduled = $0; return true }
        #expect(await reminders.updateReminderTimes([DailyReminderTime(hour: 9, minute: 0)]))
        #expect(await reminders.updateReminderTimes([DailyReminderTime(hour: 12, minute: 0)], timelineID: survivor))
        let service = deletionService(library, reminders: reminders)
        let selection = TimelineSelectionStore(defaults: library.defaults)
        await selection.start(in: context)
        selection.select(TimelineIdentity.defaultID)
        try await selection.delete(id: TimelineIdentity.defaultID, in: context, using: service)
        try await service.reconcile(in: context)
        _ = await reminders.refreshReminders().value

        #expect(selection.selectedID == survivor)
        #expect(selection.timelines.map(\.id) == [survivor])
        #expect(selection.select(TimelineIdentity.defaultID) == false)
        #expect(selection.canDeleteTimeline(survivor) == false)
        #expect(try context.fetch(DailyPhoto.fetchRequest()).map(\.id) == [keptID])
        #expect(library.cloud.stagedAssetURL(named: "default.jpg") == nil)
        #expect(library.cloud.stagedAssetURL(named: "alex.jpg") != nil)
        #expect(library.cloud.uploadStateStore.entry(for: doomedID) == nil)
        #expect(reminders.loadReminderTimes().isEmpty)
        #expect(await reminders.updateReminderTimes([DailyReminderTime(hour: 20, minute: 0)]))
        #expect(reminders.loadReminderTimes().isEmpty)
        #expect(reminders.loadReminderTimes(timelineID: survivor).count == 1)
        #expect(scheduled.allSatisfy { reminders.timelineID(forReminder: $0.content.userInfo) == survivor })
        #expect(library.defaults.data(forKey: "alignmentGuide") == nil)
        #expect(library.defaults.object(forKey: "eyeLinePosition") == nil)
        #expect(library.defaults.data(forKey: AlignmentGuideStore.storageKey(for: survivor)) == otherGuideBytes)
        let legacyPayload: [AnyHashable: Any] = ["source": "daily-photo-reminder", "destination": "camera"]
        #expect(await reminders.shouldSuppressReminder(userInfo: legacyPayload))
        await library.remoteAssetDeletions.processPendingDeletions()

        try await library.reopen()
        let restored = TimelineSelectionStore(defaults: library.defaults)
        await restored.start(in: library.persistence.container.viewContext)
        #expect(restored.selectedID == survivor)
        #expect(restored.timelines.map(\.id) == [survivor])
        #expect(restored.deletedIDs.contains(TimelineIdentity.defaultID))
    }

    @Test("The startup worker also cleans photos arriving after its initial pass", .timeLimit(.minutes(1)))
    func automaticCleanupObservesLateSaves() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        let id = try await TimelineStore.create(name: "Deleted", in: context)
        try await TimelineStore.markDeleted(id: id, in: context)
        let reminders = DailyReminderNotificationService(defaults: library.defaults, context: context) { _ in true }
        let service = TimelineDeletionService(photos: PhotoStorageService(cloudKitService: library.cloud,
                                                                          remoteAssetDeletionService: library.remoteAssetDeletions),
                                             reminders: reminders, guideDefaults: library.defaults, guideCloudStore: nil)
        service.start(in: context)
        await service.waitForPendingCleanup()
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: context, queue: .main) { _ in
            Task { @MainActor in
                if (try? context.count(for: DailyPhoto.fetchRequest())) == 0 { continuation.yield(()) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = addPhoto(owner: id, name: "late.jpg", in: context)
        try context.save()
        var iterator = changes.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        await service.waitForPendingCleanup()
        #expect(try context.count(for: DailyPhoto.fetchRequest()) == 0)
        #expect(try context.fetch(Timeline.fetchRequest()).filter { $0.id == id }.allSatisfy { $0.name == nil })
        _ = await reminders.refreshReminders().value
        await library.remoteAssetDeletions.processPendingDeletions()
    }

    @Test("Cleanup resumes for photos arriving after a timeline was deleted")
    func latePhotosStayDeleted() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        let id = try await TimelineStore.create(name: "Removed", in: context)
        try await TimelineStore.markDeleted(id: id, in: context)
        _ = addPhoto(owner: id, name: "late.jpg", in: context)
        _ = addPhoto(owner: nil, name: "default.jpg", in: context)
        try context.save()
        _ = try library.cloud.stageAssetData(Data([1]), named: "late.jpg")
        let reminders = DailyReminderNotificationService(defaults: library.defaults, context: context) { _ in true }
        let service = deletionService(library, reminders: reminders)
        try await service.reconcile(in: context)
        #expect(try context.fetch(DailyPhoto.fetchRequest()).map(\.fullImageAssetName) == ["default.jpg"])
        #expect(library.cloud.stagedAssetURL(named: "late.jpg") == nil)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        await #expect(throws: TimelineOperationError.self) {
            _ = try await PhotoStorageService(cloudKitService: library.cloud).saveImportedPhoto(
                imageData: #require(image.jpegData(compressionQuality: 1)), context: context,
                timelineID: id, enqueuesPendingUpload: false
            )
        }
        await library.remoteAssetDeletions.processPendingDeletions()
    }

    @Test("Crash journals for deleted timelines cannot recreate photos", arguments: [false, true])
    func crashRecoveryCannotResurrectDefault(legacyJournal: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        _ = try await TimelineStore.create(name: "Survivor", in: context)
        try await TimelineStore.markDeleted(id: TimelineIdentity.defaultID, in: context)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        let id = UUID()
        let name = "\(id).jpg"
        _ = try library.cloud.stageAssetData(#require(image.jpegData(compressionQuality: 1)), named: name)
        let entry = PendingUploadManifestEntry(photoID: id, captureDate: Date(), createdAt: Date(),
                                               latitude: 0, longitude: 0, fullImageAssetName: name,
                                               livePhotoVideoAssetName: nil,
                                               timelineID: legacyJournal ? nil : TimelineIdentity.defaultID)
        let url = library.root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode([entry]).write(to: url)
        try library.cloud.uploadStateStore.register(entry.localUpload)
        let journal = PendingUploadManifestService(storageURL: url)
        #expect(await journal.recoverPendingUploads(context: context, cloudKitService: library.cloud,
                                                    thumbnailService: .shared,
                                                    remoteAssetDeletionService: library.remoteAssetDeletions) == 0)
        #expect(try context.count(for: DailyPhoto.fetchRequest()) == 0)
        #expect(library.cloud.stagedAssetURL(named: name) == nil)
        #expect(library.cloud.uploadStateStore.entry(for: id) == nil)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        await library.remoteAssetDeletions.processPendingDeletions()
    }

    @Test("Concurrent offline deletions recover one fresh identity without restoring deleted photos")
    func concurrentDeletionsKeepAnEmptySurvivor() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        let other = try await TimelineStore.create(name: "Other", in: context)
        try await TimelineStore.rename(id: TimelineIdentity.defaultID, to: "Me", in: context)
        for row in try context.fetch(Timeline.fetchRequest()) { row.deletedAt = Date() }
        try context.save()
        let deleted: Set<UUID> = [TimelineIdentity.defaultID, other]
        let expected = TimelineIdentity.recoveryID(afterDeleting: deleted)
        let selection = TimelineSelectionStore(defaults: library.defaults)
        await selection.start(in: context)
        #expect(selection.timelines.map(\.id) == [expected])
        #expect(deleted.contains(expected) == false)
        #expect(selection.selectedID == expected)
        await selection.refresh(in: context)
        #expect(selection.timelines.map(\.id) == [expected])
        await #expect(throws: TimelineOperationError.self) { try await TimelineStore.markDeleted(id: expected, in: context) }
    }

    @Test("A stale duplicate name and a newer store copy cannot revive a tombstoned timeline")
    func deletionWinsStaleMetadata() async throws {
        let first = PersistenceController(inMemory: true)
        let second = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(first)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(second)
        let source = first.container.viewContext
        let target = second.container.viewContext
        let id = try await TimelineStore.create(name: "Old", in: source)
        try await TimelineStore.markDeleted(id: id, in: source)
        let stale = Timeline(context: target)
        stale.id = id
        stale.name = "Stale rename"
        stale.modifiedAt = Date.distantFuture
        try target.save()
        try await TimelineLibraryCopy.merge(from: source, to: target)
        #expect(try await TimelineStore.state(in: target).deletedIDs.contains(id))
        #expect(try await TimelineStore.snapshots(in: target).contains { $0.id == id } == false)
        try await TimelineLibraryCopy.merge(from: target, to: source)
        await #expect(throws: TimelineOperationError.self) { try await TimelineStore.rename(id: id, to: "Revive", in: source) }
    }

    @Test("Previous timeline schemas preserve names, ownership, and existing synced deletion intents",
          arguments: ["progressWithTimelines", "progressWithTimelinesDeletion"])
    func existingNamedTimelinesMigrate(version: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NamedTimelineMigration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let bundle = try #require(Bundle(for: PersistenceController.self).url(forResource: "progress", withExtension: "momd"))
        let old = try #require(NSManagedObjectModel(contentsOf: bundle.appendingPathComponent(version + ".mom")))
        for entity in old.entities { entity.managedObjectClassName = "NSManagedObject" }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: old)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = coordinator
        let id = UUID()
        let timeline = NSEntityDescription.insertNewObject(forEntityName: "Timeline", into: oldContext)
        timeline.setValue(id, forKey: "id")
        timeline.setValue("Existing person", forKey: "name")
        let retiredID = UUID()
        let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)
        if version == "progressWithTimelinesDeletion" {
            let retired = NSEntityDescription.insertNewObject(forEntityName: "Timeline", into: oldContext)
            retired.setValue(retiredID, forKey: "id")
            retired.setValue(deletedAt, forKey: "deletedAt")
        }
        let photo = NSEntityDescription.insertNewObject(forEntityName: "DailyPhoto", into: oldContext)
        photo.setValue(UUID(), forKey: "id")
        photo.setValue(id, forKey: "timelineID")
        try oldContext.save()
        oldContext.reset()
        try coordinator.remove(store)

        let mode = PhotoStorageModeStore(storageURL: root.appendingPathComponent("mode.json"))
        let current = PersistenceController(storageModeStore: mode, storeURL: url, cloudEnabled: false)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(current)
        let context = current.container.viewContext
        let state = try await TimelineStore.state(in: context)
        #expect(state.deletedIDs == (version == "progressWithTimelinesDeletion" ? [retiredID] : []))
        let rows = try context.fetch(Timeline.fetchRequest())
        #expect(rows.allSatisfy { $0.localDeletedAt == nil })
        if version == "progressWithTimelinesDeletion" {
            #expect(rows.first { $0.id == retiredID }?.deletedAt == deletedAt)
        }
        #expect(state.timelines.first { $0.id == id }?.name == "Existing person")
        #expect(try context.fetch(DailyPhoto.fetchRequest()).first?.timelineID == id)
        context.reset()
        for store in current.container.persistentStoreCoordinator.persistentStores {
            try current.container.persistentStoreCoordinator.remove(store)
        }
    }

    @Test("Re-enabling iCloud cannot copy old Default photos over its deletion marker")
    func cloudPreparationHonorsDeletion() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        _ = addPhoto(owner: nil, name: "old-default.jpg", in: context)
        try context.save()
        let targetURL = library.root.appendingPathComponent("cloud.sqlite")
        let survivor = UUID()
        try await PhotoCloudLibraryPreparation.prepare(from: library.persistence.container, at: targetURL,
                                                      mirrorsCloud: false, loader: { target in
            try await PhotoCloudLibraryMergeTests.load(target)
            let kept = Timeline(context: target.viewContext)
            kept.id = survivor
            kept.name = "Survivor"
            let deleted = Timeline(context: target.viewContext)
            deleted.id = TimelineIdentity.defaultID
            deleted.deletedAt = Date()
            try target.viewContext.save()
        }, validateAccount: {})
        let target = NSPersistentContainer(name: "progress", managedObjectModel: library.persistence.container.managedObjectModel)
        target.persistentStoreDescriptions = [NSPersistentStoreDescription(url: targetURL)]
        try await PhotoCloudLibraryMergeTests.load(target)
        #expect(try target.viewContext.count(for: DailyPhoto.fetchRequest()) == 0)
        #expect(try await TimelineStore.snapshots(in: target.viewContext).map(\.id) == [survivor])
        target.viewContext.reset()
        for store in target.persistentStoreCoordinator.persistentStores { try target.persistentStoreCoordinator.remove(store) }
    }

    private func deletionService(_ library: PhotoStorageScenarioLibrary, reminders: DailyReminderNotificationService) -> TimelineDeletionService {
        TimelineDeletionService(photos: PhotoStorageService(cloudKitService: library.cloud,
                                                           remoteAssetDeletionService: library.remoteAssetDeletions),
                                reminders: reminders, guideDefaults: library.defaults, guideCloudStore: nil,
                                automaticallyReconciles: false)
    }

    private func addPhoto(owner: UUID?, name: String, in context: NSManagedObjectContext) -> DailyPhoto {
        let photo = DailyPhoto(context: context)
        photo.id = UUID()
        photo.timelineID = owner
        photo.captureDate = Date()
        photo.fullImageAssetName = name
        return photo
    }
}
