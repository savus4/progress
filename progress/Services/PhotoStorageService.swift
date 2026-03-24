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
        livePhotoImageData: Data? = nil,
        livePhotoVideoURL: URL? = nil,
        location: (latitude: Double, longitude: Double)?,
        context: NSManagedObjectContext
    ) async throws -> DailyPhoto {
        // Create the Core Data object
        let photo = DailyPhoto(context: context)
        photo.id = UUID()
        photo.captureDate = Date()
        photo.createdAt = Date()
        photo.modifiedAt = Date()
        
        // Save location if available
        if let location = location {
            photo.latitude = location.latitude
            photo.longitude = location.longitude
        }
        
        // Generate and save thumbnail
        if let thumbnailData = thumbnailService.generateThumbnail(from: image) {
            photo.thumbnailData = thumbnailData
        }
        
        // Save full-res image as CloudKit asset
        let imageAssetName = try await cloudKitService.saveImageAsset(image)
        photo.fullImageAssetName = imageAssetName
        
        // Save Live Photo data if available
        if let livePhotoImageData = livePhotoImageData {
            let livePhotoImageDataWithMetadata = embedMetadata(
                in: livePhotoImageData,
                location: location,
                captureDate: photo.captureDate
            )
            let liveImageExtension = imageFileExtension(for: livePhotoImageDataWithMetadata)
            let liveImageAssetName = try await cloudKitService.saveImageDataAsset(
                livePhotoImageDataWithMetadata,
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

        let sourceImageURL = try cloudKitService.loadAssetURL(named: livePhotoImageAssetName)
        let videoURL = try cloudKitService.loadAssetURL(named: livePhotoVideoAssetName)
        let imageURL: URL

        let sourceExtension = sourceImageURL.pathExtension.lowercased()
        if sourceExtension == "heic" || sourceExtension == "heif" {
            imageURL = sourceImageURL
        } else {
            let convertedHEICURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).heic")
            try convertImageToHEIC(sourceURL: sourceImageURL, destinationURL: convertedHEICURL, photo: photo)
            imageURL = convertedHEICURL
        }

        return [imageURL, videoURL]
    }

    /// Prepare a still-image URL as HEIC while preserving metadata where possible.
    func prepareStillPhotoHEICShareURL(for photo: DailyPhoto) throws -> URL {
        guard let fullImageAssetName = photo.fullImageAssetName else {
            throw PhotoStorageError.noImageAsset
        }

        let sourceURL = try cloudKitService.loadAssetURL(named: fullImageAssetName)
        let sourceExtension = sourceURL.pathExtension.lowercased()
        if (sourceExtension == "heic" || sourceExtension == "heif"),
           !sourceStillImageNeedsMetadataRewrite(sourceURL: sourceURL, photo: photo) {
            return sourceURL
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).heic")
        try convertImageToHEIC(sourceURL: sourceURL, destinationURL: outputURL, photo: photo)
        return outputURL
    }

    /// Prepare still-image HEIC bytes with embedded metadata for share-sheet transfer.
    func prepareStillPhotoHEICShareData(for photo: DailyPhoto) throws -> Data {
        let url = try prepareStillPhotoHEICShareURL(for: photo)
        return try Data(contentsOf: url)
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

    private func embedMetadata(
        in imageData: Data,
        location: (latitude: Double, longitude: Double)?,
        captureDate: Date?
    ) -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let type = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return imageData
        }

        let metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        var updatedMetadata = metadata

        if let location {
            updatedMetadata[kCGImagePropertyGPSDictionary] = gpsDictionary(for: location)
        }
        if let captureDate {
            updatedMetadata[kCGImagePropertyExifDictionary] = exifDateDictionary(for: captureDate)
            updatedMetadata[kCGImagePropertyTIFFDictionary] = tiffDateDictionary(for: captureDate)
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, type, 1, nil) else {
            return imageData
        }

        CGImageDestinationAddImage(destination, image, updatedMetadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return imageData
        }

        return mutableData as Data
    }

    private func gpsDictionary(for location: (latitude: Double, longitude: Double)) -> [CFString: Any] {
        let lat = location.latitude
        let lon = location.longitude

        return [
            kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLatitude: abs(lat),
            kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
            kCGImagePropertyGPSLongitude: abs(lon)
        ]
    }

    private func exifDateDictionary(for date: Date) -> [CFString: Any] {
        let offset = exifOffsetString(from: date)
        return [
            kCGImagePropertyExifDateTimeOriginal: exifDateString(from: date),
            kCGImagePropertyExifDateTimeDigitized: exifDateString(from: date),
            "OffsetTimeOriginal" as CFString: offset,
            "OffsetTimeDigitized" as CFString: offset
        ]
    }

    private func tiffDateDictionary(for date: Date) -> [CFString: Any] {
        return [
            kCGImagePropertyTIFFDateTime: exifDateString(from: date)
        ]
    }

    private func exifDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func exifOffsetString(from date: Date) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        return String(format: "%@%02d:%02d", sign, hours, minutes)
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

    private func sourceStillImageNeedsMetadataRewrite(sourceURL: URL, photo: DailyPhoto) -> Bool {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return true
        }

        if photo.latitude != 0 || photo.longitude != 0 {
            let gps = metadata[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            if gps?[kCGImagePropertyGPSLatitude] == nil || gps?[kCGImagePropertyGPSLongitude] == nil {
                return true
            }
        }

        if photo.captureDate != nil {
            let exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any]
            if exif?[kCGImagePropertyExifDateTimeOriginal] == nil {
                return true
            }
        }

        return false
    }

    private func convertImageToHEIC(sourceURL: URL, destinationURL: URL, photo: DailyPhoto) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let sourceType = CGImageSourceGetType(source) else {
            throw PhotoStorageError.noImageAsset
        }

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoStorageError.saveFailed
        }

        var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]

        if photo.latitude != 0 || photo.longitude != 0 {
            metadata[kCGImagePropertyGPSDictionary] = gpsDictionary(
                for: (latitude: photo.latitude, longitude: photo.longitude)
            )
        }
        if let captureDate = photo.captureDate {
            metadata[kCGImagePropertyExifDictionary] = exifDateDictionary(for: captureDate)
            metadata[kCGImagePropertyTIFFDictionary] = tiffDateDictionary(for: captureDate)
        }

        if sourceType as String != UTType.heic.identifier {
            metadata[kCGImageDestinationLossyCompressionQuality] = 0.9
        }

        CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoStorageError.saveFailed
        }
    }
}

enum PhotoStorageError: LocalizedError {
    case noImageAsset
    case noVideoAsset
    case noLivePhotoAssets
    case saveFailed
    
    var errorDescription: String? {
        switch self {
        case .noImageAsset:
            return "No image asset found for this photo"
        case .noVideoAsset:
            return "No video asset found for this Live Photo"
        case .noLivePhotoAssets:
            return "No paired Live Photo assets found"
        case .saveFailed:
            return "Failed to save photo"
        }
    }
}
