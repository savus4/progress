import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct CloudSyncMonitorTests {
    @Test("Unavailable iCloud is distinct from the local-only preference and recovers", arguments: [
        "iCloud is not signed in on this device.", "iCloud is temporarily unavailable."
    ])
    func cloudUnavailableDoesNotImplyLocalOnly(reason: String) async throws {
        let fixture = try Fixture(isUnavailable: true, reason: reason)
        defer { fixture.removeFiles() }
        await fixture.monitor.refreshUploadStatus()
        #expect(fixture.modeStore.mode == .iCloud)
        #expect(fixture.monitor.statusTitle == "iCloud sync is unavailable")
        #expect(fixture.monitor.statusDetail.contains(reason))
        #expect(fixture.monitor.statusDetail.contains("enabled in Photo Storage"))
        #expect(fixture.monitor.showsStatusDetail)
        #expect(fixture.monitor.isFailing)
        #expect(fixture.monitor.statusSymbolName == "icloud.slash")

        fixture.availability.isUnavailable = false
        await fixture.monitor.refreshUploadStatus()
        #expect(fixture.monitor.statusTitle == "iCloud sync is ready")
        #expect(fixture.monitor.showsStatusDetail == false)
        #expect(fixture.monitor.isFailing == false)
        #expect(fixture.modeStore.mode == .iCloud)
    }

    @Test("Local-only status follows the preference regardless of account availability", arguments: [false, true])
    func explicitLocalOnly(isUnavailable: Bool) async throws {
        let fixture = try Fixture(mode: .local, isUnavailable: isUnavailable)
        defer { fixture.removeFiles() }
        await fixture.monitor.refreshUploadStatus()
        #expect(fixture.monitor.statusTitle == "Photos stored only on this device")
        #expect(fixture.monitor.statusSymbolName == "internaldrive")
        #expect(fixture.monitor.showsStatusDetail)
        #expect(fixture.monitor.isFailing == false)
    }

    @Test("Simulator examples explain their separate local library without changing the normal preference")
    func simulatorExampleStatus() async throws {
        let fixture = try Fixture(usesSimulatorExamples: true)
        defer { fixture.removeFiles() }
        await fixture.monitor.refreshUploadStatus()
        #expect(fixture.monitor.statusTitle == "Simulator example library")
        #expect(fixture.monitor.statusDetail.contains("iCloud sync is disabled for this example library"))
        #expect(fixture.monitor.showsStatusDetail)
        #expect(fixture.monitor.isFailing == false)
        #expect(fixture.monitor.statusSymbolName == "internaldrive")
        #expect(fixture.modeStore.mode == .iCloud)
    }

    @Test("Migration status takes precedence over an unavailable iCloud account", arguments: [
        PhotoStorageMode.downloading, .deletingCloudCopies, .preparingUpload
    ])
    func migrationStatus(mode: PhotoStorageMode) async throws {
        let fixture = try Fixture(mode: mode, isUnavailable: true)
        defer { fixture.removeFiles() }
        await fixture.monitor.refreshUploadStatus()
        let expected = switch mode {
        case .downloading: "Switching to local photo storage"
        case .deletingCloudCopies: "Removing iCloud copies"
        case .preparingUpload: "Preparing private iCloud upload"
        default: ""
        }
        #expect(fixture.monitor.statusTitle == expected)
        #expect(fixture.monitor.showsStatusDetail)
        #expect(fixture.monitor.isFailing == false)
    }

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
        final class Availability {
            var isUnavailable: Bool
            let reason: String?

            init(isUnavailable: Bool, reason: String?) {
                self.isUnavailable = isUnavailable
                self.reason = reason
            }
        }

        let root: URL
        let persistence = PersistenceController(inMemory: true)
        let uploadStore: LocalPhotoUploadStore
        let monitor: CloudSyncMonitor
        let modeStore: PhotoStorageModeStore
        let availability: Availability
        var context: NSManagedObjectContext { persistence.container.viewContext }

        init(mode: PhotoStorageMode = .iCloud, isUnavailable: Bool = false, reason: String? = nil,
             usesSimulatorExamples: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSyncMonitorTests-\(UUID())")
            uploadStore = LocalPhotoUploadStore(storageURL: root.appendingPathComponent("uploads.json"))
            modeStore = PhotoStorageModeStore(storageURL: root.appendingPathComponent("preference/mode.json"))
            try modeStore.set(mode)
            let availability = Availability(isUnavailable: isUnavailable, reason: reason)
            self.availability = availability
            monitor = CloudSyncMonitor(
                context: persistence.container.viewContext,
                uploadStore: uploadStore,
                iCloudUnavailableProvider: { availability.isUnavailable },
                observesChanges: false,
                storageModeStore: modeStore,
                iCloudUnavailableReasonProvider: { availability.reason },
                usesSimulatorExampleLibrary: usesSimulatorExamples
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
