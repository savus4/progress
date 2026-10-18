import CoreData
import Foundation
import Testing
import UIKit
@testable import progress

@MainActor
struct PhotoVideoVisibilityTests {
    @Test("Hide and unhide persist, clear favorites, and keep photos in the library")
    func visibilityAndFavorites() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let first = DailyPhoto(context: context)
        first.id = UUID()
        first.isHearted = true
        first.isFavoriteLivePhoto = true
        let second = DailyPhoto(context: context)
        second.id = UUID()
        try context.save()
        let ids = [first.objectID, second.objectID]
        let controller = PhotoGridDataController()
        controller.configureIfNeeded(context: context, filter: .all)

        #expect(first.isHiddenFromVideo == false)
        #expect(PhotoVideoVisibility.shouldHide([first, second]))
        try PhotoVideoVisibility.setHidden(true, for: [first], in: context)
        #expect(PhotoVideoVisibility.shouldHide([first, second]))
        #expect(PhotoVideoVisibility.shouldHide([first]) == false)
        #expect(first.isHearted == false)
        #expect(first.isFavoriteLivePhoto == false)
        #expect(first.modifiedAt != nil)
        #expect(controller.totalPhotoCount == 2)
        #expect(controller.heartedPhotoCount == 0)
        #expect(controller.favoriteLivePhotoCount == 0)
        controller.setFilter(.hidden)
        #expect(controller.photoCount == 1)
        #expect(controller.allPhotos.first?.objectID == first.objectID)
        #expect(controller.allStoredPhotos().count == 2)
        controller.setFilter(.all)
        #expect(controller.photoCount == 2)

        let gridItem = try #require(controller.itemsSnapshot.first { $0.objectID == first.objectID })
        #expect(gridItem.isHiddenFromVideo)
        #expect(PhotoDetailItem(gridItem: gridItem).isHiddenFromVideo)
        #expect(PortraitVideoExportItem(photo: first).isHiddenFromVideo)
        let cell = PhotoGridCollectionViewCell(frame: CGRect(x: 0, y: 0, width: 120, height: 160))
        cell.configure(with: gridItem, showsUploadStatus: false, isSelectionMode: false, isSelected: false)
        #expect(cell.accessibilityValue == "Hidden from video")
        let hiddenBadge = cell.contentView.subviews.compactMap { $0 as? UIImageView }
            .first { $0.accessibilityIdentifier == "photoGridHiddenFromVideoBadge" }
        #expect(hiddenBadge?.image != nil)
        #expect(hiddenBadge?.isHidden == false)

        // The model also prevents alternate save paths from favoriting a hidden photo.
        first.isHearted = true
        first.isFavoriteLivePhoto = true
        try context.save()
        #expect(first.isHearted == false)
        #expect(first.isFavoriteLivePhoto == false)

        try PhotoVideoVisibility.setHidden(true, for: [first, second], in: context)
        #expect(PhotoVideoVisibility.shouldHide([first, second]) == false)
        let reloadedContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reloadedContext.persistentStoreCoordinator = persistence.container.persistentStoreCoordinator
        let reloaded = try ids.map { try #require(reloadedContext.existingObject(with: $0) as? DailyPhoto) }
        #expect(reloaded.allSatisfy { $0.isHiddenFromVideo })
        try PhotoVideoVisibility.setHidden(false, for: reloaded, in: reloadedContext)
        #expect(reloaded.allSatisfy { !$0.isHiddenFromVideo && !$0.isHearted && !$0.isFavoriteLivePhoto })
        #expect(try reloadedContext.count(for: DailyPhoto.fetchRequest()) == 2)
    }

    @Test("Existing SQLite photos migrate with video inclusion and metadata intact")
    func migratesExistingPhotos() throws {
        let bundle = Bundle(for: PersistenceController.self)
        let modelDirectory = try #require(bundle.url(forResource: "progress", withExtension: "momd"))
        let sourceModel = try #require(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("progress.mom"))?.copy() as? NSManagedObjectModel)
        let destinationModel = try #require(NSManagedObjectModel(contentsOf: modelDirectory)?.copy() as? NSManagedObjectModel)
        // Migration fixtures use generic objects so extra models don't register DailyPhoto.
        for model in [sourceModel, destinationModel] {
            for entity in model.entities { entity.managedObjectClassName = "NSManagedObject" }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoVisibilityMigration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photos.sqlite")
        let sourceCoordinator = NSPersistentStoreCoordinator(managedObjectModel: sourceModel)
        let sourceStore = try sourceCoordinator.addPersistentStore(type: .sqlite, at: url)
        let sourceContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        sourceContext.persistentStoreCoordinator = sourceCoordinator
        let photo = NSEntityDescription.insertNewObject(forEntityName: "DailyPhoto", into: sourceContext)
        let id = UUID()
        let captureDate = Date(timeIntervalSince1970: 1_000_000)
        let thumbnail = Data([1, 2, 3])
        photo.setValue(id, forKey: "id")
        photo.setValue(captureDate, forKey: "captureDate")
        photo.setValue("existing.jpg", forKey: "fullImageAssetName")
        photo.setValue(thumbnail, forKey: "thumbnailData")
        photo.setValue(true, forKey: "isHearted")
        try sourceContext.save()
        sourceContext.reset()
        try sourceCoordinator.remove(sourceStore)

        let destinationCoordinator = NSPersistentStoreCoordinator(managedObjectModel: destinationModel)
        let destinationStore = try destinationCoordinator.addPersistentStore(
            type: .sqlite, at: url,
            options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true]
        )
        defer { try? destinationCoordinator.remove(destinationStore) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = destinationCoordinator
        let photos = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DailyPhoto"))
        #expect(photos.count == 1)
        let migrated = try #require(photos.first)
        #expect(migrated.value(forKey: "id") as? UUID == id)
        #expect(migrated.value(forKey: "captureDate") as? Date == captureDate)
        #expect(migrated.value(forKey: "fullImageAssetName") as? String == "existing.jpg")
        #expect(migrated.value(forKey: "thumbnailData") as? Data == thumbnail)
        #expect(migrated.value(forKey: "isHearted") as? Bool == true)
        #expect(migrated.value(forKey: "isHiddenFromVideo") as? Bool == false)
    }
}
