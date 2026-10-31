import CoreData
import CloudKit
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

    @Test("Metadata failures stay visible through retries and unrelated successful imports", arguments: [
        CKError.Code.networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy
    ])
    func metadataRetryRemainsVisible(code: CKError.Code) throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.finish(.export, error: CKError(code))
        let detail = fixture.monitor.statusDetail
        #expect(fixture.monitor.statusTitle == "iCloud sync will retry automatically")
        #expect(fixture.monitor.showsStatusDetail)
        #expect(fixture.monitor.isFailing == false)

        let retryID = fixture.start(.export)
        fixture.finish(.import)
        #expect(fixture.monitor.statusTitle == "iCloud sync will retry automatically")
        #expect(fixture.monitor.statusDetail == detail)
        #expect(fixture.monitor.showsStatusDetail)

        fixture.finish(.export, identifier: retryID)
        #expect(fixture.monitor.syncState == .idle)
        #expect(fixture.monitor.statusTitle == "iCloud sync is ready")
        #expect(fixture.monitor.showsStatusDetail == false)
    }

    @Test("A wrapped iCloud network failure explains the automatic retry")
    func wrappedMetadataNetworkFailure() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let networkError = CKError(.networkFailure, userInfo: [
            NSUnderlyingErrorKey: URLError(.cannotParseResponse)
        ])
        let error = NSError(domain: NSCocoaErrorDomain, code: 134409, userInfo: [NSUnderlyingErrorKey: networkError])
        fixture.finish(.export, error: error)

        #expect(fixture.monitor.statusTitle == "iCloud sync will retry automatically")
        #expect(fixture.monitor.statusDetail.contains("network request failed"))
        #expect(fixture.monitor.statusDetail.contains("retry automatically"))
    }

    @Test("Nontransient metadata failures keep their warning until the matching operation succeeds")
    func metadataFailureRequiresMatchingSuccess() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let error = NSError(domain: "CloudSyncMonitorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid photo metadata"])
        fixture.finish(.export, error: error)
        let retryID = fixture.start(.export)
        fixture.finish(.setup)
        fixture.finish(.import)

        #expect(fixture.monitor.statusTitle == "iCloud sync needs attention")
        #expect(fixture.monitor.statusDetail == "Invalid photo metadata")
        #expect(fixture.monitor.statusSymbolName == "exclamationmark.icloud")
        #expect(fixture.monitor.isFailing)

        fixture.finish(.export, identifier: retryID)
        #expect(fixture.monitor.syncState == .idle)
        #expect(fixture.monitor.isFailing == false)
    }

    @Test("An overlapping import completing does not end an active export")
    func overlappingMetadataOperations() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let exportID = fixture.start(.export)
        let importID = fixture.start(.import)
        #expect(fixture.monitor.isMetadataImportActive)

        fixture.finish(.import, identifier: importID)
        #expect(fixture.monitor.isMetadataImportActive == false)
        #expect(fixture.monitor.syncState == .syncing(.export))

        fixture.finish(.export, identifier: exportID)
        #expect(fixture.monitor.syncState == .idle)
    }

    @Test("Finishing one import leaves another import active")
    func overlappingMetadataImports() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let firstID = fixture.start(.import)
        let secondID = fixture.start(.import)

        fixture.finish(.import, identifier: firstID)
        #expect(fixture.monitor.isMetadataImportActive)
        #expect(fixture.monitor.syncState == .syncing(.import))

        fixture.finish(.import, identifier: secondID)
        #expect(fixture.monitor.isMetadataImportActive == false)
        #expect(fixture.monitor.syncState == .idle)
    }

    @Test("System deferral cannot clear a previous export failure")
    func metadataDeferralPreservesFailure() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.finish(.export, error: CKError(.networkFailure))
        let retryID = fixture.start(.export)
        fixture.finish(.export, identifier: retryID, error: NSError(domain: NSCocoaErrorDomain, code: 134419))

        #expect(fixture.monitor.statusTitle == "iCloud sync will retry automatically")
        #expect(fixture.monitor.showsStatusDetail)
    }

    @Test("Recovering an export does not erase a separate import failure")
    func metadataFailuresRecoverIndependently() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.finish(.export, error: CKError(.networkFailure))
        fixture.finish(.import, error: CKError(.serviceUnavailable))
        fixture.finish(.export)
        #expect(fixture.monitor.statusTitle == "iCloud sync will retry automatically")

        fixture.finish(.import)
        #expect(fixture.monitor.syncState == .idle)
    }

    @Test("Another library's events cannot change this library's sync status")
    func ignoresOtherLibraryEvents() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.finish(.export, error: CKError(.networkFailure))
        fixture.monitor.handleCloudKitEvent(identifier: UUID(), storeIdentifier: "another-library",
                                           type: .export, endDate: Date(), error: nil)
        #expect(fixture.monitor.statusTitle == "iCloud sync will retry automatically")

        fixture.finish(.export)
        fixture.monitor.handleCloudKitEvent(identifier: UUID(), storeIdentifier: "another-library",
                                           type: .export, endDate: nil, error: nil)
        #expect(fixture.monitor.syncState == .idle)
    }

    @Test("Replacing the active library clears its old failure and unfinished operations")
    func replacingLibraryResetsMetadataStatus() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.finish(.export, error: CKError(.networkFailure))
        fixture.start(.export)
        let coordinator = fixture.persistence.container.persistentStoreCoordinator
        for store in coordinator.persistentStores { try coordinator.remove(store) }
        let replacement = try coordinator.addPersistentStore(ofType: NSInMemoryStoreType,
                                                             configurationName: nil, at: nil)
        fixture.monitor.handleCloudKitEvent(identifier: UUID(), storeIdentifier: try #require(replacement.identifier),
                                           type: .import, endDate: Date(), error: nil)

        #expect(fixture.monitor.syncState == .idle)
        #expect(fixture.monitor.statusTitle == "iCloud sync is ready")
    }

    @Test("Account recovery restores unresolved failures without retaining interrupted operations")
    func accountRecoveryPreservesUnresolvedFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.finish(.export, error: CKError(.networkFailure))
        fixture.start(.import)
        fixture.availability.isUnavailable = true
        await fixture.monitor.refreshUploadStatus()
        #expect(fixture.monitor.statusTitle == "iCloud sync is unavailable")
        #expect(fixture.monitor.isMetadataImportActive == false)

        fixture.availability.isUnavailable = false
        await fixture.monitor.refreshUploadStatus()
        #expect(fixture.monitor.statusTitle == "iCloud sync will retry automatically")

        fixture.finish(.export)
        #expect(fixture.monitor.syncState == .idle)
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
        let storeIdentifier: String
        var context: NSManagedObjectContext { persistence.container.viewContext }

        init(mode: PhotoStorageMode = .iCloud, isUnavailable: Bool = false, reason: String? = nil,
             usesSimulatorExamples: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSyncMonitorTests-\(UUID())")
            uploadStore = LocalPhotoUploadStore(storageURL: root.appendingPathComponent("uploads.json"))
            modeStore = PhotoStorageModeStore(storageURL: root.appendingPathComponent("preference/mode.json"))
            try modeStore.set(mode)
            let availability = Availability(isUnavailable: isUnavailable, reason: reason)
            self.availability = availability
            storeIdentifier = try #require(persistence.container.persistentStoreCoordinator.persistentStores.first?.identifier)
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

        @discardableResult
        func start(_ type: NSPersistentCloudKitContainer.EventType) -> UUID {
            let identifier = UUID()
            monitor.handleCloudKitEvent(identifier: identifier, storeIdentifier: storeIdentifier,
                                       type: type, endDate: nil, error: nil)
            return identifier
        }

        func finish(_ type: NSPersistentCloudKitContainer.EventType, identifier: UUID = UUID(), error: (any Error)? = nil) {
            monitor.handleCloudKitEvent(identifier: identifier, storeIdentifier: storeIdentifier,
                                       type: type, endDate: Date(), error: error)
        }

        func removeFiles() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
