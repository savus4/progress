import Foundation
@preconcurrency import BackgroundTasks
import CloudKit
@preconcurrency import CoreData
import Network
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import os

nonisolated struct ImportedPhotoLibraryMetadata: Sendable {
    let creationDate: Date?
    let location: (latitude: Double, longitude: Double)?

    init(creationDate: Date? = nil, location: (latitude: Double, longitude: Double)? = nil) {
        self.creationDate = creationDate
        self.location = location
    }
}

struct ImportedPhotoPayload: Sendable {
    let imageData: Data
    let livePhotoVideoURL: URL?
    let libraryMetadata: ImportedPhotoLibraryMetadata?

    init(imageData: Data, livePhotoVideoURL: URL? = nil, libraryMetadata: ImportedPhotoLibraryMetadata? = nil) {
        self.imageData = imageData
        self.livePhotoVideoURL = livePhotoVideoURL
        self.libraryMetadata = libraryMetadata
    }
}

struct ImportedPhotoBatchResult: Sendable {
    let importedCount: Int
    let duplicateCount: Int
    let failedCount: Int
    let failureMessages: [String]
}

struct DeleteAllPhotosResult: Sendable {
    enum CloudMetadataDeletionState: Sendable {
        case confirmed
        case pending
        case failed(String)
    }

    let deletedCount: Int
    let cloudMetadataDeletionState: CloudMetadataDeletionState
    let pendingRemoteAssetDeletionCount: Int
    let shouldRebuildPersistentStore: Bool
    let isDeferredUntilICloudAvailable: Bool

    var isCloudDeletionComplete: Bool {
        if pendingRemoteAssetDeletionCount > 0 {
            return false
        }

        switch cloudMetadataDeletionState {
        case .confirmed:
            return true
        case .pending, .failed:
            return false
        }
    }
}

private struct StoredPendingPhoto {
    let objectID: NSManagedObjectID
    let photoID: UUID
    let fullImageAssetName: String
}

nonisolated enum PhotoUploadState: String, Codable, Sendable {
    case pending
    case uploading
    case uploaded
    case failed
    case paused
}

nonisolated extension DailyPhoto {
    var uploadState: PhotoUploadState {
        guard let id else { return .uploaded }
        return LocalPhotoUploadStore.shared.entry(for: id)?.state ?? .uploaded
    }
}

final class PhotoStorageService {
    static let shared = PhotoStorageService()

    private enum StorageOptimizationKeys {
        static let thumbnailRecompressionV1Completed = "thumbnail-recompression-v1-completed"
    }

    private static let orphanedPendingUploadGracePeriod: TimeInterval = 7 * 24 * 60 * 60

