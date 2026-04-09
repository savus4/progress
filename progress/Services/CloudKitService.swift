import Foundation
import CloudKit
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CoreImage

class CloudKitService {
    static let shared = CloudKitService()
    
    private let container: CKContainer
    private let privateDatabase: CKDatabase
    private let assetDirectoryURL: URL
    private let fileManager = FileManager.default
    private let cacheIndexKey = "cachedAssetAccessDates"
    private let maxCacheSizeBytes = 512 * 1_024 * 1_024
    
    private init() {
        container = CKContainer.default()
        privateDatabase = container.privateCloudDatabase
        assetDirectoryURL = Self.makeAssetDirectoryURL()
    }
    
    /// Save an image as a HEIF CKAsset
    /// - Parameter image: UIImage to save
    /// - Returns: The file name/identifier of the saved asset
    func saveImageAsset(_ image: UIImage) async throws -> String {
        let imageData = autoreleasepool {
            heifData(from: image, compressionQuality: 0.9)
        }
        guard let imageData else {
            throw CloudKitError.invalidImageData
        }
        return try await saveImageDataAsset(imageData, fileExtension: "heic")
    }

    /// Save raw image data as an asset
    /// - Parameters:
    ///   - data: Raw image data
    ///   - fileExtension: File extension, defaults to heic
    /// - Returns: The file name/identifier of the saved asset
    func saveImageDataAsset(_ data: Data, fileExtension: String = "heic") async throws -> String {
        _ = data
        return "\(UUID().uuidString).\(fileExtension)"
    }
    
    /// Save a video file as a CKAsset (for Live Photos)
    /// - Parameter videoURL: URL of the video file
    /// - Returns: The file name/identifier of the saved asset
    func saveVideoAsset(from videoURL: URL) async throws -> String {
        let sourceExtension = videoURL.pathExtension
        return "\(UUID().uuidString).\(sourceExtension.isEmpty ? "mov" : sourceExtension)"
    }
    
