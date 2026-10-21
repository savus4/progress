import CloudKit
import CoreData
import Foundation
import Observation

@MainActor @Observable
final class PhotoStorageCoordinator {
    static let shared = PhotoStorageCoordinator()

    private(set) var mode: PhotoStorageMode
    private(set) var isWorking = false
    private(set) var completedAssets = 0
    private(set) var totalAssets = 0
    private(set) var statusMessage: String? {
        didSet {
            completionMessageTask?.cancel()
            completionMessageTask = nil
        }
    }
    private(set) var errorMessage: String?

    @ObservationIgnored private let cloud: CloudKitService
    @ObservationIgnored private let persistence: PersistenceController
    @ObservationIgnored private let copies: PhotoCloudCopyService
    @ObservationIgnored private let remoteAssetDeletionService: RemoteAssetDeletionService
    @ObservationIgnored private let capacityProvider: @Sendable () async -> Int64?
    @ObservationIgnored private let suspendServices: @MainActor () async throws -> Void
    @ObservationIgnored private let resumeServices: @MainActor () async -> Void
    @ObservationIgnored private let validateMigrationReadiness: @MainActor (Bool) throws -> Void
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var completionMessageTask: Task<Void, Never>?

    init(cloudKitService: CloudKitService = .shared, persistenceController: PersistenceController = .shared,
         cloudCopyService: PhotoCloudCopyService = PhotoCloudCopyService(),
         remoteAssetDeletionService: RemoteAssetDeletionService = .shared,
         capacityProvider: @escaping @Sendable () async -> Int64? = { await PhotoOfflineStorageCapacity.availableBytes() },
         suspendServices: @escaping @MainActor () async throws -> Void = {
             PhotoOfflineCoordinator.shared.cancelPendingWork()
             PhotoUploadService.shared.cancelPendingWork()
             guard await PhotoUploadService.shared.waitUntilIdle(timeout: .seconds(30)) else {
                 throw PhotoStorageMigrationError.attention("Waiting for an earlier upload to finish. Retry the switch in a moment.")
             }
         }, resumeServices: @escaping @MainActor () async -> Void = {
             await ICloudAvailabilityMonitor.shared.refresh()
             PhotoOfflineCoordinator.shared.requestReconciliation(delay: .zero)
             // Upload attempts belong to the long-lived uploader and its journal;
             // finishing the setting switch must not wait for the entire upload.
             Task { await PhotoUploadService.shared.enqueuePendingUploads(expeditingRetries: true, forceRetryExpedite: true) }
         }, validateMigrationReadiness: @escaping @MainActor (Bool) throws -> Void = { checksMetadataImport in
             guard !PhotoImportCoordinator.shared.isImporting else {
                 throw PhotoStorageMigrationError.attention("Let the current photo import finish first.")
             }
             if checksMetadataImport, CloudSyncMonitor.shared.isMetadataImportActive {
                 throw PhotoStorageMigrationError.attention("Your iCloud library is still downloading. Wait for it to finish, then try again.")
             }
         }) {
        cloud = cloudKitService
        persistence = persistenceController
        copies = cloudCopyService
        self.remoteAssetDeletionService = remoteAssetDeletionService
        self.capacityProvider = capacityProvider
        self.suspendServices = suspendServices
        self.resumeServices = resumeServices
        self.validateMigrationReadiness = validateMigrationReadiness
        mode = cloudKitService.storageModeStore.mode
        do { try cloud.storageModeStore.checkReadable() }
        catch {
            errorMessage = error.localizedDescription
            statusMessage = "The photo storage preference couldn’t be read. Automatic sync is paused to protect your privacy."
        }
    }

    var usesSimulatorExampleLibrary: Bool {
        #if DEBUG && targetEnvironment(simulator)
        cloud === CloudKitService.shared && SimulatorExampleLibrary.isEnabled
        #else
        false
        #endif
    }

    var isLocalOnly: Bool { usesSimulatorExampleLibrary || mode != .iCloud }
    var isRemovingCloudCopies: Bool { cloud.storageModeStore.deletionPlan != nil }