    private let cloudKitService: CloudKitService
    private let pendingUploadManifestService: PendingUploadManifestService
    private let legacyRecoveryContext: NSManagedObjectContext?
    private let thumbnailService = ThumbnailService.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "PhotoStorage")
    private let metadataSyncBatchLimit = 50
    private let decodedFullImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 18
        cache.totalCostLimit = 320 * 1_024 * 1_024
        return cache
    }()

    init(cloudKitService: CloudKitService = .shared, legacyRecoveryContext: NSManagedObjectContext? = nil) {
        self.cloudKitService = cloudKitService
        pendingUploadManifestService = cloudKitService.pendingUploadManifestService
        self.legacyRecoveryContext = legacyRecoveryContext
    }

    func savePhoto(
        image: UIImage,
        imageData: Data? = nil,
        livePhotoImageData: Data? = nil,
        livePhotoVideoURL: URL? = nil,
        location: (latitude: Double, longitude: Double)?,
        context: NSManagedObjectContext,
        enqueuesPendingUpload: Bool = true
    ) async throws -> NSManagedObjectID {
        let photoID = UUID()
        let sourceImageData = livePhotoImageData ?? imageData
        guard let sourceImageData else {
            throw PhotoStorageError.missingImageData
        }

        let extractedMetadata = await Self.exifMetadata(from: sourceImageData)
        let resolvedLocation = extractedMetadata?.location ?? location
        let importFingerprint = try await fingerprint(imageData: sourceImageData, livePhotoVideoURL: livePhotoVideoURL)
        let thumbnailData = await thumbnailService.generateThumbnailAsync(from: sourceImageData)
        let (stillAssetName, livePhotoVideoAssetName) = try await stagePhotoOriginals(
            imageData: sourceImageData, videoURL: livePhotoVideoURL, photoID: photoID
        )
        let createdAt = Date()
        let manifestEntry = PendingUploadManifestEntry(
            photoID: photoID,
            captureDate: extractedMetadata?.captureDate ?? createdAt,
            createdAt: createdAt,
            latitude: resolvedLocation?.latitude ?? 0,
            longitude: resolvedLocation?.longitude ?? 0,
            fullImageAssetName: stillAssetName,
            livePhotoVideoAssetName: livePhotoVideoAssetName
        )
        let objectID: NSManagedObjectID
        do {
            try await pendingUploadManifestService.record(manifestEntry)
            try cloudKitService.uploadStateStore.register(manifestEntry.localUpload)
            objectID = try await context.perform {
                let photo = DailyPhoto(context: context)
                photo.id = photoID
                photo.captureDate = manifestEntry.captureDate
                photo.createdAt = createdAt
                photo.modifiedAt = createdAt
                photo.latitude = manifestEntry.latitude
                photo.longitude = manifestEntry.longitude
                photo.thumbnailData = thumbnailData
                photo.fullImageAssetName = stillAssetName
                photo.livePhotoImageAssetName = livePhotoVideoAssetName == nil ? nil : stillAssetName
                photo.livePhotoVideoAssetName = livePhotoVideoAssetName
                photo.setValue(nil, forKey: "fullImageData")
                photo.setValue(nil, forKey: "livePhotoImageData")
                photo.setValue(nil, forKey: "livePhotoVideoData")
                photo.setValue(importFingerprint, forKey: "importFingerprint")
                do {
                    try context.save()
                } catch {
                    context.delete(photo)
                    throw error
                }
                return photo.objectID
            }
            await pendingUploadManifestService.remove(photoID: photoID)
        } catch {
            // A handled failed save is retryable by the caller; it must not later
            // resurrect a second capture from its manifest.
            await discardPendingUpload(photoID: photoID, assetNames: manifestEntry.localUpload.assetNames)
            throw error
        }

        // The grid reads thumbnails through a separate background context. Prime the
        // decoded cache before returning so a photo saved while the grid is covered by
        // the camera is immediately available, even when no CloudKit event follows.
        _ = await DecodedThumbnailCache.shared.image(for: objectID, data: thumbnailData)
        await cloudKitService.recordPhotoAccess(named: stillAssetName)

        if enqueuesPendingUpload {
            Task.detached(priority: .utility) {
                await PhotoUploadService.shared.enqueuePendingUploads()
            }
        }
        return objectID
    }

    func saveImportedPhoto(
        imageData: Data,
        libraryMetadata: ImportedPhotoLibraryMetadata? = nil,
        context: NSManagedObjectContext,
        enqueuesPendingUpload: Bool = true
    ) async throws -> NSManagedObjectID {
        let storedPhoto = try await makeImportedPhoto(
            imageData: imageData,
            livePhotoVideoURL: nil,
            libraryMetadata: libraryMetadata,
            context: context
        )
        if enqueuesPendingUpload {
            Task.detached(priority: .utility) {
                await PhotoUploadService.shared.enqueuePendingUploads()
            }
        }
        return storedPhoto.objectID
    }

    func saveImportedLivePhoto(
        imageData: Data,
        videoURL: URL,
        libraryMetadata: ImportedPhotoLibraryMetadata? = nil,
        context: NSManagedObjectContext,
        enqueuesPendingUpload: Bool = true
    ) async throws -> NSManagedObjectID {
        let storedPhoto = try await makeImportedPhoto(
            imageData: imageData,
            livePhotoVideoURL: videoURL,
            libraryMetadata: libraryMetadata,
            context: context
        )
        if enqueuesPendingUpload {
            Task.detached(priority: .utility) {
                await PhotoUploadService.shared.enqueuePendingUploads()
            }
        }
        return storedPhoto.objectID
    }

    func saveImportedPhotos(
        _ payloads: [ImportedPhotoPayload],
        batchSize: Int = 4,
        context: NSManagedObjectContext? = nil,
        enqueuesPendingUploads: Bool = true
    ) async -> ImportedPhotoBatchResult {
        guard !payloads.isEmpty else {
            return ImportedPhotoBatchResult(importedCount: 0, duplicateCount: 0, failedCount: 0, failureMessages: [])
        }

        let ownsContext = context == nil
        let importContext = context ?? PersistenceController.shared.makeBackgroundContext()
        let clock = ContinuousClock()
        let startedAt = clock.now
        let effectiveBatchSize = max(batchSize, 1)

        var importedCount = 0
        var duplicateCount = 0
        var failedCount = 0
        var pendingInsertCount = 0
        var failureMessages: [String] = []
        var payloadFingerprints: [Int: String] = [:]
        var pendingManifestPhotoIDs: [UUID] = []
        var pendingAccessNames: [String] = []

        func recordFailure(_ message: String) {
            if failureMessages.count < 20 {
                failureMessages.append(message)
            }
        }

        for (index, payload) in payloads.enumerated() {
            do {
                payloadFingerprints[index] = try await fingerprint(for: payload)
            } catch {
                let stage = payload.livePhotoVideoURL == nil ? "fingerprint-still" : "fingerprint-live-photo"
                let message = "\(stage) payload=\(index): \(error.localizedDescription)"
                failedCount += 1
                logger.error("\(message, privacy: .public)")
                recordFailure(message)
                if let livePhotoVideoURL = payload.livePhotoVideoURL {
                    try? FileManager.default.removeItem(at: livePhotoVideoURL)
                }
            }
        }

        var knownFingerprints = await existingImportedPhotoFingerprints(
            matching: Set(payloadFingerprints.values),
            context: importContext
        )

        for (index, payload) in payloads.enumerated() {
            do {
                guard let fingerprint = payloadFingerprints[index] else {
                    continue
                }

                if knownFingerprints.contains(fingerprint) {
                    duplicateCount += 1
                    if let livePhotoVideoURL = payload.livePhotoVideoURL {
                        try? FileManager.default.removeItem(at: livePhotoVideoURL)
                    }
                    continue
                }

                let storedPhoto = try await makeImportedPhoto(
                    imageData: payload.imageData,
                    livePhotoVideoURL: payload.livePhotoVideoURL,
                    libraryMetadata: payload.libraryMetadata,
                    context: importContext,
                    saveChanges: false
                )
                importedCount += 1
                pendingInsertCount += 1
                pendingManifestPhotoIDs.append(storedPhoto.photoID)
                pendingAccessNames.append(storedPhoto.fullImageAssetName)
                knownFingerprints.insert(fingerprint)

                if pendingInsertCount >= effectiveBatchSize {
                    do {
                        try await importContext.perform {
                            try importContext.save()
                            if ownsContext {
                                importContext.reset()
                            }
                        }
                        for photoID in pendingManifestPhotoIDs {
                            await pendingUploadManifestService.remove(photoID: photoID)
                        }
                        for name in pendingAccessNames { await cloudKitService.recordPhotoAccess(named: name) }
                        pendingInsertCount = 0
                        pendingManifestPhotoIDs.removeAll(keepingCapacity: true)
                        pendingAccessNames.removeAll(keepingCapacity: true)
                    } catch {
                        let message = "batch-save payload=\(index) pending=\(pendingInsertCount): \(error.localizedDescription)"
                        logger.error("\(message, privacy: .public)")
                        recordFailure(message)
                        importedCount -= pendingInsertCount
                        failedCount += pendingInsertCount
                        pendingInsertCount = 0
                        for photoID in pendingManifestPhotoIDs {
                            await discardPendingUpload(photoID: photoID)
                        }
                        pendingManifestPhotoIDs.removeAll(keepingCapacity: true)
                        pendingAccessNames.removeAll(keepingCapacity: true)
                        await importContext.perform {
                            importContext.rollback()
                        }
                    }
                }
            } catch {
                let stage = payload.livePhotoVideoURL == nil ? "persist-still" : "persist-live-photo"
                let message = "\(stage) payload=\(index): \(error.localizedDescription)"
                failedCount += 1
                logger.error("\(message, privacy: .public)")
                recordFailure(message)
            }

            if let livePhotoVideoURL = payload.livePhotoVideoURL {
                try? FileManager.default.removeItem(at: livePhotoVideoURL)
            }
        }

        do {
            if await importContext.perform({ importContext.hasChanges }) {
                try await importContext.perform {
                    try importContext.save()
                    if ownsContext {
                        importContext.reset()
                    }
                }
                for photoID in pendingManifestPhotoIDs {
                    await pendingUploadManifestService.remove(photoID: photoID)
                }
                for name in pendingAccessNames { await cloudKitService.recordPhotoAccess(named: name) }
                pendingManifestPhotoIDs.removeAll(keepingCapacity: true)
                pendingAccessNames.removeAll(keepingCapacity: true)
            }
        } catch {
            let message = "final-batch-save pending=\(pendingInsertCount): \(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
            recordFailure(message)
            importedCount -= pendingInsertCount
            failedCount += pendingInsertCount
            for photoID in pendingManifestPhotoIDs {
                await discardPendingUpload(photoID: photoID)
            }
            pendingManifestPhotoIDs.removeAll(keepingCapacity: true)
            pendingAccessNames.removeAll(keepingCapacity: true)
            await importContext.perform {
                importContext.rollback()
            }
        }

        let elapsed = startedAt.duration(to: clock.now)
        logger.log(
            "Imported \(importedCount, privacy: .public) photos, skipped \(duplicateCount, privacy: .public) duplicates, failed \(failedCount, privacy: .public), elapsed \(String(describing: elapsed), privacy: .public)"
        )

        if importedCount > 0, enqueuesPendingUploads {
            Task.detached(priority: .utility) {
                await PhotoUploadService.shared.enqueuePendingUploads()
            }
        }

        return ImportedPhotoBatchResult(
            importedCount: importedCount,
            duplicateCount: duplicateCount,
            failedCount: failedCount,
            failureMessages: failureMessages
        )
    }

    func syncPhotoMetadataFromAssetsIfNeeded(limit: Int? = nil) async {
        let batchLimit = max(limit ?? metadataSyncBatchLimit, 1)
        let context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() }

        let candidates: [PhotoMetadataSyncCandidate] = (try? await context.perform {
            let request = NSFetchRequest<DailyPhoto>(entityName: "DailyPhoto")
            request.fetchLimit = batchLimit
            request.sortDescriptors = [
                NSSortDescriptor(keyPath: \DailyPhoto.createdAt, ascending: false),
                NSSortDescriptor(keyPath: \DailyPhoto.modifiedAt, ascending: false)
            ]
            request.predicate = NSPredicate(
                format: "fullImageAssetName != nil AND (captureDate == nil OR (latitude == 0 AND longitude == 0))"
            )

            return try context.fetch(request).map {
                PhotoMetadataSyncCandidate(
                    objectID: $0.objectID,
                    fullImageAssetName: $0.fullImageAssetName,
                    captureDate: $0.captureDate,
                    latitude: $0.latitude,
                    longitude: $0.longitude
                )
            }
        }) ?? []

        guard !candidates.isEmpty else { return }
        await syncPhotoMetadataFromAssetsIfNeeded(candidates: candidates, context: context)
    }

    @MainActor
    func loadFullImage(from photo: DailyPhoto) async throws -> UIImage {
        let snapshot = snapshot(for: photo)
        do {
            let recovered = try await recoverLegacyOriginals(for: snapshot, context: photo.managedObjectContext)
            return try await loadFullImage(named: recovered.fullImageAssetName)
        } catch {
            if let data = snapshot.fullImageData, let image = UIImage(data: data) { return image }
            throw error
        }
    }

    @MainActor
    func loadLivePhotoVideo(from photo: DailyPhoto) async throws -> URL {
        let snapshot = try await recoverLegacyOriginals(for: snapshot(for: photo), context: photo.managedObjectContext)
        return try await loadLivePhotoVideo(named: snapshot.livePhotoVideoAssetName)
    }

    @MainActor
    func syncPhotoMetadataFromAssetsIfNeeded(photos: [DailyPhoto], context: NSManagedObjectContext) async {
        let candidates = photos.prefix(metadataSyncBatchLimit).map {
            PhotoMetadataSyncCandidate(
                objectID: $0.objectID,
                fullImageAssetName: $0.fullImageAssetName,
                captureDate: $0.captureDate,
                latitude: $0.latitude,
                longitude: $0.longitude
            )
        }
        await syncPhotoMetadataFromAssetsIfNeeded(candidates: candidates, context: context)
    }

    private func syncPhotoMetadataFromAssetsIfNeeded(
        candidates: [PhotoMetadataSyncCandidate],
        context: NSManagedObjectContext
    ) async {
        var updatesByObjectID: [NSManagedObjectID: PhotoMetadataUpdate] = [:]

        for candidate in candidates {
            guard let assetName = candidate.fullImageAssetName else { continue }
            guard let assetURL = try? await cloudKitService.loadAssetURL(
                named: assetName,
                reportsTransferEvents: false
            ) else { continue }
            guard let metadata = await Self.exifMetadata(from: assetURL) else { continue }

            if let exifDate = metadata.captureDate {
                let shouldUpdateDate: Bool
                if let currentDate = candidate.captureDate {
                    shouldUpdateDate = abs(currentDate.timeIntervalSince(exifDate)) > 1
                } else {
                    shouldUpdateDate = true
                }

                if shouldUpdateDate {
                    let existing = updatesByObjectID[candidate.objectID] ?? PhotoMetadataUpdate(objectID: candidate.objectID)
                    updatesByObjectID[candidate.objectID] = PhotoMetadataUpdate(
                        objectID: candidate.objectID,
                        captureDate: exifDate,
                        latitude: existing.latitude,
                        longitude: existing.longitude
                    )
                }
            }

            if let location = metadata.location {
                let shouldUpdateLocation =
                    abs(candidate.latitude - location.latitude) > 0.000_001 ||
                    abs(candidate.longitude - location.longitude) > 0.000_001

                if shouldUpdateLocation {
                    let existing = updatesByObjectID[candidate.objectID] ?? PhotoMetadataUpdate(objectID: candidate.objectID)
                    updatesByObjectID[candidate.objectID] = PhotoMetadataUpdate(
                        objectID: candidate.objectID,
                        captureDate: existing.captureDate,
                        latitude: location.latitude,
                        longitude: location.longitude
                    )
                }
            }
        }

        guard !updatesByObjectID.isEmpty else { return }
        let metadataUpdates = Array(updatesByObjectID.values)

        do {
            try await context.perform {
                var updatedPhotos: [DailyPhoto] = []

                for update in metadataUpdates {
                    guard let photo = try? context.existingObject(with: update.objectID) as? DailyPhoto else {
                        continue
                    }

                    if let captureDate = update.captureDate {
                        photo.captureDate = captureDate
                    }
                    if let latitude = update.latitude, let longitude = update.longitude {
                        photo.latitude = latitude
                        photo.longitude = longitude
                    }

                    updatedPhotos.append(photo)
                }

                guard !updatedPhotos.isEmpty else { return }
                self.updateModifiedTimestamps(for: updatedPhotos)
                try context.save()
            }
        } catch {
            logger.error("sync-photo-metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    func loadLivePhotoResources(from photo: DailyPhoto) async throws -> (imageURL: URL, videoURL: URL) {
        let snapshot = try await recoverLegacyOriginals(for: snapshot(for: photo), context: photo.managedObjectContext)
        return try await loadLivePhotoResources(
            imageAssetName: snapshot.livePhotoImageAssetName,
            videoAssetName: snapshot.livePhotoVideoAssetName
        )
    }

    func deletePhoto(_ objectID: NSManagedObjectID, context: NSManagedObjectContext) async throws {
        let assetNames = try await context.perform {
            guard let photo = try context.existingObject(with: objectID) as? DailyPhoto else {
                return Set<String>()
            }

            let assetNames = Set(self.assetNames(for: photo))
            context.delete(photo)
            try context.save()
            return assetNames
        }
        await deleteAssets(named: assetNames)
    }

    func deletePhotos(
        _ objectIDs: [NSManagedObjectID],
        context: NSManagedObjectContext,
        deletesAssetsInBackground: Bool = true
    ) async throws -> Int {
        let uniqueObjectIDs = Array(Set(objectIDs))
        guard !uniqueObjectIDs.isEmpty else { return 0 }

        let (assetNames, deletedCount) = try await context.perform {
            var assetNames = Set<String>()
            var deletedCount = 0

            for objectID in uniqueObjectIDs {
                guard let photo = try? context.existingObject(with: objectID) as? DailyPhoto else {
                    continue
                }

                assetNames.formUnion(self.assetNames(for: photo))
                context.delete(photo)
                deletedCount += 1
            }

            if context.hasChanges {
                try context.save()
            }

            return (assetNames, deletedCount)
        }

        if deletesAssetsInBackground {
            await deleteAssetsInBackground(named: assetNames)
        } else {
            await deleteAssets(named: assetNames)
        }

        return deletedCount
    }

    func photoCount(
        from startDate: Date,
        to endDate: Date,
        context: NSManagedObjectContext
    ) async throws -> Int {
        return try await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.predicate = Self.dateRangePredicate(from: startDate, to: endDate)
            return try context.count(for: request)
        }
    }

    func deletePhotos(
        from startDate: Date,
        to endDate: Date,
        context: NSManagedObjectContext
    ) async throws -> Int {
        let (assetNames, deletedCount) = try await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.predicate = Self.dateRangePredicate(from: startDate, to: endDate)
            let photos = try context.fetch(request)
            guard !photos.isEmpty else { return (Set<String>(), 0) }

            let assetNames = Set(photos.flatMap(self.assetNames(for:)))
            for photo in photos {
                context.delete(photo)
            }

            try context.save()
            return (assetNames, photos.count)
        }

        await deleteAssets(named: assetNames)
        return deletedCount
    }

    func deleteAllPhotos(context: NSManagedObjectContext) async throws -> DeleteAllPhotosResult {
        try await deleteAllPhotos(
            context: context,
            operations: DeleteAllPhotosOperations(
                cancelPendingUploads: { await PhotoUploadService.shared.cancelPendingWork() },
                waitUntilUploadsIdle: { await PhotoUploadService.shared.waitUntilIdle(timeout: .seconds(30)) },
                isLocalModeActive: { ICloudAvailabilityMonitor.shared.isLocalModeActive },
                waitForNextExportCompletion: {
                    await CloudSyncMonitor.shared.waitForNextExportCompletion(timeout: .seconds(30))
                },
                deleteAssets: { await self.deleteAssets(named: $0) },
                deleteAssetsAndWaitForRemoteCleanup: { await self.deleteAssetsAndWaitForRemoteCleanup(named: $0) }
            )
        )
    }

    func deleteAllPhotos(
        context: NSManagedObjectContext,
        operations: DeleteAllPhotosOperations
    ) async throws -> DeleteAllPhotosResult {
        // Freeze the user's deletion targets before upload draining can suspend.
        // Captures saved while deletion is in progress belong to the next library.
        let photoIDsToDelete = try await context.perform {
            let request = DailyPhoto.fetchRequest()
            let photos = try context.fetch(request)
            let temporaryPhotos = photos.filter { $0.objectID.isTemporaryID }
            if !temporaryPhotos.isEmpty {
                try context.obtainPermanentIDs(for: temporaryPhotos)
            }
            return photos.map(\.objectID)
        }

        guard !photoIDsToDelete.isEmpty else {
            return DeleteAllPhotosResult(
                deletedCount: 0,
                cloudMetadataDeletionState: .confirmed,
                pendingRemoteAssetDeletionCount: 0,
                shouldRebuildPersistentStore: false,
                isDeferredUntilICloudAvailable: false
            )
        }

        await operations.cancelPendingUploads()
        let uploadsDrainedBeforeDeletion = await operations.waitUntilUploadsIdle()

        if operations.isLocalModeActive() {
            let (assetNames, deletedCount) = try await context.perform {
                let photos = photoIDsToDelete.compactMap { objectID -> DailyPhoto? in
                    guard let photo = try? context.existingObject(with: objectID) as? DailyPhoto,
                          !photo.isDeleted else { return nil }
                    return photo
                }
                guard !photos.isEmpty else { return (Set<String>(), 0) }

                let assetNames = Set(photos.flatMap(self.assetNames(for:)))
                for photo in photos {
                    context.delete(photo)
                }

                try context.save()
                return (assetNames, photos.count)
            }

            await operations.deleteAssets(assetNames)

            return DeleteAllPhotosResult(
                deletedCount: deletedCount,
                cloudMetadataDeletionState: .pending,
                pendingRemoteAssetDeletionCount: assetNames.count,
                shouldRebuildPersistentStore: false,
                isDeferredUntilICloudAvailable: true
            )
        }

        let exportWaitTask = Task { @MainActor in
            await operations.waitForNextExportCompletion()
        }

        let (assetNames, deletedCount) = try await context.perform {
            let photos = photoIDsToDelete.compactMap { objectID -> DailyPhoto? in
                guard let photo = try? context.existingObject(with: objectID) as? DailyPhoto,
                      !photo.isDeleted else { return nil }
                return photo
            }
            guard !photos.isEmpty else { return (Set<String>(), 0) }

            let assetNames = Set(photos.flatMap(self.assetNames(for:)))
            for photo in photos {
                context.delete(photo)
            }

            try context.save()
            return (assetNames, photos.count)
        }

        let cloudMetadataDeletionState: DeleteAllPhotosResult.CloudMetadataDeletionState
        switch await exportWaitTask.value {
        case .completed:
            // Export events cover the whole store and may belong to an earlier
            // transaction. They cannot acknowledge this deletion specifically.
            cloudMetadataDeletionState = .pending
        case .failed(let message):
            cloudMetadataDeletionState = .failed(message)
        case .timedOut:
            cloudMetadataDeletionState = .pending
        }

        let pendingRemoteAssetDeletionCount: Int
        if uploadsDrainedBeforeDeletion {
            let pendingAssetNames = await operations.deleteAssetsAndWaitForRemoteCleanup(assetNames)
            pendingRemoteAssetDeletionCount = pendingAssetNames.count
        } else {
            await operations.deleteAssets(assetNames)
            pendingRemoteAssetDeletionCount = assetNames.count
        }

        return DeleteAllPhotosResult(
            deletedCount: deletedCount,
            cloudMetadataDeletionState: cloudMetadataDeletionState,
            pendingRemoteAssetDeletionCount: pendingRemoteAssetDeletionCount,
            // CloudKit still needs the store's deletion history to export tombstones.
            shouldRebuildPersistentStore: false,
            isDeferredUntilICloudAvailable: false
        )
    }

    func purgeOrphanedAssets(
        context: NSManagedObjectContext,
        ignoreGracePeriod: Bool = false
    ) async {
        let referencedAssetNames: Set<String>

        do {
            referencedAssetNames = try await context.perform {
                let request = NSFetchRequest<NSDictionary>(entityName: "DailyPhoto")
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = [
                    "objectID",
                    "fullImageAssetName",
                    "livePhotoImageAssetName",
                    "livePhotoVideoAssetName"
                ]
                request.fetchBatchSize = 500

                let rows = try context.fetch(request)
                var assetNames = Set<String>()
                assetNames.reserveCapacity(rows.count)

                for row in rows {
                    for key in ["fullImageAssetName", "livePhotoImageAssetName", "livePhotoVideoAssetName"] {
                        if let assetName = row[key] as? String {
                            assetNames.insert(assetName)
                        }
                    }
                }

                return assetNames
            }
        } catch {
            logger.error("orphan-asset-fetch: \(error.localizedDescription, privacy: .public)")
            return
        }

        let cachedAssetNames = cloudKitService.storedPersistentAssetNames()
        let orphanedAssetNames = cachedAssetNames.subtracting(referencedAssetNames)
        guard !orphanedAssetNames.isEmpty else { return }

        let assetDirectoryURLs = cloudKitService.localAssetDirectoryURLs()
        let fileManager = FileManager.default
        let gracePeriodCutoff = Date().addingTimeInterval(-Self.orphanedPendingUploadGracePeriod)

        var deletedCount = 0
        var deferredCount = 0

        for assetName in orphanedAssetNames {
            let stagedURL = assetDirectoryURLs.staging.appendingPathComponent(assetName)
            let shouldKeepRecentOrphan: Bool

            if ignoreGracePeriod {
                shouldKeepRecentOrphan = false
            } else if let values = try? stagedURL.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modificationDate = values.contentModificationDate {
                shouldKeepRecentOrphan = modificationDate > gracePeriodCutoff
            } else {
                shouldKeepRecentOrphan = fileManager.fileExists(atPath: stagedURL.path)
            }

            if shouldKeepRecentOrphan {
                deferredCount += 1
                continue
            }

            await cloudKitService.deleteAssetAndWait(named: assetName)
            deletedCount += 1
        }

        if deferredCount > 0 {
            logger.log(
                "orphaned-asset-purge-deferred recent=\(deferredCount, privacy: .public) deleted=\(deletedCount, privacy: .public)"
            )
        }
    }

    func recoverPendingUploadsFromManifest(context: NSManagedObjectContext) async -> Int {
        await pendingUploadManifestService.recoverPendingUploads(
            context: context,
            cloudKitService: cloudKitService,
            thumbnailService: thumbnailService
        )
    }

    /// Copies previous versions' original payloads without deleting the old bytes.
    /// Each photo is processed separately so a large blob library is not loaded at once.
    @discardableResult
    func recoverLegacyOriginals(context: NSManagedObjectContext) async -> Int {
        let objectIDs: [NSManagedObjectID] = (try? await context.perform {
            let request = NSFetchRequest<NSManagedObjectID>(entityName: "DailyPhoto")
            request.resultType = .managedObjectIDResultType
            return try context.fetch(request)
        }) ?? []
        var recoveredCount = 0
        for objectID in objectIDs {
            guard !Task.isCancelled else { break }
            guard let snapshot = try? await context.perform({
                guard let photo = try context.existingObject(with: objectID) as? DailyPhoto else { return nil as PhotoSnapshot? }
                return PhotoSnapshot(photo: photo)
            }) else { continue }
            if let id = snapshot.id, cloudKitService.uploadStateStore.entry(for: id)?.state == .uploaded { continue }
            do {
                _ = try await recoverLegacyOriginals(for: snapshot, context: context)
                if let id = snapshot.id, cloudKitService.uploadStateStore.entry(for: id) != nil { recoveredCount += 1 }
            } catch {
                logger.error("legacy-original-recovery photo=\(snapshot.id?.uuidString ?? "nil", privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        return recoveredCount
    }

    private func recoverLegacyOriginals(for original: PhotoSnapshot, context: NSManagedObjectContext?) async throws -> PhotoSnapshot {
        var snapshot = original
        let photoID = snapshot.id ?? UUID()
        let wasUploaded = cloudKitService.uploadStateStore.entry(for: photoID)?.state == .uploaded
        let existingNames = [snapshot.fullImageAssetName, snapshot.livePhotoImageAssetName, snapshot.livePhotoVideoAssetName].compactMap { $0 }
        if snapshot.fullImageAssetName != nil,
           cloudKitService.uploadStateStore.entry(for: photoID) != nil,
           existingNames.allSatisfy({ cloudKitService.stagedAssetURL(named: $0) != nil }) { return snapshot }
        let stillData = snapshot.fullImageData ?? (snapshot.fullImageAssetName == snapshot.livePhotoImageAssetName ? snapshot.livePhotoImageData : nil)
        if snapshot.fullImageAssetName == nil, let stillData {
            snapshot.fullImageAssetName = cloudKitService.makeAssetName(photoID: photoID, role: .still, fileExtension: await Self.imageFileExtension(for: stillData))
        }
        if snapshot.livePhotoImageAssetName == nil, let data = snapshot.livePhotoImageData {
            snapshot.livePhotoImageAssetName = cloudKitService.makeAssetName(photoID: photoID, role: .livePhotoImage, fileExtension: await Self.imageFileExtension(for: data))
        }
        if snapshot.livePhotoVideoAssetName == nil, snapshot.livePhotoVideoData != nil {
            snapshot.livePhotoVideoAssetName = cloudKitService.makeAssetName(photoID: photoID, role: .livePhotoVideo, fileExtension: "mov")
        }

        let assets = [
            (snapshot.fullImageAssetName, stillData),
            (snapshot.livePhotoImageAssetName, snapshot.livePhotoImageData),
            (snapshot.livePhotoVideoAssetName, snapshot.livePhotoVideoData)
        ]
        for (name, data) in assets {
            guard let name, cloudKitService.stagedAssetURL(named: name) == nil else { continue }
            if let data {
                _ = try await cloudKitService.stageAssetDataAsync(data, named: name, includesInBackup: true)
            } else if let legacyURL = cloudKitService.legacyAssetURL(named: name) {
                _ = try await cloudKitService.stageAssetFileAsync(from: legacyURL, named: name, includesInBackup: true)
            }
        }
        guard let stillName = snapshot.fullImageAssetName,
              assets.compactMap({ $0.0 }).allSatisfy({ cloudKitService.stagedAssetURL(named: $0) != nil }) else {
            return original
        }

        if wasUploaded { return snapshot }

        snapshot.id = photoID
        let entry = PendingUploadManifestEntry(
            photoID: photoID, captureDate: snapshot.captureDate ?? Date(), createdAt: snapshot.createdAt ?? Date(),
            latitude: snapshot.latitude, longitude: snapshot.longitude,
            fullImageAssetName: stillName, livePhotoVideoAssetName: snapshot.livePhotoVideoAssetName,
            livePhotoImageAssetName: snapshot.livePhotoImageAssetName
        )
        try await pendingUploadManifestService.record(entry)
        try cloudKitService.uploadStateStore.register(entry.localUpload)
        if let context {
            let objectID = snapshot.objectID
            let updated = snapshot
            try await context.perform {
                guard let photo = try context.existingObject(with: objectID) as? DailyPhoto, !photo.isDeleted else { return }
                if photo.id != updated.id || photo.fullImageAssetName != updated.fullImageAssetName ||
                    photo.livePhotoImageAssetName != updated.livePhotoImageAssetName || photo.livePhotoVideoAssetName != updated.livePhotoVideoAssetName {
                    photo.id = updated.id
                    photo.fullImageAssetName = updated.fullImageAssetName
                    photo.livePhotoImageAssetName = updated.livePhotoImageAssetName
                    photo.livePhotoVideoAssetName = updated.livePhotoVideoAssetName
                    try context.save()
                }
            }
            await pendingUploadManifestService.remove(photoID: photoID)
        }
        return snapshot
    }

    /// Name-based readers include the pager, Photos saving, and video export.
    func recoverLegacyAssetIfNeeded(named assetName: String) async throws {
        guard cloudKitService.stagedAssetURL(named: assetName) == nil,
              cloudKitService.legacyAssetURL(named: assetName) == nil else { return }
        let context: NSManagedObjectContext
        if let legacyRecoveryContext { context = legacyRecoveryContext }
        else {
            guard PersistenceController.shared.isLoaded else { return }
            context = PersistenceController.shared.makeBackgroundContext()
        }
        let snapshot = try await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.fetchLimit = 1
            request.predicate = NSPredicate(
                format: "fullImageAssetName == %@ OR livePhotoImageAssetName == %@ OR livePhotoVideoAssetName == %@",
                assetName, assetName, assetName
            )
            return try context.fetch(request).first.map(PhotoSnapshot.init)
        }
        guard let snapshot else { return }
        do {
            _ = try await recoverLegacyOriginals(for: snapshot, context: context)
        } catch {
            // A failed journal write must not hide originals successfully copied above.
            if cloudKitService.stagedAssetURL(named: assetName) == nil { throw error }
            logger.error("legacy-asset-journal: \(error.localizedDescription, privacy: .public)")
        }
    }

    func optimizeStoredThumbnailsIfNeeded(
        context: NSManagedObjectContext,
        batchSize: Int = 150
    ) async {
        if UserDefaults.standard.bool(forKey: StorageOptimizationKeys.thumbnailRecompressionV1Completed) {
            return
        }

        let objectIDs: [NSManagedObjectID]
        do {
            objectIDs = try await context.perform {
                let request = NSFetchRequest<NSManagedObjectID>(entityName: "DailyPhoto")
                request.resultType = .managedObjectIDResultType
                request.predicate = NSPredicate(format: "thumbnailData != nil")
                request.fetchBatchSize = batchSize
                return try context.fetch(request)
            }
        } catch {
            logger.error("thumbnail-recompression-fetch-failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard !objectIDs.isEmpty else {
            UserDefaults.standard.set(true, forKey: StorageOptimizationKeys.thumbnailRecompressionV1Completed)
            return
        }

        var totalScanned = 0
        var totalUpdated = 0
        var totalBytesSaved = 0

        for startIndex in stride(from: 0, to: objectIDs.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, objectIDs.count)
            let batch = Array(objectIDs[startIndex..<endIndex])

            do {
                let (scanned, updated, bytesSaved) = try await context.perform {
                    var scanned = 0
                    var updated = 0
                    var bytesSaved = 0

                    for objectID in batch {
                        guard let photo = try? context.existingObject(with: objectID) as? DailyPhoto,
                              let currentData = photo.thumbnailData else {
                            continue
                        }

                        scanned += 1
                        guard let optimizedData = self.thumbnailService.optimizedThumbnailDataIfSmaller(currentData) else {
                            continue
                        }

                        bytesSaved += max(currentData.count - optimizedData.count, 0)
                        photo.thumbnailData = optimizedData
                        photo.modifiedAt = Date()
                        updated += 1
                    }

                    if context.hasChanges {
                        try context.save()
                    }
                    context.reset()

                    return (scanned, updated, bytesSaved)
                }

                totalScanned += scanned
                totalUpdated += updated
                totalBytesSaved += bytesSaved
            } catch {
                logger.error("thumbnail-recompression-batch-failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        logger.log(
            "thumbnail-recompression-finished scanned=\(totalScanned, privacy: .public) updated=\(totalUpdated, privacy: .public) bytesSaved=\(totalBytesSaved, privacy: .public)"
        )
        UserDefaults.standard.set(true, forKey: StorageOptimizationKeys.thumbnailRecompressionV1Completed)
    }

    func countPhotosMissingSyncedPayloads(context: NSManagedObjectContext) async -> Int {
        await legacyMigrationCandidates(context: context).count
    }

    func backfillMissingSyncedPayloads(
        context: NSManagedObjectContext,
        batchSize: Int = 1,
        maxPhotosPerRun: Int = 4,
        progress: (@MainActor @Sendable (Int) -> Void)? = nil
    ) async -> LegacyPayloadMigrationResult {
        let candidates = await legacyMigrationCandidates(context: context)
        var scanned = 0
        var migrated = 0
        var missing = 0
        var failed = 0
        for objectID in candidates.prefix(max(0, maxPhotosPerRun)) {
            guard !Task.isCancelled else { break }
            scanned += 1
            do {
                let snapshot = try await context.perform {
                    guard let photo = try context.existingObject(with: objectID) as? DailyPhoto,
                          !photo.isDeleted else { return nil as PhotoSnapshot? }
                    return PhotoSnapshot(photo: photo)
                }
                guard let snapshot else { continue }
                let recovered = try await recoverLegacyOriginals(for: snapshot, context: context)
                if let id = recovered.id, cloudKitService.uploadStateStore.entry(for: id) != nil { migrated += 1 }
                else { missing += 1 }
            } catch { failed += 1 }
            if let progress { progress(max(0, candidates.count - migrated)) }
            if scanned.isMultiple(of: max(1, batchSize)) { await Task.yield() }
        }
        if scanned == 0, let progress { progress(candidates.count) }
        return LegacyPayloadMigrationResult(scannedCount: scanned, migratedCount: migrated, missingAssetCount: missing, failedCount: failed)
    }

    private func legacyMigrationCandidates(context: NSManagedObjectContext) async -> [NSManagedObjectID] {
        let store = cloudKitService.uploadStateStore
        let legacyDirectories = cloudKitService.legacyAssetDirectoryURLsSnapshot
        return (try? await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.fetchBatchSize = 50
            return try context.fetch(request).compactMap { photo in
                if let id = photo.id, store.entry(for: id) != nil { return nil }
                let names = [photo.fullImageAssetName, photo.livePhotoImageAssetName, photo.livePhotoVideoAssetName].compactMap { $0 }
                let hasLegacyFile = names.contains { name in
                    legacyDirectories.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) }
                }
                guard hasLegacyFile || photo.fullImageData != nil || photo.livePhotoImageData != nil || photo.livePhotoVideoData != nil else { return nil }
                return photo.objectID
            }
        }) ?? []
    }

    @MainActor
    func prepareExportFiles(for photos: [DailyPhoto]) async throws -> [URL] {
        var snapshots: [PhotoSnapshot] = []
        for photo in photos {
            snapshots.append(try await recoverLegacyOriginals(for: snapshot(for: photo), context: photo.managedObjectContext))
        }
        let exportRoot = try makeExportRootDirectory()
        var exportedDirectories: [URL] = []

        for snapshot in snapshots {
            let photoDirectory = try createPhotoExportDirectory(for: snapshot, inside: exportRoot)
            try await exportPhotoAssets(for: snapshot, to: photoDirectory)
            exportedDirectories.append(photoDirectory)
        }

        return exportedDirectories
    }

    @MainActor
    func prepareShareItemURLs(for photo: DailyPhoto) async throws -> [URL] {
        let directories = try await prepareExportFiles(for: [photo])
        guard let directory = directories.first else { return [] }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @MainActor
    func prepareLivePhotoShareItemURLs(for photo: DailyPhoto) async throws -> [URL] {
        let snapshot = try await recoverLegacyOriginals(for: snapshot(for: photo), context: photo.managedObjectContext)
        let resources = try await loadLivePhotoResources(
            imageAssetName: snapshot.livePhotoImageAssetName,
            videoAssetName: snapshot.livePhotoVideoAssetName
        )
        return [resources.imageURL, resources.videoURL]
    }

    @MainActor
    func prepareStillPhotoShareURL(for photo: DailyPhoto) async throws -> URL {
        let snapshot = try await recoverLegacyOriginals(for: snapshot(for: photo), context: photo.managedObjectContext)
        return try await prepareStillPhotoShareURL(fullImageAssetName: snapshot.fullImageAssetName)
    }

    func loadFullImage(named fullImageAssetName: String?) async throws -> UIImage {
        guard let fullImageAssetName else {
            throw PhotoStorageError.noImageAsset
        }

        let cacheKey = fullImageAssetName
        if let cachedImage = decodedFullImageCache.object(forKey: cacheKey as NSString) {
            return cachedImage
        }

        try await recoverLegacyAssetIfNeeded(named: fullImageAssetName)

        let firstURL = try await cloudKitService.loadAssetURL(named: fullImageAssetName)

        do {
            return try await decodeAndCacheFullImage(from: firstURL, cacheKey: cacheKey)
        } catch {
            let refreshedURL = try await cloudKitService.loadAssetURL(
                named: fullImageAssetName,
                forceRefetch: true
            )
            return try await decodeAndCacheFullImage(from: refreshedURL, cacheKey: cacheKey)
        }
    }

    func loadLivePhotoVideo(named livePhotoVideoAssetName: String?) async throws -> URL {
        guard let livePhotoVideoAssetName else {
            throw PhotoStorageError.noVideoAsset
        }
        try await recoverLegacyAssetIfNeeded(named: livePhotoVideoAssetName)
        return try await cloudKitService.loadVideoAsset(named: livePhotoVideoAssetName)
    }

    func loadLivePhotoResources(
        imageAssetName: String?,
        videoAssetName: String?
    ) async throws -> (imageURL: URL, videoURL: URL) {
        guard let imageAssetName,
              let videoAssetName else {
            throw PhotoStorageError.noLivePhotoAssets
        }

        try await recoverLegacyAssetIfNeeded(named: imageAssetName)
        try await recoverLegacyAssetIfNeeded(named: videoAssetName)

        var imageURL = try await cloudKitService.loadAssetURL(named: imageAssetName)
        var videoURL = try await cloudKitService.loadAssetURL(named: videoAssetName)

        if !isReadableAssetURL(imageURL) {
            imageURL = try await cloudKitService.loadAssetURL(named: imageAssetName, forceRefetch: true)
        }

        if !isReadableAssetURL(videoURL) {
            videoURL = try await cloudKitService.loadAssetURL(named: videoAssetName, forceRefetch: true)
        }

        return (imageURL, videoURL)
    }

    func prefetchPagerAssets(
        fullImageAssetName: String?,
        livePhotoImageAssetName: String?,
        livePhotoVideoAssetName: String?
    ) async {
        if let fullImageAssetName {
            guard !Task.isCancelled else { return }
            _ = try? await loadFullImage(named: fullImageAssetName)
        }

        if let livePhotoImageAssetName, livePhotoImageAssetName != fullImageAssetName {
            guard !Task.isCancelled else { return }
            _ = try? await loadFullImage(named: livePhotoImageAssetName)
        }

        if let livePhotoVideoAssetName {
            guard !Task.isCancelled else { return }
            _ = try? await cloudKitService.loadAssetURL(named: livePhotoVideoAssetName)
        }
    }

    func prepareStillPhotoShareURL(fullImageAssetName: String?) async throws -> URL {
        guard let fullImageAssetName else {
            throw PhotoStorageError.noImageAsset
        }
        try await recoverLegacyAssetIfNeeded(named: fullImageAssetName)
        return try await cloudKitService.loadAssetURL(named: fullImageAssetName)
    }

    private func stagePhotoOriginals(imageData: Data, videoURL: URL?, photoID: UUID) async throws -> (String, String?) {
        let imageExtension = await Self.imageFileExtension(for: imageData)
        let still = cloudKitService.makeAssetName(photoID: photoID, role: .still, fileExtension: imageExtension)
        let video = videoURL.map {
            cloudKitService.makeAssetName(
                photoID: photoID, role: .livePhotoVideo,
                fileExtension: $0.pathExtension.isEmpty ? "mov" : $0.pathExtension
            )
        }
        do {
            try Task.checkCancellation()
            _ = try await cloudKitService.stageAssetDataAsync(imageData, named: still, includesInBackup: true)
            if let videoURL, let video {
                _ = try await cloudKitService.stageAssetFileAsync(from: videoURL, named: video, includesInBackup: true)
            }
            try Task.checkCancellation()
            return (still, video)
        } catch {
            for name in [still, video].compactMap({ $0 }) { cloudKitService.removeStagedAsset(named: name) }
            throw error
        }
    }

    private func discardPendingUpload(photoID: UUID, assetNames: Set<String> = []) async {
        let names = assetNames.union(cloudKitService.uploadStateStore.entry(for: photoID)?.assetNames ?? [])
        await pendingUploadManifestService.remove(photoID: photoID)
        do {
            try cloudKitService.uploadStateStore.remove(assetNames: names)
        } catch {
            logger.error("discard-failed-save: \(error.localizedDescription, privacy: .public)")
        }
        for name in names { cloudKitService.removeStagedAsset(named: name) }
    }

    private func decodeAndCacheFullImage(from fileURL: URL, cacheKey: String) async throws -> UIImage {
        let preparedImage = try await Self.decodeFullImage(from: fileURL)
        decodedFullImageCache.setObject(
            preparedImage,
            forKey: cacheKey as NSString,
            cost: cacheCost(for: preparedImage)
        )
        return preparedImage
    }

    @concurrent
    nonisolated private static func decodeFullImage(from fileURL: URL) async throws -> UIImage {
        guard let image = UIImage(contentsOfFile: fileURL.path) else {
            throw CloudKitError.assetNotFound
        }
        return image.preparingForDisplay() ?? image
    }

    private func cacheCost(for image: UIImage) -> Int {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        return max(pixelWidth * pixelHeight * 4, 1)
    }

    private func isReadableAssetURL(_ url: URL) -> Bool {
        guard (try? url.checkResourceIsReachable()) == true else {
            return false
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }

        do {
            _ = try handle.read(upToCount: 1)
            try handle.close()
            return true
        } catch {
            try? handle.close()
            return false
        }
    }

    private func makeExportRootDirectory() throws -> URL {
        let rootName = "progress_export_\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))"
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(rootName, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private func createPhotoExportDirectory(for snapshot: PhotoSnapshot, inside root: URL) throws -> URL {
        let dateText = snapshot.captureDate?
            .formatted(date: .numeric, time: .standard)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "_") ?? "unknown_date"
        let idText = snapshot.id?.uuidString ?? UUID().uuidString
        let directoryName = "photo_\(dateText)_\(idText)"
        let directoryURL = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func exportPhotoAssets(for snapshot: PhotoSnapshot, to directory: URL) async throws {
        if let livePhotoImageAssetName = snapshot.livePhotoImageAssetName,
           let livePhotoVideoAssetName = snapshot.livePhotoVideoAssetName {
            try await copyAsset(named: livePhotoImageAssetName, to: directory)
            try await copyAsset(named: livePhotoVideoAssetName, to: directory)
            return
        }

        guard let fullImageAssetName = snapshot.fullImageAssetName else {
            throw PhotoStorageError.noImageAsset
        }
        try await copyAsset(named: fullImageAssetName, to: directory)
    }

    private func copyAsset(named assetName: String, to directory: URL) async throws {
        let sourceURL = try await cloudKitService.loadAssetURL(named: assetName)
        let destinationURL = directory.appendingPathComponent(assetName)
        try await PhotoAssetFileWorker.copyReplacingItem(from: sourceURL, to: destinationURL)
    }

    @concurrent
    nonisolated private static func imageFileExtension(for imageData: Data) async -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            return "heic"
        }

        let typeIdentifier = type as String
        if let utType = UTType(typeIdentifier),
           let preferredExtension = utType.preferredFilenameExtension {
            return preferredExtension
        }

        return "heic"
    }

    @concurrent
    nonisolated private static func exifMetadata(from imageData: Data) async -> (captureDate: Date?, location: (latitude: Double, longitude: Double)?)? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let captureDate = Self.extractCaptureDate(from: metadata)
        let location = Self.extractLocation(from: metadata)
        return (captureDate: captureDate, location: location)
    }

    @concurrent
    nonisolated private static func exifMetadata(from imageURL: URL) async -> (captureDate: Date?, location: (latitude: Double, longitude: Double)?)? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]

        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, sourceOptions as CFDictionary),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let captureDate = Self.extractCaptureDate(from: metadata)
        let location = Self.extractLocation(from: metadata)
        return (captureDate: captureDate, location: location)
    }

    nonisolated private static func extractCaptureDate(from metadata: [CFString: Any]) -> Date? {
        let exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        let offsetTime = exif?["OffsetTimeOriginal" as CFString] as? String
            ?? exif?["OffsetTimeDigitized" as CFString] as? String

        if let exifDateString = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
           let parsedExifDate = Self.parseExifDate(exifDateString, offset: offsetTime) {
            return parsedExifDate
        }

        if let tiffDateString = tiff?[kCGImagePropertyTIFFDateTime] as? String,
           let parsedTiffDate = Self.parseExifDate(tiffDateString, offset: nil) {
            return parsedTiffDate
        }

        return nil
    }

    nonisolated private static func extractLocation(from metadata: [CFString: Any]) -> (latitude: Double, longitude: Double)? {
        guard let gps = metadata[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let rawLatitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let rawLongitude = gps[kCGImagePropertyGPSLongitude] as? Double else {
            return nil
        }

        let latitudeRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased()
        let longitudeRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased()

        let latitude = latitudeRef == "S" ? -abs(rawLatitude) : abs(rawLatitude)
        let longitude = longitudeRef == "W" ? -abs(rawLongitude) : abs(rawLongitude)
        return (latitude, longitude)
    }

    nonisolated private static func parseExifDate(_ dateString: String, offset: String?) -> Date? {
        if let offset,
           let date = Self.exifDateTimeWithOffsetFormatter.date(from: "\(dateString)\(offset)") {
            return date
        }
        return Self.exifDateTimeFormatter.date(from: dateString)
    }

    nonisolated private static var exifDateTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }

    nonisolated private static var exifDateTimeWithOffsetFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        return formatter
    }

    nonisolated private func updateModifiedTimestamps(for photos: [DailyPhoto]) {
        let now = Date()
        for photo in photos {
            photo.modifiedAt = now
        }
    }

    nonisolated private func assetNames(for photo: DailyPhoto) -> [String] {
        Set([
            photo.fullImageAssetName,
            photo.livePhotoImageAssetName,
            photo.livePhotoVideoAssetName
        ].compactMap { $0 }).map { $0 }
    }

    private func deleteAssets(named assetNames: Set<String>) async {
        guard !assetNames.isEmpty else { return }

        for assetName in assetNames {
            await cloudKitService.deleteAssetAndWait(named: assetName)
        }

        await RemoteAssetDeletionService.shared.enqueue(assetNames: assetNames)
    }

    private func deleteAssetsInBackground(named assetNames: Set<String>) async {
        guard !assetNames.isEmpty else { return }

        await RemoteAssetDeletionService.shared.enqueueForDeferredProcessing(assetNames: assetNames)
        Task.detached(priority: .utility) {
            for assetName in assetNames {
                await CloudKitService.shared.deleteAssetAndWait(named: assetName)
            }

            await RemoteAssetDeletionService.shared.processPendingDeletions()
        }
    }

    private func deleteAssetsAndWaitForRemoteCleanup(named assetNames: Set<String>) async -> Set<String> {
        guard !assetNames.isEmpty else { return [] }

        for assetName in assetNames {
            await cloudKitService.deleteAssetAndWait(named: assetName)
        }

        return await RemoteAssetDeletionService.shared.enqueueAndAttemptImmediateDeletion(assetNames: assetNames)
    }

    private func existingImportedPhotoFingerprints(
        matching fingerprints: Set<String>,
        context: NSManagedObjectContext
    ) async -> Set<String> {
        guard !fingerprints.isEmpty else { return [] }

        do {
            return try await context.perform {
                let request = NSFetchRequest<NSDictionary>(entityName: "DailyPhoto")
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["importFingerprint"]
                request.predicate = NSPredicate(format: "importFingerprint IN %@", Array(fingerprints))

                let rows = try context.fetch(request)
                let fingerprints = rows.compactMap { $0["importFingerprint"] as? String }
                return Set(fingerprints)
            }
        } catch {
            logger.error("fingerprint-fetch: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    nonisolated private static func dateRangePredicate(from startDate: Date, to endDate: Date) -> NSPredicate {
        let calendar = Calendar.current
        let normalizedStartDate = calendar.startOfDay(for: min(startDate, endDate))
        let normalizedEndDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(startDate, endDate))) ?? max(startDate, endDate)
        return NSPredicate(
            format: "captureDate >= %@ AND captureDate < %@",
            normalizedStartDate as NSDate,
            normalizedEndDate as NSDate
        )
    }

    private func makeImportedPhoto(
        imageData: Data,
        livePhotoVideoURL: URL?,
        libraryMetadata: ImportedPhotoLibraryMetadata? = nil,
        context: NSManagedObjectContext,
        saveChanges: Bool = true
    ) async throws -> StoredPendingPhoto {
        let photoID = UUID()
        let exifMetadata = await Self.exifMetadata(from: imageData)
        let thumbnailData = await thumbnailService.generateThumbnailAsync(from: imageData)
        let importFingerprint = try await fingerprint(imageData: imageData, livePhotoVideoURL: livePhotoVideoURL)
        let (imageAssetName, videoAssetName) = try await stagePhotoOriginals(
            imageData: imageData, videoURL: livePhotoVideoURL, photoID: photoID
        )
        let createdAt = Date()
        let captureDate = exifMetadata?.captureDate ?? libraryMetadata?.creationDate ?? createdAt
        let location = exifMetadata?.location ?? libraryMetadata?.location
        let manifestEntry = PendingUploadManifestEntry(
            photoID: photoID,
            captureDate: captureDate,
            createdAt: createdAt,
            latitude: location?.latitude ?? 0,
            longitude: location?.longitude ?? 0,
            fullImageAssetName: imageAssetName,
            livePhotoVideoAssetName: videoAssetName
        )
        do {
            try await pendingUploadManifestService.record(manifestEntry)
            try cloudKitService.uploadStateStore.register(manifestEntry.localUpload)
            let objectID = try await context.perform {
                let photo = DailyPhoto(context: context)
                photo.id = photoID
                photo.captureDate = manifestEntry.captureDate
                photo.createdAt = createdAt
                photo.modifiedAt = createdAt
                photo.latitude = manifestEntry.latitude
                photo.longitude = manifestEntry.longitude
                photo.thumbnailData = thumbnailData
                photo.fullImageAssetName = imageAssetName
                photo.livePhotoImageAssetName = videoAssetName == nil ? nil : imageAssetName
                photo.livePhotoVideoAssetName = videoAssetName
                photo.setValue(nil, forKey: "fullImageData")
                photo.setValue(nil, forKey: "livePhotoImageData")
                photo.setValue(nil, forKey: "livePhotoVideoData")
                photo.setValue(importFingerprint, forKey: "importFingerprint")
                if saveChanges {
                    do {
                        try context.save()
                    } catch {
                        context.delete(photo)
                        throw error
                    }
                }
                return photo.objectID
            }
            if saveChanges {
                await pendingUploadManifestService.remove(photoID: photoID)
                await cloudKitService.recordPhotoAccess(named: imageAssetName)
            }
            return StoredPendingPhoto(objectID: objectID, photoID: photoID, fullImageAssetName: imageAssetName)
        } catch {
            await discardPendingUpload(photoID: photoID, assetNames: manifestEntry.localUpload.assetNames)
            throw error
        }
    }

    private func fingerprint(for payload: ImportedPhotoPayload) async throws -> String {
        try await fingerprint(imageData: payload.imageData, livePhotoVideoURL: payload.livePhotoVideoURL)
    }

    private func fingerprint(imageData: Data, livePhotoVideoURL: URL?) async throws -> String {
        try await PhotoAssetFileWorker.fingerprint(
            imageData: imageData,
            videoURL: livePhotoVideoURL
        )
    }

    @MainActor
    private func snapshot(for photo: DailyPhoto) -> PhotoSnapshot {
        PhotoSnapshot(photo: photo)
    }

}