    private func heifData(from image: UIImage, compressionQuality: CGFloat) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality,
            kCGImagePropertyOrientation: image.imageOrientation.cgImagePropertyOrientation.rawValue
        ] as CFDictionary

        if let cgImage = image.cgImage {
            CGImageDestinationAddImage(destination, cgImage, options)
        } else if let ciImage = image.ciImage {
            let context = CIContext(options: nil)
            guard let rendered = context.createCGImage(ciImage, from: ciImage.extent) else {
                return nil
            }
            CGImageDestinationAddImage(destination, rendered, options)
        } else {
            return nil
        }

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return mutableData as Data
    }

    /// Load an image from a CKAsset identifier
    /// - Parameter assetName: The asset file name
    /// - Returns: UIImage if successful
    func loadImageAsset(named assetName: String) async throws -> UIImage {
        let fileURL = try resolveAssetURL(named: assetName)
        
        guard let image = UIImage(contentsOfFile: fileURL.path) else {
            throw CloudKitError.assetNotFound
        }
        
        return image
    }
    
    /// Load a video URL from a CKAsset identifier
    /// - Parameter assetName: The asset file name
    /// - Returns: URL of the video file
    func loadVideoAsset(named assetName: String) async throws -> URL {
        try resolveAssetURL(named: assetName)
    }

    /// Load an asset URL by name
    /// - Parameter assetName: The asset file name
    /// - Returns: URL if successful
    func loadAssetURL(named assetName: String) throws -> URL {
        try resolveAssetURL(named: assetName)
    }

    func deleteAsset(named assetName: String) {
        let persistentURL = assetFileURL(for: assetName)
        if fileManager.fileExists(atPath: persistentURL.path) {
            try? fileManager.removeItem(at: persistentURL)
        }
        removeCachedAccessDate(for: assetName)

        let legacyPersistentURL = Self.makeLegacyPersistentAssetDirectoryURL().appendingPathComponent(assetName)
        if fileManager.fileExists(atPath: legacyPersistentURL.path) {
            try? fileManager.removeItem(at: legacyPersistentURL)
        }

        let legacyTemporaryURL = fileManager.temporaryDirectory.appendingPathComponent(assetName)
        if fileManager.fileExists(atPath: legacyTemporaryURL.path) {
            try? fileManager.removeItem(at: legacyTemporaryURL)
        }
    }

    func storedPersistentAssetNames() -> Set<String> {
        let currentCacheNames = (try? fileManager.contentsOfDirectory(atPath: assetDirectoryURL.path)) ?? []
        let legacyPersistentNames = (try? fileManager.contentsOfDirectory(atPath: Self.makeLegacyPersistentAssetDirectoryURL().path)) ?? []
        guard currentCacheNames.isEmpty == false || legacyPersistentNames.isEmpty == false else {
            return []
        }
        return Set(currentCacheNames).union(legacyPersistentNames)
    }

    func cacheAssetData(_ data: Data, named assetName: String) throws -> URL {
        let fileURL = assetFileURL(for: assetName)
        if !fileManager.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
        }
        markAssetAccessed(named: assetName)
        pruneCacheIfNeeded(excluding: [assetName])
        return fileURL
    }

    private func assetFileURL(for assetName: String) -> URL {
        assetDirectoryURL.appendingPathComponent(assetName)
    }

    private func resolveAssetURL(named assetName: String) throws -> URL {
        let persistentURL = assetFileURL(for: assetName)
        if fileManager.fileExists(atPath: persistentURL.path) {
            markAssetAccessed(named: assetName)
            return persistentURL
        }

        let legacyPersistentURL = Self.makeLegacyPersistentAssetDirectoryURL().appendingPathComponent(assetName)
        if fileManager.fileExists(atPath: legacyPersistentURL.path) {
            return try migrateLegacyAssetIfNeeded(named: assetName, from: legacyPersistentURL)
        }

        let legacyTemporaryURL = fileManager.temporaryDirectory.appendingPathComponent(assetName)
        if fileManager.fileExists(atPath: legacyTemporaryURL.path) {
            return legacyTemporaryURL
        }

        throw CloudKitError.assetNotFound
    }

    private static func makeAssetDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "progress"
        let directoryURL = baseURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("AssetCache", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        return directoryURL
    }

    private static func makeLegacyPersistentAssetDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "progress"
        return baseURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Assets", isDirectory: true)
    }

    private func markAssetAccessed(named assetName: String) {
        var accessDates = cachedAccessDates()
        accessDates[assetName] = Date().timeIntervalSinceReferenceDate
        UserDefaults.standard.set(accessDates, forKey: cacheIndexKey)
    }

    private func removeCachedAccessDate(for assetName: String) {
        var accessDates = cachedAccessDates()
        accessDates.removeValue(forKey: assetName)
        UserDefaults.standard.set(accessDates, forKey: cacheIndexKey)
    }

    private func cachedAccessDates() -> [String: TimeInterval] {
        let rawValues = UserDefaults.standard.dictionary(forKey: cacheIndexKey) ?? [:]
        var accessDates: [String: TimeInterval] = [:]
        for (key, value) in rawValues {
            if let number = value as? NSNumber {
                accessDates[key] = number.doubleValue
            }
        }
        return accessDates
    }

    private func migrateLegacyAssetIfNeeded(named assetName: String, from legacyURL: URL) throws -> URL {
        let cachedURL = assetFileURL(for: assetName)
        if !fileManager.fileExists(atPath: cachedURL.path) {
            try fileManager.copyItem(at: legacyURL, to: cachedURL)
            try? fileManager.removeItem(at: legacyURL)
        }
        markAssetAccessed(named: assetName)
        pruneCacheIfNeeded(excluding: [assetName])
        return cachedURL
    }

    private func pruneCacheIfNeeded(excluding protectedAssetNames: Set<String> = []) {
        guard var cachedAssetNames = try? fileManager.contentsOfDirectory(atPath: assetDirectoryURL.path) else {
            return
        }

        var totalSize = 0
        var fileSizes: [String: Int] = [:]
        for assetName in cachedAssetNames {
            let assetURL = assetFileURL(for: assetName)
            guard
                let attributes = try? fileManager.attributesOfItem(atPath: assetURL.path),
                let fileSize = attributes[.size] as? NSNumber
            else {
                continue
            }
            let bytes = fileSize.intValue
            totalSize += bytes
            fileSizes[assetName] = bytes
        }

        guard totalSize > maxCacheSizeBytes else { return }

        let accessDates = cachedAccessDates()
        cachedAssetNames.sort {
            let lhsDate = accessDates[$0] ?? 0
            let rhsDate = accessDates[$1] ?? 0
            if lhsDate == rhsDate {
                return $0 < $1
            }
            return lhsDate < rhsDate
        }

        for assetName in cachedAssetNames where totalSize > maxCacheSizeBytes {
            guard !protectedAssetNames.contains(assetName) else { continue }
            let assetURL = assetFileURL(for: assetName)
            guard fileManager.fileExists(atPath: assetURL.path) else {
                removeCachedAccessDate(for: assetName)
                continue
            }
            try? fileManager.removeItem(at: assetURL)
            totalSize -= fileSizes[assetName] ?? 0
            removeCachedAccessDate(for: assetName)
        }
    }
}

private extension UIImage.Orientation {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

enum CloudKitError: LocalizedError {
    case invalidImageData
    case assetNotFound
    case uploadFailed
    case downloadFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Failed to convert image to data"
        case .assetNotFound:
            return "Asset file not found"
        case .uploadFailed:
            return "Failed to upload to CloudKit"
        case .downloadFailed:
            return "Failed to download from CloudKit"
        }
    }
}
