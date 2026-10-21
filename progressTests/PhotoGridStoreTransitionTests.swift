import Combine
import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct PhotoGridStoreTransitionTests {
    @Test("Enabling iCloud in an empty local library makes all three cloud photos visible",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func emptyLocalLibraryImportsCloudPhotos(deletedLocalPhotos: Bool) async throws {
        let ids = [UUID(), UUID(), UUID()]
        let library = try await PhotoStorageScenarioLibrary(empty: true, cloudLibraryLoader: { target in
            try await PhotoCloudLibraryMergeTests.load(target)
            for id in ids {
                PhotoCloudLibraryMergeTests.addPhoto(id, to: target.viewContext, location: "Retained cloud photo")
            }
            try target.viewContext.save()
        })
        defer { library.cleanup() }
        try library.modeStore.set(.local)
        let context = library.persistence.container.viewContext
        if deletedLocalPhotos {
            for id in ids {
                PhotoCloudLibraryMergeTests.addPhoto(id, to: context, location: "Local copy")
            }
            try context.save()
        }
        let grid = PhotoGridDataController()
        grid.configureIfNeeded(context: context, filter: .all)
        if deletedLocalPhotos {
            try #require(grid.photoCount == 3)
            let service = PhotoStorageService(cloudKitService: library.cloud,
                                              remoteAssetDeletionService: library.remoteAssetDeletions)
            _ = try await service.deletePhotos(grid.itemsSnapshot.map(\.objectID), context: context,
                                               deletesAssetsInBackground: false)
        }
        try #require(try context.count(for: DailyPhoto.fetchRequest()) == 0)
        try #require(!grid.hasAnyPhotos)
        let storage = library.coordinator()

        try await storage.beginICloudStorage()
        await storage.resumeAndWait()
        try #require(storage.errorMessage == nil, Comment(rawValue: storage.errorMessage ?? ""))
        #expect(storage.mode == .iCloud)
        await context.perform(schedule: .enqueued) { }

        #expect(try context.count(for: DailyPhoto.fetchRequest()) == 3)
        #expect(grid.hasAnyPhotos)
        #expect(!grid.isEmpty)
        #expect(grid.photoCount == 3)
        #expect(grid.totalPhotoCount == 3)
        #expect(Set(grid.allPhotos.compactMap(\.id)) == Set(ids))
        #expect(grid.photos(for: Set(grid.itemsSnapshot.map(\.objectID))).count == 3)
        #expect(library.cloud.uploadStateStore.allEntries().isEmpty)
        try await library.reopen()
        #expect(try library.persistence.container.viewContext.count(for: DailyPhoto.fetchRequest()) == 3)
    }

    @Test("All three photos can be selected and deleted immediately after switching to local storage",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func deleteSelectionAfterLocalSwitch(removeCloudCopies: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        for _ in 0..<2 {
            let id = UUID()
            PhotoCloudLibraryMergeTests.addPhoto(id, to: context, location: "Local selection regression")
            _ = try library.cloud.stageAssetData(Data("original \(id)".utf8), named: "\(id).heic")
        }
        try context.save()
        let grid = PhotoGridDataController()
        grid.configureIfNeeded(context: context, filter: .all)
        #expect(grid.photoCount == 3)

        let storage = library.coordinator()
        try await storage.beginLocalStorage(removeCloudCopies: removeCloudCopies)
        await storage.resumeAndWait()
        try #require(storage.errorMessage == nil, Comment(rawValue: storage.errorMessage ?? ""))
        #expect(storage.mode == .local)
        // Let already queued UI updates run, without favoriting a photo, saving
        // the context, or manually requesting an upload/grid refresh.
        await context.perform(schedule: .enqueued) { }

        let selection = Set(grid.itemsSnapshot.map(\.objectID))
        let selectedPhotos = grid.photos(for: selection)
        try #require(selectedPhotos.count == 3)
        let activeStores = library.persistence.container.persistentStoreCoordinator.persistentStores
        #expect(selectedPhotos.allSatisfy { photo in
            photo.objectID.persistentStore.map(activeStores.contains) ?? false
        })
        let service = PhotoStorageService(cloudKitService: library.cloud,
                                          remoteAssetDeletionService: library.remoteAssetDeletions)
        let count = try await service.deletePhotos(selectedPhotos.map(\.objectID), context: context,
                                                   deletesAssetsInBackground: false)
        #expect(count == 3)
        #expect(try context.count(for: DailyPhoto.fetchRequest()) == 0)
        #expect(grid.photoCount == 0)
        #expect(grid.itemsSnapshot.isEmpty)
    }

    @Test("The live grid survives enabling iCloud with three local photos and one matching cloud photo",
          .timeLimit(.minutes(1)))
    func uploadRefreshDuringStoreReplacement() async throws {
        let ids = [UUID(), UUID(), UUID()]
        let state = ImportState()
        let library = try await PhotoStorageScenarioLibrary(empty: true, cloudLibraryLoader: { target in
            try await PhotoCloudLibraryMergeTests.load(target)
            PhotoCloudLibraryMergeTests.addPhoto(ids[0], to: target.viewContext, location: "Matching cloud photo")
            try target.viewContext.save()
            // Force the same debounced upload notification from the crash log
            // while the old grid is retained and the replacement is importing.
            if let grid = state.grid { await Self.refreshUploadSnapshot(grid) }
        })
        defer { state.grid = nil; library.cleanup() }
        try library.modeStore.set(.local)
        let context = library.persistence.container.viewContext
        for id in ids {
            PhotoCloudLibraryMergeTests.addPhoto(id, to: context, location: "Local photo")
            _ = try library.cloud.stageAssetData(Data("original \(id)".utf8), named: "\(id).heic")
        }
        try context.save()
        let grid = PhotoGridDataController()
        state.grid = grid
        grid.configureIfNeeded(context: context, filter: .all)
        #expect(grid.photoCount == 3)
        let oldObjectIDs = Set(grid.itemsSnapshot.map(\.objectID))
        let thumbnails = PhotoThumbnailDataProvider(context: library.persistence.makeBackgroundContext())

        let storage = library.coordinator()
        try await storage.beginICloudStorage()
        await storage.resumeAndWait()
        try #require(storage.errorMessage == nil, Comment(rawValue: storage.errorMessage ?? ""))
        #expect(storage.mode == .iCloud)
        await context.perform(schedule: .enqueued) { }

        #expect(grid.photoCount == 3)
        #expect(grid.totalPhotoCount == 3)
        #expect(Set(grid.allPhotos.compactMap(\.id)) == Set(ids))
        #expect(grid.photos(for: oldObjectIDs).isEmpty)
        let activeStores = library.persistence.container.persistentStoreCoordinator.persistentStores
        #expect(grid.itemsSnapshot.allSatisfy { item in
            item.objectID.persistentStore.map(activeStores.contains) ?? false
        })
        for id in oldObjectIDs {
            #expect(await thumbnails.thumbnailData(for: id) == nil)
        }
        // Reconfiguring with the same context must keep using the new store.
        grid.configureIfNeeded(context: context, filter: .all)
        #expect(Set(grid.allStoredPhotos().compactMap(\.id)) == Set(ids))
    }

    @Test("The grid drops removed-store results and refetches when its store returns", .timeLimit(.minutes(1)))
    func temporarilyRemovedStore() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        let grid = PhotoGridDataController()
        grid.configureIfNeeded(context: context, filter: .all)
        #expect(grid.photoCount == 1)
        context.reset()
        for store in library.persistence.container.persistentStoreCoordinator.persistentStores {
            try library.persistence.container.persistentStoreCoordinator.remove(store)
        }
        await context.perform(schedule: .enqueued) { }
        #expect(grid.photoCount == 0)
        #expect(grid.totalPhotoCount == 0)
        #expect(grid.itemsSnapshot.isEmpty)
        #expect(grid.allPhotos.isEmpty)
        #expect(grid.allStoredPhotos().isEmpty)
        grid.setFilter(.hearted)

        try await library.persistence.reloadCloudConfiguration(cloudEnabled: false)
        await context.perform(schedule: .enqueued) { }
        #expect(grid.photoCount == 1)
        #expect(grid.heartedPhotoCount == 1)
        #expect(grid.allPhotos.first?.id == library.photoID)
    }

    @Test("Reconfiguring the same grid for a different context replaces its fetched results")
    func differentContext() throws {
        let first = PersistenceController(inMemory: true)
        let second = PersistenceController(inMemory: true)
        let firstPhoto = DailyPhoto(context: first.container.viewContext)
        firstPhoto.id = UUID()
        firstPhoto.isHearted = true
        try first.container.viewContext.save()
        let secondID = UUID()
        let secondPhoto = DailyPhoto(context: second.container.viewContext)
        secondPhoto.id = secondID
        secondPhoto.isHearted = true
        try second.container.viewContext.save()
        let grid = PhotoGridDataController()
        grid.configureIfNeeded(context: first.container.viewContext, filter: .hearted)
        grid.configureIfNeeded(context: second.container.viewContext, filter: .hearted)
        #expect(grid.photoCount == 1)
        #expect(grid.allPhotos.first?.id == secondID)
        #expect(grid.itemsSnapshot.first?.objectID == secondPhoto.objectID)
    }

    static func refreshUploadSnapshot(_ grid: PhotoGridDataController) async {
        let token = grid.changeToken
        NotificationCenter.default.post(name: LocalPhotoUploadStore.didChangeNotification, object: nil)
        for await _ in grid.$changeToken.first(where: { $0 > token }).values { break }
    }

    @MainActor private final class ImportState {
        var grid: PhotoGridDataController?
    }
}
