import CoreData
import Foundation
import Testing
import UIKit
@testable import progress

@MainActor
final class PortraitVideoExportFixture {
    let directoryURL: URL
    let exportDirectoryURL: URL
    let sessionStorageKey: String
    let stagingStorageKey: String
    let configuration: PortraitVideoExportConfiguration
    private(set) var items: [PortraitVideoExportItem]
    private var container: NSPersistentContainer
    private let stagingDirectoryURL: URL
    private let model: NSManagedObjectModel
    lazy var service = makeService()

    init(
        photoCount: Int,
        hiddenIndices: Set<Int> = [],
        missingAssetIndices: Set<Int> = [],
        livePhotoIndices: Set<Int> = [],
        picturesPerSecond: Int = 30,
        reversesPhotoOrder: Bool = false
    ) throws {
        let fixtureID = UUID().uuidString
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportRecovery-\(fixtureID)", isDirectory: true)
        exportDirectoryURL = directoryURL.appendingPathComponent("exports", isDirectory: true)
        stagingDirectoryURL = directoryURL.appendingPathComponent("staging", isDirectory: true)
        sessionStorageKey = "export-recovery-\(fixtureID)"
        stagingStorageKey = "export-recovery-staging-\(fixtureID)"
        try FileManager.default.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
        model = PersistenceController(inMemory: true).container.managedObjectModel
        container = try Self.makeContainer(model: model, directoryURL: directoryURL)
        let context = container.viewContext
        let entity = try #require(model.entitiesByName["DailyPhoto"])
        let livePhotoData: Data?
        if livePhotoIndices.isEmpty {
            livePhotoData = nil
        } else {
            let url = try #require(Bundle(for: Self.self).url(forResource: "live-photo-audio", withExtension: "mov"))
            livePhotoData = try Data(contentsOf: url)
        }
        for index in 0..<photoCount {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 48)).image { renderer in
                UIColor(hue: CGFloat(index) / CGFloat(photoCount), saturation: 1, brightness: 1, alpha: 1).setFill()
                renderer.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
            }
            let assetName = "recovery-\(index).jpg"
            try #require(image.jpegData(compressionQuality: 0.8)).write(
                to: stagingDirectoryURL.appendingPathComponent(assetName)
            )
            let photo = DailyPhoto(entity: entity, insertInto: context)
            photo.id = UUID()
            photo.captureDate = Date(timeIntervalSince1970: Double(index) * 86_400)
            photo.fullImageAssetName = missingAssetIndices.contains(index) ? nil : assetName
            photo.isHiddenFromVideo = hiddenIndices.contains(index)
            if livePhotoIndices.contains(index), let livePhotoData {
                let movieName = "recovery-\(index).mov"
                try livePhotoData.write(to: stagingDirectoryURL.appendingPathComponent(movieName))
                photo.livePhotoVideoAssetName = movieName
                photo.isFavoriteLivePhoto = true
            }
        }
        try context.save()
        let exportItems = try Self.fetchItems(in: container)
        items = exportItems
        configuration = PortraitVideoExportConfiguration(
            picturesPerSecond: picturesPerSecond, quality: .compact,
            includesDateBanner: false, includesLocationBanner: false,
            includesFavoriteLivePhotoVideo: !livePhotoIndices.isEmpty, holdsHeartedPhotos: false,
            usesAllPhotos: true, startDate: exportItems[0].captureDate, endDate: exportItems[photoCount - 1].captureDate,
            reversesPhotoOrder: reversesPhotoOrder
        )
    }

    var orderedItems: [PortraitVideoExportItem] {
        configuration.reversesPhotoOrder ? Array(items.reversed()) : items
    }

    func reopen() throws {
        container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
        container = try Self.makeContainer(model: model, directoryURL: directoryURL)
        items = try Self.fetchItems(in: container)
        service = makeService()
    }

    func removeSources(for photos: some Sequence<PortraitVideoExportItem>) throws {
        for photo in photos {
            for name in [photo.fullImageAssetName, photo.livePhotoVideoAssetName].compactMap({ $0 }) {
                try FileManager.default.removeItem(at: stagingDirectoryURL.appendingPathComponent(name))
            }
        }
    }

    func pausedDirectory(for session: PortraitVideoExportPausedSession) -> URL {
        exportDirectoryURL.appendingPathComponent("paused_\(session.id.uuidString)", isDirectory: true)
    }

    func rewriteCheckpoint(_ edit: (inout [String: Any]) -> Void) throws {
        let data = try #require(UserDefaults.standard.data(forKey: sessionStorageKey))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        edit(&object)
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: object), forKey: sessionStorageKey)
    }

    func close() {
        service.discardPausedSession()
        container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores {
            try? container.persistentStoreCoordinator.remove(store)
        }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func makeService() -> PortraitVideoExportService {
        let cloud = CloudKitService(
            stagingDirectoryURL: stagingDirectoryURL,
            temporaryReadableAssetsDirectoryURL: directoryURL.appendingPathComponent("readable-\(UUID())"),
            legacyAssetDirectoryURLs: [],
            assetURLLoader: { _ in throw CloudKitError.assetNotFound }
        )
        return PortraitVideoExportService(
            cloudKitService: cloud, exportDirectoryURL: exportDirectoryURL,
            pausedSessionStorageKey: sessionStorageKey, pausedSessionStagingStorageKey: stagingStorageKey
        )
    }

    private static func makeContainer(model: NSManagedObjectModel, directoryURL: URL) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "progress", managedObjectModel: model)
        _ = try container.persistentStoreCoordinator.addPersistentStore(
            type: .sqlite, at: directoryURL.appendingPathComponent("photos.sqlite")
        )
        return container
    }

    private static func fetchItems(in container: NSPersistentContainer) throws -> [PortraitVideoExportItem] {
        let request = DailyPhoto.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "captureDate", ascending: true)]
        return try container.viewContext.fetch(request).map(PortraitVideoExportItem.init(photo:))
    }
}
