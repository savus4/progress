import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct TimelineGridTests {
    @Test("Timeline switching scopes grid counts, filters, selections, and complete exports")
    func timelineSwitchReplacesEveryPhotoScope() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let otherID = UUID()
        let legacy = addPhoto(timelineID: nil, hearted: true, favoriteLivePhoto: true, to: context)
        let explicitDefault = addPhoto(timelineID: TimelineIdentity.defaultID, to: context)
        let otherVisible = addPhoto(timelineID: otherID, hearted: true, to: context)
        let otherHidden = addPhoto(timelineID: otherID, hidden: true, to: context)
        try context.save()

        let grid = PhotoGridDataController()
        grid.configureIfNeeded(context: context, filter: .all)
        #expect(grid.totalPhotoCount == 2)
        #expect(grid.photoCount == 2)
        #expect(grid.heartedPhotoCount == 1)
        #expect(grid.favoriteLivePhotoCount == 1)
        #expect(Set(grid.itemsSnapshot.map(\.objectID)) == [legacy.objectID, explicitDefault.objectID])
        grid.setFilter(.hearted)
        #expect(grid.allPhotos.map(\.objectID) == [legacy.objectID])
        #expect(Set(grid.allStoredPhotos().map(\.objectID)) == [legacy.objectID, explicitDefault.objectID])

        grid.configureIfNeeded(context: context, filter: .all, timelineID: otherID)
        #expect(grid.timelineID == otherID)
        #expect(grid.totalPhotoCount == 2)
        #expect(grid.photoCount == 2)
        #expect(grid.heartedPhotoCount == 1)
        #expect(grid.favoriteLivePhotoCount == 0)
        #expect(Set(grid.itemsSnapshot.map(\.objectID)) == [otherVisible.objectID, otherHidden.objectID])
        #expect(grid.photos(for: [legacy.objectID, explicitDefault.objectID]).isEmpty)
        #expect(grid.index(of: legacy.objectID) == nil)
        grid.setFilter(.hidden)
        #expect(grid.allPhotos.map(\.objectID) == [otherHidden.objectID])
        // Export-all bypasses the visual filter, but retains timeline ownership.
        #expect(Set(grid.allStoredPhotos().map(\.objectID)) == [otherVisible.objectID, otherHidden.objectID])
        grid.setFilter(.favoriteLivePhotos)
        #expect(grid.isEmpty)
        #expect(grid.hasAnyPhotos)

        grid.configureIfNeeded(context: context, filter: .all, timelineID: UUID())
        #expect(grid.isEmpty)
        #expect(grid.hasAnyPhotos == false)
        #expect(grid.totalPhotoCount == 0)
        #expect(grid.allStoredPhotos().isEmpty)
        grid.configureIfNeeded(context: context, filter: .all)
        #expect(grid.totalPhotoCount == 2)
        #expect(Set(grid.allPhotos.map(\.objectID)) == [legacy.objectID, explicitDefault.objectID])
    }

    @Test("Live fetched results track photo ownership changes without showing other timelines")
    func fetchedResultsTrackOwnershipChanges() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let otherID = UUID()
        let defaultPhoto = addPhoto(timelineID: nil, to: context)
        let otherPhoto = addPhoto(timelineID: otherID, to: context)
        try context.save()
        let grid = PhotoGridDataController()
        grid.configureIfNeeded(context: context, filter: .all, timelineID: otherID)
        #expect(grid.allPhotos.map(\.objectID) == [otherPhoto.objectID])

        defaultPhoto.timelineID = otherID
        try context.save()
        await context.perform(schedule: .enqueued) {}
        #expect(grid.totalPhotoCount == 2)
        #expect(Set(grid.allPhotos.map(\.objectID)) == [defaultPhoto.objectID, otherPhoto.objectID])
        otherPhoto.timelineID = TimelineIdentity.defaultID
        try context.save()
        await context.perform(schedule: .enqueued) {}
        #expect(grid.totalPhotoCount == 1)
        #expect(grid.allPhotos.map(\.objectID) == [defaultPhoto.objectID])
    }

    @Test("Store replacement keeps the selected timeline through automatic refetch")
    func replacementStoreRetainsTimelineScope() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        let selectedID = UUID()
        let selectedPhoto = addPhoto(timelineID: selectedID, hearted: true, to: context)
        let photoID = try #require(selectedPhoto.id)
        _ = addPhoto(timelineID: nil, hearted: true, to: context)
        try context.save()
        let grid = PhotoGridDataController()
        grid.configureIfNeeded(context: context, filter: .hearted, timelineID: selectedID)
        #expect(grid.photoCount == 1)

        context.reset()
        for store in library.persistence.container.persistentStoreCoordinator.persistentStores {
            try library.persistence.container.persistentStoreCoordinator.remove(store)
        }
        await context.perform(schedule: .enqueued) {}
        #expect(grid.allPhotos.isEmpty)
        grid.setFilter(.all)
        try await library.persistence.reloadCloudConfiguration(cloudEnabled: false)
        await context.perform(schedule: .enqueued) {}

        #expect(grid.timelineID == selectedID)
        #expect(grid.totalPhotoCount == 1)
        #expect(grid.allPhotos.compactMap(\.id) == [photoID])
        #expect(grid.allStoredPhotos().compactMap(\.id) == [photoID])
    }

    @discardableResult
    private func addPhoto(timelineID: UUID?, hearted: Bool = false, favoriteLivePhoto: Bool = false,
                          hidden: Bool = false, to context: NSManagedObjectContext) -> DailyPhoto {
        let photo = DailyPhoto(context: context)
        photo.id = UUID()
        photo.timelineID = timelineID
        photo.captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        photo.isHearted = hearted
        photo.isFavoriteLivePhoto = favoriteLivePhoto
        photo.isHiddenFromVideo = hidden
        return photo
    }
}