    func estimate(forLocalStorage: Bool) async throws -> PhotoStorageEstimate {
        if usesSimulatorExampleLibrary {
            throw PhotoStorageMigrationError.attention("The simulator example library already uses local storage. Set SIMULATOR_EXAMPLE_PHOTOS=0 to test photo storage switching with the normal library.")
        }
        try cloud.storageModeStore.checkReadable()
        try validateMigrationReadiness(forLocalStorage && mode == .iCloud)
        let context = persistence.makeBackgroundContext()
        _ = await PhotoStorageService(cloudKitService: cloud).recoverLegacyOriginals(context: context)
        let photos = try await photos(in: context)
        let names = Set(photos.flatMap(\.assetNames))
        let local = try await cloud.localAssetMetadata(named: names)
        let persistent = try await cloud.offlineStore.assetNames()
        var metadata = local
        let missing = names.subtracting(metadata.keys).sorted()
        if !missing.isEmpty {
            guard forLocalStorage else {
                throw PhotoStorageMigrationError.attention("Some local originals are missing. Restore them before enabling iCloud. Your storage setting has not changed.")
            }
            for offset in stride(from: 0, to: missing.count, by: 100) {
                let batch = Array(missing[offset..<min(offset + 100, missing.count)])
                let results = try await cloud.offlineAssetMetadata(named: batch, allowsCellularAccess: PhotoOfflineSettings.allowsCellular(in: cloud.offlineSettingsDefaults))
                for name in batch {
                    guard let result = results[name] else { throw CloudKitError.assetNotFound }
                    metadata[name] = try result.get()
                }
                try Task.checkCancellation()
            }
        }
        guard let capacity = await capacityProvider() else {
            throw PhotoStorageMigrationError.attention("Available device storage couldn’t be checked. Try again before changing storage.")
        }
        var bytes: Int64 = 0
        var additional: Int64 = 0
        for name in names {
            guard let size = metadata[name]?.byteCount, size > 0 else { throw CloudKitError.assetNotFound }
            bytes = try adding(bytes, size)
            if !persistent.contains(name) { additional = try adding(additional, size) }
        }
        let copyBytes: Int64
        if let description = persistence.container.persistentStoreDescriptions.first,
           description.type == NSSQLiteStoreType, let url = description.url {
            copyBytes = try await PhotoStorageEstimate.libraryFootprint(at: url)
        } else { copyBytes = 0 }
        return PhotoStorageEstimate(photoCount: photos.count, originalBytes: bytes,
                                    additionalLocalBytes: additional, freeDeviceBytes: capacity, libraryCopyBytes: copyBytes)
    }

    func beginLocalStorage(removeCloudCopies: Bool) async throws {
        guard mode == .iCloud, !isWorking else { return }
        // Recheck after confirmation: the library or free space may have changed.
        let estimate = try await estimate(forLocalStorage: true)
        guard estimate.fitsOnDevice else {
            throw PhotoStorageMigrationError.attention("There isn’t enough free device storage for all originals and safe download space. Free up storage and try again.")
        }
        let context = persistence.makeBackgroundContext()
        let photos = try await photos(in: context)
        let names = Set(photos.flatMap(\.assetNames))
        let persistent = try await cloud.offlineStore.assetNames().union(cloud.storedPersistentAssetNames())
        let account = !names.isSubset(of: persistent) || removeCloudCopies ? try await copies.accountID() : nil
        var plan: PhotoCloudDeletionPlan?
        if removeCloudCopies, let account {
            let ids = try await context.perform {
                let request = NSFetchRequest<NSManagedObjectID>(entityName: "DailyPhoto")
                request.resultType = .managedObjectIDResultType
                return try context.fetch(request)
            }
            let records = (persistence.container as? NSPersistentCloudKitContainer)?.recordIDs(for: ids) ?? [:]
            plan = PhotoCloudDeletionPlan(accountID: account,
                                         metadataRecords: records.values.map { PhotoCloudDeletionPlan.Record($0) },
                                         assetNames: Set(photos.flatMap(\.assetNames)))
            if let plan { try await copies.validate(plan) }
        }
        try await suspendServices()
        try applyBackupPreference(excluding: true)
        try checkpoint(.downloading, account: account, plan: plan)
        resume()
    }

