import CloudKit
import CoreData
import Foundation
import Testing
import UIKit
@testable import progress

@MainActor
struct PhotoStorageFailureTests {
    @Test("An empty library can switch both ways without creating photos", arguments: [false, true])
    func emptyLibrary(removeCopies: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let storage = library.coordinator()
        try await storage.beginLocalStorage(removeCloudCopies: removeCopies)
        await storage.resumeAndWait()
        #expect(storage.errorMessage == nil)
        #expect(storage.mode == .local)
        try await storage.beginICloudStorage()
        await storage.resumeAndWait()
        #expect(storage.errorMessage == nil)
        #expect(storage.mode == .iCloud)
        #expect(try library.persistence.container.viewContext.count(for: DailyPhoto.fetchRequest()) == 0)
        #expect(library.network.uploads.isEmpty)
    }

    @Test("Unknown or insufficient device space blocks preflight", arguments: [nil, Int64(0), Int64(49_999_999)])
    func preflightCapacity(_ capacity: Int64?) async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        library.capacity = capacity
        let storage = library.coordinator()
        await #expect(throws: (any Error).self) { try await storage.beginLocalStorage(removeCloudCopies: true) }
        #expect(storage.mode == .iCloud)
        #expect(library.network.deleted.isEmpty)
        #expect(library.network.downloads.isEmpty)
        #expect(library.names.isSubset(of: library.cloud.storedPersistentAssetNames()))
    }

    @Test("Small cloud libraries complete with less than the background cache reserve", arguments: [false, true])
    func smallLibraryUsesScaledMargin(removeCloudCopies: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try await library.uploadOriginals()
        try await library.makeRemoteOnly()
        library.capacity = 80_000_000
        let storage = library.coordinator()
        let estimate = try await storage.estimate(forLocalStorage: true)
        #expect(estimate.safetyMarginBytes == 50_000_000)
        #expect(estimate.requiredDeviceBytes < 80_000_000)
        try await storage.beginLocalStorage(removeCloudCopies: removeCloudCopies)
        await storage.resumeAndWait()
        #expect(storage.mode == .local)
        #expect(storage.errorMessage == nil)
        try await library.assertLocalOriginals()
        #expect(library.network.records.isEmpty == removeCloudCopies)
    }

    @Test("Unavailable remote metadata cannot silently omit originals", arguments: [CKError.Code.networkFailure, .notAuthenticated, .serviceUnavailable])
    func remotePreflightFailure(_ code: CKError.Code) async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try await library.uploadOriginals()
        try await library.makeRemoteOnly()
        library.network.metadataFailure = CKError(code)
        let storage = library.coordinator()
        await #expect(throws: (any Error).self) { try await storage.beginLocalStorage(removeCloudCopies: false) }
        #expect(storage.mode == .iCloud)
        #expect(library.network.records.count == 3)
        #expect(library.network.deleted.isEmpty)
    }

    @Test("A missing remote original blocks the entire switch")
    func missingOriginal() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try await library.makeRemoteOnly()
        library.network.data.removeValue(forKey: try #require(library.names.first))
        let storage = library.coordinator()
        await #expect(throws: (any Error).self) { try await storage.beginLocalStorage(removeCloudCopies: true) }
        #expect(storage.mode == .iCloud)
        #expect(library.network.deleted.isEmpty)
    }

    @Test("Partial downloads survive reconstructed stores and skip completed resources")
    func interruptedRemoteDownload() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try await library.uploadOriginals()
        try await library.makeRemoteOnly()
        let names = library.names.sorted()
        library.network.failingDownloads = [names[1]]
        let storage = library.coordinator()
        try await storage.beginLocalStorage(removeCloudCopies: false)
        await storage.resumeAndWait()
        #expect(storage.mode == .downloading)
        #expect(storage.errorMessage != nil)
        #expect(try await library.cloud.offlineStore.assetNames() == [names[0]])
        library.network.failingDownloads = []
        try await library.reopen()
        let resumed = library.coordinator()
        await resumed.resumeAndWait()
        #expect(resumed.mode == .local)
        #expect(resumed.errorMessage == nil)
        #expect(library.network.downloads.filter { $0 == names[0] }.count == 1)
        try await library.assertLocalOriginals()
        #expect(library.network.records.count == 3)
    }

    @Test("A foreground suspension leaves a resumable download checkpoint")
    func cancelledTaskResumes() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try await library.uploadOriginals()
        try await library.makeRemoteOnly()
        let storage = library.coordinator()
        library.network.afterDownload = { _ in storage.suspend() }
        try await storage.beginLocalStorage(removeCloudCopies: true)
        await storage.resumeAndWait()
        #expect(storage.mode == .downloading)
        #expect(library.network.deleted.isEmpty)
        library.network.afterDownload = nil
        try await library.reopen()
        let resumed = library.coordinator()
        await resumed.resumeAndWait()
        #expect(resumed.errorMessage == nil)
        #expect(resumed.mode == .local)
        #expect(library.network.records.isEmpty)
        try await library.assertLocalOriginals()
    }

    @Test("Space exhaustion during download preserves verified work and retries")
    func spaceRunsOutMidDownload() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try await library.uploadOriginals()
        try await library.makeRemoteOnly()
        library.network.afterDownload = { _ in library.capacity = 0 }
        let storage = library.coordinator()
        try await storage.beginLocalStorage(removeCloudCopies: true)
        await storage.resumeAndWait()
        #expect(storage.mode == .downloading)
        #expect(storage.errorMessage != nil)
        #expect(try await library.cloud.offlineStore.assetNames().count == 1)
        #expect(library.network.deleted.isEmpty)
        library.capacity = 10_000_000_000
        library.network.afterDownload = nil
        await storage.resumeAndWait()
        #expect(storage.mode == .local)
        #expect(storage.errorMessage == nil)
        try await library.assertLocalOriginals()
    }

    @Test("Account changes during download stop before deletion")
    func accountChangesMidDownload() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try await library.uploadOriginals()
        try await library.makeRemoteOnly()
        library.network.afterDownload = { _ in library.network.account = "a-different-account" }
        let storage = library.coordinator()
        try await storage.beginLocalStorage(removeCloudCopies: true)
        await storage.resumeAndWait()
        #expect(storage.mode == .downloading)
        #expect(storage.errorMessage != nil)
        #expect(library.network.deleted.isEmpty)
        #expect(library.network.records.count == 3)
    }

    @Test("Photos added remotely after confirmation block destructive completion")
    func remoteLibraryChangesDuringDownload() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try await library.uploadOriginals()
        try await library.makeRemoteOnly()
        library.network.afterDownload = { _ in library.network.records.insert(CKRecord.ID(recordName: "late-photo")) }
        let storage = library.coordinator()
        try await storage.beginLocalStorage(removeCloudCopies: true)
        await storage.resumeAndWait()
        #expect(storage.mode == .downloading)
        #expect(storage.errorMessage != nil)
        #expect(library.network.deleted.isEmpty)
        try await library.assertLocalOriginals()
    }

    @Test("Success responses cannot conceal cloud copies that still exist")
    func deletionVerifiesAbsence() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try await library.uploadOriginals()
        library.network.ignoresDeletion = true
        let storage = library.coordinator()
        try await storage.beginLocalStorage(removeCloudCopies: true)
        await storage.resumeAndWait()
        #expect(storage.mode == .deletingCloudCopies)
        #expect(storage.errorMessage != nil)
        #expect(library.network.records.count == 3)
        try await library.assertLocalOriginals()
        library.network.ignoresDeletion = false
        try await library.reopen()
        let resumed = library.coordinator()
        await resumed.resumeAndWait()
        #expect(resumed.mode == .local)
        #expect(resumed.errorMessage == nil)
        #expect(library.network.records.isEmpty)
        #expect(try library.persistence.container.viewContext.fetch(DailyPhoto.fetchRequest()).first?.id == library.photoID)
    }

    @Test("Deletion retries after partial batches and is idempotent for missing targets")
    func partialBatchDeletion() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let ids = (0..<251).map { CKRecord.ID(recordName: "owned-metadata-\($0)") }
        library.network.records = Set(ids)
        library.network.failDeletionAtBatch = 2
        let plan = PhotoCloudDeletionPlan(accountID: library.network.account, metadataRecords: ids.map(PhotoCloudDeletionPlan.Record.init), assetNames: [])
        await #expect(throws: (any Error).self) { try await library.copies().remove(plan) }
        #expect(library.network.deleted.count == 100)
        #expect(library.network.records.count == 151)
        library.network.failDeletionAtBatch = nil
        try await library.copies().remove(plan)
        try await library.copies().remove(plan)
        #expect(library.network.deleted == Set(ids))
        #expect(library.network.records.isEmpty)
    }

    @Test("Cancelling a failed remote download keeps all remaining originals in iCloud")
    func cancelAfterDownloadFailure() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try await library.uploadOriginals()
        try await library.makeRemoteOnly()
        library.network.failingDownloads = library.names
        let storage = library.coordinator()
        try await storage.beginLocalStorage(removeCloudCopies: true)
        await storage.resumeAndWait()
        try await storage.cancelLocalSwitch()
        #expect(storage.mode == .iCloud)
        #expect(library.modeStore.deletionPlan == nil)
        #expect(library.network.records.count == 3)
        #expect(library.network.deleted.isEmpty)
    }

    @Test("A missing local original blocks enabling iCloud before upload ownership changes")
    func missingLocalOriginalBlocksUpload() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try library.modeStore.set(.local)
        library.cloud.removeStagedAsset(named: try #require(library.names.first))
        let storage = library.coordinator()
        await #expect(throws: (any Error).self) { try await storage.beginICloudStorage() }
        #expect(storage.mode == .local)
        #expect(library.cloud.uploadStateStore.entry(for: library.photoID) == nil)
        #expect(library.network.uploads.isEmpty)
    }

    @Test("Signing out prevents enabling iCloud and preserves local originals")
    func signedOutBlocksUpload() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try library.modeStore.set(.local)
        library.network.accountFailure = CKError(.notAuthenticated)
        let storage = library.coordinator()
        await #expect(throws: (any Error).self) { try await storage.beginICloudStorage() }
        #expect(storage.mode == .local)
        #expect(library.names.isSubset(of: library.cloud.storedPersistentAssetNames()))
        #expect(library.network.uploads.isEmpty)
    }

    @Test("Upload preparation resumes from disk and journals every Live resource")
    func uploadPreparationRestart() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try library.modeStore.set(.preparingUpload, downloadAccountID: library.network.account)
        try await library.reopen()
        let storage = library.coordinator()
        await storage.resumeAndWait()
        #expect(storage.errorMessage == nil)
        #expect(storage.mode == .iCloud)
        let entry = try #require(library.cloud.uploadStateStore.entry(for: library.photoID))
        #expect(entry.state == .pending)
        #expect(entry.assetNames == library.names)
        #expect(library.network.uploads.isEmpty, "Preparation must retain upload ownership before the uploader starts.")
    }

    @Test("Repeated switches preserve photo identity, details, and resource bytes", arguments: [false, true])
    func repeatedSwitches(removeCopies: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try await library.uploadOriginals()
        for _ in 0..<3 {
            let storage = library.coordinator()
            try await storage.beginLocalStorage(removeCloudCopies: removeCopies)
            await storage.resumeAndWait()
            #expect(storage.errorMessage == nil)
            #expect(storage.mode == .local)
            try await library.assertLocalOriginals()
            try await storage.beginICloudStorage()
            await storage.resumeAndWait()
            #expect(storage.errorMessage == nil)
            #expect(storage.mode == .iCloud)
            #expect(try await library.uploader().uploadNextPendingPhotoForTesting(in: library.persistence.makeBackgroundContext()))
            #expect(library.cloud.uploadStateStore.entry(for: library.photoID)?.state == .uploaded)
            try await library.reopen()
            let photos = try library.persistence.container.viewContext.fetch(DailyPhoto.fetchRequest())
            let photo = try #require(photos.first)
            #expect(photos.count == 1)
            #expect(photo.id == library.photoID)
            #expect(photo.locationName == "Synthetic storage-test location")
            #expect(photo.isHearted)
            #expect(photo.captureDate == Date(timeIntervalSince1970: 1_700_000_000))
            #expect(photo.latitude == 48.1)
            #expect(photo.longitude == 11.6)
        }
    }

    @Test("Every non-cloud phase prevents asset uploads", arguments: [PhotoStorageMode.local, .downloading, .deletingCloudCopies, .preparingUpload])
    func uploadGuard(_ mode: PhotoStorageMode) async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try library.modeStore.set(mode)
        let name = try #require(library.names.first)
        await #expect(throws: CancellationError.self) { try await library.cloud.uploadStagedAsset(named: name, photoID: library.photoID, role: .still) }
        #expect(library.network.uploads.isEmpty)
        #expect(library.cloud.stagedAssetURL(named: name) != nil)
    }

    @Test("Adding or deleting photos cannot race a migration", arguments: [PhotoStorageMode.downloading, .deletingCloudCopies, .preparingUpload])
    func libraryMutationGuard(_ mode: PhotoStorageMode) async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try library.modeStore.set(mode)
        let context = library.persistence.container.viewContext
        let objectID = try #require(try context.fetch(DailyPhoto.fetchRequest()).first?.objectID)
        let service = PhotoStorageService(cloudKitService: library.cloud)
        await #expect(throws: PhotoStorageMigrationError.self) { try await service.deletePhoto(objectID, context: context) }
        await #expect(throws: PhotoStorageMigrationError.self) {
            _ = try await service.savePhoto(image: UIImage(), imageData: Data([1]), location: nil, context: context, enqueuesPendingUpload: false)
        }
        #expect(try context.count(for: DailyPhoto.fetchRequest()) == 1)
        #expect(library.names.isSubset(of: library.cloud.storedPersistentAssetNames()))
        #expect(library.network.deleted.isEmpty)
    }

    @Test("Corrupt remote bytes cannot become verified local originals or permit cloud deletion")
    func corruptRemoteDownload() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try await library.uploadOriginals()
        try await library.makeRemoteOnly()
        let name = library.names.sorted()[0]
        let data = try #require(library.network.data[name])
        try Data(repeating: 0xff, count: data.count).write(to: #require(library.network.urls[name]))
        let storage = library.coordinator()
        try await storage.beginLocalStorage(removeCloudCopies: true)
        await storage.resumeAndWait()
        #expect(storage.mode == .downloading)
        #expect(storage.errorMessage != nil)
        #expect(try await library.cloud.offlineStore.assetNames().isEmpty)
        #expect(library.network.records.count == 3)
        #expect(library.network.deleted.isEmpty)
    }

    @Test("An unwritable mode checkpoint never changes the in-memory privacy preference")
    func checkpointWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageCheckpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocked")
        try Data([0]).write(to: blocker)
        let store = PhotoStorageModeStore(storageURL: blocker.appendingPathComponent("mode.json"))
        #expect(store.mode == .iCloud)
        #expect(throws: (any Error).self) { try store.set(.local) }
        #expect(store.mode == .iCloud)
        #expect(try Data(contentsOf: blocker) == Data([0]))
    }

    @Test("Repeated start requests do not create duplicate local stores or uploads")
    func duplicateStart() async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try await library.uploadOriginals()
        let storage = library.coordinator()
        try await storage.beginLocalStorage(removeCloudCopies: true)
        try await storage.beginLocalStorage(removeCloudCopies: true)
        await storage.resumeAndWait()
        #expect(storage.errorMessage == nil)
        let filename = library.modeStore.storeFilename
        try await storage.beginLocalStorage(removeCloudCopies: true)
        #expect(library.modeStore.storeFilename == filename)
        try await storage.beginICloudStorage()
        try await storage.beginICloudStorage()
        await storage.resumeAndWait()
        #expect(storage.errorMessage == nil)
        #expect(library.cloud.uploadStateStore.allEntries().count == 1)
        #expect(try library.persistence.container.viewContext.count(for: DailyPhoto.fetchRequest()) == 1)
    }

    @Test("Upload failures after consent preserve originals and allow switching back to local", arguments: [CKError.Code.quotaExceeded, .networkFailure, .notAuthenticated])
    func failedUploadRoundTrip(_ code: CKError.Code) async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        try library.modeStore.set(.local)
        var storage = library.coordinator()
        try await storage.beginICloudStorage()
        await storage.resumeAndWait()
        try #require(storage.mode == .iCloud)
        library.network.uploadFailure = CKError(code)
        let uploader = library.uploader()
        await #expect(throws: CKError.self) { _ = try await uploader.uploadNextPendingPhotoForTesting(in: library.persistence.makeBackgroundContext()) }
        #expect(library.cloud.uploadStateStore.entry(for: library.photoID)?.state != .uploaded)
        if code == .quotaExceeded {
            #expect(library.cloud.uploadStateStore.entry(for: library.photoID)?.failureReason == .iCloudStorageFull)
        }
        #expect(library.names.isSubset(of: library.cloud.storedPersistentAssetNames()))
        try await library.reopen()
        storage = library.coordinator()
        try await storage.beginLocalStorage(removeCloudCopies: false)
        await storage.resumeAndWait()
        #expect(storage.errorMessage == nil)
        #expect(storage.mode == .local)
        try await library.assertLocalOriginals()
        library.network.uploadFailure = nil
        try await storage.beginICloudStorage()
        await storage.resumeAndWait()
        try #require(storage.mode == .iCloud)
        #expect(try await library.uploader().uploadNextPendingPhotoForTesting(in: library.persistence.makeBackgroundContext()))
        #expect(library.cloud.uploadStateStore.entry(for: library.photoID)?.state == .uploaded)
        #expect(Set(library.network.uploads) == library.names)
    }

    @Test("Local captures and imports work without iCloud and survive reopening", arguments: [false, true])
    func localCaptureAndImport(importPhoto: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        try library.modeStore.set(.local)
        library.network.accountFailure = CKError(.notAuthenticated)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        let bytes = try #require(image.pngData())
        let service = PhotoStorageService(cloudKitService: library.cloud)
        let context = library.persistence.container.viewContext
        let objectID: NSManagedObjectID
        if importPhoto {
            objectID = try await service.saveImportedPhoto(imageData: bytes, context: context, enqueuesPendingUpload: false)
        } else {
            objectID = try await service.savePhoto(image: image, imageData: bytes, location: nil, context: context, enqueuesPendingUpload: false)
        }
        let photo = try #require(try context.existingObject(with: objectID) as? DailyPhoto)
        let id = try #require(photo.id)
        let name = try #require(photo.fullImageAssetName)
        #expect(try Data(contentsOf: #require(library.cloud.stagedAssetURL(named: name))) == bytes)
        #expect(library.cloud.uploadStateStore.entry(for: id)?.state == .pending)
        try await library.reopen()
        let restored = try #require(try library.persistence.container.viewContext.fetch(DailyPhoto.fetchRequest()).first)
        #expect(restored.id == id)
        #expect(library.modeStore.mode == .local)
        let readable = try await library.cloud.loadAssetURL(named: name)
        #expect(try Data(contentsOf: readable) == bytes)
        #expect(library.network.downloads.isEmpty)
        #expect(library.network.uploads.isEmpty)
    }
}
