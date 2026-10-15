import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct CloudSyncMonitorTests {
    @Test("Unuploaded originals remain visible even when staged files are missing", arguments: [
        PhotoUploadState.pending, .uploading, .failed, .paused
    ])
    func missingStagedAssetsDoNotHideUploadStatus(state: PhotoUploadState) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        _ = try fixture.makePhoto(state: state)

        await fixture.monitor.refreshUploadStatus()

        #expect(fixture.monitor.statusTitle != "iCloud sync is ready")
        #expect(fixture.monitor.pendingUploadCount == (state == .pending ? 1 : 0))
        #expect(fixture.monitor.uploadingAssetCount == (state == .uploading ? 1 : 0))
        #expect(fixture.monitor.failedUploadCount == (state == .failed ? 1 : 0))
        #expect(fixture.monitor.pausedUploadCount == (state == .paused ? 1 : 0))
        #expect(fixture.monitor.hasRetryableUploads == (state == .failed || state == .paused))
        if state == .paused {
            #expect(fixture.monitor.statusTitle == "Some photo uploads are paused")
            #expect(fixture.monitor.isFailing)
            #expect(fixture.monitor.statusSymbolName == "exclamationmark.icloud")
            #expect(fixture.monitor.statusDetail.contains("1 photo"))
        }
    }

    @Test("A missing staged original does not hide a persisted iCloud quota pause")
    func quotaPauseRemainsVisible() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto(state: .paused)
        try fixture.uploadStore.update(photoID: try #require(photo.id)) {
            $0.failureReason = .iCloudStorageFull
        }

        await fixture.monitor.refreshUploadStatus()

        #expect(fixture.monitor.pausedUploadCount == 1)
        #expect(fixture.monitor.isICloudStorageFull)
        #expect(fixture.monitor.statusTitle == "iCloud storage is full")
        #expect(fixture.monitor.statusDetail.contains("have not uploaded"))
    }

    @Test("Uploaded, deleted, and remote-only bookkeeping do not create local upload warnings")
    func ignoresCompletedAndUnownedUploads() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        _ = try fixture.makePhoto(state: .uploaded)
        let deleted = try fixture.makePhoto(state: .paused)
        fixture.context.delete(deleted)
        let remotePhoto = DailyPhoto(context: fixture.context)
        remotePhoto.id = UUID()
        remotePhoto.captureDate = Date()
        remotePhoto.fullImageAssetName = "remote.heic"
        remotePhoto.uploadStateRaw = PhotoUploadState.paused.rawValue
        try fixture.context.save()

        await fixture.monitor.refreshUploadStatus()

        #expect(fixture.monitor.pendingUploadCount == 0)
        #expect(fixture.monitor.uploadingAssetCount == 0)
        #expect(fixture.monitor.failedUploadCount == 0)
        #expect(fixture.monitor.pausedUploadCount == 0)
        #expect(!fixture.monitor.hasRetryableUploads)
        #expect(!fixture.monitor.isFailing)
        #expect(fixture.monitor.statusTitle == "iCloud sync is ready")
    }

    @Test("An upload warning clears only after the local journal records success")
    func refreshReflectsCompletedUpload() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto(state: .paused)
        await fixture.monitor.refreshUploadStatus()
        #expect(fixture.monitor.pausedUploadCount == 1)

        try fixture.uploadStore.update(photoID: try #require(photo.id)) { $0.state = .uploaded }
        await fixture.monitor.refreshUploadStatus()

        #expect(fixture.monitor.pausedUploadCount == 0)
        #expect(!fixture.monitor.hasRetryableUploads)
        #expect(!fixture.monitor.isFailing)
        #expect(fixture.monitor.statusTitle == "iCloud sync is ready")
    }

    private final class Fixture {
        let root: URL
        let persistence = PersistenceController(inMemory: true)
        let uploadStore: LocalPhotoUploadStore
        let monitor: CloudSyncMonitor
        var context: NSManagedObjectContext { persistence.container.viewContext }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSyncMonitorTests-\(UUID())")
            uploadStore = LocalPhotoUploadStore(storageURL: root.appendingPathComponent("uploads.json"))
            monitor = CloudSyncMonitor(
                context: persistence.container.viewContext,
                uploadStore: uploadStore,
                iCloudUnavailableProvider: { false },
                observesChanges: false
            )
        }

        func makePhoto(state: PhotoUploadState) throws -> DailyPhoto {
            let photo = DailyPhoto(context: context)
            let id = UUID()
            let assetName = "\(id).heic"
            photo.id = id
            photo.captureDate = Date()
            photo.createdAt = Date()
            photo.fullImageAssetName = assetName
            try context.save()
            try uploadStore.register(LocalPhotoUpload(
                photoID: id,
                stillAssetName: assetName,
                livePhotoImageAssetName: nil,
                videoAssetName: nil,
                createdAt: Date(),
                state: state
            ))
            return photo
        }

        func removeFiles() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
