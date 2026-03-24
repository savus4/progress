import Foundation
import CoreData
import UIKit
import ImageIO
import UniformTypeIdentifiers

class PhotoStorageService {
    static let shared = PhotoStorageService()
    
    private let cloudKitService = CloudKitService.shared
    private let thumbnailService = ThumbnailService.shared
    
    private init() {}
    
    /// Save a photo with all its data
    func savePhoto(
        image: UIImage,
        imageData: Data? = nil,
        livePhotoImageData: Data? = nil,
        livePhotoVideoURL: URL? = nil,
        location: (latitude: Double, longitude: Double)?,
        context: NSManagedObjectContext
    ) async throws -> DailyPhoto {
        let metadataSourceData = livePhotoImageData ?? imageData
        let extractedExifMetadata = metadataSourceData.flatMap(exifMetadata(from:))
        let fallbackCaptureDate = Date()
        let resolvedCaptureDate = extractedExifMetadata?.captureDate ?? fallbackCaptureDate
        let resolvedLocation = extractedExifMetadata?.location ?? location

        // Create the Core Data object
        let photo = DailyPhoto(context: context)
        photo.id = UUID()
        photo.captureDate = extractedExifMetadata?.captureDate ?? resolvedCaptureDate
        photo.createdAt = Date()
        photo.modifiedAt = Date()

        if let exifLocation = extractedExifMetadata?.location ?? resolvedLocation {
            photo.latitude = exifLocation.latitude
            photo.longitude = exifLocation.longitude
        } else {
            photo.latitude = 0
            photo.longitude = 0
        }
        
        // Generate and save thumbnail
        if let thumbnailData = thumbnailService.generateThumbnail(from: image) {
            photo.thumbnailData = thumbnailData
        }
        
        // Save full-res image as CloudKit asset, preserving original metadata when available.
        let imageAssetName: String
        if let metadataSourceData {
            let imageExtension = imageFileExtension(for: metadataSourceData)
            imageAssetName = try await cloudKitService.saveImageDataAsset(
                metadataSourceData,
                fileExtension: imageExtension
            )
        } else {
            throw PhotoStorageError.missingImageData
        }
        photo.fullImageAssetName = imageAssetName
        
        // Save Live Photo data if available
        if let livePhotoImageData = livePhotoImageData {
            let liveImageExtension = imageFileExtension(for: livePhotoImageData)
            let liveImageAssetName = try await cloudKitService.saveImageDataAsset(
                livePhotoImageData,
                fileExtension: liveImageExtension
            )
            photo.livePhotoImageAssetName = liveImageAssetName
        }
        
        if let livePhotoVideoURL = livePhotoVideoURL {
            let videoAssetName = try await cloudKitService.saveVideoAsset(from: livePhotoVideoURL)
            photo.livePhotoVideoAssetName = videoAssetName
        }
        
        try context.save()
        
        return photo
    }
    
    /// Save imported photo data without decoding full image into memory first.
    func saveImportedPhoto(
        imageData: Data,
        context: NSManagedObjectContext
    ) async throws -> DailyPhoto {
        let exifMetadata = exifMetadata(from: imageData)

        let photo = DailyPhoto(context: context)
        photo.id = UUID()
        photo.captureDate = exifMetadata?.captureDate ?? Date()
        photo.createdAt = Date()
        photo.modifiedAt = Date()

        if let location = exifMetadata?.location {
            photo.latitude = location.latitude
            photo.longitude = location.longitude
        } else {
            photo.latitude = 0
            photo.longitude = 0
        }

        if let thumbnailData = thumbnailService.generateThumbnail(from: imageData) {
            photo.thumbnailData = thumbnailData
        }

        let imageExtension = imageFileExtension(for: imageData)
        let imageAssetName = try await cloudKitService.saveImageDataAsset(imageData, fileExtension: imageExtension)
        photo.fullImageAssetName = imageAssetName

        try context.save()
        return photo
    }

    /// Save imported Live Photo resources without converting formats.
    func saveImportedLivePhoto(
        imageData: Data,
        videoURL: URL,
        context: NSManagedObjectContext
    ) async throws -> DailyPhoto {
        let exifMetadata = exifMetadata(from: imageData)

        let photo = DailyPhoto(context: context)
        photo.id = UUID()
        photo.captureDate = exifMetadata?.captureDate ?? Date()
        photo.createdAt = Date()
        photo.modifiedAt = Date()

        if let location = exifMetadata?.location {
            photo.latitude = location.latitude
            photo.longitude = location.longitude
        } else {
            photo.latitude = 0
            photo.longitude = 0
        }

        if let thumbnailData = thumbnailService.generateThumbnail(from: imageData) {
            photo.thumbnailData = thumbnailData
        }

        let imageExtension = imageFileExtension(for: imageData)
        let imageAssetName = try await cloudKitService.saveImageDataAsset(imageData, fileExtension: imageExtension)
        photo.fullImageAssetName = imageAssetName
        photo.livePhotoImageAssetName = imageAssetName

        let videoAssetName = try await cloudKitService.saveVideoAsset(from: videoURL)
        photo.livePhotoVideoAssetName = videoAssetName

        try context.save()
        return photo
    }

