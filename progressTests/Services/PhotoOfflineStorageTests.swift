import CloudKit
import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct PhotoOfflineStorageTests {
    @Test("The reserve uses decimal GB and resumes at exactly 550 MB")
    func storageThresholds() {
        #expect(PhotoOfflineSettings.reserveBytes == 500_000_000)
        #expect(PhotoOfflineSettings.resumeBytes == 550_000_000)
        #expect(!PhotoOfflineSettings.canDownload(availableBytes: 499_999_999, requiredBytes: 1, wasPaused: false))
        #expect(!PhotoOfflineSettings.canDownload(availableBytes: 549_999_999, requiredBytes: 9_000_000, wasPaused: true))
        #expect(PhotoOfflineSettings.canDownload(availableBytes: 550_000_000, requiredBytes: 9_000_000, wasPaused: true))
        #expect(!PhotoOfflineSettings.canDownload(availableBytes: 510_000_000, requiredBytes: 9_000_000, wasPaused: false))
        #expect(!PhotoOfflineSettings.canDownload(availableBytes: Int64.max, requiredBytes: Int64.max, wasPaused: false))
    }

    @Test("Either heart selects all resources; all overrides the remembered hearted preference")
    func selectionAndNetworkPolicy() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        #expect(PhotoOfflineSettings.policy(in: fixture.defaults) == .onDemand)
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepHeartedKey)
        #expect(PhotoOfflineSettings.policy(in: fixture.defaults).selects(isHearted: false, isFavoriteLivePhoto: true))
        #expect(PhotoOfflineSettings.policy(in: fixture.defaults).selects(isHearted: true, isFavoriteLivePhoto: false))
        #expect(!PhotoOfflineSettings.policy(in: fixture.defaults).selects(isHearted: false, isFavoriteLivePhoto: false))
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepAllKey)
        #expect(PhotoOfflineSettings.policy(in: fixture.defaults).selects(isHearted: false, isFavoriteLivePhoto: false))
        fixture.defaults.set(false, forKey: PhotoOfflineSettings.keepAllKey)
        #expect(PhotoOfflineSettings.policy(in: fixture.defaults) == .hearted)
        #expect(PhotoOfflineSettings.networkPauseReason(isConnected: true, isExpensive: true, isConstrained: false, allowsCellular: false) != nil)
        #expect(PhotoOfflineSettings.networkPauseReason(isConnected: true, isExpensive: true, isConstrained: false, allowsCellular: true) == nil)
        #expect(PhotoOfflineSettings.networkPauseReason(isConnected: true, isExpensive: false, isConstrained: true, allowsCellular: true) != nil)
    }

    @Test("Complete Live originals survive restart and temporary cache removal without upload ownership")
    func retainsLivePhotoAcrossRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepHeartedKey)
        let photo = fixture.makePhoto(isLive: true)
        photo.isFavoriteLivePhoto = true
        try fixture.context.save()
        let coordinator = fixture.coordinator()

        await coordinator.reconcileNow()

        #expect(coordinator.availablePhotoCount == 1)
        #expect(coordinator.selectedPhotoCount == 1)
        #expect(fixture.cloud.uploadStateStore.allEntries().isEmpty)
        #expect(fixture.cloud.storedPersistentAssetNames().isEmpty)
        try FileManager.default.removeItem(at: fixture.readable)
        let restartedStore = PhotoOfflineStore(directoryURL: fixture.offline)
        let restartedCloud = CloudKitService(
            stagingDirectoryURL: fixture.staging, temporaryReadableAssetsDirectoryURL: fixture.readable,
            legacyAssetDirectoryURLs: [], assetURLLoader: { _ in throw CloudKitError.downloadFailed },
            offlineStore: restartedStore, offlineSettingsDefaults: fixture.defaults
        )
        for name in fixture.names(for: photo) {
            #expect(restartedCloud.isAssetAvailableForImmediateRead(named: name))
            let url = try await restartedCloud.loadAssetURL(named: name)
            #expect(try Data(contentsOf: url) == fixture.original)
            let retained = try #require(try await restartedStore.assetURL(named: name))
            #expect(try retained.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
        #expect(try await restartedStore.assetNames().count == 3)
    }

    @Test("Removing both hearts releases only offline copies and preserves pending originals")
    func unheartAndDisablePreservePendingOriginals() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepHeartedKey)
        let photo = fixture.makePhoto(isLive: true)
        photo.isHearted = true
        photo.isFavoriteLivePhoto = true
        let pending = fixture.makePhoto()
        let pendingName = try #require(pending.fullImageAssetName)
        _ = try fixture.cloud.stageAssetData(fixture.original, named: pendingName, includesInBackup: true)
        try fixture.context.save()
        let coordinator = fixture.coordinator()
        await coordinator.reconcileNow()
        photo.isHearted = false
        try fixture.context.save()
        await coordinator.reconcileNow()
        #expect(coordinator.availablePhotoCount == 1)
        photo.isFavoriteLivePhoto = false
        try fixture.context.save()
        await coordinator.reconcileNow()
        #expect(try await fixture.cloud.offlineStore.assetNames().isEmpty)
        #expect(fixture.cloud.stagedAssetURL(named: pendingName) != nil)
        #expect(try fixture.cloud.stagedAssetURL(named: pendingName)?.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true)
    }

    @Test("Low storage keeps completed files and does not resume before 550 MB, including after restart")
    func pausesAndResumesWithoutEviction() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepAllKey)
        let existing = fixture.makePhoto()
        let existingName = try #require(existing.fullImageAssetName)
        try await fixture.cloud.offlineStore.retain(from: fixture.source, named: existingName)
        _ = fixture.makePhoto()
        try fixture.context.save()
        let low = fixture.coordinator(capacity: 499_999_999)
        await low.reconcileNow()
        #expect(low.availablePhotoCount == 1)
        #expect(low.statusMessage.contains("storage is low"))
        let belowResume = fixture.coordinator(capacity: 549_999_999)
        await belowResume.reconcileNow()
        #expect(belowResume.availablePhotoCount == 1)
        let resumed = fixture.coordinator(capacity: 550_000_000)
        await resumed.reconcileNow()
        #expect(resumed.availablePhotoCount == 2)
        #expect(try await fixture.cloud.offlineStore.assetURL(named: existingName) != nil)
    }

    @Test("A partial Live download is incomplete and resumes its missing resource")
    func partialLiveDownloadRetries() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepAllKey)
        let photo = fixture.makePhoto(isLive: true)
        try fixture.context.save()
        let videoName = try #require(photo.livePhotoVideoAssetName)
        fixture.failedNames.insert(videoName)
        let coordinator = fixture.coordinator()
        await coordinator.reconcileNow()
        #expect(coordinator.availablePhotoCount == 0)
        #expect(try await fixture.cloud.offlineStore.assetNames().count == 2)
        fixture.failedNames.remove(videoName)
        await coordinator.reconcileNow()
        #expect(coordinator.availablePhotoCount == 1)
        #expect(try await fixture.cloud.offlineStore.assetNames().count == 3)
    }

    @Test("A mismatched checksum never publishes a completed offline file")
    func rejectsCorruptDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        await #expect(throws: CocoaError.self) {
            try await fixture.cloud.offlineStore.retain(
                from: fixture.source, named: "corrupt.heic",
                expected: PhotoAssetMetadata(byteCount: Int64(fixture.original.count), checksum: "wrong")
            )
        }
        #expect(try await fixture.cloud.offlineStore.assetURL(named: "corrupt.heic") == nil)
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
    }

    @Test("Upload success moves selected still and motion to offline storage")
    func uploadHandoffAndRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepHeartedKey)
        let photo = fixture.makePhoto(isLive: true)
        photo.isHearted = true
        try fixture.context.save()
        for name in fixture.names(for: photo) { _ = try fixture.cloud.stageAssetData(fixture.original, named: name, includesInBackup: true) }
        let uploader = PhotoUploadService(cloudKitService: fixture.cloud)
        #expect(try await uploader.uploadNextPendingPhotoForTesting(in: fixture.context))
        #expect(fixture.cloud.storedPersistentAssetNames().isEmpty)
        #expect(try await fixture.cloud.offlineStore.assetNames() == fixture.names(for: photo))
        #expect(fixture.cloud.uploadStateStore.entry(for: try #require(photo.id))?.state == .uploaded)

        // Model a crash after durable upload success but before staging cleanup.
        for name in fixture.names(for: photo) { _ = try fixture.cloud.stageAssetData(fixture.original, named: name) }
        fixture.defaults.set(false, forKey: PhotoOfflineSettings.keepHeartedKey)
        let coordinator = fixture.coordinator()
        await coordinator.reconcileNow()
        #expect(fixture.cloud.storedPersistentAssetNames().isEmpty)
        #expect(try await fixture.cloud.offlineStore.assetNames().isEmpty)
    }

    @Test("Quota errors preserve staging, pause later uploads, and remain typed across restart")
    func quotaPreservesOriginalsAndBlocksUploads() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.uploadError = CKError(.quotaExceeded)
        let first = fixture.makePhoto(isLive: true)
        let second = fixture.makePhoto()
        try fixture.context.save()
        for name in fixture.names(for: first).union(fixture.names(for: second)) {
            _ = try fixture.cloud.stageAssetData(fixture.original, named: name, includesInBackup: true)
        }
        let uploader = PhotoUploadService(cloudKitService: fixture.cloud)
        await #expect(throws: CKError.self) { _ = try await uploader.uploadNextPendingPhotoForTesting(in: fixture.context) }
        let entries = fixture.cloud.uploadStateStore.allEntries()
        #expect(entries.contains { $0.state == .paused && $0.failureReason == .iCloudStorageFull })
        #expect(try await uploader.uploadNextPendingPhotoForTesting(in: fixture.context) == false)
        #expect(fixture.cloud.storedPersistentAssetNames().count == 4)
        let reloaded = LocalPhotoUploadStore(storageURL: fixture.root.appendingPathComponent("local-uploads.json"))
        #expect(reloaded.allEntries().contains { $0.failureReason == .iCloudStorageFull })
        let nested = NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: CKError(.quotaExceeded)])
        #expect(PhotoUploadFailureReason.classify(nested) == .iCloudStorageFull)
    }

    @Test("Deleting a photo also removes its offline resources")
    func deletesOfflineOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await fixture.cloud.offlineStore.retain(from: fixture.source, named: "deleted.heic")
        await fixture.cloud.deleteAssetAndWait(named: "deleted.heic")
        #expect(try await fixture.cloud.offlineStore.assetURL(named: "deleted.heic") == nil)
    }

    @Test("Unknown device capacity waits without downloading or evicting retained photos")
    func unknownCapacityPauses() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepAllKey)
        _ = fixture.makePhoto()
        try fixture.context.save()
        let coordinator = fixture.coordinator(capacity: nil)
        await coordinator.reconcileNow()
        #expect(coordinator.availablePhotoCount == 0)
        #expect(coordinator.statusMessage.contains("couldn’t be checked"))
        #expect(fixture.downloadCount == 0)
    }

    @Test("Changing all to hearted keeps selected files and releases the remainder")
    func changingPolicyReleasesOnlyUnselected() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepAllKey)
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepHeartedKey)
        let hearted = fixture.makePhoto(isLive: true)
        hearted.isFavoriteLivePhoto = true
        _ = fixture.makePhoto()
        try fixture.context.save()
        let coordinator = fixture.coordinator()
        await coordinator.reconcileNow()
        #expect(coordinator.availablePhotoCount == 2)
        fixture.defaults.set(false, forKey: PhotoOfflineSettings.keepAllKey)
        await coordinator.reconcileNow()
        #expect(coordinator.availablePhotoCount == 1)
        #expect(try await fixture.cloud.offlineStore.assetNames() == fixture.names(for: hearted))
    }

    @Test("Turning off retention while a fetch completes never publishes the unwanted file")
    func changingSettingDuringDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepAllKey)
        _ = fixture.makePhoto()
        try fixture.context.save()
        fixture.onDownload = { fixture.defaults.set(false, forKey: PhotoOfflineSettings.keepAllKey) }
        let coordinator = fixture.coordinator()
        await coordinator.reconcileNow()
        #expect(fixture.downloadCount == 1)
        #expect(try await fixture.cloud.offlineStore.assetNames().isEmpty)
    }

    @Test("Deleting a photo during a fetch never recreates its offline resources")
    func deletionDuringDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepAllKey)
        let photo = fixture.makePhoto()
        try fixture.context.save()
        fixture.onDownload = {
            fixture.context.delete(photo)
            try? fixture.context.save()
        }
        let coordinator = fixture.coordinator()
        await coordinator.reconcileNow()
        #expect(try await fixture.cloud.offlineStore.assetNames().isEmpty)
        #expect(try fixture.context.count(for: DailyPhoto.fetchRequest()) == 0)
    }

    @Test("Older upload journals still decode without the new failure reason")
    func backwardCompatibleUploadJournal() throws {
        let upload = LocalPhotoUpload(photoID: UUID(), stillAssetName: "still.heic", livePhotoImageAssetName: nil, videoAssetName: nil, createdAt: Date())
        let data = try JSONEncoder().encode([upload])
        let decoded = try JSONDecoder().decode([LocalPhotoUpload].self, from: data)
        #expect(decoded.first?.failureReason == nil)
        #expect(decoded.first?.state == .pending)
    }

    @Test("Failed offline handoff preserves uploaded staging and recovers without uploading again")
    func failedUploadHandoffRecovers() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepAllKey)
        let photo = fixture.makePhoto()
        try fixture.context.save()
        let name = try #require(photo.fullImageAssetName)
        _ = try fixture.cloud.stageAssetData(fixture.original, named: name, includesInBackup: true)
        try FileManager.default.createDirectory(at: fixture.offline, withIntermediateDirectories: true)
        let index = fixture.offline.appendingPathComponent(".inventory.json")
        try Data("unreadable inventory".utf8).write(to: index)
        let uploader = PhotoUploadService(cloudKitService: fixture.cloud)
        #expect(try await uploader.uploadNextPendingPhotoForTesting(in: fixture.context))
        #expect(fixture.cloud.stagedAssetURL(named: name) != nil)
        #expect(fixture.cloud.uploadStateStore.entry(for: try #require(photo.id))?.state == .uploaded)
        #expect(try await uploader.uploadNextPendingPhotoForTesting(in: fixture.context) == false)
        try FileManager.default.removeItem(at: index)
        await fixture.coordinator().reconcileNow()
        #expect(fixture.cloud.stagedAssetURL(named: name) == nil)
        #expect(try await fixture.cloud.offlineStore.assetURL(named: name) != nil)
    }

    @Test("Recent cache limits persist, start at 100 MB, and reject invalid values")
    func recentLimitSettings() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        #expect(PhotoOfflineSettings.recentLimitBytes(in: fixture.defaults) == 1_000_000_000)
        fixture.defaults.set(10_000_000, forKey: PhotoOfflineSettings.recentLimitKey)
        #expect(PhotoOfflineSettings.recentLimitBytes(in: fixture.defaults) == 100_000_000)
        fixture.defaults.set(750_000_000, forKey: PhotoOfflineSettings.recentLimitKey)
        #expect(PhotoOfflineSettings.recentLimitBytes(in: fixture.defaults) == 750_000_000)
        fixture.defaults.set(Double.infinity, forKey: PhotoOfflineSettings.recentLimitKey)
        #expect(PhotoOfflineSettings.recentLimitBytes(in: fixture.defaults) == 1_000_000_000)
    }

    @Test("Recently opened Live Photos persist; unopened photos are not fetched and low space pauses downloads")
    func recentAccessPersistenceAndStoragePause() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.recentPhotosKey)
        let opened = fixture.makePhoto(isLive: true)
        _ = fixture.makePhoto()
        try fixture.context.save()
        let fullName = try #require(opened.fullImageAssetName)
        await fixture.cloud.recordPhotoAccess(named: fullName)
        let restartedStore = PhotoOfflineStore(directoryURL: fixture.offline)
        #expect(try await restartedStore.accessDates()[fullName] != nil)
        let low = fixture.coordinator(capacity: 499_999_999)
        await low.reconcileNow()
        #expect(low.hasMissingPhotos)
        #expect(fixture.downloadCount == 0)
        let resumed = fixture.coordinator(capacity: 550_000_000)
        await resumed.reconcileNow()
        #expect(resumed.selectedPhotoCount == 1)
        #expect(resumed.availablePhotoCount == 1)
        #expect(try await fixture.cloud.offlineStore.assetNames() == fixture.names(for: opened))
        fixture.defaults.set(false, forKey: PhotoOfflineSettings.recentPhotosKey)
        await resumed.reconcileNow()
        #expect(try await fixture.cloud.offlineStore.assetNames().isEmpty)
    }

    @Test("Lowering the limit evicts the oldest opening, and reopening changes which photo is evicted")
    func recentEvictionAndReopening() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.recentPhotosKey)
        fixture.defaults.set(200_000_000, forKey: PhotoOfflineSettings.recentLimitKey)
        try fixture.resizeSource(to: 40_000_000)
        var names: [String] = []
        for index in 1...3 {
            let photo = fixture.makePhoto()
            let name = try #require(photo.fullImageAssetName)
            names.append(name)
            try await fixture.cloud.offlineStore.retain(from: fixture.source, named: name)
            try await fixture.cloud.offlineStore.recordAccess(to: name, at: Date(timeIntervalSince1970: Double(index)))
        }
        try fixture.context.save()
        let readableOldest = try await fixture.cloud.loadAssetURL(named: names[0])
        let coordinator = fixture.coordinator()
        await coordinator.reconcileNow()
        #expect(coordinator.availablePhotoCount == 3)
        fixture.defaults.set(100_000_000, forKey: PhotoOfflineSettings.recentLimitKey)
        await coordinator.reconcileNow()
        #expect(try await fixture.cloud.offlineStore.assetNames() == Set(names[1...2]))
        #expect(!FileManager.default.fileExists(atPath: readableOldest.path))
        #expect(coordinator.recentPhotoBytes == 80_000_000)
        try await fixture.cloud.offlineStore.recordAccess(to: names[0], at: Date(timeIntervalSince1970: 4))
        await coordinator.reconcileNow()
        #expect(try await fixture.cloud.offlineStore.assetNames() == [names[0], names[2]])
        #expect(try await fixture.cloud.offlineStore.accessDates()[names[1]] == nil)
    }

    @Test("A capture evicts older cloud copies, preserves its pending original, and enters the cache after upload")
    func captureAndUploadEnterRecentCache() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.recentPhotosKey)
        fixture.defaults.set(100_000_000, forKey: PhotoOfflineSettings.recentLimitKey)
        try fixture.resizeSource(to: 60_000_000)
        let old = fixture.makePhoto()
        let oldName = try #require(old.fullImageAssetName)
        try await fixture.cloud.offlineStore.retain(from: fixture.source, named: oldName)
        try await fixture.cloud.offlineStore.recordAccess(to: oldName, at: .distantPast)
        let new = fixture.makePhoto()
        let newName = try #require(new.fullImageAssetName)
        _ = try await fixture.cloud.stageAssetFileAsync(from: fixture.source, named: newName, includesInBackup: true)
        try fixture.context.save()
        await fixture.cloud.recordPhotoAccess(named: newName)
        let coordinator = fixture.coordinator()
        await coordinator.reconcileNow()
        #expect(try await fixture.cloud.offlineStore.assetURL(named: oldName) == nil)
        #expect(fixture.cloud.stagedAssetURL(named: newName) != nil)
        let uploader = PhotoUploadService(cloudKitService: fixture.cloud)
        #expect(try await uploader.uploadNextPendingPhotoForTesting(in: fixture.context))
        #expect(fixture.cloud.stagedAssetURL(named: newName) != nil)
        await coordinator.reconcileNow()
        #expect(try await fixture.cloud.offlineStore.assetNames() == [newName])
        #expect(fixture.cloud.stagedAssetURL(named: newName) == nil)
        #expect(coordinator.recentPhotoBytes == 60_000_000)
    }

    @Test("Hearted copies remain outside the cache limit and oversized pending originals are never evicted")
    func protectedHeartedAndPendingPhotos() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.recentPhotosKey)
        fixture.defaults.set(true, forKey: PhotoOfflineSettings.keepHeartedKey)
        fixture.defaults.set(100_000_000, forKey: PhotoOfflineSettings.recentLimitKey)
        try fixture.resizeSource(to: 60_000_000)
        let hearted = fixture.makePhoto()
        hearted.isFavoriteLivePhoto = true
        let heartName = try #require(hearted.fullImageAssetName)
        try await fixture.cloud.offlineStore.retain(from: fixture.source, named: heartName)
        let recent = fixture.makePhoto()
        let recentName = try #require(recent.fullImageAssetName)
        try await fixture.cloud.offlineStore.retain(from: fixture.source, named: recentName)
        try await fixture.cloud.offlineStore.recordAccess(to: recentName)
        let pending = fixture.makePhoto()
        let pendingName = try #require(pending.fullImageAssetName)
        try fixture.resizeSource(to: 120_000_000)
        _ = try await fixture.cloud.stageAssetFileAsync(from: fixture.source, named: pendingName, includesInBackup: true)
        try await fixture.cloud.offlineStore.recordAccess(to: pendingName)
        try fixture.context.save()
        let coordinator = fixture.coordinator()
        await coordinator.reconcileNow()
        #expect(coordinator.offlineBytes == 120_000_000)
        #expect(coordinator.heartedPhotoBytes == 60_000_000)
        #expect(coordinator.recentPhotoBytes == 60_000_000)
        #expect(fixture.cloud.stagedAssetURL(named: pendingName) != nil)
        #expect(try await fixture.cloud.offlineStore.assetNames() == [heartName, recentName])
    }

    private final class Fixture {
        let root: URL
        let source: URL
        let staging: URL
        let readable: URL
        let offline: URL
        let defaults: UserDefaults
        let persistence: PersistenceController
        let original = Data("original photo resource".utf8)
        var failedNames: Set<String> = []
        var uploadError: (any Error)?
        var downloadCount = 0
        var onDownload: (() -> Void)?
        var context: NSManagedObjectContext { persistence.container.viewContext }
        lazy var cloud = CloudKitService(
            stagingDirectoryURL: staging, temporaryReadableAssetsDirectoryURL: readable,
            legacyAssetDirectoryURLs: [], assetURLLoader: { [unowned self] name in
                downloadCount += 1
                onDownload?()
                if failedNames.contains(name) { throw CloudKitError.downloadFailed }
                return source
            }, assetUploader: { [unowned self] _, _, _ in
                if let uploadError { throw uploadError }
            }, offlineSettingsDefaults: defaults,
            assetMetadataLoader: { [unowned self] _ in PhotoAssetMetadata(byteCount: Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? original.count), checksum: nil) }
        )

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoOfflineTests-\(UUID())", isDirectory: true)
            source = root.appendingPathComponent("source.heic")
            staging = root.appendingPathComponent("Staging", isDirectory: true)
            readable = root.appendingPathComponent("Readable", isDirectory: true)
            offline = root.appendingPathComponent("OfflinePhotoOriginals", isDirectory: true)
            defaults = try #require(UserDefaults(suiteName: "PhotoOfflineTests-\(UUID())"))
            persistence = PersistenceController(inMemory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try original.write(to: source)
        }

        func makePhoto(isLive: Bool = false) -> DailyPhoto {
            let photo = DailyPhoto(context: context)
            let id = UUID()
            photo.id = id
            photo.createdAt = Date()
            photo.captureDate = Date()
            photo.fullImageAssetName = "\(id)_still.heic"
            if isLive {
                photo.livePhotoImageAssetName = "\(id)_live.heic"
                photo.livePhotoVideoAssetName = "\(id)_video.mov"
            }
            return photo
        }

        func names(for photo: DailyPhoto) -> Set<String> {
            Set([photo.fullImageAssetName, photo.livePhotoImageAssetName, photo.livePhotoVideoAssetName].compactMap { $0 })
        }

        func coordinator(capacity: Int64? = 1_000_000_000) -> PhotoOfflineCoordinator {
            PhotoOfflineCoordinator(cloudKitService: cloud, context: context, capacityProvider: { capacity }, conditionsProvider: { nil })
        }

        func resizeSource(to bytes: UInt64) throws {
            let handle = try FileHandle(forWritingTo: source)
            defer { try? handle.close() }
            try handle.truncate(atOffset: bytes)
        }

        func removeFiles() {
            try? FileManager.default.removeItem(at: root)
            for key in [PhotoOfflineSettings.keepAllKey, PhotoOfflineSettings.keepHeartedKey, PhotoOfflineSettings.cellularKey, PhotoOfflineSettings.recentPhotosKey, PhotoOfflineSettings.recentLimitKey, "offlinePhotoDownloadsPausedForStorage"] { defaults.removeObject(forKey: key) }
        }
    }
}
