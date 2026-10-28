import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct TimelineMigrationTests {
    @Test("Timeline discovery supplies a virtual default and coalesces duplicate cloud metadata")
    func timelineMetadataUsesLogicalIdentity() async throws {
        let persistence = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        let context = persistence.container.viewContext
        let initial = try await TimelineStore.snapshots(in: context)
        #expect(initial.map(\.id) == [TimelineIdentity.defaultID])
        #expect(try context.count(for: Timeline.fetchRequest()) == 0)

        let id = try await TimelineStore.create(name: "  Another person  ", in: context)
        let row = try #require(try context.fetch(Timeline.fetchRequest()).first)
        #expect(row.id == id)
        #expect(row.name == "Another person")
        row.modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        addTimeline(id, name: "Newer cloud name", modifiedAt: Date(timeIntervalSince1970: 1_700_000_100), to: context)
        try context.save()
        let snapshots = try await TimelineStore.snapshots(in: context)
        #expect(snapshots.count == 2)
        #expect(snapshots.first?.id == TimelineIdentity.defaultID)
        #expect(snapshots.first { $0.id == id }?.name == "Newer cloud name")

        try await TimelineStore.rename(id: id, to: " Updated person ", in: context)
        let rows = try context.fetch(Timeline.fetchRequest())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.name == "Updated person" })
        try await TimelineStore.rename(id: TimelineIdentity.defaultID, to: "Me", in: context)
        try await TimelineStore.rename(id: TimelineIdentity.defaultID, to: "Myself", in: context)
        let renamed = try await TimelineStore.snapshots(in: context)
        #expect(renamed.first?.name == "Myself")
        #expect(renamed.count == 2)
        #expect(try context.count(for: Timeline.fetchRequest()) == 3)
    }

    @Test("Previous SQLite models migrate without rewriting the existing library",
          arguments: ["progress", "progressVideoVisibility", "progressWithTimelines", "progressWithTimelinesDeletion", "progressWithTimelinesDeletionScope", "progressWithTimelinesLivePhotos"])
    func existingLibraryMigrates(modelVersion: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TimelineMigration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("library.sqlite")
        let modeStore = PhotoStorageModeStore(storageURL: root.appendingPathComponent("mode.json"))
        try modeStore.set(.local)
        let photoID = UUID()
        let captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        let originalBytes = Data(repeating: 0x71, count: 4_096)
        let thumbnail = Data([0x12, 0x34, 0x56])
        try writeLegacyLibrary(version: modelVersion, at: storeURL, photoID: photoID,
                               captureDate: captureDate, original: originalBytes, thumbnail: thumbnail)

        let persistence = PersistenceController(storageModeStore: modeStore, storeURL: storeURL, cloudEnabled: false)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        defer { close(persistence.container) }
        let context = persistence.container.viewContext
        let photo = try #require(try context.fetch(DailyPhoto.fetchRequest()).first)
        #expect(photo.id == photoID)
        #expect(photo.captureDate == captureDate)
        #expect(photo.fullImageData == originalBytes)
        #expect(photo.thumbnailData == thumbnail)
        #expect(photo.fullImageAssetName == "legacy-original.heic")
        #expect(photo.locationName == "Original location")
        #expect(photo.importFingerprint == "legacy-fingerprint")
        #expect(photo.latitude == 48.1)
        #expect(photo.longitude == 11.6)
        #expect(photo.isHearted)
        #expect(photo.isHiddenFromVideo == false)
        // Nil ownership is deliberately retained: old devices may still sync it.
        #expect(photo.timelineID == nil)
        #expect(photo.effectiveTimelineID == TimelineIdentity.defaultID)
        if modelVersion == "progressWithTimelinesLivePhotos" {
            let timeline = try #require(try context.fetch(Timeline.fetchRequest()).first)
            #expect(timeline.id == TimelineIdentity.defaultID)
            #expect(timeline.name == "Legacy timeline")
            #expect(timeline.livePhotoCaptureEnabled?.boolValue == false)
            #expect(timeline.livePhotoPreferenceModifiedAt == captureDate)
        } else {
            #expect(try context.fetch(Timeline.fetchRequest()).allSatisfy { $0.livePhotoPreference == nil })
        }
        #expect(try context.fetch(Timeline.fetchRequest()).allSatisfy { $0.cameraPreference == nil })

        let otherTimelineID = UUID()
        let otherPhoto = DailyPhoto(context: context)
        otherPhoto.id = UUID()
        otherPhoto.timelineID = otherTimelineID
        let explicitDefaultPhoto = DailyPhoto(context: context)
        explicitDefaultPhoto.id = UUID()
        explicitDefaultPhoto.timelineID = TimelineIdentity.defaultID
        try context.save()
        let defaultRequest = DailyPhoto.fetchRequest()
        defaultRequest.predicate = TimelineIdentity.photoPredicate(for: TimelineIdentity.defaultID)
        #expect(try context.count(for: defaultRequest) == 2)
        let otherRequest = DailyPhoto.fetchRequest()
        otherRequest.predicate = TimelineIdentity.photoPredicate(for: otherTimelineID)
        #expect(try context.count(for: otherRequest) == 1)

        close(persistence.container)
        let reopened = PersistenceController(storageModeStore: modeStore, storeURL: storeURL, cloudEnabled: false)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(reopened)
        defer { close(reopened.container) }
        let photos = try reopened.container.viewContext.fetch(DailyPhoto.fetchRequest())
        #expect(photos.count == 3)
        let restoredLegacyPhoto = try #require(photos.first { $0.id == photoID })
        #expect(restoredLegacyPhoto.fullImageData == originalBytes)
        #expect(restoredLegacyPhoto.timelineID == nil)
        #expect(restoredLegacyPhoto.effectiveTimelineID == TimelineIdentity.defaultID)
        #expect(photos.filter { $0.effectiveTimelineID == otherTimelineID }.count == 1)
        if modelVersion == "progressWithTimelinesLivePhotos" {
            let timeline = try #require(try reopened.container.viewContext.fetch(Timeline.fetchRequest()).first)
            #expect(timeline.name == "Legacy timeline")
            #expect(timeline.livePhotoCaptureEnabled?.boolValue == false)
            #expect(timeline.cameraPreference == nil)
        }
    }

    @Test("Switching to a clean local store preserves timeline metadata and photo ownership")
    func localLibraryCopyPreservesTimelines() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        let timelineID = UUID()
        let photoID = UUID()
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_100)
        addTimeline(timelineID, name: "Another person", modifiedAt: modifiedAt, to: context)
        let preferenceRow = try #require(try context.fetch(Timeline.fetchRequest()).first)
        preferenceRow.livePhotoCaptureEnabled = false
        preferenceRow.livePhotoPreferenceModifiedAt = modifiedAt
        preferenceRow.cameraPositionRaw = "back"
        preferenceRow.cameraPreferenceModifiedAt = modifiedAt
        let photo = DailyPhoto(context: context)
        photo.id = photoID
        photo.timelineID = timelineID
        photo.fullImageAssetName = "timeline-original.heic"
        try context.save()

        let filename = try await library.persistence.copyLibraryForLocalStorage()
        let sourceURL = try #require(library.persistence.container.persistentStoreDescriptions.first?.url)
        let copied = try await open(at: sourceURL.deletingLastPathComponent().appendingPathComponent(filename),
                                    model: library.persistence.container.managedObjectModel)
        defer { close(copied) }
        let copiedPhoto = try #require(try copied.viewContext.fetch(DailyPhoto.fetchRequest()).first)
        #expect(copiedPhoto.id == photoID)
        #expect(copiedPhoto.timelineID == timelineID)
        let timelines = try copied.viewContext.fetch(Timeline.fetchRequest())
        let copiedTimeline = try #require(timelines.first { $0.id == timelineID })
        #expect(copiedTimeline.name == "Another person")
        #expect(copiedTimeline.modifiedAt == modifiedAt)
        #expect(copiedTimeline.livePhotoCaptureEnabled?.boolValue == false)
        #expect(copiedTimeline.livePhotoPreferenceModifiedAt == modifiedAt)
        #expect(copiedTimeline.cameraPreference == TimelineCameraPreference(position: .back, modifiedAt: modifiedAt))
    }

    @Test("Cloud library preparation retains cloud-only timelines and merges newer timeline metadata",
          arguments: [false, true])
    func cloudLibraryMergePreservesTimelines(cloudIsNewer: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let sharedTimelineID = UUID()
        let cloudOnlyTimelineID = UUID()
        let photoID = UUID()
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(100)
        let context = library.persistence.container.viewContext
        addTimeline(sharedTimelineID, name: "Local name", modifiedAt: cloudIsNewer ? older : newer, to: context)
        let localPreference = try #require(try context.fetch(Timeline.fetchRequest()).first)
        localPreference.livePhotoCaptureEnabled = false
        localPreference.livePhotoPreferenceModifiedAt = newer
        localPreference.cameraPositionRaw = "back"
        localPreference.cameraPreferenceModifiedAt = newer
        let photo = DailyPhoto(context: context)
        photo.id = photoID
        photo.timelineID = sharedTimelineID
        try context.save()
        let destinationURL = library.root.appendingPathComponent("merged.sqlite")

        try await PhotoCloudLibraryPreparation.prepare(from: library.persistence.container, at: destinationURL,
                                                      mirrorsCloud: false, loader: { target in
            try await PhotoCloudLibraryMergeTests.load(target)
            addTimeline(sharedTimelineID, name: "Cloud name", modifiedAt: cloudIsNewer ? newer : older, to: target.viewContext)
            addTimeline(cloudOnlyTimelineID, name: "Cloud-only timeline", modifiedAt: newer, to: target.viewContext)
            let cloudPreference = try #require(try target.viewContext.fetch(Timeline.fetchRequest()).first { $0.id == sharedTimelineID })
            cloudPreference.livePhotoCaptureEnabled = true
            cloudPreference.livePhotoPreferenceModifiedAt = older
            cloudPreference.cameraPositionRaw = "front"
            cloudPreference.cameraPreferenceModifiedAt = older
            try target.viewContext.save()
        }, validateAccount: {})

        let merged = try await open(at: destinationURL, model: library.persistence.container.managedObjectModel)
        defer { close(merged) }
        let timelines = try merged.viewContext.fetch(Timeline.fetchRequest())
        #expect(timelines.count == 2)
        #expect(timelines.first { $0.id == sharedTimelineID }?.name == (cloudIsNewer ? "Cloud name" : "Local name"))
        #expect(timelines.first { $0.id == cloudOnlyTimelineID }?.name == "Cloud-only timeline")
        #expect(timelines.first { $0.id == sharedTimelineID }?.livePhotoCaptureEnabled?.boolValue == false)
        #expect(timelines.first { $0.id == sharedTimelineID }?.livePhotoPreferenceModifiedAt == newer)
        #expect(timelines.first { $0.id == sharedTimelineID }?.cameraPreference == TimelineCameraPreference(position: .back, modifiedAt: newer))
        let restoredPhoto = try #require(try merged.viewContext.fetch(DailyPhoto.fetchRequest()).first)
        #expect(restoredPhoto.id == photoID)
        #expect(restoredPhoto.timelineID == sharedTimelineID)
    }

    private func writeLegacyLibrary(version: String, at url: URL, photoID: UUID, captureDate: Date,
                                    original: Data, thumbnail: Data) throws {
        let modelDirectory = try #require(Bundle(for: PersistenceController.self).url(forResource: "progress", withExtension: "momd"))
        let model = try #require(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("\(version).mom")))
        // Legacy objects must not run the current DailyPhoto insertion/save hooks.
        let entity = try #require(model.entitiesByName["DailyPhoto"])
        entity.managedObjectClassName = "NSManagedObject"
        if version == "progressWithTimelinesLivePhotos" {
            model.entitiesByName["Timeline"]?.managedObjectClassName = "NSManagedObject"
        }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: nil)
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let photo = NSManagedObject(entity: entity, insertInto: context)
        photo.setValue(photoID, forKey: "id")
        photo.setValue(captureDate, forKey: "captureDate")
        photo.setValue(captureDate, forKey: "createdAt")
        photo.setValue(captureDate, forKey: "modifiedAt")
        photo.setValue(original, forKey: "fullImageData")
        photo.setValue(thumbnail, forKey: "thumbnailData")
        photo.setValue("legacy-original.heic", forKey: "fullImageAssetName")
        photo.setValue("Original location", forKey: "locationName")
        photo.setValue("legacy-fingerprint", forKey: "importFingerprint")
        photo.setValue(48.1, forKey: "latitude")
        photo.setValue(11.6, forKey: "longitude")
        photo.setValue(true, forKey: "isHearted")
        if version == "progressWithTimelinesLivePhotos" {
            let timeline = NSEntityDescription.insertNewObject(forEntityName: "Timeline", into: context)
            timeline.setValue(TimelineIdentity.defaultID, forKey: "id")
            timeline.setValue("Legacy timeline", forKey: "name")
            timeline.setValue(false, forKey: "livePhotoCaptureEnabled")
            timeline.setValue(captureDate, forKey: "livePhotoPreferenceModifiedAt")
        }
        try context.save()
        context.reset()
    }

    private func addTimeline(_ id: UUID, name: String, modifiedAt: Date, to context: NSManagedObjectContext) {
        let timeline = Timeline(context: context)
        timeline.id = id
        timeline.name = name
        timeline.createdAt = modifiedAt
        timeline.modifiedAt = modifiedAt
    }

    private func open(at url: URL, model: NSManagedObjectModel) async throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "progress", managedObjectModel: model)
        container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
        try await PhotoCloudLibraryMergeTests.load(container)
        return container
    }

    private func close(_ container: NSPersistentContainer) {
        container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores {
            try? container.persistentStoreCoordinator.remove(store)
        }
    }
}
