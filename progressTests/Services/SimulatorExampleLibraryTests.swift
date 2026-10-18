#if DEBUG && targetEnvironment(simulator)
import CoreData
import Foundation
import Testing
import UIKit
@testable import progress

@MainActor
struct SimulatorExampleLibraryTests {
    @Test("Examples preserve dates and Live Photo pairing without creating uploads")
    func seedsExportedPhotos() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await SimulatorExampleLibrary.seed(in: fixture.context, from: fixture.root)

        let photos = try fixture.context.fetch(DailyPhoto.fetchRequest())
        #expect(photos.count == 2)
        let live = try #require(photos.first { $0.livePhotoVideoAssetName != nil })
        let still = try #require(photos.first { $0.livePhotoVideoAssetName == nil })
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: try #require(live.captureDate))
        #expect(components.year == 2026)
        #expect(components.month == 10)
        #expect(components.day == 1)
        #expect(components.hour == 7)
        #expect(components.minute == 50)
        #expect(components.second == 0)
        #expect(live.fullImageAssetName == live.livePhotoImageAssetName)
        #expect(live.livePhotoVideoAssetName?.hasPrefix("simulator-example-") == true)
        #expect(live.thumbnailData?.isEmpty == false)
        #expect(still.livePhotoImageAssetName == nil)
        #expect(live.id != UUID(uuidString: fixture.liveID))
        #expect(LocalPhotoUploadStore.shared.entry(for: try #require(live.id)) == nil)
    }

    @Test("Relaunch restores missing examples while retaining edits and unrelated photos")
    func reseedingPreservesEdits() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await SimulatorExampleLibrary.seed(in: fixture.context, from: fixture.root)
        let initial = try fixture.context.fetch(DailyPhoto.fetchRequest())
        let favorite = try #require(initial.first { $0.livePhotoVideoAssetName != nil })
        favorite.isHearted = true
        favorite.isFavoriteLivePhoto = true
        let removed = try #require(initial.first { $0.livePhotoVideoAssetName == nil })
        let removedID = removed.id
        fixture.context.delete(removed)
        let unrelated = DailyPhoto(context: fixture.context)
        unrelated.id = UUID()
        unrelated.isHiddenFromVideo = true
        try fixture.context.save()

        try await SimulatorExampleLibrary.seed(in: fixture.context, from: fixture.root)
        try await SimulatorExampleLibrary.seed(in: fixture.context, from: fixture.root)
        let photos = try fixture.context.fetch(DailyPhoto.fetchRequest())
        #expect(photos.count == 3)
        #expect(favorite.isHearted)
        #expect(favorite.isFavoriteLivePhoto)
        #expect(unrelated.isHiddenFromVideo)
        #expect(photos.contains { $0.id == removedID })
        #expect(photos.contains { $0.id == unrelated.id })
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SimulatorExamplesTests-\(UUID())")
        let persistence = PersistenceController(inMemory: true)
        let liveID = "10992C41-353E-4495-824C-19E2146121BA"
        var context: NSManagedObjectContext { persistence.container.viewContext }

        init() throws {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
            let data = try #require(image.jpegData(compressionQuality: 0.8))
            for (id, date) in [(liveID, "1.10.2026_7:50:00"), ("5721E5DB-A832-440A-AEE9-0EB96EFFBBCC", "30.7.2026_21:00:24")] {
                let folder = root.appendingPathComponent("photo_\(date)_\(id)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("\(id)_still.jpg"))
                if id == liveID {
                    try Data("paired movie fixture".utf8).write(to: folder.appendingPathComponent("\(id)_livePhotoVideo.mov"))
                }
            }
        }

        func removeFiles() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
#endif
