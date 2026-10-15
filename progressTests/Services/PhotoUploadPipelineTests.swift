import CloudKit
import CoreData
import Foundation
import Testing
import UIKit
@testable import progress

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PhotoUploadPipelineTests {
    @Test("A saved capture stages exact Live originals and keeps them until the complete upload succeeds")
    func savesAndUploadsCompleteCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepAllKey)
        let photo = try await fixture.saveCapture(isLive: true)
        let id = try #require(photo.id)
        let names = fixture.names(for: photo)
        let reloaded = LocalPhotoUploadStore(storageURL: fixture.root.appendingPathComponent("local-uploads.json"))
        #expect(reloaded.entry(for: id)?.state == .pending)
        #expect(reloaded.entry(for: id)?.assetNames == names)
        #expect(try Data(contentsOf: fixture.video) == fixture.videoData)
        for name in names {
            let staged = try #require(fixture.cloud.stagedAssetURL(named: name))
            #expect(try staged.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true)
        }
        fixture.recorder.onUpload = { _, _ in
            #expect(names.allSatisfy { fixture.cloud.stagedAssetURL(named: $0) != nil })
        }

        #expect(try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context))

        #expect(fixture.cloud.uploadStateStore.entry(for: id)?.state == .uploaded)
        #expect(fixture.recorder.roles == [.still, .livePhotoVideo])
        #expect(fixture.cloud.storedPersistentAssetNames().isEmpty)
        let stillName = try #require(photo.fullImageAssetName)
        let videoName = try #require(photo.livePhotoVideoAssetName)
        let stillURL = try #require(try await fixture.cloud.offlineStore.assetURL(named: stillName))
        let videoURL = try #require(try await fixture.cloud.offlineStore.assetURL(named: videoName))
        #expect(try Data(contentsOf: stillURL) == fixture.imageData)
        #expect(try Data(contentsOf: videoURL) == fixture.videoData)
    }

    @Test("A failed camera save cleans staged files and ownership but keeps the capture retryable")
    func failedCaptureSaveDoesNotLeakOriginals() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let context = fixture.failingContext()
        await #expect(throws: PipelineTestError.self) {
            _ = try await fixture.storage.savePhoto(
                image: fixture.image, imageData: fixture.imageData,
                livePhotoVideoURL: fixture.video, location: nil,
                context: context, enqueuesPendingUpload: false
            )
        }
        #expect(fixture.cloud.storedPersistentAssetNames().isEmpty)
        #expect(fixture.cloud.uploadStateStore.allEntries().isEmpty)
        #expect(context.insertedObjects.isEmpty)
        #expect(try Data(contentsOf: fixture.video) == fixture.videoData)
        #expect(await fixture.storage.recoverPendingUploadsFromManifest(context: context) == 0)

        _ = try await fixture.storage.savePhoto(
            image: fixture.image, imageData: fixture.imageData,
            livePhotoVideoURL: fixture.video, location: nil,
            context: context, enqueuesPendingUpload: false
        )
        #expect(try context.count(for: DailyPhoto.fetchRequest()) == 1)
        #expect(fixture.cloud.storedPersistentAssetNames().count == 2)
    }

    @Test("A missing movie fails before creating staged files or an upload journal")
    func missingCaptureVideoLeavesNoPartialPhoto() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.storage.savePhoto(
                image: fixture.image, imageData: fixture.imageData,
                livePhotoVideoURL: fixture.root.appendingPathComponent("missing.mov"),
                location: nil, context: fixture.context, enqueuesPendingUpload: false
            )
        }
        #expect(fixture.cloud.storedPersistentAssetNames().isEmpty)
        #expect(fixture.cloud.uploadStateStore.allEntries().isEmpty)
        #expect(try fixture.context.count(for: DailyPhoto.fetchRequest()) == 0)
    }

    @Test("An unreadable crash journal is not overwritten by the next capture")
    func preservesUnreadableManifest() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let journal = fixture.root.appendingPathComponent("pending-uploads.json")
        let unreadable = Data("unreadable manifest".utf8)
        try unreadable.write(to: journal)

        await #expect(throws: (any Error).self) { _ = try await fixture.saveCapture(isLive: true) }

        #expect(try Data(contentsOf: journal) == unreadable)
        #expect(fixture.cloud.storedPersistentAssetNames().isEmpty)
        #expect(fixture.cloud.uploadStateStore.allEntries().isEmpty)
        #expect(try Data(contentsOf: fixture.video) == fixture.videoData)
        #expect(try fixture.context.count(for: DailyPhoto.fetchRequest()) == 0)
    }

    @Test("A failed import batch removes its files and upload entries")
    func failedBatchCleansPendingOriginals() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let result = await fixture.storage.saveImportedPhotos(
            [ImportedPhotoPayload(imageData: fixture.imageData)],
            batchSize: 1, context: fixture.failingContext(), enqueuesPendingUploads: false
        )
        #expect(result.importedCount == 0)
        #expect(result.failedCount == 1)
        #expect(fixture.cloud.storedPersistentAssetNames().isEmpty)
        #expect(fixture.cloud.uploadStateStore.allEntries().isEmpty)
    }

    @Test("Crash recovery does not consume a manifest belonging to an active save")
    func skipsActiveManifest() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let entry = try await fixture.recordManifest()

        #expect(await fixture.storage.recoverPendingUploadsFromManifest(context: fixture.context) == 0)
        #expect(try fixture.context.count(for: DailyPhoto.fetchRequest()) == 0)
        #expect(fixture.cloud.stagedAssetURL(named: entry.fullImageAssetName) != nil)

        let restarted = fixture.restartedManifest()
        #expect(await restarted.recoverPendingUploads(context: fixture.context, cloudKitService: fixture.cloud, thumbnailService: .shared) == 1)
        #expect(try fixture.context.count(for: DailyPhoto.fetchRequest()) == 1)
    }

    @Test("Concurrent crash recovery creates only one photo, even across suspension points")
    func serializesManifestRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        _ = try await fixture.recordManifest()
        let restarted = fixture.restartedManifest()

        async let first = restarted.recoverPendingUploads(context: fixture.context, cloudKitService: fixture.cloud, thumbnailService: .shared)
        async let second = restarted.recoverPendingUploads(context: fixture.context, cloudKitService: fixture.cloud, thumbnailService: .shared)
        let counts = await [first, second]

        #expect(counts.reduce(0, +) == 1)
        #expect(try fixture.context.count(for: DailyPhoto.fetchRequest()) == 1)
    }

    @Test("Failed manifest recovery removes its unsaved row and can recover exactly once later")
    func failedManifestSaveCanRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        _ = try await fixture.recordManifest()
        let restarted = fixture.restartedManifest()
        let context = fixture.failingContext()

        #expect(await restarted.recoverPendingUploads(context: context, cloudKitService: fixture.cloud, thumbnailService: .shared) == 0)
        #expect(context.insertedObjects.isEmpty)
        #expect(await restarted.recoverPendingUploads(context: context, cloudKitService: fixture.cloud, thumbnailService: .shared) == 1)
        #expect(try context.count(for: DailyPhoto.fetchRequest()) == 1)
    }

    @Test("Recovery repairs upload ownership when metadata was saved before the upload journal")
    func repairsMissingOwnershipAfterRecoveryCrash() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let entry = try await fixture.recordManifest()
        let photo = DailyPhoto(context: fixture.context)
        photo.id = entry.photoID
        photo.fullImageAssetName = entry.fullImageAssetName
        try fixture.context.save()
        let restarted = fixture.restartedManifest()

        #expect(await restarted.recoverPendingUploads(context: fixture.context, cloudKitService: fixture.cloud, thumbnailService: .shared) == 0)

        #expect(fixture.cloud.uploadStateStore.entry(for: entry.photoID)?.state == .pending)
        #expect(try fixture.context.count(for: DailyPhoto.fetchRequest()) == 1)
    }

    @Test("An active photo cannot be claimed again while its upload is suspended")
    func preventsDuplicateClaims() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try await fixture.saveCapture()
        let gate = Gate()
        fixture.recorder.onUpload = { _, _ in await gate.hold() }
        let first = Task { try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context) }
        await gate.waitUntilEntered()

        let duplicate = try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context)
        #expect(!duplicate)
        await gate.release()

        #expect(try await first.value)
        #expect(fixture.recorder.roles == [.still])
        #expect(fixture.cloud.uploadStateStore.entry(for: try #require(photo.id))?.attemptCount == 1)
    }

    @Test("A process restart resumes an upload left in the uploading state")
    func resumesInterruptedUpload() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try await fixture.saveCapture()
        #expect(await fixture.uploader.claimNextPendingUploadForTesting(in: fixture.context) == photo.objectID)
        let restarted = PhotoUploadService(cloudKitService: fixture.cloud)

        #expect(try await restarted.uploadNextPendingPhotoForTesting(in: fixture.context))
        #expect(fixture.cloud.uploadStateStore.entry(for: try #require(photo.id))?.state == .uploaded)
        #expect(fixture.recorder.roles == [.still])
    }

    @Test("Upload processing reserves the worker before its first suspension")
    func reservesWorkerBeforeAvailabilityCheck() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        _ = try await fixture.saveCapture()
        let gate = Gate()
        let uploader = PhotoUploadService(cloudKitService: fixture.cloud, context: fixture.context, cloudOperationsAvailable: {
            await gate.hold()
            return true
        })
        let first = Task { await uploader.processPendingUploadsForTesting() }
        await gate.waitUntilEntered()
        await uploader.processPendingUploadsForTesting()
        #expect(await gate.entryCount == 1)
        await gate.release()
        await first.value
        #expect(await uploader.waitUntilIdle())
        #expect(fixture.recorder.roles == [.still])
    }

    @Test("Retry-after errors retry while the app stays open, without waiting for a background launch")
    func retriesInForeground() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try await fixture.saveCapture()
        let signals = AsyncStream<Int>.makeStream()
        fixture.recorder.onUpload = { _, _ in
            let count = fixture.recorder.roles.count
            signals.continuation.yield(count)
            if count == 1 {
                throw CKError(.networkFailure, userInfo: [CKErrorRetryAfterKey: 0.01])
            }
            signals.continuation.finish()
        }

        await fixture.uploader.processPendingUploadsForTesting()
        for await _ in signals.stream {}
        #expect(await fixture.uploader.waitUntilIdle())

        #expect(fixture.recorder.roles == [.still, .still])
        #expect(fixture.cloud.uploadStateStore.entry(for: try #require(photo.id))?.state == .uploaded)
    }

    @Test("Deleting an in-flight capture preserves the CKAsset source until completion and stops remaining Live uploads")
    func deletionDrainsUploadBeforeRemoteCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try await fixture.saveCapture(isLive: true)
        let name = try #require(photo.fullImageAssetName)
        let gate = Gate()
        fixture.recorder.onUpload = { _, _ in await gate.hold() }
        let upload = Task {
            _ = await #expect(throws: CancellationError.self) {
                _ = try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context)
            }
        }
        await gate.waitUntilEntered()
        fixture.cloud.deleteAsset(named: name)
        #expect(fixture.cloud.stagedAssetURL(named: name) != nil)
        let deletion = Task { await fixture.cloud.deleteAssetAndWait(named: name) }
        await gate.release()
        await upload.value
        await deletion.value

        #expect(fixture.cloud.stagedAssetURL(named: name) == nil)
        #expect(fixture.cloud.uploadStateStore.allEntries().isEmpty)
        #expect(fixture.recorder.roles == [.still])
    }

    @Test("A missing CloudKit save result cannot discard originals as if upload succeeded")
    func requiresConfirmedCloudSave() throws {
        #expect(throws: CloudKitError.uploadFailed) { try CloudKitService.validateAssetSaveResult(nil) }
        #expect(throws: CKError.self) { try CloudKitService.validateAssetSaveResult(.failure(CKError(.networkFailure))) }
        try CloudKitService.validateAssetSaveResult(.success(CKRecord(recordType: "PhotoAsset")))
    }

    @Test("Quota failures pause even when CloudKit also supplies a retry-after delay")
    func quotaTakesPriorityOverRetryAfter() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try await fixture.saveCapture()
        fixture.recorder.onUpload = { _, _ in
            throw CKError(.quotaExceeded, userInfo: [CKErrorRetryAfterKey: 60])
        }

        await #expect(throws: CKError.self) {
            _ = try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context)
        }

        let id = try #require(photo.id)
        let entry = try #require(fixture.cloud.uploadStateStore.entry(for: id))
        #expect(entry.state == .paused)
        #expect(entry.failureReason == .iCloudStorageFull)
        #expect(entry.retryAfter == nil)
        #expect(fixture.cloud.storedPersistentAssetNames() == fixture.names(for: photo))
    }

    @Test("Connectivity errors keep originals and use the retry queue instead of pausing forever")
    func retriesURLConnectivityFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try await fixture.saveCapture()
        fixture.recorder.onUpload = { _, _ in throw URLError(.networkConnectionLost) }

        await #expect(throws: URLError.self) {
            _ = try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context)
        }

        let id = try #require(photo.id)
        let entry = try #require(fixture.cloud.uploadStateStore.entry(for: id))
        #expect(entry.state == .failed)
        #expect(entry.retryAfter != nil)
        #expect(fixture.cloud.storedPersistentAssetNames() == fixture.names(for: photo))
    }

    @Test("A failed restage preserves the existing original and restaging a file onto itself is safe")
    func restagingPreservesExistingFile() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let name = "original.mov"
        let url = try fixture.cloud.stageAssetData(fixture.videoData, named: name)
        #expect(throws: (any Error).self) {
            _ = try fixture.cloud.stageAssetFile(from: fixture.root.appendingPathComponent("missing.mov"), named: name)
        }
        #expect(try Data(contentsOf: url) == fixture.videoData)
        _ = try fixture.cloud.stageAssetFile(from: url, named: name)
        #expect(try Data(contentsOf: url) == fixture.videoData)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.cloud.stageAssetFileAsync(from: fixture.root.appendingPathComponent("missing.mov"), named: name)
        }
        #expect(try Data(contentsOf: url) == fixture.videoData)
    }

    @Test("A refetch returning the existing readable path cannot delete that file while stabilizing its URL")
    func preservesReadableSourceAtDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadableAliasTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let readable = root.appendingPathComponent("Readable")
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
        let source = readable.appendingPathComponent("photo.heic")
        let data = Data("readable original".utf8)
        try data.write(to: source)
        let cloud = CloudKitService(
            stagingDirectoryURL: root.appendingPathComponent("Staging"),
            temporaryReadableAssetsDirectoryURL: readable,
            legacyAssetDirectoryURLs: [], assetURLLoader: { _ in source }
        )

        let result = try await cloud.loadAssetURL(named: source.lastPathComponent, forceRefetch: true)

        #expect(try Data(contentsOf: result) == data)
        #expect(try Data(contentsOf: source) == data)
    }

    private final class Recorder {
        var roles: [PhotoAssetRole] = []
        var onUpload: (@MainActor (String, PhotoAssetRole) async throws -> Void)?
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoUploadPipelineTests-\(UUID())")
        let persistence = PersistenceController(inMemory: true)
        let recorder = Recorder()
        let image: UIImage
        let imageData: Data
        let videoData = Data("paired video original".utf8)
        let cloud: CloudKitService
        let storage: PhotoStorageService
        let uploader: PhotoUploadService
        let defaults: UserDefaults
        private let domain = "PhotoUploadPipelineTests-\(UUID())"
        var context: NSManagedObjectContext { persistence.container.viewContext }
        var video: URL { root.appendingPathComponent("capture.mov") }

        init() throws {
            defaults = try #require(UserDefaults(suiteName: domain))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).image { renderer in
                UIColor.red.setFill()
                renderer.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            }
            imageData = try #require(image.jpegData(compressionQuality: 0.9))
            let recorder = self.recorder
            cloud = CloudKitService(
                stagingDirectoryURL: root.appendingPathComponent("Staging"),
                temporaryReadableAssetsDirectoryURL: root.appendingPathComponent("Readable"),
                legacyAssetDirectoryURLs: [],
                assetURLLoader: { _ in throw CloudKitError.assetNotFound },
                assetUploader: { name, _, role in
                    recorder.roles.append(role)
                    try await recorder.onUpload?(name, role)
                },
                remoteAssetExistenceChecker: { _ in false },
                offlineSettingsDefaults: defaults
            )
            storage = PhotoStorageService(cloudKitService: cloud)
            uploader = PhotoUploadService(cloudKitService: cloud, context: persistence.container.viewContext, cloudOperationsAvailable: { true })
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try videoData.write(to: video)
        }

        func saveCapture(isLive: Bool = false) async throws -> DailyPhoto {
            let objectID = try await storage.savePhoto(
                image: image, imageData: imageData,
                livePhotoVideoURL: isLive ? video : nil,
                location: nil, context: context, enqueuesPendingUpload: false
            )
            return try #require(context.existingObject(with: objectID) as? DailyPhoto)
        }

        func names(for photo: DailyPhoto) -> Set<String> {
            Set([photo.fullImageAssetName, photo.livePhotoImageAssetName, photo.livePhotoVideoAssetName].compactMap { $0 })
        }

        func recordManifest() async throws -> PendingUploadManifestEntry {
            let id = UUID()
            let name = "\(id)_still.jpeg"
            _ = try cloud.stageAssetData(imageData, named: name, includesInBackup: true)
            let entry = PendingUploadManifestEntry(
                photoID: id, captureDate: Date(), createdAt: Date(), latitude: 0, longitude: 0,
                fullImageAssetName: name, livePhotoVideoAssetName: nil
            )
            try await cloud.pendingUploadManifestService.record(entry)
            return entry
        }

        func restartedManifest() -> PendingUploadManifestService {
            PendingUploadManifestService(storageURL: root.appendingPathComponent("pending-uploads.json"))
        }

        func failingContext() -> NSManagedObjectContext {
            let context = FailingPipelineContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = persistence.container.persistentStoreCoordinator
            return context
        }

        func removeFiles() {
            recorder.onUpload = nil
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private actor Gate {
        private(set) var entryCount = 0
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

        func hold() async {
            entryCount += 1
            let entered = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in entered { waiter.resume() }
            guard !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func waitUntilEntered() async {
            guard entryCount == 0 else { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
}

nonisolated private enum PipelineTestError: Error { case saveFailed }

nonisolated private final class FailingPipelineContext: NSManagedObjectContext, @unchecked Sendable {
    private var shouldFail = true

    override func save() throws {
        if shouldFail {
            shouldFail = false
            throw PipelineTestError.saveFailed
        }
        try super.save()
    }
}