nonisolated private struct PhotoSnapshot: Sendable {
    let objectID: NSManagedObjectID
    var id: UUID?
    let createdAt: Date?
    let captureDate: Date?
    let latitude: Double
    let longitude: Double
    var fullImageAssetName: String?
    var livePhotoImageAssetName: String?
    var livePhotoVideoAssetName: String?
    let fullImageData: Data?
    let livePhotoImageData: Data?
    let livePhotoVideoData: Data?

    init(photo: DailyPhoto) {
        objectID = photo.objectID
        id = photo.id
        createdAt = photo.createdAt
        captureDate = photo.captureDate
        latitude = photo.latitude
        longitude = photo.longitude
        fullImageAssetName = photo.fullImageAssetName
        livePhotoImageAssetName = photo.livePhotoImageAssetName
        livePhotoVideoAssetName = photo.livePhotoVideoAssetName
        fullImageData = photo.fullImageData
        livePhotoImageData = photo.livePhotoImageData
        livePhotoVideoData = photo.livePhotoVideoData
    }
}

private struct PhotoMetadataSyncCandidate: Sendable {
    let objectID: NSManagedObjectID
    let fullImageAssetName: String?
    let captureDate: Date?
    let latitude: Double
    let longitude: Double
}

private struct PhotoMetadataUpdate: Sendable {
    let objectID: NSManagedObjectID
    var captureDate: Date? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
}