    func beginICloudStorage() async throws {
        guard mode == .local, !isWorking else { return }
        let account = try await copies.accountID()
        let estimate = try await estimate(forLocalStorage: false)
        guard estimate.fitsOnDevice else {
            throw PhotoStorageMigrationError.attention("There isn’t enough free device storage to merge the iCloud library safely. Free up storage and try again.")
        }
        try checkpoint(.preparingUpload, account: account)
        resume()
    }

    func resume() {
        guard mode.isMigrating, worker == nil, persistence.isLoaded else { return }
        isWorking = true
        errorMessage = nil
        worker = Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false; worker = nil }
            do {
                if mode == .downloading { try await finishDownloading() }
                if mode == .deletingCloudCopies { try await finishDeletingCloudCopies() }
                if mode == .preparingUpload { try await finishPreparingUpload() }
            } catch is CancellationError {
                statusMessage = "Paused. The switch will resume when you reopen the app."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "The switch needs attention. Your existing originals have been kept."
            }
        }
    }

    func resumeAndWait() async {
        resume()
        await worker?.value
    }

    func suspend() { worker?.cancel() }

    func recordStartupError(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = "Photo storage needs attention. Your originals have been kept."
    }

    func cancelLocalSwitch() async throws {
        guard mode == .downloading else { return }
        worker?.cancel()
        await worker?.value
        guard mode == .downloading else {
            throw PhotoStorageMigrationError.attention("The download has finished. Check the current photo storage setting before changing it again.")
        }
        try checkpoint(.iCloud)
        try await persistence.reloadCloudConfiguration()
        try applyBackupPreference()
        statusMessage = "The switch was cancelled. Private iCloud sync remains enabled."
        await resumeServices()
    }

    func cancelUploadPreparation() async throws {
        guard mode == .preparingUpload, !isWorking else { return }
        // Also detach mirroring if opening the cloud configuration succeeded but
        // committing its final checkpoint failed.
        try await persistence.reloadCloudConfiguration()
        try checkpoint(.local)
        try applyBackupPreference()
        errorMessage = nil
        statusMessage = "Upload preparation was cancelled. Photos remain only on this device."
    }

    func applyBackupPreference(excluding: Bool? = nil) throws {
        let excluded = excluding ?? mode.keepsAllOriginals
        try persistence.setLibraryExcludedFromBackup(excluded)
        let directories = cloud.localAssetDirectoryURLs()
        for directory in [directories.staging, directories.offline] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory
            var values = URLResourceValues()
            // Offline originals always remain excluded; staging is a backup
            // fallback only when the user has consented to cloud storage.
            values.isExcludedFromBackup = excluded || directory == directories.offline
            try url.setResourceValues(values)
        }
        for directory in cloud.legacyAssetDirectoryURLsSnapshot
            where directory != FileManager.default.temporaryDirectory && FileManager.default.fileExists(atPath: directory.path) {
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = excluded
            try url.setResourceValues(values)
        }
    }

    private func finishDownloading() async throws {
        try await suspendServices()
        try await persistence.reloadCloudConfiguration()
        try applyBackupPreference()
        try await checkDownloadAccount()
        let context = persistence.makeBackgroundContext()
        let photos = try await photos(in: context)
        let names = Set(photos.flatMap(\.assetNames))
        totalAssets = names.count
        completedAssets = 0
        let localMetadata = try await cloud.localAssetMetadata(named: names)
        let estimate = try await estimate(forLocalStorage: true)
        guard estimate.fitsOnDevice else { throw PhotoStorageMigrationError.attention("Downloads paused: free up device storage, then retry.") }
        for name in names.sorted() {
            try Task.checkCancellation()
            statusMessage = "Saving and verifying original \(completedAssets + 1) of \(totalAssets)…"
            if try await cloud.offlineStore.assetURL(named: name) != nil {
                try await cloud.offlineStore.verifyOriginal(named: name)
            } else {
                try await checkDownloadAccount()
                let expected: PhotoAssetMetadata
                if cloud.stagedAssetURL(named: name) != nil, let local = localMetadata[name] { expected = local }
                else { expected = try await cloud.offlineAssetMetadata(named: name, allowsCellularAccess: PhotoOfflineSettings.allowsCellular(in: cloud.offlineSettingsDefaults)) }
                guard let capacity = await capacityProvider(),
                      estimate.canRetainOriginal(byteCount: expected.byteCount, availableBytes: capacity) else {
                    throw PhotoStorageMigrationError.attention("Downloads paused: device storage is low. Completed originals are safe; free space and retry.")
                }
                let source = try await cloud.loadAssetURL(named: name, allowsCellularAccess: PhotoOfflineSettings.allowsCellular(in: cloud.offlineSettingsDefaults))
                try await cloud.offlineStore.retain(from: source, named: name, expected: expected)
            }
            // The durable inventory has committed a verified replacement. The
            // upload journal can restore staging from it if sync is enabled later.
            cloud.removeStagedAsset(named: name)
            completedAssets += 1
        }
        try await checkDownloadAccount()
        // Retain a fresh library snapshot before any remote deletion. Store
        // identity is checkpointed only after the copy is closed and complete.
        if let plan = cloud.storageModeStore.deletionPlan {
            try await copies.validate(plan)
            guard try await self.estimate(forLocalStorage: true).fitsOnDevice else {
                throw PhotoStorageMigrationError.attention("More free space is needed to protect the local library before cloud deletion. Free up device storage and retry.")
            }
            statusMessage = "Protecting the local library before removing iCloud copies…"
            let filename = try await persistence.copyLibraryForLocalStorage()
            try checkpoint(.deletingCloudCopies, account: plan.accountID, filename: filename, plan: plan)
            try await persistence.reloadCloudConfiguration()
            try applyBackupPreference()
        } else {
            try checkpoint(.local)
            showCompletionMessage("All originals are on this device. Existing iCloud copies were kept.")
        }
    }

    private func finishDeletingCloudCopies() async throws {
        guard let plan = cloud.storageModeStore.deletionPlan else { throw CocoaError(.fileReadCorruptFile) }
        // Reverify after every restart, even if deletion had already begun.
        totalAssets = plan.assetNames.count
        completedAssets = 0
        let metadata = try await cloud.offlineStore.assetMetadata()
        for name in plan.assetNames.sorted() {
            try Task.checkCancellation()
            guard try await cloud.offlineStore.assetURL(named: name) != nil, metadata[name] != nil else {
                throw PhotoStorageMigrationError.attention("A verified local original is missing. iCloud deletion is paused to protect your photos.")
            }
            try await cloud.offlineStore.verifyOriginal(named: name)
            completedAssets += 1
        }
        statusMessage = "Removing iCloud originals, thumbnails, and photo records…"
        try await copies.remove(plan)
        try checkpoint(.local)
        showCompletionMessage("All originals are on this device. Removal of the iCloud copies was verified.")
    }

    private func showCompletionMessage(_ message: String) {
        statusMessage = message
        completionMessageTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5 * 60))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    private func finishPreparingUpload() async throws {
        try await suspendServices()
        // A previous attempt may have opened its new store before the final
        // checkpoint failed. Always resume from the durable local source.
        try await persistence.reloadCloudConfiguration(cloudEnabled: false)
        statusMessage = "Preparing originals for private iCloud upload…"
        try await checkDownloadAccount()
        let photos = try await photos(in: persistence.makeBackgroundContext())
        let metadata = try await cloud.offlineStore.assetMetadata()
        for photo in photos {
            try Task.checkCancellation()
            for name in photo.assetNames {
                let offline = try await cloud.offlineStore.assetURL(named: name)
                let url = cloud.stagedAssetURL(named: name) ?? offline
                guard let url else { throw CloudKitError.assetNotFound }
                try await verify(url, expected: metadata[name])
            }
            guard let still = photo.fullImageAssetName else { throw CloudKitError.assetNotFound }
            try cloud.uploadStateStore.register(LocalPhotoUpload(photoID: photo.id, stillAssetName: still,
                                                                livePhotoImageAssetName: photo.livePhotoImageAssetName,
                                                                videoAssetName: photo.livePhotoVideoAssetName, createdAt: photo.createdAt))
            try cloud.uploadStateStore.update(photoID: photo.id) {
                $0.state = .pending; $0.attemptCount = 0; $0.retryAfter = nil; $0.errorMessage = nil; $0.failureReason = nil
            }
        }
        // Every original has durable upload ownership before either cloud path
        // resumes. Offline eviction already protects all pending ownership.
        try await checkDownloadAccount()
        statusMessage = "Downloading the iCloud library and merging local photos…"
        let filename = try await persistence.prepareLibraryForICloudStorage {
            try await self.checkDownloadAccount()
        }
        try await persistence.reloadCloudConfiguration(cloudEnabled: true, storeFilename: filename)
        let mergedContext = persistence.makeBackgroundContext()
        let mergedAssetNames = try await mergedContext.perform {
            Set(try mergedContext.fetch(DailyPhoto.fetchRequest()).flatMap { photo in
                [photo.fullImageAssetName, photo.livePhotoImageAssetName, photo.livePhotoVideoAssetName].compactMap { $0 }
            })
        }
        // Older local-only deletions may already be in the durable cleanup queue.
        // No original referenced by the merged library may be deleted remotely.
        await remoteAssetDeletionService.cancel(assetNames: mergedAssetNames)
        cloud.restoreAssetAccess(named: mergedAssetNames)
        try checkpoint(.iCloud, filename: filename)
        try applyBackupPreference()
        cloud.markStagedAssetsIncludedInBackup()
        statusMessage = "Photos will upload privately to your iCloud. Originals are kept until uploads succeed."
        await resumeServices()
    }

    private func photos(in context: NSManagedObjectContext) async throws -> [PhotoOfflinePhoto] {
        try await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.fetchBatchSize = 100
            return try context.fetch(request).map { photo in
                guard let id = photo.id, let still = photo.fullImageAssetName, !still.isEmpty else {
                    throw PhotoStorageMigrationError.attention("An older photo’s original couldn’t be recovered. The switch is paused; no original was removed.")
                }
                return PhotoOfflinePhoto(id: id, createdAt: photo.createdAt ?? .distantPast,
                                         isHearted: photo.isHearted, isFavoriteLivePhoto: photo.isFavoriteLivePhoto,
                                         fullImageAssetName: still, livePhotoImageAssetName: photo.livePhotoImageAssetName,
                                         livePhotoVideoAssetName: photo.livePhotoVideoAssetName)
            }
        }
    }

    private func verify(_ url: URL, expected: PhotoAssetMetadata?) async throws {
        let digest = try await PhotoAssetFileWorker.digestAndByteCount(at: url)
        guard digest.byteCount > 0, expected == nil || (expected?.byteCount == digest.byteCount && (expected?.checksum == nil || expected?.checksum == digest.checksum)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func checkDownloadAccount() async throws {
        if let account = cloud.storageModeStore.downloadAccountID, try await copies.accountID() != account {
            throw PhotoStorageMigrationError.accountChanged
        }
    }

    private func checkpoint(_ value: PhotoStorageMode, account: String? = nil, filename: String? = nil, plan: PhotoCloudDeletionPlan? = nil) throws {
        try cloud.storageModeStore.set(value, downloadAccountID: account, storeFilename: filename, deletionPlan: plan)
        mode = value
        if cloud === CloudKitService.shared {
            ICloudAvailabilityMonitor.shared.storagePreferenceDidChange()
            PhotoOfflineCoordinator.shared.scheduleBackgroundProcessing()
        }
    }

    private func adding(_ left: Int64, _ right: Int64) throws -> Int64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw CocoaError(.fileWriteOutOfSpace) }
        return sum
    }
}
