import Foundation
import BackgroundTasks
import CloudKit
@preconcurrency import CoreData
import Network
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import os

struct ImportedPhotoPayload: Sendable {
    let imageData: Data
    let livePhotoVideoURL: URL?

    init(imageData: Data, livePhotoVideoURL: URL? = nil) {
        self.imageData = imageData
        self.livePhotoVideoURL = livePhotoVideoURL
    }
}

struct ImportedPhotoBatchResult: Sendable {
    let importedCount: Int
    let duplicateCount: Int
    let failedCount: Int
    let failureMessages: [String]
}

enum PhotoUploadState: String, Sendable {
    case pending
    case uploading
    case uploaded
    case failed
    case paused
}

extension DailyPhoto {
    var uploadState: PhotoUploadState {
        get {
            guard let rawValue = uploadStateRaw else {
                return .uploaded
            }
            return PhotoUploadState(rawValue: rawValue) ?? .uploaded
        }
        set {
            uploadStateRaw = newValue.rawValue
        }
    }
}

final class PhotoStorageService {
    static let shared = PhotoStorageService()

    private let cloudKitService = CloudKitService.shared
    private let thumbnailService = ThumbnailService.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "PhotoStorage")
    private let metadataSyncBatchLimit = 50

    private init() {}

    func savePhoto(
        image: UIImage,
        imageData: Data? = nil,
        livePhotoImageData: Data? = nil,
        livePhotoVideoURL: URL? = nil,
        location: (latitude: Double, longitude: Double)?,
        context: NSManagedObjectContext
    ) async throws -> NSManagedObjectID {
        let photoID = UUID()
        let sourceImageData = livePhotoImageData ?? imageData
        guard let sourceImageData else {
            throw PhotoStorageError.missingImageData
        }

        let extractedMetadata = exifMetadata(from: sourceImageData)
        let resolvedLocation = extractedMetadata?.location ?? location
        let stillAssetName = try stageStillAsset(
            data: sourceImageData,
            photoID: photoID,
            role: .still
        )
        let livePhotoVideoAssetName: String?
        if let livePhotoVideoURL {
            livePhotoVideoAssetName = try stageVideoAsset(
                from: livePhotoVideoURL,
                photoID: photoID,
                role: .livePhotoVideo
            )
        } else {
            livePhotoVideoAssetName = nil
        }

        let importFingerprint = try fingerprint(imageData: sourceImageData, livePhotoVideoURL: livePhotoVideoURL)
        let thumbnailData = await thumbnailService.generateThumbnailAsync(from: sourceImageData)

        let objectID = try await context.perform {
            let photo = DailyPhoto(context: context)
            photo.id = photoID
            photo.captureDate = extractedMetadata?.captureDate ?? Date()
            photo.createdAt = Date()
            photo.modifiedAt = Date()
            photo.latitude = resolvedLocation?.latitude ?? 0
            photo.longitude = resolvedLocation?.longitude ?? 0
            photo.thumbnailData = thumbnailData
            photo.fullImageAssetName = stillAssetName
            photo.livePhotoImageAssetName = livePhotoVideoAssetName == nil ? nil : stillAssetName
            photo.livePhotoVideoAssetName = livePhotoVideoAssetName
            photo.setValue(nil, forKey: "fullImageData")
            photo.setValue(nil, forKey: "livePhotoImageData")
            photo.setValue(nil, forKey: "livePhotoVideoData")
            photo.setValue(importFingerprint, forKey: "importFingerprint")
            photo.uploadState = .pending
            photo.uploadAttemptCount = 0
            photo.uploadErrorMessage = nil
            photo.uploadRetryAfter = nil

            try context.save()
            return photo.objectID
        }
        Task.detached(priority: .utility) {
            await PhotoUploadService.shared.enqueuePendingUploads()
        }
        return objectID
    }

    func saveImportedPhoto(
        imageData: Data,
        context: NSManagedObjectContext
    ) async throws -> NSManagedObjectID {
        let objectID = try await makeImportedPhoto(
            imageData: imageData,
            livePhotoVideoURL: nil,
            context: context
        )
        Task.detached(priority: .utility) {
            await PhotoUploadService.shared.enqueuePendingUploads()
        }
        return objectID
    }

    func saveImportedLivePhoto(
        imageData: Data,
        videoURL: URL,
        context: NSManagedObjectContext
    ) async throws -> NSManagedObjectID {
        let objectID = try await makeImportedPhoto(
            imageData: imageData,
            livePhotoVideoURL: videoURL,
            context: context
        )
        Task.detached(priority: .utility) {
            await PhotoUploadService.shared.enqueuePendingUploads()
        }
        return objectID
    }

    func saveImportedPhotos(
        _ payloads: [ImportedPhotoPayload],
        batchSize: Int = 4,
        context: NSManagedObjectContext? = nil
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

        func recordFailure(_ message: String) {
            if failureMessages.count < 20 {
                failureMessages.append(message)
            }
        }

        for (index, payload) in payloads.enumerated() {
            do {
                payloadFingerprints[index] = try fingerprint(for: payload)
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

                _ = try await makeImportedPhoto(
                    imageData: payload.imageData,
                    livePhotoVideoURL: payload.livePhotoVideoURL,
                    context: importContext,
                    saveChanges: false
                )
                importedCount += 1
                pendingInsertCount += 1
                knownFingerprints.insert(fingerprint)

                if importContext.hasChanges, pendingInsertCount >= effectiveBatchSize {
                    do {
                        try await importContext.perform {
                            try importContext.save()
                            if ownsContext {
                                importContext.reset()
                            }
                        }
                        pendingInsertCount = 0
                    } catch {
                        let message = "batch-save payload=\(index) pending=\(pendingInsertCount): \(error.localizedDescription)"
                        logger.error("\(message, privacy: .public)")
                        recordFailure(message)
                        importedCount -= pendingInsertCount
                        failedCount += pendingInsertCount
                        pendingInsertCount = 0
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
            if importContext.hasChanges {
                try await importContext.perform {
                    try importContext.save()
                    if ownsContext {
                        importContext.reset()
                    }
                }
            }
        } catch {
            let message = "final-batch-save pending=\(pendingInsertCount): \(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
            recordFailure(message)
            importedCount -= pendingInsertCount
            failedCount += pendingInsertCount
            await importContext.perform {
                importContext.rollback()
            }
        }

        let elapsed = startedAt.duration(to: clock.now)
        logger.log(
            "Imported \(importedCount, privacy: .public) photos, skipped \(duplicateCount, privacy: .public) duplicates, failed \(failedCount, privacy: .public), elapsed \(String(describing: elapsed), privacy: .public)"
        )

        if importedCount > 0 {
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
        return try await loadFullImage(named: snapshot.fullImageAssetName)
    }

    @MainActor
    func loadLivePhotoVideo(from photo: DailyPhoto) async throws -> URL {
        let snapshot = snapshot(for: photo)
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
            guard let assetURL = try? await cloudKitService.loadAssetURL(named: assetName) else { continue }
            guard let metadata = exifMetadata(from: assetURL) else { continue }

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

        do {
            try await context.perform {
                var updatedPhotos: [DailyPhoto] = []

                for update in updatesByObjectID.values {
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
        let snapshot = snapshot(for: photo)
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

    func deleteAllPhotos(context: NSManagedObjectContext) async throws -> Int {
        let (assetNames, deletedCount) = try await context.perform {
            let request = DailyPhoto.fetchRequest()
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
        try await reclaimPersistentStoreSpaceIfNeeded(context: context)
        return deletedCount
    }

    func purgeOrphanedAssets(context: NSManagedObjectContext) async {
        let referencedAssetNames: Set<String>

        do {
            referencedAssetNames = try await context.perform {
                let request = DailyPhoto.fetchRequest()
                let photos = try context.fetch(request)
                return Set(photos.flatMap(self.assetNames(for:)))
            }
        } catch {
            logger.error("orphan-asset-fetch: \(error.localizedDescription, privacy: .public)")
            return
        }

        let cachedAssetNames = cloudKitService.storedPersistentAssetNames()
        let orphanedAssetNames = cachedAssetNames.subtracting(referencedAssetNames)
        guard !orphanedAssetNames.isEmpty else { return }

        for assetName in orphanedAssetNames {
            cloudKitService.deleteAsset(named: assetName)
        }
    }

    private func reclaimPersistentStoreSpaceIfNeeded(context: NSManagedObjectContext) async throws {
        let remainingPhotoCount = try await context.perform {
            let request = DailyPhoto.fetchRequest()
            return try context.count(for: request)
        }

        guard remainingPhotoCount == 0 else { return }
        await PhotoUploadService.shared.cancelPendingWork()
        cloudKitService.deleteAllLocalAssets()
        try await PersistenceController.shared.rebuildPersistentStore()
    }

    func countPhotosMissingSyncedPayloads(context: NSManagedObjectContext) async -> Int {
        _ = context
        return 0
    }

    func backfillMissingSyncedPayloads(
        context: NSManagedObjectContext,
        batchSize: Int = 1,
        maxPhotosPerRun: Int = 4,
        progress: (@MainActor @Sendable (Int) -> Void)? = nil
    ) async -> LegacyPayloadMigrationResult {
        _ = context
        _ = batchSize
        _ = maxPhotosPerRun
        if let progress {
            await MainActor.run {
                progress(0)
            }
        }
        return LegacyPayloadMigrationResult(scannedCount: 0, migratedCount: 0, missingAssetCount: 0, failedCount: 0)
    }

    @MainActor
    func prepareExportFiles(for photos: [DailyPhoto]) async throws -> [URL] {
        let snapshots = photos.map(snapshot(for:))
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
        let snapshot = snapshot(for: photo)
        let resources = try await loadLivePhotoResources(
            imageAssetName: snapshot.livePhotoImageAssetName,
            videoAssetName: snapshot.livePhotoVideoAssetName
        )
        return [resources.imageURL, resources.videoURL]
    }

    @MainActor
    func prepareStillPhotoShareURL(for photo: DailyPhoto) async throws -> URL {
        let snapshot = snapshot(for: photo)
        return try await prepareStillPhotoShareURL(fullImageAssetName: snapshot.fullImageAssetName)
    }

    func loadFullImage(named fullImageAssetName: String?) async throws -> UIImage {
        guard let fullImageAssetName else {
            throw PhotoStorageError.noImageAsset
        }
        let fileURL = try await cloudKitService.loadAssetURL(named: fullImageAssetName)
        guard let image = UIImage(contentsOfFile: fileURL.path) else {
            throw CloudKitError.assetNotFound
        }
        return image
    }

    func loadLivePhotoVideo(named livePhotoVideoAssetName: String?) async throws -> URL {
        guard let livePhotoVideoAssetName else {
            throw PhotoStorageError.noVideoAsset
        }
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

        async let imageURL = cloudKitService.loadAssetURL(named: imageAssetName)
        async let videoURL = cloudKitService.loadAssetURL(named: videoAssetName)
        return try await (imageURL, videoURL)
    }

    func prepareStillPhotoShareURL(fullImageAssetName: String?) async throws -> URL {
        guard let fullImageAssetName else {
            throw PhotoStorageError.noImageAsset
        }
        return try await cloudKitService.loadAssetURL(named: fullImageAssetName)
    }

    private func stageStillAsset(data: Data, photoID: UUID, role: PhotoAssetRole) throws -> String {
        let fileExtension = imageFileExtension(for: data)
        let assetName = cloudKitService.makeAssetName(photoID: photoID, role: role, fileExtension: fileExtension)
        _ = try cloudKitService.stageAssetData(data, named: assetName)
        return assetName
    }

    private func stageVideoAsset(from videoURL: URL, photoID: UUID, role: PhotoAssetRole) throws -> String {
        let fileExtension = videoURL.pathExtension.isEmpty ? "mov" : videoURL.pathExtension
        let assetName = cloudKitService.makeAssetName(photoID: photoID, role: role, fileExtension: fileExtension)
        _ = try cloudKitService.stageAssetFile(from: videoURL, named: assetName)
        return assetName
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
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private func imageFileExtension(for imageData: Data) -> String {
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

    private func exifMetadata(from imageData: Data) -> (captureDate: Date?, location: (latitude: Double, longitude: Double)?)? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let captureDate = extractCaptureDate(from: metadata)
        let location = extractLocation(from: metadata)
        return (captureDate: captureDate, location: location)
    }

    private func exifMetadata(from imageURL: URL) -> (captureDate: Date?, location: (latitude: Double, longitude: Double)?)? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]

        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, sourceOptions as CFDictionary),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let captureDate = extractCaptureDate(from: metadata)
        let location = extractLocation(from: metadata)
        return (captureDate: captureDate, location: location)
    }

    private func extractCaptureDate(from metadata: [CFString: Any]) -> Date? {
        let exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        let offsetTime = exif?["OffsetTimeOriginal" as CFString] as? String
            ?? exif?["OffsetTimeDigitized" as CFString] as? String

        if let exifDateString = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
           let parsedExifDate = parseExifDate(exifDateString, offset: offsetTime) {
            return parsedExifDate
        }

        if let tiffDateString = tiff?[kCGImagePropertyTIFFDateTime] as? String,
           let parsedTiffDate = parseExifDate(tiffDateString, offset: nil) {
            return parsedTiffDate
        }

        return nil
    }

    private func extractLocation(from metadata: [CFString: Any]) -> (latitude: Double, longitude: Double)? {
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

    private func parseExifDate(_ dateString: String, offset: String?) -> Date? {
        if let offset,
           let date = exifDateTimeWithOffsetFormatter.date(from: "\(dateString)\(offset)") {
            return date
        }
        return exifDateTimeFormatter.date(from: dateString)
    }

    private var exifDateTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }

    private var exifDateTimeWithOffsetFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        return formatter
    }

    private func updateModifiedTimestamps(for photos: [DailyPhoto]) {
        let now = Date()
        for photo in photos {
            photo.modifiedAt = now
        }
    }

    private func assetNames(for photo: DailyPhoto) -> [String] {
        Set([
            photo.fullImageAssetName,
            photo.livePhotoImageAssetName,
            photo.livePhotoVideoAssetName
        ].compactMap { $0 }).map { $0 }
    }

    private func deleteAssets(named assetNames: Set<String>) async {
        guard !assetNames.isEmpty else { return }

        for assetName in assetNames {
            cloudKitService.deleteAsset(named: assetName)
        }

        await RemoteAssetDeletionService.shared.enqueue(assetNames: assetNames)
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

    private static func dateRangePredicate(from startDate: Date, to endDate: Date) -> NSPredicate {
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
        context: NSManagedObjectContext,
        saveChanges: Bool = true
    ) async throws -> NSManagedObjectID {
        let photoID = UUID()
        let exifMetadata = exifMetadata(from: imageData)
        let thumbnailData = await thumbnailService.generateThumbnailAsync(from: imageData)
        let importFingerprint = try fingerprint(imageData: imageData, livePhotoVideoURL: livePhotoVideoURL)
        let imageAssetName = try stageStillAsset(
            data: imageData,
            photoID: photoID,
            role: .still
        )

        let videoAssetName: String?
        if let livePhotoVideoURL {
            videoAssetName = try stageVideoAsset(
                from: livePhotoVideoURL,
                photoID: photoID,
                role: .livePhotoVideo
            )
        } else {
            videoAssetName = nil
        }

        return try await context.perform {
            let photo = DailyPhoto(context: context)
            photo.id = photoID
            photo.captureDate = exifMetadata?.captureDate ?? Date()
            photo.createdAt = Date()
            photo.modifiedAt = Date()
            photo.latitude = exifMetadata?.location?.latitude ?? 0
            photo.longitude = exifMetadata?.location?.longitude ?? 0
            photo.thumbnailData = thumbnailData
            photo.fullImageAssetName = imageAssetName
            photo.livePhotoImageAssetName = videoAssetName == nil ? nil : imageAssetName
            photo.livePhotoVideoAssetName = videoAssetName
            photo.setValue(nil, forKey: "fullImageData")
            photo.setValue(nil, forKey: "livePhotoImageData")
            photo.setValue(nil, forKey: "livePhotoVideoData")
            photo.setValue(importFingerprint, forKey: "importFingerprint")
            photo.uploadState = .pending
            photo.uploadAttemptCount = 0
            photo.uploadErrorMessage = nil
            photo.uploadRetryAfter = nil
            if saveChanges {
                try context.save()
            }
            return photo.objectID
        }
    }

    private func fingerprint(for payload: ImportedPhotoPayload) throws -> String {
        try fingerprint(imageData: payload.imageData, livePhotoVideoURL: payload.livePhotoVideoURL)
    }

    private func fingerprint(imageData: Data, livePhotoVideoURL: URL?) throws -> String {
        let imageDigest = SHA256.hash(data: imageData).hexString

        if let livePhotoVideoURL {
            let videoData = try Data(contentsOf: livePhotoVideoURL)
            let videoDigest = SHA256.hash(data: videoData).hexString
            return "\(imageDigest):\(videoDigest)"
        }

        return imageDigest
    }

    @MainActor
    private func snapshot(for photo: DailyPhoto) -> PhotoSnapshot {
        PhotoSnapshot(
            id: photo.id,
            captureDate: photo.captureDate,
            latitude: photo.latitude,
            longitude: photo.longitude,
            fullImageAssetName: photo.fullImageAssetName,
            livePhotoImageAssetName: photo.livePhotoImageAssetName,
            livePhotoVideoAssetName: photo.livePhotoVideoAssetName
        )
    }

}

private struct PhotoSnapshot: Sendable {
    let id: UUID?
    let captureDate: Date?
    let latitude: Double
    let longitude: Double
    let fullImageAssetName: String?
    let livePhotoImageAssetName: String?
    let livePhotoVideoAssetName: String?
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

actor RemoteAssetDeletionService {
    static let shared = RemoteAssetDeletionService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "RemoteAssetDeletion")
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "progress.remote-asset-deletion.monitor")
    private let storageURL: URL

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

    func processPendingDeletions(expeditingRetries: Bool = false) async {
        loadQueueIfNeeded()

        guard !queuedDeletionsByAssetName.isEmpty else { return }
        guard !isProcessing else { return }

        if !expeditingRetries, pathMonitor.currentPath.status != .satisfied {
            return
        }

        if expeditingRetries {
            expediteRetryableDeletionsIfReachable()
        }

        isProcessing = true
        defer { isProcessing = false }

        let now = Date()
        let orderedAssetNames = queuedDeletionsByAssetName.keys.sorted()
        var didChangeQueue = false

        for assetName in orderedAssetNames {
            guard var pendingDeletion = queuedDeletionsByAssetName[assetName] else {
                continue
            }

            if let retryAfter = pendingDeletion.retryAfter, retryAfter > now {
                continue
            }

            do {
                try await CloudKitService.shared.deleteRemoteAssetRecord(named: assetName)
                queuedDeletionsByAssetName.removeValue(forKey: assetName)
                didChangeQueue = true
                logger.log("remote-asset-delete-succeeded name=\(assetName, privacy: .public)")
            } catch {
                pendingDeletion.attemptCount += 1
                pendingDeletion.retryAfter = retryDate(for: error, attemptCount: pendingDeletion.attemptCount, now: now)
                pendingDeletion.lastErrorDescription = describe(error)
                queuedDeletionsByAssetName[assetName] = pendingDeletion
                didChangeQueue = true
                logger.error(
                    "remote-asset-delete-failed name=\(assetName, privacy: .public) attempt=\(pendingDeletion.attemptCount, privacy: .public) error=\(self.describe(error), privacy: .public)"
                )
            }
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

    private func retryDate(for error: Error, attemptCount: Int, now: Date) -> Date {
        if let ckError = error as? CKError {
            if let retryAfterSeconds = ckError.retryAfterSeconds {
                return now.addingTimeInterval(retryAfterSeconds)
            }

            switch ckError.code {
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

    private func describe(_ error: Error) -> String {
        if let ckError = error as? CKError {
            return "CKError(\(ckError.code.rawValue)): \(ckError.localizedDescription)"
        }
        return error.localizedDescription
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

private struct PendingPhotoUpload {
    let objectID: NSManagedObjectID
    let photoID: UUID
    let stillAssetName: String
    let videoAssetName: String?
    let attemptCount: Int
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

    private var didStart = false
    private var isProcessing = false

    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            Task {
                await PhotoUploadService.shared.handleBackgroundProcessingTask(processingTask)
            }
        }
    }

    nonisolated static func scheduleBackgroundProcessing(earliestBeginDate: Date? = nil) {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "PhotoUpload")
            logger.error("bg-submit: \(error.localizedDescription, privacy: .public)")
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        pathMonitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task {
                await PhotoUploadService.shared.enqueuePendingUploads(
                    expeditingRetries: true,
                    forceRetryExpedite: false
                )
            }
        }
        pathMonitor.start(queue: monitorQueue)

        Self.scheduleBackgroundProcessing()

        Task {
            await enqueuePendingUploads(
                expeditingRetries: true,
                forceRetryExpedite: true
            )
        }
    }

    func enqueuePendingUploads(expeditingRetries: Bool = false, forceRetryExpedite: Bool = false) async {
        if expeditingRetries {
            await expediteRetryableUploadsIfPossible(force: forceRetryExpedite)
        }
        Self.scheduleBackgroundProcessing()
        _ = await processPendingUploads(maxCount: nil)
    }

    func processPendingUploadsForTesting() async {
        _ = await processPendingUploads(maxCount: nil)
    }

    func cancelPendingWork() {
        isProcessing = false
    }

    private func handleBackgroundProcessingTask(_ task: BGProcessingTask) async {
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
    private func processPendingUploads(maxCount: Int?) async -> Int {
        guard !isProcessing else {
            return await pendingUploadCount()
        }

        isProcessing = true
        await MainActor.run {
            NotificationCenter.default.post(
                name: Self.processingStateDidChangeNotification,
                object: nil,
                userInfo: ["isProcessing": true]
            )
        }
        defer {
            isProcessing = false
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: Self.processingStateDidChangeNotification,
                    object: nil,
                    userInfo: ["isProcessing": false]
                )
            }
        }

        var processedCount = 0

        while !Task.isCancelled {
            if let maxCount, processedCount >= maxCount {
                break
            }

            guard let candidate = await claimNextPendingUpload() else {
                break
            }

            do {
                try await upload(candidate)
                await markUploadCompleted(for: candidate.objectID)
                processedCount += 1
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.didCompleteUploadNotification, object: candidate.objectID)
                }
            } catch is CancellationError {
                logger.error("upload-candidate-cancelled photo=\(candidate.photoID.uuidString, privacy: .public) attempt=\(candidate.attemptCount, privacy: .public)")
                await markUploadFailure(
                    for: candidate.objectID,
                    message: "Upload cancelled before completion.",
                    disposition: .retry(Date().addingTimeInterval(60))
                )
                break
            } catch {
                let disposition = retryDisposition(for: error, attemptCount: candidate.attemptCount)
                logger.error(
                    "upload-candidate-failed photo=\(candidate.photoID.uuidString, privacy: .public) attempt=\(candidate.attemptCount, privacy: .public) error=\(self.describe(error), privacy: .public)"
                )
                await markUploadFailure(
                    for: candidate.objectID,
                    message: self.describe(error),
                    disposition: disposition
                )
                processedCount += 1
            }
        }

        let remaining = await pendingUploadCount()
        if remaining > 0 {
            Self.scheduleBackgroundProcessing(earliestBeginDate: await nextRetryDate())
        }
        return remaining
    }

    private func upload(_ candidate: PendingPhotoUpload) async throws {
        let cloudKitService = await MainActor.run { CloudKitService.shared }
        logger.log(
            "upload-candidate-start photo=\(candidate.photoID.uuidString, privacy: .public) still=\(candidate.stillAssetName, privacy: .public) video=\(candidate.videoAssetName ?? "nil", privacy: .public) attempt=\(candidate.attemptCount, privacy: .public)"
        )

        try await cloudKitService.uploadStagedAsset(
            named: candidate.stillAssetName,
            photoID: candidate.photoID,
            role: .still
        )

        if let videoAssetName = candidate.videoAssetName {
            try await cloudKitService.uploadStagedAsset(
                named: videoAssetName,
                photoID: candidate.photoID,
                role: .livePhotoVideo
            )
        }

        logger.log("upload-candidate-finished photo=\(candidate.photoID.uuidString, privacy: .public)")
    }

    private func claimNextPendingUpload() async -> PendingPhotoUpload? {
        let context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() }
        let now = Date()

        return try? await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.fetchLimit = 1
            request.sortDescriptors = [
                NSSortDescriptor(keyPath: \DailyPhoto.createdAt, ascending: true),
                NSSortDescriptor(keyPath: \DailyPhoto.captureDate, ascending: true)
            ]
            request.predicate = NSPredicate(
                format: """
                fullImageAssetName != nil AND (
                    uploadStateRaw == %@ OR
                    uploadStateRaw == %@ OR
                    (uploadStateRaw == %@ AND (uploadRetryAfter == nil OR uploadRetryAfter <= %@))
                )
                """,
                PhotoUploadState.pending.rawValue,
                PhotoUploadState.uploading.rawValue,
                PhotoUploadState.failed.rawValue,
                now as NSDate
            )

            guard let photo = try context.fetch(request).first,
                  let photoID = photo.id,
                  let stillAssetName = photo.fullImageAssetName else {
                return nil
            }

            if photo.uploadAttemptCount >= Self.maxUploadAttemptCount {
                photo.uploadState = .paused
                photo.uploadErrorMessage = "Upload paused after too many retry attempts."
                photo.uploadRetryAfter = nil
                try context.save()

                self.logger.error(
                    "claim-pending-upload-attempt-limit photo=\(photoID.uuidString, privacy: .public) still=\(stillAssetName, privacy: .public)"
                )
                return nil
            }

            photo.uploadState = .uploading
            photo.uploadAttemptCount += 1
            photo.uploadErrorMessage = nil
            try context.save()

            self.logger.log(
                "claim-pending-upload photo=\(photoID.uuidString, privacy: .public) still=\(stillAssetName, privacy: .public) video=\(photo.livePhotoVideoAssetName ?? "nil", privacy: .public) attempt=\(photo.uploadAttemptCount, privacy: .public)"
            )

            return PendingPhotoUpload(
                objectID: photo.objectID,
                photoID: photoID,
                stillAssetName: stillAssetName,
                videoAssetName: photo.livePhotoVideoAssetName,
                attemptCount: Int(photo.uploadAttemptCount)
            )
        }
    }

    private func markUploadCompleted(for objectID: NSManagedObjectID) async {
        let context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() }
        do {
            try await context.perform {
                guard let photo = try? context.existingObject(with: objectID) as? DailyPhoto else {
                    return
                }
                photo.uploadState = .uploaded
                photo.uploadErrorMessage = nil
                photo.uploadRetryAfter = nil
                photo.modifiedAt = Date()
                try context.save()
                self.logger.log("mark-uploaded photo=\(photo.id?.uuidString ?? "nil", privacy: .public)")
            }
        } catch {
            logger.error("mark-uploaded: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func markUploadFailure(for objectID: NSManagedObjectID, message: String, disposition: UploadFailureDisposition) async {
        let context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() }
        do {
            try await context.perform {
                guard let photo = try? context.existingObject(with: objectID) as? DailyPhoto else {
                    return
                }

                switch disposition {
                case .retry(let retryAfter):
                    photo.uploadState = .failed
                    photo.uploadRetryAfter = retryAfter
                case .pause:
                    photo.uploadState = .paused
                    photo.uploadRetryAfter = nil
                }

                photo.uploadErrorMessage = message
                try context.save()
                self.logger.error(
                    "mark-upload-failed photo=\(photo.id?.uuidString ?? "nil", privacy: .public) disposition=\(String(describing: disposition), privacy: .public) message=\(message, privacy: .public)"
                )
            }
        } catch {
            logger.error("mark-upload-failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pendingUploadCount() async -> Int {
        let context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() }
        return (try? await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.predicate = NSPredicate(
                format: "uploadStateRaw == %@ OR uploadStateRaw == %@ OR uploadStateRaw == %@",
                PhotoUploadState.pending.rawValue,
                PhotoUploadState.uploading.rawValue,
                PhotoUploadState.failed.rawValue
            )
            return try context.count(for: request)
        }) ?? 0
    }

    func retryFailedUploads() async -> Int {
        let context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() }

        let resetCount = (try? await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.predicate = NSPredicate(
                format: "uploadStateRaw == %@ OR uploadStateRaw == %@",
                PhotoUploadState.failed.rawValue,
                PhotoUploadState.paused.rawValue
            )

            let photos = try context.fetch(request)
            guard !photos.isEmpty else { return 0 }

            for photo in photos {
                photo.uploadState = .pending
                photo.uploadAttemptCount = 0
                photo.uploadErrorMessage = nil
                photo.uploadRetryAfter = nil
            }

            try context.save()
            return photos.count
        }) ?? 0

        guard resetCount > 0 else { return 0 }
        await enqueuePendingUploads(expeditingRetries: true, forceRetryExpedite: true)
        return resetCount
    }

    private func expediteRetryableUploadsIfPossible(force: Bool) async {
        if !force {
            guard pathMonitor.currentPath.status == .satisfied else { return }
        }

        let context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() }
        let expeditedCount = (try? await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.predicate = NSPredicate(
                format: "uploadStateRaw == %@ AND uploadRetryAfter != nil",
                PhotoUploadState.failed.rawValue
            )

            let photos = try context.fetch(request)
            guard !photos.isEmpty else { return 0 }

            for photo in photos {
                photo.uploadState = .pending
                photo.uploadRetryAfter = nil
            }

            try context.save()
            return photos.count
        }) ?? 0

        if expeditedCount > 0 {
            logger.log(
                "expedite-retryable-uploads count=\(expeditedCount, privacy: .public) force=\(force, privacy: .public)"
            )
        }
    }

    private func nextRetryDate() async -> Date? {
        let context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() }
        return try? await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.fetchLimit = 1
            request.sortDescriptors = [NSSortDescriptor(keyPath: \DailyPhoto.uploadRetryAfter, ascending: true)]
            request.predicate = NSPredicate(
                format: "uploadStateRaw == %@ AND uploadRetryAfter != nil",
                PhotoUploadState.failed.rawValue
            )
            return try context.fetch(request).first?.uploadRetryAfter
        }
    }

    private func retryDisposition(for error: Error, attemptCount: Int) -> UploadFailureDisposition {
        let now = Date()

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
        }
    }
}
