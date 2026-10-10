import CoreData
import Foundation
import Testing
import UIKit
@testable import progress

@MainActor
struct LegacyOriginalAndUploadOwnershipTests {
    @Test("An upgraded photo can read and stage its legacy Core Data original")
    func readsLegacyStillBlob() async throws {
        let fixture = try StorageFixture()
        defer { fixture.removeFiles() }
        let photo = fixture.makePhoto(state: .uploaded)
        let original = try makeJPEG()
        photo.fullImageData = original
        try fixture.context.save()

        let image = try await fixture.storage.loadFullImage(from: photo)

        #expect(image.size == CGSize(width: 40, height: 30))
        let name = try #require(photo.fullImageAssetName)
        let staged = try #require(fixture.cloud.stagedAssetURL(named: name))
        #expect(try Data(contentsOf: staged) == original)
        #expect(photo.fullImageData == original, "Keep the original until remote upload is confirmed.")
    }

    @Test("Legacy Live Photo image and video blobs are recovered independently")
    func readsLegacyLivePhotoBlobs() async throws {
        let fixture = try StorageFixture()
        defer { fixture.removeFiles() }
        let photo = fixture.makePhoto(state: .uploaded)
        let imageData = try makeJPEG()
        let videoData = Data("legacy paired video".utf8)
        photo.livePhotoImageAssetName = "\(UUID().uuidString).jpeg"
        photo.livePhotoVideoAssetName = "\(UUID().uuidString).mov"
        photo.livePhotoImageData = imageData
        photo.fullImageData = imageData
        photo.livePhotoVideoData = videoData
        try fixture.context.save()

        let resources = try await fixture.storage.loadLivePhotoResources(from: photo)

        #expect(try Data(contentsOf: resources.imageURL) == imageData)
        #expect(try Data(contentsOf: resources.videoURL) == videoData)
        let imageName = try #require(photo.livePhotoImageAssetName)
        let videoName = try #require(photo.livePhotoVideoAssetName)
        #expect(fixture.cloud.stagedAssetURL(named: imageName) != nil)
        #expect(fixture.cloud.stagedAssetURL(named: videoName) != nil)
        #expect(photo.livePhotoImageData == imageData)
        #expect(photo.livePhotoVideoData == videoData)
    }

    @Test("Older filesystem assets migrate to staging without deleting the only original")
    func readsAndStagesLegacyFilesystemAsset() async throws {
        let fixture = try StorageFixture()
        defer { fixture.removeFiles() }
        let name = "\(UUID().uuidString).jpeg"
        let original = try makeJPEG()
        let legacyURL = fixture.legacyDirectory.appendingPathComponent(name)
        try original.write(to: legacyURL)

        let readable = try await fixture.cloud.loadAssetURL(named: name)

        #expect(try Data(contentsOf: readable) == original)
        let staged = try #require(fixture.cloud.stagedAssetURL(named: name))
        #expect(try Data(contentsOf: staged) == original)
        #expect(try Data(contentsOf: legacyURL) == original)
    }

    @Test("A mirrored pending record without a local original is never claimed or mutated")
    func ignoresRemotePendingRecord() async throws {
        let fixture = try StorageFixture()
        defer { fixture.removeFiles() }
        let photo = fixture.makePhoto(state: .pending)
        photo.uploadAttemptCount = 4
        photo.uploadErrorMessage = "Owner's previous failure"
        try fixture.context.save()
        let uploader = PhotoUploadService(cloudKitService: fixture.cloud)

        let claimed = await uploader.claimNextPendingUploadForTesting(in: fixture.context)

        #expect(claimed == nil)
        #expect(photo.uploadStateRaw == PhotoUploadState.pending.rawValue)
        #expect(photo.uploadAttemptCount == 4)
        #expect(photo.uploadErrorMessage == "Owner's previous failure")
    }

    @Test("A local staged original remains uploadable when mirrored bookkeeping says paused")
    func claimsLocalOriginalDespiteRemotePause() async throws {
        let fixture = try StorageFixture()
        defer { fixture.removeFiles() }
        let photo = fixture.makePhoto(state: .paused)
        photo.uploadAttemptCount = .max
        photo.uploadErrorMessage = "Another device couldn't find the asset"
        try fixture.context.save()
        let name = try #require(photo.fullImageAssetName)
        _ = try fixture.cloud.stageAssetData(try makeJPEG(), named: name, includesInBackup: true)
        let uploader = PhotoUploadService(cloudKitService: fixture.cloud)

        let claimed = await uploader.claimNextPendingUploadForTesting(in: fixture.context)

        #expect(claimed == photo.objectID)
        #expect(photo.uploadStateRaw == PhotoUploadState.paused.rawValue)
        #expect(photo.uploadAttemptCount == .max)
        #expect(photo.uploadErrorMessage == "Another device couldn't find the asset")
    }

