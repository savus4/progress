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
    
    private init() {
        container = CKContainer.default()
        privateDatabase = container.privateCloudDatabase
    }
    
    /// Save an image as a HEIF CKAsset
    /// - Parameter image: UIImage to save
    /// - Returns: The file name/identifier of the saved asset
    func saveImageAsset(_ image: UIImage) async throws -> String {
        let fileName = "\(UUID().uuidString).heic"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
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
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        try data.write(to: fileURL)
        return fileName
    }
    
    /// Save a video file as a CKAsset (for Live Photos)
    /// - Parameter videoURL: URL of the video file
    /// - Returns: The file name/identifier of the saved asset
    func saveVideoAsset(from videoURL: URL) async throws -> String {
        let fileName = "\(UUID().uuidString).mov"
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
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
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(assetName)
        
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let imageData = try? Data(contentsOf: fileURL),
              let image = UIImage(data: imageData) else {
            throw CloudKitError.assetNotFound
        }
        
        return image
    }
    
    /// Load a video URL from a CKAsset identifier
    /// - Parameter assetName: The asset file name
    /// - Returns: URL of the video file
    func loadVideoAsset(named assetName: String) async throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(assetName)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CloudKitError.assetNotFound
        }
        
        return fileURL
    }

    /// Load an asset URL by name
    /// - Parameter assetName: The asset file name
    /// - Returns: URL if successful
    func loadAssetURL(named assetName: String) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(assetName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CloudKitError.assetNotFound
        }

        return fileURL
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
