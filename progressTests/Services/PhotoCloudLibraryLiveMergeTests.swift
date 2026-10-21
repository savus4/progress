import CloudKit
import CoreData
import Foundation
import Testing
@testable import progress

/// Only the synthetic UUIDs created here are written or cleaned up. Existing account photos
/// may import into the test store but are never edited or deleted.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUN_LIVE_CLOUDKIT_TESTS"] == "1"))
@MainActor
struct PhotoCloudLibraryLiveMergeTests {
    @Test("Real iCloud restores retained cloud photos into empty, new, and overlapping local libraries while the grid is active",
          .timeLimit(.minutes(5)), arguments: [0, 1, 2])
    func restoresRetainedCloudPhotos(localPhotoCount: Int) async throws {
        try #require(StorageTestConfiguration.isIsolatedHost)
        let cloudContainer = CKContainer(identifier: CloudKitConfiguration.containerIdentifier)
        try #require(try await cloudContainer.accountStatus() == .available)
        let database = cloudContainer.privateCloudDatabase
        let overlappingLocalLibrary = localPhotoCount == 2
        let cloudIDs = overlappingLocalLibrary ? [UUID()] : [UUID(), UUID(), UUID()]
        let newLocalIDs = (0..<localPhotoCount).map { _ in UUID() }
        let ownIDs = Set(cloudIDs + newLocalIDs)
        var ownedRecords = Set<CKRecord.ID>()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveCloudMerge-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seedPreference = PhotoStorageModeStore(storageURL: root.appendingPathComponent("preference/mode.json"))
        let seed = PersistenceController(storageModeStore: seedPreference, storeURL: root.appendingPathComponent("seed.sqlite"))
        let library = try await PhotoStorageScenarioLibrary(empty: true, mirrorsCloud: true)

        do {
            try await PhotoStorageScenarioLibrary.waitUntilLoaded(seed)
            let seedMirror = try #require(seed.container as? NSPersistentCloudKitContainer)
            for id in cloudIDs {
                PhotoCloudLibraryMergeTests.addPhoto(id, to: seedMirror.viewContext, location: "StorageTests cloud original")
            }
            try seedMirror.viewContext.save()
            let seedPhotos = try seedMirror.viewContext.fetch(DailyPhoto.fetchRequest()).filter { $0.id.map(ownIDs.contains) ?? false }
            try await eventually("The synthetic photos did not reach iCloud") {
                for photo in seedPhotos {
                    guard let recordID = seedMirror.recordID(for: photo.objectID) else { return false }
                    ownedRecords.insert(recordID)
                    guard try await exists(recordID, in: database) else { return false }
                }
                return seedPhotos.count == cloudIDs.count
            }
            // Detach the seeder before exercising the app's actual switch path.
            detach(seed)

            let context = library.persistence.container.viewContext
            for id in cloudIDs {
                PhotoCloudLibraryMergeTests.addPhoto(id, to: context, location: "StorageTests cloud original")
                _ = try library.cloud.stageAssetData(Data("original \(id)".utf8), named: "\(id).heic")
            }
            try context.save()
            let grid = PhotoGridDataController()
            grid.configureIfNeeded(context: context, filter: .all)
            let storage = library.coordinator()
            try await storage.beginLocalStorage(removeCloudCopies: false)
            await storage.resumeAndWait()
            try #require(storage.mode == .local)
            let service = PhotoStorageService(cloudKitService: library.cloud, remoteAssetDeletionService: library.remoteAssetDeletions)
            if !overlappingLocalLibrary {
                for photo in try context.fetch(DailyPhoto.fetchRequest()) {
                    try await service.deletePhoto(photo.objectID, context: context)
                }
            }
            for localID in newLocalIDs {
                PhotoCloudLibraryMergeTests.addPhoto(localID, to: context, location: "StorageTests new local photo")
                _ = try library.cloud.stageAssetData(Data("new original".utf8), named: "\(localID).heic")
            }
            try context.save()
            await context.perform(schedule: .enqueued) { }
            #expect(grid.photoCount == (overlappingLocalLibrary ? 3 : localPhotoCount))
            try await storage.beginICloudStorage()
            await storage.resumeAndWait()
            try #require(storage.mode == .iCloud, Comment(rawValue: storage.errorMessage ?? "Switch did not finish"))
            let mirror = try #require(library.persistence.container as? NSPersistentCloudKitContainer)
            let photos = try context.fetch(DailyPhoto.fetchRequest()).filter { $0.id.map(ownIDs.contains) ?? false }
            #expect(photos.count == ownIDs.count)
            #expect(Set(photos.compactMap(\.id)) == ownIDs)
            for localID in newLocalIDs {
                #expect(library.cloud.uploadStateStore.entry(for: localID)?.state == .pending)
            }
            await context.perform(schedule: .enqueued) { }
            #expect(grid.hasAnyPhotos)
            #expect(!grid.isEmpty)
            #expect(Set(grid.allPhotos.compactMap(\.id)).isSuperset(of: ownIDs))
            let activeStores = mirror.persistentStoreCoordinator.persistentStores
            #expect(grid.itemsSnapshot.allSatisfy { $0.objectID.persistentStore.map(activeStores.contains) ?? false })
            for photo in photos where photo.id.map(cloudIDs.contains) ?? false {
                let recordID = try #require(mirror.recordID(for: photo.objectID))
                #expect(ownedRecords.contains(recordID), "Restored photos must keep their original server identities.")
                #expect(try await exists(recordID, in: database))
            }
            try await eventually("The new local photo did not export after merging") {
                for photo in photos where photo.id.map(newLocalIDs.contains) ?? false {
                    guard let id = mirror.recordID(for: photo.objectID) else { return false }
                    ownedRecords.insert(id)
                    guard try await exists(id, in: database) else { return false }
                }
                return true
            }
            #expect(ownedRecords.count == ownIDs.count)
        } catch {
            try await cleanup(seed: seed, library: library, root: root, ownIDs: ownIDs, records: ownedRecords, database: database)
            throw error
        }
        try await cleanup(seed: seed, library: library, root: root, ownIDs: ownIDs, records: ownedRecords, database: database)
    }

    private func eventually(_ message: String, condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(100))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw PhotoStorageMigrationError.attention(message)
    }

    private func exists(_ id: CKRecord.ID, in database: CKDatabase) async throws -> Bool {
        do { _ = try await database.record(for: id); return true }
        catch let error as CKError where error.code == .unknownItem { return false }
    }

    private func detach(_ persistence: PersistenceController) {
        persistence.container.viewContext.reset()
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try? persistence.container.persistentStoreCoordinator.remove(store)
        }
    }

    private func cleanup(seed: PersistenceController, library: PhotoStorageScenarioLibrary, root: URL,
                         ownIDs: Set<UUID>, records: Set<CKRecord.ID>, database: CKDatabase) async throws {
        var records = records
        for persistence in [seed, library.persistence] {
            if let mirror = persistence.container as? NSPersistentCloudKitContainer {
                for photo in (try? mirror.viewContext.fetch(DailyPhoto.fetchRequest())) ?? []
                    where photo.id.map(ownIDs.contains) ?? false {
                    if let id = mirror.recordID(for: photo.objectID) { records.insert(id) }
                }
            }
            detach(persistence)
        }
        if !records.isEmpty {
            let result = try await database.modifyRecords(saving: [], deleting: Array(records), atomically: false)
            for deletion in result.deleteResults.values {
                do { _ = try deletion.get() }
                catch let error as CKError where error.code == .unknownItem { }
            }
        }
        library.cleanup()
        try FileManager.default.removeItem(at: root)
    }
}
