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
    
    private init() {
        container = CKContainer.default()
        privateDatabase = container.privateCloudDatabase
        assetDirectoryURL = Self.makeAssetDirectoryURL()
    }
    
    /// Save an image as a HEIF CKAsset
    /// - Parameter image: UIImage to save
    /// - Returns: The file name/identifier of the saved asset
    func saveImageAsset(_ image: UIImage) async throws -> String {
        let fileName = "\(UUID().uuidString).heic"
        let fileURL = assetFileURL(for: fileName)
        let imageData = autoreleasepool {
            heifData(from: image, compressionQuality: 0.9)
        }
        guard let imageData else {
            throw CloudKitError.invalidImageData
        }
        try imageData.write(to: fileURL, options: .atomic)

        return fileName
    }

    /// Save raw image data as an asset
    /// - Parameters:
    ///   - data: Raw image data
    ///   - fileExtension: File extension, defaults to heic
    /// - Returns: The file name/identifier of the saved asset
    func saveImageDataAsset(_ data: Data, fileExtension: String = "heic") async throws -> String {
        let fileName = "\(UUID().uuidString).\(fileExtension)"
        let fileURL = assetFileURL(for: fileName)

        try data.write(to: fileURL)
        return fileName
    }
    
    /// Save a video file as a CKAsset (for Live Photos)
    /// - Parameter videoURL: URL of the video file
    /// - Returns: The file name/identifier of the saved asset
    func saveVideoAsset(from videoURL: URL) async throws -> String {
        let sourceExtension = videoURL.pathExtension
        let fileExtension = sourceExtension.isEmpty ? "mov" : sourceExtension
        let fileName = "\(UUID().uuidString).\(fileExtension)"
        let destinationURL = assetFileURL(for: fileName)
        
        try FileManager.default.copyItem(at: videoURL, to: destinationURL)
        
        return fileName
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
        if FileManager.default.fileExists(atPath: persistentURL.path) {
            try? FileManager.default.removeItem(at: persistentURL)
        }

        let legacyTemporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(assetName)
        if FileManager.default.fileExists(atPath: legacyTemporaryURL.path) {
            try? FileManager.default.removeItem(at: legacyTemporaryURL)
        }
    }

    func storedPersistentAssetNames() -> Set<String> {
        guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: assetDirectoryURL.path) else {
            return []
        }
        return Set(fileNames)
    }

    private func assetFileURL(for assetName: String) -> URL {
        assetDirectoryURL.appendingPathComponent(assetName)
    }

    private func resolveAssetURL(named assetName: String) throws -> URL {
        let persistentURL = assetFileURL(for: assetName)
        if FileManager.default.fileExists(atPath: persistentURL.path) {
            return persistentURL
        }

        let legacyTemporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(assetName)
        if FileManager.default.fileExists(atPath: legacyTemporaryURL.path) {
            return legacyTemporaryURL
        }

        throw CloudKitError.assetNotFound
    }

    private static func makeAssetDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "progress"
        let directoryURL = baseURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Assets", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        return directoryURL
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
