import Foundation
import BackgroundTasks
import CloudKit
import CoreData
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

    private init() {}

    func savePhoto(
        image: UIImage,
        imageData: Data? = nil,
        livePhotoImageData: Data? = nil,
        livePhotoVideoURL: URL? = nil,
        location: (latitude: Double, longitude: Double)?,
        context: NSManagedObjectContext
    ) async throws -> DailyPhoto {
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
        Task.detached(priority: .utility) {
            await PhotoUploadService.shared.enqueuePendingUploads()
        }
        return photo
    }

    func saveImportedPhoto(
        imageData: Data,
        context: NSManagedObjectContext
    ) async throws -> DailyPhoto {
        let photo = try await makeImportedPhoto(
            imageData: imageData,
            livePhotoVideoURL: nil,
            context: context
        )
        try context.save()
        Task.detached(priority: .utility) {
            await PhotoUploadService.shared.enqueuePendingUploads()
        }
        return photo
    }

    func saveImportedLivePhoto(
        imageData: Data,
        videoURL: URL,
        context: NSManagedObjectContext
    ) async throws -> DailyPhoto {
        let photo = try await makeImportedPhoto(
            imageData: imageData,
            livePhotoVideoURL: videoURL,
            context: context
        )
        try context.save()
        Task.detached(priority: .utility) {
            await PhotoUploadService.shared.enqueuePendingUploads()
        }
        return photo
    }

    func saveImportedPhotos(
        _ payloads: [ImportedPhotoPayload],
        batchSize: Int = 12,
        context: NSManagedObjectContext? = nil
    ) async -> ImportedPhotoBatchResult {
        guard !payloads.isEmpty else {
            return ImportedPhotoBatchResult(importedCount: 0, duplicateCount: 0, failedCount: 0, failureMessages: [])
        }

        let importContext = context ?? PersistenceController.shared.makeBackgroundContext()
        let clock = ContinuousClock()
        let startedAt = clock.now

        var importedCount = 0
        var duplicateCount = 0
        var failedCount = 0
        var pendingInsertCount = 0
        var failureMessages: [String] = []
        var knownFingerprints = await existingImportedPhotoFingerprints(context: importContext)

        func recordFailure(_ message: String) {
            if failureMessages.count < 20 {
                failureMessages.append(message)
            }
        }

        for (index, payload) in payloads.enumerated() {
            do {
                let fingerprint = try fingerprint(for: payload)
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
                    context: importContext
                )
                importedCount += 1
                pendingInsertCount += 1
                knownFingerprints.insert(fingerprint)

                if importContext.hasChanges, importedCount.isMultiple(of: max(batchSize, 1)) {
                    do {
                        try await importContext.perform {
                            try importContext.save()
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

    func loadFullImage(from photo: DailyPhoto) async throws -> UIImage {
        guard let assetName = photo.fullImageAssetName else {
            throw PhotoStorageError.noImageAsset
        }

        let fileURL = try await cloudKitService.loadAssetURL(named: assetName)
        guard let image = UIImage(contentsOfFile: fileURL.path) else {
            throw CloudKitError.assetNotFound
        }
        return image
    }

    func loadLivePhotoVideo(from photo: DailyPhoto) async throws -> URL {
        guard let assetName = photo.livePhotoVideoAssetName else {
            throw PhotoStorageError.noVideoAsset
        }
        return try await cloudKitService.loadVideoAsset(named: assetName)
    }

    @MainActor
    func syncPhotoMetadataFromAssetsIfNeeded(photos: [DailyPhoto], context: NSManagedObjectContext) async {
        var updatedPhotos: [DailyPhoto] = []

        for photo in photos {
            guard let assetName = photo.fullImageAssetName else { continue }
            guard let assetURL = try? await cloudKitService.loadAssetURL(named: assetName) else { continue }
            guard let imageData = try? Data(contentsOf: assetURL) else { continue }
            guard let metadata = exifMetadata(from: imageData) else { continue }

            if let exifDate = metadata.captureDate {
                let shouldUpdateDate: Bool
                if let currentDate = photo.captureDate {
                    shouldUpdateDate = abs(currentDate.timeIntervalSince(exifDate)) > 1
                } else {
                    shouldUpdateDate = true
                }

                if shouldUpdateDate {
                    photo.captureDate = exifDate
                    updatedPhotos.append(photo)
                }
            }

            if let location = metadata.location {
                let shouldUpdateLocation =
                    abs(photo.latitude - location.latitude) > 0.000_001 ||
                    abs(photo.longitude - location.longitude) > 0.000_001

                if shouldUpdateLocation {
                    photo.latitude = location.latitude
                    photo.longitude = location.longitude
                    if !updatedPhotos.contains(where: { $0.objectID == photo.objectID }) {
                        updatedPhotos.append(photo)
                    }
                }
            }
        }

        if !updatedPhotos.isEmpty {
            updateModifiedTimestamps(for: updatedPhotos)
            try? context.save()
        }
    }

    func loadLivePhotoResources(from photo: DailyPhoto) async throws -> (imageURL: URL, videoURL: URL) {
        guard let imageAssetName = photo.livePhotoImageAssetName,
              let videoAssetName = photo.livePhotoVideoAssetName else {
            throw PhotoStorageError.noLivePhotoAssets
        }

        async let imageURL = cloudKitService.loadAssetURL(named: imageAssetName)
        async let videoURL = cloudKitService.loadAssetURL(named: videoAssetName)
        return try await (imageURL, videoURL)
    }

    func deletePhoto(_ photo: DailyPhoto, context: NSManagedObjectContext) async throws {
        let assetNames = Set(assetNames(for: photo))
        context.delete(photo)
        try context.save()
        await deleteAssets(named: assetNames)
    }

    func photoCount(
        from startDate: Date,
        to endDate: Date,
        context: NSManagedObjectContext
    ) throws -> Int {
        let request = DailyPhoto.fetchRequest()
        request.predicate = dateRangePredicate(from: startDate, to: endDate)
        return try context.count(for: request)
    }

    func deletePhotos(
        from startDate: Date,
        to endDate: Date,
        context: NSManagedObjectContext
    ) async throws -> Int {
        let request = DailyPhoto.fetchRequest()
        request.predicate = dateRangePredicate(from: startDate, to: endDate)

        let photos = try context.fetch(request)
        guard !photos.isEmpty else { return 0 }

        let assetNames = Set(photos.flatMap(assetNames(for:)))

        for photo in photos {
            context.delete(photo)
        }

        try context.save()
        await deleteAssets(named: assetNames)
        return photos.count
    }

    func deleteAllPhotos(context: NSManagedObjectContext) async throws -> Int {
        let request = DailyPhoto.fetchRequest()
        let photos = try context.fetch(request)
        guard !photos.isEmpty else { return 0 }

        let assetNames = Set(photos.flatMap(assetNames(for:)))

        for photo in photos {
            context.delete(photo)
        }

        try context.save()
        await deleteAssets(named: assetNames)
        try await reclaimPersistentStoreSpaceIfNeeded(context: context)
        return photos.count
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

    func prepareExportFiles(for photos: [DailyPhoto]) async throws -> [URL] {
        let exportRoot = try makeExportRootDirectory()
        var exportedDirectories: [URL] = []

        for photo in photos {
            let photoDirectory = try createPhotoExportDirectory(for: photo, inside: exportRoot)
            try await exportPhotoAssets(for: photo, to: photoDirectory)
            exportedDirectories.append(photoDirectory)
        }

        return exportedDirectories
    }

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

    func prepareLivePhotoShareItemURLs(for photo: DailyPhoto) async throws -> [URL] {
        let resources = try await loadLivePhotoResources(from: photo)
        return [resources.imageURL, resources.videoURL]
    }

    func prepareStillPhotoShareURL(for photo: DailyPhoto) async throws -> URL {
        guard let fullImageAssetName = photo.fullImageAssetName else {
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

    private func createPhotoExportDirectory(for photo: DailyPhoto, inside root: URL) throws -> URL {
        let dateText = photo.captureDate?
            .formatted(date: .numeric, time: .standard)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "_") ?? "unknown_date"
        let idText = photo.id?.uuidString ?? UUID().uuidString
        let directoryName = "photo_\(dateText)_\(idText)"
        let directoryURL = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func exportPhotoAssets(for photo: DailyPhoto, to directory: URL) async throws {
        if let livePhotoImageAssetName = photo.livePhotoImageAssetName,
           let livePhotoVideoAssetName = photo.livePhotoVideoAssetName {
            try await copyAsset(named: livePhotoImageAssetName, to: directory)
            try await copyAsset(named: livePhotoVideoAssetName, to: directory)
            return
        }

        guard let fullImageAssetName = photo.fullImageAssetName else {
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
        for assetName in assetNames {
            await cloudKitService.deleteRemoteAsset(named: assetName)
        }
    }

    private func existingImportedPhotoFingerprints(context: NSManagedObjectContext) async -> Set<String> {
        do {
            return try await context.perform {
                let request = NSFetchRequest<NSDictionary>(entityName: "DailyPhoto")
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["importFingerprint"]

                let rows = try context.fetch(request)
                let fingerprints = rows.compactMap { $0["importFingerprint"] as? String }
                return Set(fingerprints)
            }
        } catch {
            logger.error("fingerprint-fetch: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func dateRangePredicate(from startDate: Date, to endDate: Date) -> NSPredicate {
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
        context: NSManagedObjectContext
    ) async throws -> DailyPhoto {
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

        return await context.perform {
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
            return photo
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
}

private struct PendingPhotoUpload {
    let objectID: NSManagedObjectID
    let photoID: UUID
    let stillAssetName: String
    let videoAssetName: String?
    let attemptCount: Int
}

actor PhotoUploadService {
    static let shared = PhotoUploadService()
    static let backgroundTaskIdentifier = "me.riepl.progress.photo-upload"
    static let didCompleteUploadNotification = Notification.Name("PhotoUploadService.didCompleteUpload")

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
                await PhotoUploadService.shared.enqueuePendingUploads()
            }
        }
        pathMonitor.start(queue: monitorQueue)

        Self.scheduleBackgroundProcessing()

        Task {
            await enqueuePendingUploads()
        }
    }

    func enqueuePendingUploads() async {
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
        defer { isProcessing = false }

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
                await markUploadFailed(
                    for: candidate.objectID,
                    message: "Upload cancelled before completion.",
                    retryAfter: Date().addingTimeInterval(60)
                )
                break
            } catch {
                logger.error(
                    "upload-candidate-failed photo=\(candidate.photoID.uuidString, privacy: .public) attempt=\(candidate.attemptCount, privacy: .public) error=\(self.describe(error), privacy: .public)"
                )
                await markUploadFailed(
                    for: candidate.objectID,
                    message: self.describe(error),
                    retryAfter: retryDate(for: error, attemptCount: candidate.attemptCount)
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

    private func markUploadFailed(for objectID: NSManagedObjectID, message: String, retryAfter: Date?) async {
        let context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() }
        do {
            try await context.perform {
                guard let photo = try? context.existingObject(with: objectID) as? DailyPhoto else {
                    return
                }
                photo.uploadState = .failed
                photo.uploadErrorMessage = message
                photo.uploadRetryAfter = retryAfter
                try context.save()
                self.logger.error(
                    "mark-upload-failed photo=\(photo.id?.uuidString ?? "nil", privacy: .public) retry=\(retryAfter?.description ?? "nil", privacy: .public) message=\(message, privacy: .public)"
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

    private func retryDate(for error: Error, attemptCount: Int) -> Date? {
        let now = Date()

        if let ckError = error as? CKError {
            if let retryAfter = ckError.retryAfterSeconds {
                return now.addingTimeInterval(retryAfter)
            }

            switch ckError.code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .serverResponseLost:
                let seconds = min(pow(2.0, Double(max(attemptCount, 1))) * 30.0, 60.0 * 60.0)
                return now.addingTimeInterval(seconds)
            case .notAuthenticated:
                return now.addingTimeInterval(10 * 60)
            default:
                return nil
            }
        }

        return nil
    }

    private func describe(_ error: Error) -> String {
        if let ckError = error as? CKError {
            return "CKError(\(ckError.code.rawValue)): \(ckError.localizedDescription)"
        }
        return error.localizedDescription
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