private struct PendingRemoteAssetDeletion: Codable, Sendable {
    let assetName: String
    var attemptCount: Int
    var retryAfter: Date?
    var lastErrorDescription: String?
}

struct PendingUploadManifestEntry: Codable, Sendable {
    let photoID: UUID
    let captureDate: Date
    let createdAt: Date
    let latitude: Double
    let longitude: Double
    let fullImageAssetName: String
    let livePhotoVideoAssetName: String?
    var livePhotoImageAssetName: String? = nil

    nonisolated var localUpload: LocalPhotoUpload {
        LocalPhotoUpload(
            photoID: photoID, stillAssetName: fullImageAssetName,
            livePhotoImageAssetName: livePhotoImageAssetName ?? (livePhotoVideoAssetName == nil ? nil : fullImageAssetName),
            videoAssetName: livePhotoVideoAssetName, createdAt: createdAt
        )
    }
}

actor PendingUploadManifestService {
    static let shared = PendingUploadManifestService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "PendingUploadManifest")
    private let storageURL: URL

    private var didLoadEntries = false
    private var entriesByPhotoID: [UUID: PendingUploadManifestEntry] = [:]
    private var activePhotoIDs: Set<UUID> = []
    private var isRecovering = false
    private var loadError: Error?

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.makeStorageURL()
    }

    func record(_ entry: PendingUploadManifestEntry) throws {
        loadEntriesIfNeeded()
        if let loadError { throw loadError }
        let oldEntry = entriesByPhotoID[entry.photoID]
        entriesByPhotoID[entry.photoID] = entry
        do {
            try persistEntriesThrowing()
            activePhotoIDs.insert(entry.photoID)
        } catch {
            entriesByPhotoID[entry.photoID] = oldEntry
            throw error
        }
    }

    func remove(photoID: UUID) {
        loadEntriesIfNeeded()
        guard loadError == nil else { return }
        activePhotoIDs.remove(photoID)
        guard entriesByPhotoID.removeValue(forKey: photoID) != nil else { return }
        persistEntries()
    }

    func recoverPendingUploads(
        context: NSManagedObjectContext,
        cloudKitService: CloudKitService,
        thumbnailService: ThumbnailService
    ) async -> Int {
        guard !isRecovering else { return 0 }
        isRecovering = true
        defer { isRecovering = false }
        loadEntriesIfNeeded()
        guard loadError == nil else { return 0 }
        guard !entriesByPhotoID.isEmpty else { return 0 }

        var recoveredCount = 0
        let entries = entriesByPhotoID.values.sorted { $0.createdAt < $1.createdAt }

        for entry in entries {
            if Task.isCancelled { break }
            guard !activePhotoIDs.contains(entry.photoID), entriesByPhotoID[entry.photoID] != nil else { continue }
            do {
                if try await photoAlreadyExists(for: entry, context: context) {
                    try cloudKitService.uploadStateStore.register(entry.localUpload)
                    entriesByPhotoID.removeValue(forKey: entry.photoID)
                    continue
                }
            } catch {
                logger.error("manifest-recovery-existing-photo: \(error.localizedDescription, privacy: .public)")
                continue
            }

            guard let imageURL = await MainActor.run(body: {
                cloudKitService.stagedAssetURL(named: entry.fullImageAssetName)
            }),
                  let imageData = try? Data(contentsOf: imageURL) else {
                logger.error(
                    "manifest-recovery-missing-still photo=\(entry.photoID.uuidString, privacy: .public) still=\(entry.fullImageAssetName, privacy: .public)"
                )
                entriesByPhotoID.removeValue(forKey: entry.photoID)
                continue
            }

            let videoURL: URL? = if let videoAssetName = entry.livePhotoVideoAssetName {
                await MainActor.run(body: {
                    cloudKitService.stagedAssetURL(named: videoAssetName)
                })
            } else {
                nil
            }

            if entry.livePhotoVideoAssetName != nil, videoURL == nil {
                logger.error(
                    "manifest-recovery-missing-video photo=\(entry.photoID.uuidString, privacy: .public) video=\(entry.livePhotoVideoAssetName ?? "nil", privacy: .public)"
                )
                entriesByPhotoID.removeValue(forKey: entry.photoID)
                continue
            }

            let thumbnailData = await thumbnailService.generateThumbnailAsync(from: imageData)
            let importFingerprint: String
            do {
                importFingerprint = try Self.makeFingerprint(
                    imageData: imageData,
                    videoURL: videoURL
                )
            } catch {
                logger.error(
                    "manifest-recovery-fingerprint photo=\(entry.photoID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                continue
            }

            do {
                try await context.perform {
                    let photo = DailyPhoto(context: context)
                    photo.id = entry.photoID
                    photo.captureDate = entry.captureDate
                    photo.createdAt = entry.createdAt
                    photo.modifiedAt = entry.createdAt
                    photo.latitude = entry.latitude
                    photo.longitude = entry.longitude
                    photo.thumbnailData = thumbnailData
                    photo.fullImageAssetName = entry.fullImageAssetName
                    photo.livePhotoImageAssetName = entry.livePhotoImageAssetName ?? (entry.livePhotoVideoAssetName == nil ? nil : entry.fullImageAssetName)
                    photo.livePhotoVideoAssetName = entry.livePhotoVideoAssetName
                    photo.setValue(nil, forKey: "fullImageData")
                    photo.setValue(nil, forKey: "livePhotoImageData")
                    photo.setValue(nil, forKey: "livePhotoVideoData")
                    photo.setValue(importFingerprint, forKey: "importFingerprint")
                    do {
                        try context.save()
                    } catch {
                        context.delete(photo)
                        throw error
                    }
                }
                let store = cloudKitService.uploadStateStore
                try store.register(entry.localUpload)
                entriesByPhotoID.removeValue(forKey: entry.photoID)
                recoveredCount += 1
                logger.log("manifest-recovery-succeeded photo=\(entry.photoID.uuidString, privacy: .public)")
            } catch {
                logger.error(
                    "manifest-recovery-save photo=\(entry.photoID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        persistEntries()
        return recoveredCount
    }

    private func photoAlreadyExists(for entry: PendingUploadManifestEntry, context: NSManagedObjectContext) async throws -> Bool {
        try await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.fetchLimit = 1
            request.predicate = NSPredicate(
                format: "id == %@ OR fullImageAssetName == %@ OR livePhotoVideoAssetName == %@",
                entry.photoID as CVarArg,
                entry.fullImageAssetName,
                entry.livePhotoVideoAssetName ?? ""
            )
            return try context.count(for: request) > 0
        }
    }

    private func loadEntriesIfNeeded() {
        guard !didLoadEntries else { return }
        defer { didLoadEntries = true }
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let entries = try JSONDecoder().decode([PendingUploadManifestEntry].self, from: data)
            entriesByPhotoID = Dictionary(entries.map { ($0.photoID, $0) }, uniquingKeysWith: { _, latest in latest })
        } catch {
            loadError = error
            logger.error("manifest-load: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistEntries() {
        do {
            try persistEntriesThrowing()
        } catch {
            logger.error("manifest-persist: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistEntriesThrowing() throws {
        let entries = entriesByPhotoID.values.sorted { $0.createdAt < $1.createdAt }

        if entries.isEmpty {
            try? FileManager.default.removeItem(at: storageURL)
            return
        }

        let data = try JSONEncoder().encode(entries)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storageURL, options: .atomic)
    }

    private static func makeFingerprint(imageData: Data, videoURL: URL?) throws -> String {
        let imageDigest = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()

        if let videoURL {
            let videoData = try Data(contentsOf: videoURL)
            let videoDigest = SHA256.hash(data: videoData).map { String(format: "%02x", $0) }.joined()
            return "\(imageDigest):\(videoDigest)"
        }

        return imageDigest
    }

    private static func makeStorageURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "progress"
        let directoryURL = baseURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("PendingUploadManifest", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        return directoryURL.appendingPathComponent("pending-uploads.json", isDirectory: false)
    }
}

actor RemoteAssetDeletionService {
    static let shared = RemoteAssetDeletionService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "RemoteAssetDeletion")
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "progress.remote-asset-deletion.monitor")
    private let storageURL: URL
    private let deletionBatchSize = 100

    private var didStart = false
    private var didLoadQueue = false
    private var isProcessing = false
    private var queuedDeletionsByAssetName: [String: PendingRemoteAssetDeletion] = [:]

    init() {
        storageURL = Self.makeStorageURL()
    }

    func start() async {
        guard !didStart else { return }
        didStart = true

        loadQueueIfNeeded()

        pathMonitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task {
                await RemoteAssetDeletionService.shared.processPendingDeletions(expeditingRetries: true)
            }
        }
        pathMonitor.start(queue: monitorQueue)

        await processPendingDeletions(expeditingRetries: true)
    }

    func enqueue(assetNames: Set<String>) async {
        guard !assetNames.isEmpty else { return }
        loadQueueIfNeeded()

        var didChangeQueue = false
        for assetName in assetNames {
            if queuedDeletionsByAssetName[assetName] == nil {
                queuedDeletionsByAssetName[assetName] = PendingRemoteAssetDeletion(
                    assetName: assetName,
                    attemptCount: 0,
                    retryAfter: nil,
                    lastErrorDescription: nil
                )
                didChangeQueue = true
            }
        }

        if didChangeQueue {
            persistQueue()
        }

        await processPendingDeletions()
    }

    func enqueueForDeferredProcessing(assetNames: Set<String>) async {
        guard !assetNames.isEmpty else { return }
        loadQueueIfNeeded()

        var didChangeQueue = false
        for assetName in assetNames {
            if queuedDeletionsByAssetName[assetName] == nil {
                queuedDeletionsByAssetName[assetName] = PendingRemoteAssetDeletion(
                    assetName: assetName,
                    attemptCount: 0,
                    retryAfter: nil,
                    lastErrorDescription: nil
                )
                didChangeQueue = true
            }
        }

        if didChangeQueue {
            persistQueue()
        }
    }

    func enqueueAndAttemptImmediateDeletion(assetNames: Set<String>) async -> Set<String> {
        guard !assetNames.isEmpty else { return [] }

        await enqueue(assetNames: assetNames)
        await processPendingDeletions(expeditingRetries: true)

        return Set(assetNames.filter { queuedDeletionsByAssetName[$0] != nil })
    }

    func processPendingDeletions(expeditingRetries: Bool = false) async {
        loadQueueIfNeeded()

        guard !queuedDeletionsByAssetName.isEmpty else { return }
        guard !isProcessing else { return }
        guard await ICloudAvailabilityMonitor.shared.isAvailableForCloudOperations else { return }

        if !expeditingRetries, pathMonitor.currentPath.status != .satisfied {
            return
        }

        if expeditingRetries {
            expediteRetryableDeletionsIfReachable()
        }

        isProcessing = true
        defer { isProcessing = false }

        let now = Date()
        let eligibleAssetNames = queuedDeletionsByAssetName.keys
            .sorted()
            .filter { assetName in
                guard let pendingDeletion = queuedDeletionsByAssetName[assetName] else {
                    return false
                }
                guard let retryAfter = pendingDeletion.retryAfter else {
                    return true
                }
                return retryAfter <= now
            }
        var didChangeQueue = false

        var batchStartIndex = 0
        while batchStartIndex < eligibleAssetNames.count {
            let batchEndIndex = Swift.min(batchStartIndex + deletionBatchSize, eligibleAssetNames.count)
            let assetNameBatch = Array(eligibleAssetNames[batchStartIndex..<batchEndIndex])
            let results = await CloudKitService.shared.deleteRemoteAssetRecords(named: assetNameBatch)

            for assetName in assetNameBatch {
                guard var pendingDeletion = queuedDeletionsByAssetName[assetName] else {
                    continue
                }

                let outcome = results[assetName] ?? RemoteAssetDeletionOutcome.failure(
                    RemoteAssetDeletionFailure(
                        ckErrorCodeRawValue: nil,
                        retryAfterSeconds: nil,
                        description: "CloudKit did not return a deletion result for this asset."
                    )
                )

                switch outcome {
                case .success:
                    queuedDeletionsByAssetName.removeValue(forKey: assetName)
                    didChangeQueue = true
                    logger.log("remote-asset-delete-succeeded name=\(assetName, privacy: .public)")
                case .failure(let failure):
                    if let ckErrorCodeRawValue = failure.ckErrorCodeRawValue,
                       let ckErrorCode = CKError.Code(rawValue: ckErrorCodeRawValue),
                       ICloudAvailabilityMonitor.isUnavailableCloudKitError(CKError(ckErrorCode)) {
                        await MainActor.run {
                            ICloudAvailabilityMonitor.shared.recordCloudKitError(CKError(ckErrorCode))
                        }
                        return
                    }

                    pendingDeletion.attemptCount += 1
                    pendingDeletion.retryAfter = retryDate(
                        for: failure,
                        attemptCount: pendingDeletion.attemptCount,
                        now: now
                    )
                    pendingDeletion.lastErrorDescription = describe(failure)
                    queuedDeletionsByAssetName[assetName] = pendingDeletion
                    didChangeQueue = true
                    logger.error(
                        "remote-asset-delete-failed name=\(assetName, privacy: .public) attempt=\(pendingDeletion.attemptCount, privacy: .public) error=\(self.describe(failure), privacy: .public)"
                    )
                }
            }

            batchStartIndex = batchEndIndex
        }

        if didChangeQueue {
            persistQueue()
        }
    }

    private func loadQueueIfNeeded() {
        guard !didLoadQueue else { return }
        defer { didLoadQueue = true }

        guard let data = try? Data(contentsOf: storageURL) else { return }
        guard let deletions = try? JSONDecoder().decode([PendingRemoteAssetDeletion].self, from: data) else {
            return
        }

        queuedDeletionsByAssetName = Dictionary(uniqueKeysWithValues: deletions.map { ($0.assetName, $0) })
    }

    private func persistQueue() {
        let deletions = queuedDeletionsByAssetName.values.sorted { $0.assetName < $1.assetName }

        if deletions.isEmpty {
            try? FileManager.default.removeItem(at: storageURL)
            return
        }

        do {
            let data = try JSONEncoder().encode(deletions)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            logger.error("remote-asset-delete-persist: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func expediteRetryableDeletionsIfReachable() {
        guard pathMonitor.currentPath.status == .satisfied else { return }

        var didChangeQueue = false
        for assetName in queuedDeletionsByAssetName.keys {
            guard var pendingDeletion = queuedDeletionsByAssetName[assetName],
                  pendingDeletion.retryAfter != nil else {
                continue
            }

            pendingDeletion.retryAfter = nil
            queuedDeletionsByAssetName[assetName] = pendingDeletion
            didChangeQueue = true
        }

        if didChangeQueue {
            persistQueue()
        }
    }

    private func retryDate(for failure: RemoteAssetDeletionFailure, attemptCount: Int, now: Date) -> Date {
        if let retryAfterSeconds = failure.retryAfterSeconds {
            return now.addingTimeInterval(retryAfterSeconds)
        }

        if let ckErrorCodeRawValue = failure.ckErrorCodeRawValue,
           let ckErrorCode = CKError.Code(rawValue: ckErrorCodeRawValue) {
            switch ckErrorCode {
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .serverResponseLost, .accountTemporarilyUnavailable:
                return backoffRetryDate(attemptCount: attemptCount, now: now)
            case .notAuthenticated:
                return now.addingTimeInterval(15 * 60)
            case .permissionFailure, .badContainer, .missingEntitlement, .quotaExceeded:
                return now.addingTimeInterval(60 * 60)
            default:
                return backoffRetryDate(attemptCount: attemptCount, now: now)
            }
        }

        return backoffRetryDate(attemptCount: attemptCount, now: now)
    }

    private func backoffRetryDate(attemptCount: Int, now: Date) -> Date {
        let clampedAttemptCount = max(1, min(attemptCount, 8))
        let seconds = min(pow(2.0, Double(clampedAttemptCount)) * 30.0, 60.0 * 60.0)
        return now.addingTimeInterval(seconds)
    }

    private func describe(_ failure: RemoteAssetDeletionFailure) -> String {
        failure.description
    }

    private static func makeStorageURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "progress"
        let directoryURL = baseURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("RemoteAssetDeletion", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        return directoryURL.appendingPathComponent("pending-deletions.json", isDirectory: false)
    }
}

nonisolated private struct PendingPhotoUpload: Sendable {
    let objectID: NSManagedObjectID
    let photoID: UUID
    let stillAssetName: String
    let livePhotoImageAssetName: String?
    let videoAssetName: String?
    let attemptCount: Int

    var assetNames: Set<String> {
        Set([stillAssetName, livePhotoImageAssetName, videoAssetName].compactMap { $0 })
    }
}

private enum UploadFailureDisposition: Sendable {
    case retry(Date)
    case pause
}

actor PhotoUploadService {
    static let shared = PhotoUploadService()
    static let backgroundTaskIdentifier = "me.riepl.progress.photo-upload"
    static let didCompleteUploadNotification = Notification.Name("PhotoUploadService.didCompleteUpload")
    static let processingStateDidChangeNotification = Notification.Name("PhotoUploadService.processingStateDidChange")
    private static let maxUploadAttemptCount: Int16 = .max

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "PhotoUpload")
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "progress.photo-upload.monitor")
    private let injectedCloudKitService: CloudKitService?
    private let injectedContext: NSManagedObjectContext?
    private let cloudOperationsAvailable: @Sendable () async -> Bool

    private var didStart = false
    private var isProcessing = false
    private var cancelProcessingRequested = false
    private var activeUploadCount = 0
    private var idleWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var availabilityObserver: NSObjectProtocol?
    private var claimedPhotoIDs: Set<UUID> = []
    private var processingRequested = false
    private var retryTask: Task<Void, Never>?

    init(
        cloudKitService: CloudKitService? = nil,
        context: NSManagedObjectContext? = nil,
        cloudOperationsAvailable: @escaping @Sendable () async -> Bool = {
            await MainActor.run { ICloudAvailabilityMonitor.shared.isAvailableForCloudOperations }
        }
    ) {
        injectedCloudKitService = cloudKitService
        injectedContext = context
        self.cloudOperationsAvailable = cloudOperationsAvailable
    }

    nonisolated static func registerBackgroundTask() {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "PhotoUpload")
        let didRegister = BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            Task {
                await PhotoUploadService.shared.handleBackgroundProcessingTask(processingTask)
            }
        }
        logger.log(
            "bg-register identifier=\(backgroundTaskIdentifier, privacy: .public) success=\(didRegister, privacy: .public)"
        )
    }

    nonisolated static func scheduleBackgroundProcessing(
        earliestBeginDate: Date? = nil,
        source: String = #function
    ) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "PhotoUpload")
        let request = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = earliestBeginDate
        logger.log(
            "bg-submit-attempt identifier=\(backgroundTaskIdentifier, privacy: .public) source=\(source, privacy: .public) earliest=\(String(describing: earliestBeginDate), privacy: .public)"
        )
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.log(
                "bg-submit-success identifier=\(backgroundTaskIdentifier, privacy: .public) source=\(source, privacy: .public)"
            )
            logPendingTaskRequests(reason: "post-submit-success", source: source)
        } catch {
            let nsError = error as NSError
            logger.error(
                """
                bg-submit-failure identifier=\(backgroundTaskIdentifier, privacy: .public) source=\(source, privacy: .public) \
                domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) \
                description=\(nsError.localizedDescription, privacy: .public) userInfo=\(String(describing: nsError.userInfo), privacy: .public)
                """
            )
            logPendingTaskRequests(reason: "post-submit-failure", source: source)
        }
    }

    nonisolated private static func logPendingTaskRequests(reason: String, source: String) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "PhotoUpload")
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let summary = requests.map { request in
                let beginDateDescription = String(describing: request.earliestBeginDate)
                return "\(request.identifier) earliest=\(beginDateDescription)"
            }.joined(separator: "; ")
            logger.log(
                "bg-pending reason=\(reason, privacy: .public) source=\(source, privacy: .public) count=\(requests.count, privacy: .public) requests=\(summary, privacy: .public)"
            )
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        availabilityObserver = NotificationCenter.default.addObserver(
            forName: ICloudAvailabilityMonitor.availabilityDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task {
                guard await ICloudAvailabilityMonitor.shared.isAvailableForCloudOperations else { return }
                await PhotoUploadService.shared.enqueuePendingUploads(
                    expeditingRetries: true,
                    forceRetryExpedite: true
                )
                await RemoteAssetDeletionService.shared.processPendingDeletions(expeditingRetries: true)
            }
        }

        pathMonitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task {
                guard await ICloudAvailabilityMonitor.shared.isAvailableForCloudOperations else { return }
                await PhotoUploadService.shared.enqueuePendingUploads(
                    expeditingRetries: true,
                    forceRetryExpedite: false
                )
            }
        }
        pathMonitor.start(queue: monitorQueue)

        Task {
            guard await ICloudAvailabilityMonitor.shared.isAvailableForCloudOperations else { return }
            Self.scheduleBackgroundProcessing()
        }

        Task {
            guard await ICloudAvailabilityMonitor.shared.isAvailableForCloudOperations else { return }
            await enqueuePendingUploads(
                expeditingRetries: true,
                forceRetryExpedite: true
            )
        }
    }

    func enqueuePendingUploads(expeditingRetries: Bool = false, forceRetryExpedite: Bool = false) async {
        guard await cloudOperationsAvailable() else { return }
        cancelProcessingRequested = false
        if expeditingRetries {
            await expediteRetryableUploadsIfPossible(force: forceRetryExpedite)
        }
        Self.scheduleBackgroundProcessing()
        _ = await processPendingUploads(maxCount: nil)
    }

    func processPendingUploadsDuringBackgroundTime() async {
        guard await ICloudAvailabilityMonitor.shared.isAvailableForCloudOperations else { return }
        cancelProcessingRequested = false
        await expediteRetryableUploadsIfPossible(force: false)
        _ = await processPendingUploads(maxCount: nil, schedulesRemainingWork: false)
    }

    func processPendingUploadsForTesting() async {
        cancelProcessingRequested = false
        _ = await processPendingUploads(maxCount: nil)
    }

    func cancelPendingWork() {
        cancelProcessingRequested = true
        processingRequested = false
        retryTask?.cancel()
        retryTask = nil
        signalIdleIfNeeded()
    }

    func waitUntilIdle(timeout: Duration = .seconds(30)) async -> Bool {
        if !isProcessing && activeUploadCount == 0 {
            return true
        }

        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            idleWaiters[waiterID] = continuation

            Task {
                try? await Task.sleep(for: timeout)
                self.resolveIdleWaiter(id: waiterID, result: false)
            }
        }
    }

    private func handleBackgroundProcessingTask(_ task: BGProcessingTask) async {
        guard await ICloudAvailabilityMonitor.shared.isAvailableForCloudOperations else {
            task.setTaskCompleted(success: true)
            return
        }
        Self.scheduleBackgroundProcessing()

        let worker = Task {
            let remaining = await processPendingUploads(maxCount: 8)
            task.setTaskCompleted(success: remaining == 0)
        }

        task.expirationHandler = {
            worker.cancel()
        }

        _ = await worker.value
    }

    @discardableResult
    private func processPendingUploads(maxCount: Int?, schedulesRemainingWork: Bool = true) async -> Int {
        guard !isProcessing else {
            processingRequested = true
            return await pendingUploadCount()
        }
        isProcessing = true
        processingRequested = false
        retryTask?.cancel()
        retryTask = nil
        defer {
            isProcessing = false
            signalIdleIfNeeded()
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: Self.processingStateDidChangeNotification,
                    object: nil,
                    userInfo: ["isProcessing": false]
                )
            }
            if processingRequested, !cancelProcessingRequested, !Task.isCancelled {
                processingRequested = false
                Task { [weak self] in
                    _ = await self?.processPendingUploads(maxCount: maxCount, schedulesRemainingWork: schedulesRemainingWork)
                }
            }
        }
        guard await cloudOperationsAvailable() else { return await pendingUploadCount() }
        let uploadStore = await resolvedCloudKitService().uploadStateStore
        guard !uploadStore.allEntries().contains(where: { $0.state == .paused && $0.failureReason == .iCloudStorageFull }) else {
            return await pendingUploadCount()
        }
        await MainActor.run {
            NotificationCenter.default.post(
                name: Self.processingStateDidChangeNotification,
                object: nil,
                userInfo: ["isProcessing": true]
            )
        }
        var processedCount = 0
        var attemptedPhotoIDs: Set<UUID> = []

        while !Task.isCancelled {
            if cancelProcessingRequested {
                break
            }

            if let maxCount, processedCount >= maxCount {
                break
            }

            guard let candidate = await claimNextPendingUpload(excluding: attemptedPhotoIDs) else {
                break
            }
            attemptedPhotoIDs.insert(candidate.photoID)

            do {
                activeUploadCount += 1
                defer {
                    activeUploadCount -= 1
                    signalIdleIfNeeded()
                }

                try await upload(candidate)
                try await markUploadCompleted(candidate)
                processedCount += 1
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.didCompleteUploadNotification, object: candidate.objectID)
                }
            } catch is CancellationError {
                logger.error("upload-candidate-cancelled photo=\(candidate.photoID.uuidString, privacy: .public) attempt=\(candidate.attemptCount, privacy: .public)")
                await markUploadFailure(
                    for: candidate.photoID,
                    message: "Upload cancelled before completion.",
                    disposition: .retry(Date().addingTimeInterval(60))
                )
                break
            } catch {
                if ICloudAvailabilityMonitor.isUnavailableCloudKitError(error) {
                    await MainActor.run {
                        ICloudAvailabilityMonitor.shared.recordCloudKitError(error)
                    }
                    await deferUploadUntilICloudAvailable(for: candidate.photoID)
                    break
                }

                let disposition = retryDisposition(for: error, attemptCount: candidate.attemptCount)
                logger.error(
                    "upload-candidate-failed photo=\(candidate.photoID.uuidString, privacy: .public) attempt=\(candidate.attemptCount, privacy: .public) error=\(self.describe(error), privacy: .public)"
                )
                await markUploadFailure(
                    for: candidate.photoID,
                    message: self.describe(error),
                    disposition: disposition,
                    reason: PhotoUploadFailureReason.classify(error)
                )
                processedCount += 1
                if PhotoUploadFailureReason.classify(error) == .iCloudStorageFull { break }
            }
        }

        let remaining = await pendingUploadCount()
        if schedulesRemainingWork,
           remaining > 0,
           !uploadStore.allEntries().contains(where: { $0.state == .paused && $0.failureReason == .iCloudStorageFull }),
           !cancelProcessingRequested, !Task.isCancelled,
           await cloudOperationsAvailable() {
            let retryDate = await nextRetryDate()
            Self.scheduleBackgroundProcessing(earliestBeginDate: retryDate)
            if let retryDate { scheduleRetry(at: retryDate) }
        }
        return remaining
    }

    private func resolveIdleWaiter(id: UUID, result: Bool) {
        guard let continuation = idleWaiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: result)
    }

    private func signalIdleIfNeeded() {
        guard !isProcessing && activeUploadCount == 0 else { return }

        let waiters = idleWaiters.values
        idleWaiters.removeAll()

        for continuation in waiters {
            continuation.resume(returning: true)
        }
    }

    private func upload(_ candidate: PendingPhotoUpload) async throws {
        let cloudKitService = await resolvedCloudKitService()
        logger.log(
            "upload-candidate-start photo=\(candidate.photoID.uuidString, privacy: .public) still=\(candidate.stillAssetName, privacy: .public) video=\(candidate.videoAssetName ?? "nil", privacy: .public) attempt=\(candidate.attemptCount, privacy: .public)"
        )

        try await uploadOrReconcileRemoteAsset(
            cloudKitService: cloudKitService,
            named: candidate.stillAssetName,
            photoID: candidate.photoID,
            role: .still
        )

        if let liveImageName = candidate.livePhotoImageAssetName,
           liveImageName != candidate.stillAssetName {
            try await uploadOrReconcileRemoteAsset(
                cloudKitService: cloudKitService,
                named: liveImageName,
                photoID: candidate.photoID,
                role: .livePhotoImage
            )
        }

        if let videoAssetName = candidate.videoAssetName {
            try await uploadOrReconcileRemoteAsset(
                cloudKitService: cloudKitService,
                named: videoAssetName,
                photoID: candidate.photoID,
                role: .livePhotoVideo
            )
        }

        logger.log("upload-candidate-finished photo=\(candidate.photoID.uuidString, privacy: .public)")
    }

    private func uploadOrReconcileRemoteAsset(
        cloudKitService: CloudKitService,
        named assetName: String,
        photoID: UUID,
        role: PhotoAssetRole
    ) async throws {
        try Task.checkCancellation()
        guard !cancelProcessingRequested,
              let entry = cloudKitService.uploadStateStore.entry(for: photoID),
              entry.state == .uploading, entry.assetNames.contains(assetName) else { throw CancellationError() }
        var restoredAsset = false
        if await cloudKitService.stagedAssetURL(named: assetName) == nil {
            if try await cloudKitService.remoteAssetExists(named: assetName) { return }
            guard try await cloudKitService.restoreStagedUploadAsset(named: assetName, photoID: photoID) else {
                throw CloudKitError.assetNotFound
            }
            restoredAsset = true
        }
        do {
            try await cloudKitService.uploadStagedAsset(
                named: assetName,
                photoID: photoID,
                role: role,
                retainsStagedOriginal: true
            )
        } catch {
            guard PhotoUploadFailureReason.classify(error) == .missingUploadAsset else { throw error }
            if try await cloudKitService.remoteAssetExists(named: assetName) {
                logger.log(
                    "upload-reconciled-remote-asset photo=\(photoID.uuidString, privacy: .public) name=\(assetName, privacy: .public) role=\(role.rawValue, privacy: .public)"
                )
                return
            }
            guard !restoredAsset,
                  try await cloudKitService.restoreStagedUploadAsset(named: assetName, photoID: photoID) else { throw error }
            try Task.checkCancellation()
            try await cloudKitService.uploadStagedAsset(
                named: assetName, photoID: photoID, role: role, retainsStagedOriginal: true
            )
        }
    }

    func claimNextPendingUploadForTesting(in context: NSManagedObjectContext) async -> NSManagedObjectID? {
        await claimNextPendingUpload(in: context)?.objectID
    }

    func uploadNextPendingPhotoForTesting(in context: NSManagedObjectContext) async throws -> Bool {
        guard let candidate = await claimNextPendingUpload(in: context) else { return false }
        do {
            try await upload(candidate)
            try await markUploadCompleted(candidate, in: context)
            return true
        } catch {
            await markUploadFailure(
                for: candidate.photoID, message: describe(error),
                disposition: retryDisposition(for: error, attemptCount: candidate.attemptCount),
                reason: PhotoUploadFailureReason.classify(error)
            )
            throw error
        }
    }

    private func resolvedCloudKitService() async -> CloudKitService {
        if let injectedCloudKitService { return injectedCloudKitService }
        return await MainActor.run { CloudKitService.shared }
    }

    private func claimNextPendingUpload(
        in suppliedContext: NSManagedObjectContext? = nil,
        excluding attemptedPhotoIDs: Set<UUID> = []
    ) async -> PendingPhotoUpload? {
        let cloud = await resolvedCloudKitService()
        let store = cloud.uploadStateStore
        guard !store.allEntries().contains(where: { $0.state == .paused && $0.failureReason == .iCloudStorageFull }) else { return nil }
        let stagedNames = await cloud.storedPersistentAssetNames()
        let ownedIDs = store.allEntries().filter { $0.state != .uploaded }.map { $0.photoID as NSUUID }
        guard !stagedNames.isEmpty || !ownedIDs.isEmpty else { return nil }
        let context: NSManagedObjectContext
        if let suppliedContext = suppliedContext ?? injectedContext { context = suppliedContext }
        else { context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() } }

        let candidates: [PendingPhotoUpload] = (try? await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.fetchBatchSize = 100
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DailyPhoto.createdAt, ascending: true)]
            request.predicate = NSPredicate(format: "fullImageAssetName IN %@ OR id IN %@", Array(stagedNames), ownedIDs)
            return try context.fetch(request).compactMap { photo -> PendingPhotoUpload? in
                guard let id = photo.id, let still = photo.fullImageAssetName,
                      !photo.isDeleted, !photo.objectID.isTemporaryID else { return nil }
                return PendingPhotoUpload(
                    objectID: photo.objectID, photoID: id, stillAssetName: still,
                    livePhotoImageAssetName: photo.livePhotoImageAssetName,
                    videoAssetName: photo.livePhotoVideoAssetName, attemptCount: 0
                )
            }
        }) ?? []

        for candidate in candidates {
            guard !attemptedPhotoIDs.contains(candidate.photoID), !claimedPhotoIDs.contains(candidate.photoID) else { continue }
            // Readable download caches are deliberately not proof of local ownership.
            let hasStagedOriginals = candidate.assetNames.isSubset(of: stagedNames)
            let hasUploadOwnership = store.entry(for: candidate.photoID)?.assetNames == candidate.assetNames
            guard hasStagedOriginals || hasUploadOwnership else { continue }
            do {
                if hasStagedOriginals {
                    try store.register(LocalPhotoUpload(
                        photoID: candidate.photoID, stillAssetName: candidate.stillAssetName,
                        livePhotoImageAssetName: candidate.livePhotoImageAssetName,
                        videoAssetName: candidate.videoAssetName, createdAt: Date()
                    ))
                }
                guard let entry = store.entry(for: candidate.photoID) else { continue }
                switch entry.state {
                case .uploaded: continue
                case .paused where !entry.needsAssetRecovery: continue
                case .failed where (entry.retryAfter ?? .distantPast) > Date(): continue
                default: break
                }
                guard entry.attemptCount < Int(Self.maxUploadAttemptCount) else {
                    try store.update(photoID: entry.photoID) {
                        $0.state = .paused
                        $0.errorMessage = "Upload paused after too many retry attempts."
                        $0.retryAfter = nil
                    }
                    continue
                }
                try store.update(photoID: entry.photoID) {
                    $0.state = .uploading
                    $0.attemptCount += 1
                    $0.errorMessage = nil
                    $0.retryAfter = nil
                    $0.failureReason = nil
                }
                claimedPhotoIDs.insert(candidate.photoID)
                return PendingPhotoUpload(
                    objectID: candidate.objectID, photoID: candidate.photoID,
                    stillAssetName: candidate.stillAssetName,
                    livePhotoImageAssetName: candidate.livePhotoImageAssetName,
                    videoAssetName: candidate.videoAssetName, attemptCount: entry.attemptCount + 1
                )
            } catch {
                logger.error("claim-local-upload: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return nil
    }

    private func markUploadCompleted(_ candidate: PendingPhotoUpload, in suppliedContext: NSManagedObjectContext? = nil) async throws {
        defer { claimedPhotoIDs.remove(candidate.photoID) }
        let cloud = await resolvedCloudKitService()
        let store = cloud.uploadStateStore
        guard store.entry(for: candidate.photoID) != nil else { return }
        // Persist success before removing any original, including after partial Live uploads.
        try store.update(photoID: candidate.photoID) {
            $0.state = .uploaded
            $0.errorMessage = nil
            $0.retryAfter = nil
            $0.failureReason = nil
        }
        do {
            let policy = await MainActor.run { PhotoOfflineSettings.policy(in: cloud.offlineSettingsDefaults) }
            let retaining: Bool
            if policy == .hearted {
                let context: NSManagedObjectContext
                if let suppliedContext = suppliedContext ?? injectedContext { context = suppliedContext }
                else { context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() } }
                // Read current hearts after upload, rather than an earlier queue snapshot.
                retaining = try await context.perform {
                    guard let photo = try context.existingObject(with: candidate.objectID) as? DailyPhoto, !photo.isDeleted else { return false }
                    return photo.isHearted || photo.isFavoriteLivePhoto
                }
            } else {
                retaining = policy == .all
            }
            if !retaining, await MainActor.run(body: { PhotoOfflineSettings.keepsRecentPhotos(in: cloud.offlineSettingsDefaults) }),
               try await cloud.offlineStore.accessDates()[candidate.stillAssetName] != nil {
                // The coordinator budgets the complete photo before handing off
                // uploaded staging files. Keep them safe until that reconciliation.
                return
            }
            try await cloud.finishUploadedOriginals(assetNames: candidate.assetNames, retaining: retaining)
        } catch {
            // Upload succeeded. Keep the remaining staging files and let the
            // offline coordinator recover the handoff without uploading again.
            logger.error("offline-upload-handoff: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func markUploadFailure(for photoID: UUID, message: String, disposition: UploadFailureDisposition, reason: PhotoUploadFailureReason? = nil) async {
        defer { claimedPhotoIDs.remove(photoID) }
        let store = await resolvedCloudKitService().uploadStateStore
        do {
            try store.update(photoID: photoID) {
                guard $0.state == .uploading else { return }
                switch disposition {
                case .retry(let date): $0.state = .failed; $0.retryAfter = date
                case .pause: $0.state = .paused; $0.retryAfter = nil
                }
                $0.errorMessage = message
                $0.failureReason = reason
            }
        } catch {
            logger.error("mark-local-upload-failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deferUploadUntilICloudAvailable(for photoID: UUID) async {
        defer { claimedPhotoIDs.remove(photoID) }
        let store = await resolvedCloudKitService().uploadStateStore
        try? store.update(photoID: photoID) {
            $0.state = .pending
            $0.errorMessage = nil
            $0.retryAfter = nil
            $0.failureReason = nil
        }
    }

    private func locallyOwnedUploads(in suppliedContext: NSManagedObjectContext? = nil) async -> [LocalPhotoUpload] {
        let cloud = await resolvedCloudKitService()
        let store = cloud.uploadStateStore
        let entries = store.allEntries().filter { $0.state != .uploaded }
        guard !entries.isEmpty else { return [] }
        let context: NSManagedObjectContext
        if let suppliedContext = suppliedContext ?? injectedContext { context = suppliedContext }
        else { context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() } }
        let ids: Set<UUID> = (try? await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "DailyPhoto")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]
            request.predicate = NSPredicate(format: "id IN %@", entries.map { $0.photoID as NSUUID })
            return Set(try context.fetch(request).compactMap { $0["id"] as? UUID })
        }) ?? []
        return entries.filter { ids.contains($0.photoID) }
    }

    private func pendingUploadCount() async -> Int {
        await locallyOwnedUploads().filter { $0.state != .paused }.count
    }

    func retryFailedUploads() async -> Int {
        guard await ICloudAvailabilityMonitor.shared.isAvailableForCloudOperations else { return 0 }
        let context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() }
        let resetCount = await resetFailedUploads(in: context)
        if resetCount > 0 { await enqueuePendingUploads(expeditingRetries: true, forceRetryExpedite: true) }
        return resetCount
    }

    func resetFailedUploads(in context: NSManagedObjectContext) async -> Int {
        let store = await resolvedCloudKitService().uploadStateStore
        let entries = await locallyOwnedUploads(in: context).filter { $0.state == .failed || $0.state == .paused }
        var resetCount = 0
        for entry in entries {
            do {
                var didReset = false
                try store.update(photoID: entry.photoID) {
                    guard $0.state == .failed || $0.state == .paused else { return }
                    $0.state = .pending
                    $0.attemptCount = 0
                    $0.errorMessage = nil
                    $0.retryAfter = nil
                    $0.failureReason = nil
                    didReset = true
                }
                if didReset { resetCount += 1 }
            } catch { logger.error("retry-local-upload: \(error.localizedDescription, privacy: .public)") }
        }
        return resetCount
    }

    private func expediteRetryableUploadsIfPossible(force: Bool) async {
        if !force, pathMonitor.currentPath.status != .satisfied { return }
        let store = await resolvedCloudKitService().uploadStateStore
        for entry in await locallyOwnedUploads() where entry.state == .failed && entry.retryAfter != nil {
            try? store.update(photoID: entry.photoID) {
                $0.state = .pending
                $0.retryAfter = nil
            }
        }
    }

    private func nextRetryDate() async -> Date? {
        await locallyOwnedUploads().filter { $0.state == .failed }.compactMap(\.retryAfter).min()
    }

    private func scheduleRetry(at date: Date) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.retryWhenDue()
        }
    }

    private func retryWhenDue() async {
        retryTask = nil
        guard !cancelProcessingRequested else { return }
        _ = await processPendingUploads(maxCount: nil)
    }

    private func retryDisposition(for error: Error, attemptCount: Int) -> UploadFailureDisposition {
        let now = Date()
        if PhotoUploadFailureReason.classify(error) == .iCloudStorageFull { return .pause }
        if let urlError = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(urlError.code) {
            return .retry(backoffRetryDate(attemptCount: attemptCount, now: now))
        }

        if let ckError = error as? CKError {
            if let retryAfter = ckError.retryAfterSeconds {
                return .retry(now.addingTimeInterval(retryAfter))
            }

            switch ckError.code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .serverResponseLost, .accountTemporarilyUnavailable:
                return .retry(backoffRetryDate(attemptCount: attemptCount, now: now))
            case .notAuthenticated:
                return .retry(now.addingTimeInterval(15 * 60))
            case .permissionFailure, .badContainer, .missingEntitlement, .quotaExceeded:
                return .pause
            default:
                return .pause
            }
        }

        if let cloudKitError = error as? CloudKitError {
            switch cloudKitError {
            case .assetNotFound, .invalidImageData:
                return .pause
            case .uploadFailed:
                return .retry(backoffRetryDate(attemptCount: attemptCount, now: now))
            case .downloadFailed:
                return .pause
            }
        }

        return .pause
    }

    private func describe(_ error: Error) -> String {
        if let ckError = error as? CKError {
            return "CKError(\(ckError.code.rawValue)): \(ckError.localizedDescription)"
        }
        return error.localizedDescription
    }

    private func backoffRetryDate(attemptCount: Int, now: Date) -> Date {
        let clampedAttemptCount = max(1, min(attemptCount, 8))
        let seconds = min(pow(2.0, Double(clampedAttemptCount)) * 30.0, 60.0 * 60.0)
        return now.addingTimeInterval(seconds)
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

enum PhotoStorageError: LocalizedError {
    case noImageAsset
    case noVideoAsset
    case noLivePhotoAssets
    case missingImageData
    case saveFailed
    case cloudDeletionPending

    var errorDescription: String? {
        switch self {
        case .noImageAsset:
            return "No image asset found for this photo"
        case .noVideoAsset:
            return "No video asset found for this Live Photo"
        case .noLivePhotoAssets:
            return "No paired Live Photo assets found"
        case .missingImageData:
            return "No encoded image data available to store"
        case .saveFailed:
            return "Failed to save photo"
        case .cloudDeletionPending:
            return "Photo deletion is still waiting on iCloud cleanup"
        }
    }
}