    @Test("A failed camera save removes its inserted row before retry while preserving other edits")
    func failedCaptureSaveCanRetryWithoutDuplicate() async throws {
        let fixture = try StorageFixture()
        defer { fixture.removeFiles() }
        let context = FailingCaptureSaveContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = fixture.persistence.container.persistentStoreCoordinator
        let unrelated = DailyPhoto(context: context)
        unrelated.id = UUID()
        let data = try makeJPEG()
        let image = try #require(UIImage(data: data))

        await #expect(throws: CaptureSaveTestError.self) {
            _ = try await fixture.storage.savePhoto(
                image: image, imageData: data, location: nil,
                context: context, enqueuesPendingUpload: false
            )
        }
        #expect(context.insertedObjects == Set<NSManagedObject>([unrelated]))
        #expect(fixture.cloud.uploadStateStore.allEntries().isEmpty)

        _ = try await fixture.storage.savePhoto(
            image: image, imageData: data, location: nil,
            context: context, enqueuesPendingUpload: false
        )
        #expect(try context.count(for: DailyPhoto.fetchRequest()) == 2)
    }

    @Test("The pager's name-based read recovers an original arriving after startup")
    func namedReadRecoversLegacyBlob() async throws {
        let fixture = try StorageFixture()
        defer { fixture.removeFiles() }
        let photo = fixture.makePhoto(state: .uploaded)
        let data = try makeJPEG()
        photo.fullImageData = data
        try fixture.context.save()

        let image = try await fixture.storage.loadFullImage(named: photo.fullImageAssetName)

        #expect(image.size == CGSize(width: 40, height: 30))
        #expect(photo.fullImageData == data)
        let id = try #require(photo.id)
        #expect(fixture.cloud.uploadStateStore.entry(for: id)?.state == .pending)
    }

    @Test("Backfill keeps all legacy Live originals and persists upload ownership across restart")
    func backfillPersistsCompleteLivePhotoOwnership() async throws {
        let fixture = try StorageFixture()
        defer { fixture.removeFiles() }
        let photo = fixture.makePhoto(state: .paused)
        photo.fullImageData = try makeJPEG()
        photo.livePhotoImageAssetName = "\(UUID()).jpeg"
        photo.livePhotoImageData = try makeJPEG()
        photo.livePhotoVideoAssetName = "\(UUID()).mov"
        photo.livePhotoVideoData = Data("paired original".utf8)
        photo.uploadAttemptCount = .max
        try fixture.context.save()
        #expect(await fixture.storage.countPhotosMissingSyncedPayloads(context: fixture.context) == 1)

        let result = await fixture.storage.backfillMissingSyncedPayloads(context: fixture.context)

        #expect(result.migratedCount == 1)
        #expect(result.failedCount == 0)
        #expect(await fixture.storage.countPhotosMissingSyncedPayloads(context: fixture.context) == 0)
        let reloaded = LocalPhotoUploadStore(storageURL: fixture.root.appendingPathComponent("local-uploads.json"))
        let id = try #require(photo.id)
        let entry = try #require(reloaded.entry(for: id))
        #expect(entry.state == .pending)
        #expect(entry.attemptCount == 0)
        #expect(entry.assetNames.count == 3)
        #expect(entry.assetNames.allSatisfy { fixture.cloud.stagedAssetURL(named: $0) != nil })
        #expect(photo.fullImageData != nil && photo.livePhotoImageData != nil && photo.livePhotoVideoData != nil)
        #expect(photo.uploadStateRaw == PhotoUploadState.paused.rawValue)
        #expect(photo.uploadAttemptCount == .max)
    }

    @Test("A partial Live upload retains all originals, retries after restart, and never edits mirrored state")
    func partialLiveUploadKeepsOriginalsUntilDurableSuccess() async throws {
        let recorder = UploadRecorder()
        let fixture = try StorageFixture(assetUploader: { name, _, role in
            try recorder.upload(name: name, role: role)
        })
        defer { fixture.removeFiles() }
        let photo = fixture.makePhoto(state: .paused)
        photo.livePhotoImageAssetName = "\(UUID()).jpeg"
        photo.livePhotoVideoAssetName = "\(UUID()).mov"
        photo.uploadAttemptCount = .max
        photo.uploadErrorMessage = "Another device's error"
        try fixture.context.save()
        let names = [photo.fullImageAssetName, photo.livePhotoImageAssetName, photo.livePhotoVideoAssetName].compactMap { $0 }
        for name in names { _ = try fixture.cloud.stageAssetData(Data(name.utf8), named: name) }
        let uploader = PhotoUploadService(cloudKitService: fixture.cloud)

        await #expect(throws: CloudKitError.self) {
            _ = try await uploader.uploadNextPendingPhotoForTesting(in: fixture.context)
        }

        #expect(names.allSatisfy { fixture.cloud.stagedAssetURL(named: $0) != nil })
        let id = try #require(photo.id)
        let reloaded = LocalPhotoUploadStore(storageURL: fixture.root.appendingPathComponent("local-uploads.json"))
        #expect(reloaded.entry(for: id)?.state == .failed)
        #expect(reloaded.entry(for: id)?.attemptCount == 1)
        try reloaded.update(photoID: id) { $0.retryAfter = .distantPast }
        let restartedCloud = CloudKitService(
            stagingDirectoryURL: fixture.root.appendingPathComponent("Staging", isDirectory: true),
            temporaryReadableAssetsDirectoryURL: fixture.root.appendingPathComponent("Readable", isDirectory: true),
            legacyAssetDirectoryURLs: [], uploadStateStore: reloaded,
            assetUploader: { name, _, role in try recorder.upload(name: name, role: role) }
        )
        let restartedUploader = PhotoUploadService(cloudKitService: restartedCloud)

        #expect(try await restartedUploader.uploadNextPendingPhotoForTesting(in: fixture.context))

        #expect(names.allSatisfy { restartedCloud.stagedAssetURL(named: $0) == nil })
        let completed = LocalPhotoUploadStore(storageURL: fixture.root.appendingPathComponent("local-uploads.json"))
        #expect(completed.entry(for: id)?.state == .uploaded)
        #expect(completed.entry(for: id)?.attemptCount == 2)
        #expect(recorder.roles == [.still, .livePhotoImage, .livePhotoVideo, .still, .livePhotoImage, .livePhotoVideo])
        #expect(photo.uploadStateRaw == PhotoUploadState.paused.rawValue)
        #expect(photo.uploadAttemptCount == .max)
        #expect(photo.uploadErrorMessage == "Another device's error")
        #expect(!fixture.context.hasChanges)
    }

    private final class UploadRecorder {
        var roles: [PhotoAssetRole] = []
        private var didFailVideo = false

        func upload(name: String, role: PhotoAssetRole) throws {
            roles.append(role)
            if role == .livePhotoVideo, !didFailVideo {
                didFailVideo = true
                throw CloudKitError.uploadFailed
            }
        }
    }

    private func makeJPEG() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return try #require(image.jpegData(compressionQuality: 0.9))
    }

    private struct StorageFixture {
        let root: URL
        let legacyDirectory: URL
        let persistence: PersistenceController
        let cloud: CloudKitService
        let storage: PhotoStorageService
        var context: NSManagedObjectContext { persistence.container.viewContext }

        init(assetUploader: (@MainActor @Sendable (String, UUID, PhotoAssetRole) async throws -> Void)? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyOriginalTests-\(UUID().uuidString)", isDirectory: true)
            legacyDirectory = root.appendingPathComponent("LegacyAssets", isDirectory: true)
            try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
            persistence = PersistenceController(inMemory: true)
            cloud = CloudKitService(
                stagingDirectoryURL: root.appendingPathComponent("Staging", isDirectory: true),
                temporaryReadableAssetsDirectoryURL: root.appendingPathComponent("Readable", isDirectory: true),
                legacyAssetDirectoryURLs: [legacyDirectory],
                assetURLLoader: { _ in throw CloudKitError.assetNotFound },
                assetUploader: assetUploader
            )
            storage = PhotoStorageService(cloudKitService: cloud, legacyRecoveryContext: persistence.container.viewContext)
        }

        func makePhoto(state: PhotoUploadState) -> DailyPhoto {
            let photo = DailyPhoto(context: context)
            photo.id = UUID()
            photo.createdAt = Date()
            photo.captureDate = Date()
            photo.fullImageAssetName = "\(UUID().uuidString).jpeg"
            photo.uploadStateRaw = state.rawValue
            return photo
        }

        func removeFiles() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

nonisolated private enum CaptureSaveTestError: Error { case injectedFailure }

nonisolated private final class FailingCaptureSaveContext: NSManagedObjectContext, @unchecked Sendable {
    // Accessed only on this context's queue, including through the overridden save.
    private var shouldFailNextSave = true

    override func save() throws {
        if shouldFailNextSave {
            shouldFailNextSave = false
            throw CaptureSaveTestError.injectedFailure
        }
        try super.save()
    }
}
