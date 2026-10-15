import CloudKit
import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct PhotoUploadRecoveryTests {
    @Test("Paused uploads recover complete Live originals from existing local copies", arguments: Source.allCases)
    func recoversLocalOriginals(source: Source) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto(separateLiveImage: source == .legacy)
        let names = fixture.names(for: photo)
        for name in names { try await fixture.saveOriginal(named: name, source: source) }

        #expect(try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context))

        #expect(fixture.entry(for: photo)?.state == .uploaded)
        #expect(Set(fixture.recorder.uploadedNames) == names)
        #expect(Set(fixture.recorder.checkedNames) == names)
        for name in names {
            #expect(fixture.recorder.uploadedData[name] == fixture.original(named: name))
            #expect(try Data(contentsOf: fixture.sourceURL(named: name, source: source)) == fixture.original(named: name))
        }
        #expect(photo.uploadStateRaw == PhotoUploadState.paused.rawValue)
        #expect(!fixture.context.hasChanges)
    }

    @Test("The old CKError 16 journal resumes automatically after restarting")
    func recoversLegacyPause() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto()
        let id = try #require(photo.id)
        try fixture.cloud.uploadStateStore.update(photoID: id) {
            $0.failureReason = nil
            $0.errorMessage = "CKError(16): open error: 2 (No such file or directory)"
            $0.attemptCount = 3
        }
        for name in fixture.names(for: photo) { try await fixture.saveOriginal(named: name, source: .offline) }
        let reloaded = LocalPhotoUploadStore(storageURL: fixture.root.appendingPathComponent("local-uploads.json"))
        let restartedCloud = CloudKitService(
            stagingDirectoryURL: fixture.staging,
            temporaryReadableAssetsDirectoryURL: fixture.readable,
            legacyAssetDirectoryURLs: [],
            uploadStateStore: reloaded,
            assetUploader: { [recorder = fixture.recorder] name, _, _ in recorder.uploadedNames.append(name) },
            remoteAssetExistenceChecker: { _ in false },
            offlineSettingsDefaults: fixture.defaults
        )
        let restartedUploader = PhotoUploadService(cloudKitService: restartedCloud)

        #expect(try await restartedUploader.uploadNextPendingPhotoForTesting(in: fixture.context))
        #expect(reloaded.entry(for: id)?.state == .uploaded)
        #expect(reloaded.entry(for: id)?.attemptCount == 4)
    }

    @Test("Manual retry includes locally owned photos whose staging files disappeared")
    func manualRetryFindsMissingStaging() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto()
        for name in fixture.names(for: photo) { try await fixture.saveOriginal(named: name, source: .offline) }

        #expect(await fixture.uploader.resetFailedUploads(in: fixture.context) == 1)
        #expect(fixture.entry(for: photo)?.state == .pending)
        #expect(try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context))
        #expect(fixture.entry(for: photo)?.state == .uploaded)
    }

    @Test("Confirmed cloud assets repair stale upload state without uploading or downloading again")
    func reconcilesCloudCopies() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto()
        fixture.recorder.remoteNames = fixture.names(for: photo)

        #expect(try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context))

        #expect(fixture.entry(for: photo)?.state == .uploaded)
        #expect(fixture.recorder.uploadedNames.isEmpty)
        #expect(Set(fixture.recorder.checkedNames) == fixture.names(for: photo))
        #expect(fixture.cloud.storedPersistentAssetNames().isEmpty)
    }

    @Test("A partial cloud upload restores and uploads only the missing Live resource")
    func recoversPartialLiveUpload() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto()
        let still = try #require(photo.fullImageAssetName)
        let video = try #require(photo.livePhotoVideoAssetName)
        fixture.recorder.remoteNames = [still]
        try await fixture.saveOriginal(named: video, source: .offline)

        #expect(try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context))

        #expect(fixture.recorder.uploadedNames == [video])
        #expect(fixture.entry(for: photo)?.state == .uploaded)
    }

    @Test("CloudKit losing an in-flight file rebuilds staging and retries once")
    func repairsFileLostDuringUpload() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto(isLive: false)
        let name = try #require(photo.fullImageAssetName)
        try await fixture.saveOriginal(named: name, source: .offline)
        _ = try fixture.cloud.stageAssetData(fixture.original(named: name), named: name)
        fixture.recorder.missingFileFailuresRemaining = 1

        #expect(try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context))

        #expect(fixture.recorder.uploadedNames == [name, name])
        #expect(fixture.entry(for: photo)?.state == .uploaded)
        let offlineURL = try #require(try await fixture.cloud.offlineStore.assetURL(named: name))
        #expect(try Data(contentsOf: offlineURL) == fixture.original(named: name))
    }

    @Test("Repeated missing-file errors stop after one recovery attempt and preserve the backup")
    func boundsRecoveryAttempts() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto(isLive: false)
        let name = try #require(photo.fullImageAssetName)
        try await fixture.saveOriginal(named: name, source: .offline)
        _ = try fixture.cloud.stageAssetData(fixture.original(named: name), named: name)
        fixture.recorder.missingFileFailuresRemaining = 3

        await #expect(throws: CKError.self) {
            _ = try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context)
        }

        #expect(fixture.recorder.uploadedNames == [name, name])
        #expect(fixture.entry(for: photo)?.state == .paused)
        #expect(fixture.entry(for: photo)?.failureReason == .missingUploadAsset)
        #expect(try await fixture.cloud.offlineStore.assetURL(named: name) != nil)
    }

    @Test("Missing originals remain paused instead of being marked uploaded")
    func missingEverywhereRemainsPaused() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto(isLive: false)

        await #expect(throws: CloudKitError.self) {
            _ = try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context)
        }

        #expect(fixture.entry(for: photo)?.state == .paused)
        #expect(fixture.entry(for: photo)?.failureReason == .missingUploadAsset)
        #expect(fixture.recorder.uploadedNames.isEmpty)
    }

    @Test("A failed cloud check preserves the originals and schedules a later retry")
    func cloudCheckFailureDoesNotClaimSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto()
        for name in fixture.names(for: photo) { try await fixture.saveOriginal(named: name, source: .offline) }
        fixture.recorder.remoteError = CKError(.networkFailure)

        await #expect(throws: CKError.self) {
            _ = try await fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context)
        }

        #expect(fixture.entry(for: photo)?.state == .failed)
        #expect(fixture.entry(for: photo)?.retryAfter != nil)
        #expect(fixture.recorder.uploadedNames.isEmpty)
        #expect(try await fixture.cloud.offlineStore.assetNames() == fixture.names(for: photo))
    }

    @Test("Downloaded copies without a local upload journal never become upload candidates")
    func doesNotAdoptRemotePhoto() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto(ownsUpload: false)
        for name in fixture.names(for: photo) { try await fixture.saveOriginal(named: name, source: .offline) }
        let name = try #require(photo.fullImageAssetName)
        let id = try #require(photo.id)

        #expect(try await !fixture.cloud.restoreStagedUploadAsset(named: name, photoID: id))
        #expect(try await !fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context))
        #expect(fixture.cloud.uploadStateStore.allEntries().isEmpty)
        #expect(fixture.cloud.storedPersistentAssetNames().isEmpty)
        #expect(fixture.recorder.checkedNames.isEmpty)
    }

    @Test("Offline eviction preserves the only originals of an unfinished local upload")
    func preservesRecoverySourcesDuringEviction() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto()
        let names = fixture.names(for: photo)
        for name in names { try await fixture.saveOriginal(named: name, source: .offline) }
        let coordinator = PhotoOfflineCoordinator(
            cloudKitService: fixture.cloud, context: fixture.context,
            capacityProvider: { 1_000_000_000 }, conditionsProvider: { nil }
        )

        await coordinator.reconcileNow()

        #expect(try await fixture.cloud.offlineStore.assetNames() == names)
        #expect(fixture.entry(for: photo)?.state == .paused)
    }

    @Test("Recovery does not automatically resume unrelated paused errors")
    func leavesUnrelatedPausesAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try fixture.makePhoto()
        try fixture.cloud.uploadStateStore.update(photoID: try #require(photo.id)) {
            $0.failureReason = nil
            $0.errorMessage = "Cloud configuration needs attention."
        }
        for name in fixture.names(for: photo) { try await fixture.saveOriginal(named: name, source: .offline) }

        #expect(try await !fixture.uploader.uploadNextPendingPhotoForTesting(in: fixture.context))
        #expect(fixture.entry(for: photo)?.state == .paused)
        #expect(fixture.recorder.checkedNames.isEmpty)
    }

    @Test("Nested missing-file failures are recognized while quota errors keep priority")
    func classifiesNestedErrors() {
        let missing = CKError(.assetFileNotFound)
        let wrapped = NSError(domain: "Upload", code: 1, userInfo: [NSUnderlyingErrorKey: missing])
        #expect(PhotoUploadFailureReason.classify(wrapped) == .missingUploadAsset)
        let combined = NSError(domain: CKError.errorDomain, code: CKError.partialFailure.rawValue, userInfo: [
            NSUnderlyingErrorKey: missing,
            CKPartialErrorsByItemIDKey: ["quota": CKError(.quotaExceeded)]
        ])
        #expect(PhotoUploadFailureReason.classify(combined) == .iCloudStorageFull)
    }

    enum Source: CaseIterable, Sendable {
        case offline, readable, legacy
    }

    private final class Recorder {
        var remoteNames: Set<String> = []
        var remoteError: CKError?
        var checkedNames: [String] = []
        var uploadedNames: [String] = []
        var uploadedData: [String: Data] = [:]
        var missingFileFailuresRemaining = 0
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoUploadRecoveryTests-\(UUID())")
        let persistence = PersistenceController(inMemory: true)
        let recorder = Recorder()
        let defaults: UserDefaults
        let cloud: CloudKitService
        let uploader: PhotoUploadService
        private let defaultsDomain = "PhotoUploadRecoveryTests-\(UUID())"
        var staging: URL { root.appendingPathComponent("Staging") }
        var readable: URL { root.appendingPathComponent("Readable") }
        var context: NSManagedObjectContext { persistence.container.viewContext }

        init() throws {
            defaults = try #require(UserDefaults(suiteName: defaultsDomain))
            let staging = root.appendingPathComponent("Staging")
            let readable = root.appendingPathComponent("Readable")
            let legacy = root.appendingPathComponent("Legacy")
            let recorder = self.recorder
            cloud = CloudKitService(
                stagingDirectoryURL: staging,
                temporaryReadableAssetsDirectoryURL: readable,
                legacyAssetDirectoryURLs: [legacy],
                assetURLLoader: { _ in throw CloudKitError.assetNotFound },
                assetUploader: { name, _, _ in
                    recorder.uploadedNames.append(name)
                    let url = staging.appendingPathComponent(name)
                    recorder.uploadedData[name] = try Data(contentsOf: url)
                    if recorder.missingFileFailuresRemaining > 0 {
                        recorder.missingFileFailuresRemaining -= 1
                        try FileManager.default.removeItem(at: url)
                        throw CKError(.assetFileNotFound)
                    }
                },
                remoteAssetExistenceChecker: { name in
                    recorder.checkedNames.append(name)
                    if let error = recorder.remoteError { throw error }
                    return recorder.remoteNames.contains(name)
                },
                offlineSettingsDefaults: defaults
            )
            uploader = PhotoUploadService(cloudKitService: cloud)
        }

        func makePhoto(isLive: Bool = true, separateLiveImage: Bool = false, ownsUpload: Bool = true) throws -> DailyPhoto {
            let photo = DailyPhoto(context: context)
            let id = UUID()
            let still = "\(id)_still.heic"
            let video = isLive ? "\(id)_livePhotoVideo.mov" : nil
            photo.id = id
            photo.createdAt = Date()
            photo.captureDate = Date()
            photo.fullImageAssetName = still
            photo.livePhotoImageAssetName = isLive ? (separateLiveImage ? "\(id)_livePhotoImage.heic" : still) : nil
            photo.livePhotoVideoAssetName = video
            photo.uploadStateRaw = PhotoUploadState.paused.rawValue
            try context.save()
            if ownsUpload {
                try cloud.uploadStateStore.register(LocalPhotoUpload(
                    photoID: id, stillAssetName: still,
                    livePhotoImageAssetName: photo.livePhotoImageAssetName,
                    videoAssetName: video, createdAt: Date(),
                    state: .paused, errorMessage: "Original upload file is missing.",
                    failureReason: .missingUploadAsset
                ))
            }
            return photo
        }

        func entry(for photo: DailyPhoto) -> LocalPhotoUpload? {
            photo.id.flatMap { cloud.uploadStateStore.entry(for: $0) }
        }

        func names(for photo: DailyPhoto) -> Set<String> {
            Set([photo.fullImageAssetName, photo.livePhotoImageAssetName, photo.livePhotoVideoAssetName].compactMap { $0 })
        }

        func original(named name: String) -> Data { Data("Original bytes for \(name)".utf8) }

        func sourceURL(named name: String, source: Source) -> URL {
            let directory: URL
            switch source {
            case .offline: directory = cloud.offlineStore.directoryURL
            case .readable: directory = readable
            case .legacy: directory = root.appendingPathComponent("Legacy")
            }
            return directory.appendingPathComponent(name)
        }

        func saveOriginal(named name: String, source: Source) async throws {
            let url = sourceURL(named: name, source: source)
            if source == .offline {
                let temporary = root.appendingPathComponent("source-\(name)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try original(named: name).write(to: temporary)
                try await cloud.offlineStore.retain(from: temporary, named: name)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try original(named: name).write(to: url)
            }
        }

        func removeFiles() {
            defaults.removePersistentDomain(forName: defaultsDomain)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
