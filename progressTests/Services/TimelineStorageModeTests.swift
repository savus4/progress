import CloudKit
import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct TimelineStorageModeTests {
    @Test("Re-enabling sync restores kept timelines and photos, without restoring deleted reminders or local journals",
          arguments: [false, true])
    func keptCloudTimelineReturns(deletesDefault: Bool) async throws {
        let person = UUID()
        let owner = deletesDefault ? TimelineIdentity.defaultID : person
        let photoID = UUID()
        let name = "\(photoID).jpg"
        let library = try await PhotoStorageScenarioLibrary(empty: true, cloudLibraryLoader: { target in
            try await PhotoCloudLibraryMergeTests.load(target)
            Self.addTimeline(person, name: "Alex", in: target.viewContext)
            if deletesDefault { Self.addTimeline(owner, name: "Default", in: target.viewContext) }
            let preference = try #require(try target.viewContext.fetch(Timeline.fetchRequest()).first { $0.id == owner })
            preference.livePhotoCaptureEnabled = false
            preference.livePhotoPreferenceModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
            Self.addPhoto(photoID, owner: owner, name: name, in: target.viewContext)
            try target.viewContext.save()
        })
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        Self.addTimeline(person, name: "Alex", in: context)
        Self.addPhoto(photoID, owner: owner, name: name, in: context)
        try context.save()
        let bytes = Data("Kept cloud original".utf8)
        let serverURL = library.root.appendingPathComponent("server").appendingPathComponent(name)
        try bytes.write(to: serverURL)
        library.network.data[name] = bytes
        library.network.urls[name] = serverURL
        library.network.records.insert(CKRecord.ID(recordName: name))
        _ = try library.cloud.stageAssetData(bytes, named: name)
        let storage = library.coordinator()
        try await storage.beginLocalStorage(removeCloudCopies: false)
        await storage.resumeAndWait()
        try #require(storage.mode == .local)

        let reminders = DailyReminderNotificationService(defaults: library.defaults, context: context) { _ in true }
        #expect(await reminders.updateReminderTimes([DailyReminderTime(hour: 9, minute: 0)], timelineID: owner))
        let photos = PhotoStorageService(cloudKitService: library.cloud, remoteAssetDeletionService: library.remoteAssetDeletions)
        let deletion = TimelineDeletionService(photos: photos, reminders: reminders, guideDefaults: library.defaults,
                                               guideCloudStore: nil, automaticallyReconciles: false,
                                               storageModeStore: library.modeStore)
        try await deletion.delete(id: owner, in: context)
        try await deletion.reconcile(in: context)
        let marker = try #require(try context.fetch(Timeline.fetchRequest()).first { $0.id == owner })
        #expect(marker.deletedAt == nil)
        #expect(marker.localDeletedAt != nil)
        #expect(reminders.loadReminderTimes(timelineID: owner).isEmpty)
        #expect(try context.count(for: DailyPhoto.fetchRequest()) == 0)
        #expect(library.network.deleted.isEmpty)

        // A stale save and an active/crashed journal still belong to the removed local owner.
        let lateID = UUID()
        let lateName = "\(lateID).jpg"
        Self.addPhoto(lateID, owner: owner, name: lateName, in: context)
        _ = try library.cloud.stageAssetData(Data([1, 2, 3]), named: lateName)
        let journalID = UUID()
        let journalName = "\(journalID).jpg"
        _ = try library.cloud.stageAssetData(Data([4, 5, 6]), named: journalName)
        let entry = PendingUploadManifestEntry(photoID: journalID, captureDate: Date(), createdAt: Date(),
                                               latitude: 0, longitude: 0, fullImageAssetName: journalName,
                                               livePhotoVideoAssetName: nil, timelineID: owner)
        try await library.cloud.pendingUploadManifestService.record(entry)
        try library.cloud.uploadStateStore.register(entry.localUpload)
        let survivor = deletesDefault ? person : TimelineIdentity.defaultID
        try await TimelineStore.rename(id: survivor, to: "Local survivor", in: context)
        try context.save()

        try await storage.beginICloudStorage()
        await storage.resumeAndWait()
        try #require(storage.errorMessage == nil, Comment(rawValue: storage.errorMessage ?? ""))
        #expect(storage.mode == .iCloud)
        let state = try await TimelineStore.state(in: context)
        #expect(state.deletedIDs.isEmpty)
        #expect(Set(state.timelines.map(\.id)) == [TimelineIdentity.defaultID, person])
        #expect(state.timelines.first { $0.id == survivor }?.name == "Local survivor")
        #expect(state.timelines.first { $0.id == owner }?.livePhotoPreference?.isEnabled == false)
        #expect(try context.fetch(DailyPhoto.fetchRequest()).map(\.id) == [photoID])
        #expect(reminders.loadReminderTimes(timelineID: owner).isEmpty)
        #expect(library.cloud.uploadStateStore.entry(for: journalID) == nil)
        #expect(library.cloud.uploadStateStore.entry(for: lateID) == nil)
        #expect(await photos.recoverPendingUploadsFromManifest(context: context) == 0)
        await library.remoteAssetDeletions.processPendingDeletions(expeditingRetries: true)
        #expect(library.network.deleted.isEmpty)
        #expect(library.network.records.contains(CKRecord.ID(recordName: name)))

        _ = await reminders.refreshReminders().value
        #expect(reminders.loadReminderTimes(timelineID: owner).isEmpty)
        let freshTimes = [DailyReminderTime(hour: 11, minute: 0)]
        #expect(await reminders.updateReminderTimes(freshTimes, timelineID: owner))
        #expect(reminders.loadReminderTimes(timelineID: owner) == freshTimes)

        try await library.reopen()
        #expect(try await TimelineStore.state(in: library.persistence.container.viewContext).deletedIDs.isEmpty)
        #expect(try library.persistence.container.viewContext.fetch(DailyPhoto.fetchRequest()).map(\.id) == [photoID])
    }

    @Test("Bulk deletion keeps its device-only scope even if storage changes while uploads drain", arguments: [false, true])
    func localBulkDeletionDoesNotPromiseCloudCleanup(changesModeWhileDraining: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try library.modeStore.set(.local)
        let photos = PhotoStorageService(cloudKitService: library.cloud, remoteAssetDeletionService: library.remoteAssetDeletions)
        let result = try await photos.deleteAllPhotos(context: library.persistence.container.viewContext,
            operations: DeleteAllPhotosOperations(cancelPendingUploads: {}, waitUntilUploadsIdle: {
                if changesModeWhileDraining { try? library.modeStore.set(.iCloud) }
                return true
            },
                isLocalModeActive: { true }, waitForNextExportCompletion: { Issue.record("Local deletion waited for cloud export"); return .timedOut },
                deleteAssets: { names in
                    for name in names { await library.cloud.deleteAssetAndWait(named: name) }
                }, deleteAssetsAndWaitForRemoteCleanup: { _ in Issue.record("Local deletion requested cloud cleanup"); return [] }))
        #expect(result.deletedCount == 1)
        #expect(result.isDeviceOnly)
        #expect(!result.isCloudDeletionComplete)
        #expect(!result.isDeferredUntilICloudAvailable)
        #expect(result.pendingRemoteAssetDeletionCount == 0)
        #expect(try library.persistence.container.viewContext.count(for: DailyPhoto.fetchRequest()) == 0)
        #expect(library.network.deleted.isEmpty)
    }

    @Test("Local store copies retain removal markers, while synced deletion overrides local removal")
    func deletionScopeSurvivesCopies() async throws {
        let first = PersistenceController(inMemory: true)
        let second = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(first)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(second)
        let source = first.container.viewContext
        let target = second.container.viewContext
        let id = try await TimelineStore.create(name: "Alex", in: source)
        try await TimelineStore.markDeleted(id: id, in: source, storageMode: .local)
        try await TimelineLibraryCopy.merge(from: source, to: target)
        let copied = try #require(try target.fetch(Timeline.fetchRequest()).first { $0.id == id })
        #expect(copied.localDeletedAt != nil)
        #expect(copied.deletedAt == nil)
        #expect(try await TimelineStore.state(in: target).deletedIDs.contains(id))
        let permanentDate = Date(timeIntervalSince1970: 1_600_000_000)
        let original = try #require(try source.fetch(Timeline.fetchRequest()).first { $0.id == id })
        original.localDeletedAt = nil
        original.deletedAt = permanentDate
        original.modifiedAt = permanentDate
        try source.save()
        try await TimelineLibraryCopy.merge(from: source, to: target)
        let synced = try #require(try target.fetch(Timeline.fetchRequest()).first { $0.id == id })
        #expect(synced.deletedAt == permanentDate)
        #expect(synced.localDeletedAt == nil)
    }

    private static func addTimeline(_ id: UUID, name: String, in context: NSManagedObjectContext) {
        let row = Timeline(context: context)
        row.id = id; row.name = name
        row.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        row.modifiedAt = row.createdAt
    }

    private static func addPhoto(_ id: UUID, owner: UUID, name: String, in context: NSManagedObjectContext) {
        let photo = DailyPhoto(context: context)
        photo.id = id; photo.timelineID = owner
        photo.fullImageAssetName = name
        photo.captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        photo.createdAt = photo.captureDate; photo.modifiedAt = photo.captureDate
    }
}