    /// Load full resolution image
    func loadFullImage(from photo: DailyPhoto) async throws -> UIImage {
        guard let assetName = photo.fullImageAssetName else {
            throw PhotoStorageError.noImageAsset
        }
        
        return try await cloudKitService.loadImageAsset(named: assetName)
    }
    
    /// Load Live Photo video URL
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
            guard let assetURL = try? cloudKitService.loadAssetURL(named: assetName) else { continue }
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
            photoModifiedTimestamps(photos: updatedPhotos)
            try? context.save()
        }
    }

    /// Load Live Photo paired resource URLs
    func loadLivePhotoResources(from photo: DailyPhoto) throws -> (imageURL: URL, videoURL: URL) {
        guard let imageAssetName = photo.livePhotoImageAssetName,
              let videoAssetName = photo.livePhotoVideoAssetName else {
            throw PhotoStorageError.noLivePhotoAssets
        }

        let imageURL = try cloudKitService.loadAssetURL(named: imageAssetName)
        let videoURL = try cloudKitService.loadAssetURL(named: videoAssetName)
        return (imageURL, videoURL)
    }
    
    /// Delete a photo and its assets
    func deletePhoto(_ photo: DailyPhoto, context: NSManagedObjectContext) async throws {
        // Note: In a production app, you'd want to clean up the actual files
        // from CloudKit and temporary storage here
        context.delete(photo)
        try context.save()
    }

    /// Export photos as Live Photo paired resources only (still image + companion movie).
    /// Returns URLs that can be handed to UIDocumentPickerViewController(forExporting:).
    func prepareExportFiles(for photos: [DailyPhoto]) async throws -> [URL] {
        let exportRoot = try makeExportRootDirectory()
        var exportedDirectories: [URL] = []

        for photo in photos {
            let photoDirectory = try createPhotoExportDirectory(for: photo, inside: exportRoot)
            try await exportLivePhotoAssets(for: photo, to: photoDirectory)
            exportedDirectories.append(photoDirectory)
        }

        return exportedDirectories
    }

    /// Prepare shareable file URLs for a single photo export package.
    /// The returned URLs include Live Photo paired resources when available.
    /// If the photo has no Live Photo resources, this falls back to the original still asset.
    func prepareShareItemURLs(for photo: DailyPhoto) async throws -> [URL] {
        do {
            let directories = try await prepareExportFiles(for: [photo])
            guard let directory = directories.first else { return [] }

            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch PhotoStorageError.noLivePhotoAssets {
            guard let fullImageAssetName = photo.fullImageAssetName else {
                throw PhotoStorageError.noImageAsset
            }
            let stillURL = try cloudKitService.loadAssetURL(named: fullImageAssetName)
            return [stillURL]
        }
    }

    /// Prepare shareable URLs for Live Photo paired resources only.
    func prepareLivePhotoShareItemURLs(for photo: DailyPhoto) throws -> [URL] {
        guard let livePhotoImageAssetName = photo.livePhotoImageAssetName,
              let livePhotoVideoAssetName = photo.livePhotoVideoAssetName else {
            throw PhotoStorageError.noLivePhotoAssets
        }

        let imageURL = try cloudKitService.loadAssetURL(named: livePhotoImageAssetName)
        let videoURL = try cloudKitService.loadAssetURL(named: livePhotoVideoAssetName)

        return [imageURL, videoURL]
    }

    /// Prepare a still-image URL in its original file format.
    func prepareStillPhotoShareURL(for photo: DailyPhoto) throws -> URL {
        guard let fullImageAssetName = photo.fullImageAssetName else {
            throw PhotoStorageError.noImageAsset
        }
        return try cloudKitService.loadAssetURL(named: fullImageAssetName)
    }

    private func makeExportRootDirectory() throws -> URL {
        let rootName = "progress_export_\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))"
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(rootName, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private func createPhotoExportDirectory(for photo: DailyPhoto, inside root: URL) throws -> URL {
        let dateText = photo.captureDate?.formatted(date: .numeric, time: .standard).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "_") ?? "unknown_date"
        let idText = photo.id?.uuidString ?? UUID().uuidString
        let directoryName = "photo_\(dateText)_\(idText)"
        let directoryURL = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func exportLivePhotoAssets(for photo: DailyPhoto, to directory: URL) async throws {
        guard let livePhotoImageAssetName = photo.livePhotoImageAssetName,
              let livePhotoVideoAssetName = photo.livePhotoVideoAssetName else {
            throw PhotoStorageError.noLivePhotoAssets
        }

        try copyAsset(named: livePhotoImageAssetName, to: directory)
        try copyAsset(named: livePhotoVideoAssetName, to: directory)
    }

    private func copyAsset(named assetName: String, to directory: URL) throws {
        let sourceURL = try cloudKitService.loadAssetURL(named: assetName)
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

    private func photoModifiedTimestamps(photos: [DailyPhoto]) {
        let now = Date()
        for photo in photos {
            photo.modifiedAt = now
        }
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
