import CloudKit
import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct PhotoStorageModeTests {
    @Test("Existing installations keep iCloud; migration and deletion checkpoints survive restart")
    func durablePreference() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mode.json")
        let store = PhotoStorageModeStore(storageURL: url)
        #expect(store.mode == .iCloud)
        let plan = PhotoCloudDeletionPlan(accountID: "account", metadataRecords: [], assetNames: ["still.heic", "live.mov"])
        try store.set(.downloading, downloadAccountID: "account", deletionPlan: plan)
        let restarted = PhotoStorageModeStore(storageURL: url)
        #expect(restarted.mode == .downloading)
        #expect(restarted.downloadAccountID == "account")
        #expect(restarted.deletionPlan?.assetNames == plan.assetNames)
        try restarted.set(.deletingCloudCopies, storeFilename: "DeviceLibrary-test.sqlite", deletionPlan: plan)
        let deleting = PhotoStorageModeStore(storageURL: url)
        #expect(deleting.mode == .deletingCloudCopies)
        #expect(deleting.storeFilename == "DeviceLibrary-test.sqlite")
        try deleting.set(.local)
        let local = PhotoStorageModeStore(storageURL: url)
        #expect(local.storeFilename == "DeviceLibrary-test.sqlite")
        #expect(local.deletionPlan == nil)
    }

    @Test("Unreadable preferences stop cloud writes and are never overwritten")
    func corruptPreferenceFailsClosed() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("mode.json")
        let corrupt = Data("interrupted or corrupt journal".utf8)
        try corrupt.write(to: url)
        let store = PhotoStorageModeStore(storageURL: url)
        #expect(!store.mode.allowsCloudWrites)
        #expect(throws: (any Error).self) { try store.checkReadable() }
        #expect(throws: (any Error).self) { try store.set(.iCloud) }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test("Preflight includes download copies, library copy, reserve, and overflow")
    func storageEstimate() {
        let estimate = PhotoStorageEstimate(photoCount: 1, originalBytes: 200, additionalLocalBytes: 200,
                                            freeDeviceBytes: 50_000_600, libraryCopyBytes: 100)
        #expect(estimate.peakAdditionalDeviceBytes == 600)
        #expect(estimate.safetyMarginBytes == 50_000_000)
        #expect(estimate.requiredDeviceBytes == 50_000_600)
        #expect(estimate.fitsOnDevice)
        let low = PhotoStorageEstimate(photoCount: 1, originalBytes: 200, additionalLocalBytes: 200,
                                       freeDeviceBytes: 50_000_599, libraryCopyBytes: 100)
        #expect(!low.fitsOnDevice)
        let overflow = PhotoStorageEstimate(photoCount: 1, originalBytes: .max, additionalLocalBytes: .max,
                                            freeDeviceBytes: 1_000_000_000)
        #expect(!overflow.fitsOnDevice)
        #expect(overflow.peakAdditionalDeviceBytes == .max)
        let retained = PhotoStorageEstimate(photoCount: 5, originalBytes: 10_500_000, additionalLocalBytes: 0,
                                            freeDeviceBytes: 0)
        #expect(retained.peakAdditionalDeviceBytes == 0)
        #expect(retained.safetyMarginBytes == 0)
        #expect(retained.requiredDeviceBytes == 0)
        #expect(retained.fitsOnDevice)
        let smallLibrary = PhotoStorageEstimate(photoCount: 5, originalBytes: 10_500_000, additionalLocalBytes: 10_500_000,
                                               freeDeviceBytes: 1_000_000_000, libraryCopyBytes: 3_400_000)
        #expect(smallLibrary.peakAdditionalDeviceBytes == 27_800_000)
        #expect(smallLibrary.safetyMarginBytes == 50_000_000)
        #expect(smallLibrary.requiredDeviceBytes == 77_800_000)
        #expect(smallLibrary.canRetainOriginal(byteCount: 10_500_000, availableBytes: 71_000_000))
        #expect(smallLibrary.canRetainOriginal(byteCount: 10_500_000, availableBytes: 70_999_999) == false)
        #expect(smallLibrary.canRetainOriginal(byteCount: .max, availableBytes: .max) == false)
        #expect(smallLibrary.canRetainOriginal(byteCount: -1, availableBytes: .max) == false)
        let mediumLibrary = PhotoStorageEstimate(photoCount: 100, originalBytes: 500_000_000, additionalLocalBytes: 500_000_000,
                                                freeDeviceBytes: 1_100_000_000)
        #expect(mediumLibrary.safetyMarginBytes == 100_000_000)
        #expect(mediumLibrary.requiredDeviceBytes == 1_100_000_000)
        #expect(mediumLibrary.fitsOnDevice)
        let largeLibrary = PhotoStorageEstimate(photoCount: 1_000, originalBytes: 3_000_000_000, additionalLocalBytes: 3_000_000_000,
                                               freeDeviceBytes: 6_500_000_000)
        #expect(largeLibrary.safetyMarginBytes == 500_000_000)
        #expect(largeLibrary.requiredDeviceBytes == 6_500_000_000)
        #expect(largeLibrary.fitsOnDevice)
    }

    @Test("Local mode prevents upload and uploaded-original cleanup, including across restart")
    func localModeProtectsOriginals() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let name = try #require(fixture.photo.fullImageAssetName)
        let source = try #require(fixture.cloud.stagedAssetURL(named: name))
        try await fixture.cloud.offlineStore.retain(from: source, named: name)
        try fixture.modeStore.set(.local)
        await #expect(throws: CancellationError.self) {
            try await fixture.cloud.uploadStagedAsset(named: name, photoID: fixture.photoID, role: .still)
        }
        try await fixture.cloud.finishUploadedOriginals(assetNames: [name], retaining: false)
        try await fixture.cloud.releaseOfflineCopies(except: [])
        #expect(fixture.cloud.stagedAssetURL(named: name) != nil)
        #expect(try await fixture.cloud.offlineStore.assetURL(named: name) != nil)
    }

    @Test("All Live resources are verified locally; keeping cloud copies preserves metadata identity")
    func keepCloudCopiesMigration() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let originalStore = fixture.persistence.container.persistentStoreDescriptions.first?.url
        let service = fixture.coordinator()
        try await service.beginLocalStorage(removeCloudCopies: false)
        await service.resumeAndWait()
        #expect(service.errorMessage == nil)
        #expect(service.mode == .local)
        #expect(fixture.persistence.container.persistentStoreDescriptions.first?.url == originalStore)
        #expect(try await fixture.cloud.offlineStore.assetNames() == fixture.names)
        #expect(fixture.cloud.storedPersistentAssetNames().isEmpty)
        #expect(fixture.deletedRecords.isEmpty)
        for name in fixture.names { try await fixture.cloud.offlineStore.verifyOriginal(named: name) }
        #expect(try #require(originalStore?.deletingLastPathComponent()).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("Cloud deletion runs from a fresh local store, preserves photo details, and uploads can resume")
    func deleteCloudCopiesMigration() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let originalStore = fixture.persistence.container.persistentStoreDescriptions.first?.url
        fixture.remoteRecords = Set(fixture.names.map { CKRecord.ID(recordName: $0) })
        let service = fixture.coordinator()
        try await service.beginLocalStorage(removeCloudCopies: true)
        await service.resumeAndWait()
        #expect(service.errorMessage == nil)
        #expect(service.mode == .local)
        #expect(fixture.persistence.container.persistentStoreDescriptions.first?.url != originalStore)
        #expect(fixture.deletedRecords == Set(fixture.names.map { CKRecord.ID(recordName: $0) }))
        let photos = try fixture.persistence.container.viewContext.fetch(DailyPhoto.fetchRequest())
        let photo = try #require(photos.first)
        #expect(photos.count == 1)
        #expect(photo.id == fixture.photoID)
        #expect(photo.isHearted)
        #expect(photo.locationName == "Retained place")
        #expect(photo.thumbnailData == fixture.thumbnail)
        #expect(photo.livePhotoVideoAssetName == "\(fixture.photoID)-live.mov")
        try await service.beginICloudStorage()
        await service.resumeAndWait()
        #expect(service.errorMessage == nil)
        #expect(service.mode == .iCloud)
        #expect(fixture.cloud.uploadStateStore.entry(for: fixture.photoID)?.state == .pending)
        #expect(try await fixture.cloud.offlineStore.assetNames() == fixture.names)
    }

    @Test("An unknown remote photo blocks deletion before changing settings")
    func unknownCloudPhotoBlocksDeletion() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        fixture.remoteRecords = [CKRecord.ID(recordName: "not-on-this-device")]
        let service = fixture.coordinator()
        await #expect(throws: PhotoStorageMigrationError.self) { try await service.beginLocalStorage(removeCloudCopies: true) }
        #expect(service.mode == .iCloud)
        #expect(fixture.deletedRecords.isEmpty)
    }

    @Test("Interrupted deletion remains checkpointed and retries from reverified originals")
    func interruptedDeletionResumes() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        fixture.remoteRecords = Set(fixture.names.map { CKRecord.ID(recordName: $0) })
        fixture.failDeletion = true
        let service = fixture.coordinator()
        try await service.beginLocalStorage(removeCloudCopies: true)
        await service.resumeAndWait()
        #expect(service.mode == .deletingCloudCopies)
        #expect(service.errorMessage != nil)
        #expect(fixture.modeStore.deletionPlan != nil)
        fixture.failDeletion = false
        let resumed = fixture.coordinator()
        await resumed.resumeAndWait()
        #expect(resumed.mode == .local)
        #expect(resumed.errorMessage == nil)
        #expect(fixture.remoteRecords.isEmpty)
    }

    @Test("Changed iCloud account prevents a resumed deletion")
    func accountChangedDuringDeletion() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        fixture.remoteRecords = Set(fixture.names.map { CKRecord.ID(recordName: $0) })
        fixture.failDeletion = true
        let service = fixture.coordinator()
        try await service.beginLocalStorage(removeCloudCopies: true)
        await service.resumeAndWait()
        fixture.failDeletion = false
        fixture.account = "different-account"
        let resumed = fixture.coordinator()
        await resumed.resumeAndWait()
        #expect(resumed.mode == .deletingCloudCopies)
        #expect(resumed.errorMessage != nil)
        #expect(fixture.deletedRecords.isEmpty)
    }

    @Test("A same-sized corrupt original blocks resumed cloud deletion")
    func corruptLocalOriginalBlocksDeletion() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        fixture.remoteRecords = Set(fixture.names.map { CKRecord.ID(recordName: $0) })
        fixture.failDeletion = true
        let service = fixture.coordinator()
        try await service.beginLocalStorage(removeCloudCopies: true)
        await service.resumeAndWait()
        let name = try #require(fixture.names.first)
        let url = try #require(try await fixture.cloud.offlineStore.assetURL(named: name))
        let original = try Data(contentsOf: url)
        try Data(repeating: 0xff, count: original.count).write(to: url)
        fixture.failDeletion = false
        let resumed = fixture.coordinator()
        await resumed.resumeAndWait()
        #expect(resumed.mode == .deletingCloudCopies)
        #expect(resumed.errorMessage != nil)
        #expect(fixture.deletedRecords.isEmpty)
    }

    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("PhotoStorageModeTests-\(UUID())") }

    @Test("Insufficient storage leaves the current mode and every cloud copy untouched")
    func insufficientStorageDoesNotStartMigration() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let service = fixture.coordinator(capacity: 100)
        await #expect(throws: PhotoStorageMigrationError.self) { try await service.beginLocalStorage(removeCloudCopies: false) }
        #expect(service.mode == .iCloud)
        #expect(fixture.modeStore.mode == .iCloud)
        #expect(fixture.deletedRecords.isEmpty)
    }

    @Test("A restarted download reuses durable originals and finishes the remaining Live resources")
    func interruptedDownloadResumes() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let name = try #require(fixture.names.first)
        let source = try #require(fixture.cloud.stagedAssetURL(named: name))
        try await fixture.cloud.offlineStore.retain(from: source, named: name)
        try fixture.modeStore.set(.downloading)
        let service = fixture.coordinator()
        await service.resumeAndWait()
        #expect(service.errorMessage == nil)
        #expect(service.mode == .local)
        #expect(service.completedAssets == 3)
        #expect(try await fixture.cloud.offlineStore.assetNames() == fixture.names)
    }

    @Test("A download can be cancelled before cloud deletion begins")
    func cancelDownloadKeepsCloud() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let plan = PhotoCloudDeletionPlan(accountID: fixture.account, metadataRecords: [], assetNames: fixture.names)
        try fixture.modeStore.set(.downloading, downloadAccountID: fixture.account, deletionPlan: plan)
        let service = fixture.coordinator()
        try await service.cancelLocalSwitch()
        #expect(service.mode == .iCloud)
        #expect(fixture.modeStore.deletionPlan == nil)
        #expect(fixture.deletedRecords.isEmpty)
        #expect(fixture.names.isSubset(of: fixture.cloud.storedPersistentAssetNames()))
    }

    @Test("A failed upload preparation can return to local storage without cloud writes")
    func cancelFailedUploadPreparation() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        try fixture.modeStore.set(.preparingUpload, downloadAccountID: fixture.account)
        fixture.cloud.removeStagedAsset(named: try #require(fixture.names.first))
        let service = fixture.coordinator()
        await service.resumeAndWait()
        #expect(service.mode == .preparingUpload)
        #expect(service.errorMessage != nil)
        try await service.cancelUploadPreparation()
        #expect(service.mode == .local)
        #expect(fixture.modeStore.mode == .local)
        #expect(fixture.deletedRecords.isEmpty)
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoStorageFixture-\(UUID())")
        let modeStore: PhotoStorageModeStore
        let persistence: PersistenceController
        let cloud: CloudKitService
        let photoID = UUID()
        let thumbnail = Data("thumbnail survives local copy".utf8)
        var photo: DailyPhoto!
        var remoteRecords: Set<CKRecord.ID> = []
        var deletedRecords: Set<CKRecord.ID> = []
        var failDeletion = false
        var account = "original-account"

        var names: Set<String> { ["\(photoID)-still.heic", "\(photoID)-live.heic", "\(photoID)-live.mov"] }

        init() async throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("library"), withIntermediateDirectories: true)
            modeStore = PhotoStorageModeStore(storageURL: root.appendingPathComponent("preference/mode.json"))
            persistence = PersistenceController(storageModeStore: modeStore, storeURL: root.appendingPathComponent("library/progress.sqlite"), cloudEnabled: false)
            cloud = CloudKitService(stagingDirectoryURL: root.appendingPathComponent("staging"),
                                    temporaryReadableAssetsDirectoryURL: root.appendingPathComponent("readable"),
                                    legacyAssetDirectoryURLs: [], assetURLLoader: { _ in throw CloudKitError.assetNotFound },
                                    storageModeStore: modeStore)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !persistence.isLoaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard persistence.isLoaded else { throw CocoaError(.persistentStoreOperation) }
            photo = DailyPhoto(context: persistence.container.viewContext)
            photo.id = photoID
            photo.createdAt = Date()
            photo.captureDate = Date()
            photo.fullImageAssetName = "\(photoID)-still.heic"
            photo.livePhotoImageAssetName = "\(photoID)-live.heic"
            photo.livePhotoVideoAssetName = "\(photoID)-live.mov"
            photo.isHearted = true
            photo.locationName = "Retained place"
            photo.thumbnailData = thumbnail
            try persistence.container.viewContext.save()
            for name in names { _ = try cloud.stageAssetData(Data("original \(name)".utf8), named: name) }
        }

        func coordinator(capacity: Int64 = 10_000_000_000) -> PhotoStorageCoordinator {
            let copies = PhotoCloudCopyService(accountIDProvider: { self.account }, recordIDsProvider: { self.remoteRecords },
                                              deleteRecords: { ids in
                if self.failDeletion { throw CKError(.networkFailure) }
                #expect(self.persistence.container.persistentStoreDescriptions.first?.url?.lastPathComponent.hasPrefix("DeviceLibrary-") == true)
                self.deletedRecords.formUnion(ids)
                self.remoteRecords.subtract(ids)
            }, existingRecords: { Set($0).intersection(self.remoteRecords) })
            return PhotoStorageCoordinator(cloudKitService: cloud, persistenceController: persistence,
                                           cloudCopyService: copies, capacityProvider: { capacity },
                                           suspendServices: {}, resumeServices: {}, validateMigrationReadiness: { _ in })
        }

        func cleanup() {
            for store in persistence.container.persistentStoreCoordinator.persistentStores { try? persistence.container.persistentStoreCoordinator.remove(store) }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
