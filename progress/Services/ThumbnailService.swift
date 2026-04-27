import UIKit
import CoreData
import ImageIO
import UniformTypeIdentifiers

class ThumbnailService {
    static let shared = ThumbnailService()

    private init() {}

    private let workerQueue = DispatchQueue(
        label: "me.riepl.progress.thumbnail-generation",
        qos: .userInitiated
    )

    private let heicCompressionQuality: CGFloat = 0.58
    private let jpegCompressionQuality: CGFloat = 0.62
    private let minimumSavingsRatioForRewrite: Double = 0.93
    private let minimumSavingsBytesForRewrite = 1024

    /// Generate a thumbnail from an image
    /// - Parameters:
    ///   - image: Source image
    ///   - targetSize: Target size for thumbnail (default 300x300)
    /// - Returns: Encoded thumbnail data (HEIC when supported, JPEG fallback)
    func generateThumbnail(from image: UIImage, targetSize: CGSize = CGSize(width: 300, height: 300)) -> Data? {
        let size = image.size
        let widthRatio  = targetSize.width  / size.width
        let heightRatio = targetSize.height / size.height
        let ratio = min(widthRatio, heightRatio)

        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let thumbnail = renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: newSize))
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        guard let cgImage = thumbnail.cgImage else {
            return thumbnail.jpegData(compressionQuality: jpegCompressionQuality)
        }
        return encodeThumbnail(cgImage: cgImage)
    }

    /// Generate a thumbnail directly from encoded image bytes without decoding full resolution into UIKit first.
    func generateThumbnail(from imageData: Data, targetSize: CGSize = CGSize(width: 300, height: 300)) -> Data? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]

        guard let source = CGImageSourceCreateWithData(imageData as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let maxPixelSize = Int(max(targetSize.width, targetSize.height) * 2.0)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        return encodeThumbnail(cgImage: cgThumbnail)
    }

    func optimizedThumbnailDataIfSmaller(_ data: Data) -> Data? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, sourceOptions as CFDictionary),
              let optimized = encodeThumbnail(cgImage: cgImage) else {
            return nil
        }

        let compressedRatio = Double(optimized.count) / Double(data.count)
        let byteSavings = data.count - optimized.count
        guard byteSavings >= minimumSavingsBytesForRewrite,
              compressedRatio <= minimumSavingsRatioForRewrite else {
            return nil
        }

        return optimized
    }

    func generateThumbnailAsync(
        from imageData: Data,
        targetSize: CGSize = CGSize(width: 300, height: 300)
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            workerQueue.async {
                let thumbnail = self.generateThumbnail(from: imageData, targetSize: targetSize)
                continuation.resume(returning: thumbnail)
            }
        }
    }

    private func encodeThumbnail(cgImage: CGImage) -> Data? {
        if let heicData = encode(cgImage: cgImage, as: UTType.heic.identifier as CFString, quality: heicCompressionQuality) {
            return heicData
        }
        return encode(cgImage: cgImage, as: UTType.jpeg.identifier as CFString, quality: jpegCompressionQuality)
    }

    private func encode(cgImage: CGImage, as uti: CFString, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, uti, 1, nil) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationEmbedThumbnail: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }
}

final class DecodedThumbnailCache {
    static let shared = DecodedThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private let workerQueue = DispatchQueue(
        label: "me.riepl.progress.thumbnail-decoding",
        qos: .userInitiated
    )

    private init() {
        cache.countLimit = 512
        cache.totalCostLimit = 128 * 1_024 * 1_024
    }

    func image(for objectID: NSManagedObjectID, data: Data?) async -> UIImage? {
        guard let data else { return nil }

        let stringKey = objectID.uriRepresentation().absoluteString
        let key = stringKey as NSString
        if let cachedImage = cache.object(forKey: key) {
            return cachedImage
        }

        return await withCheckedContinuation { continuation in
            workerQueue.async {
                let cacheKey = stringKey as NSString
                guard let image = self.decodeThumbnailImage(from: data) else {
                    continuation.resume(returning: nil)
                    return
                }

                let preparedImage = image.preparingForDisplay() ?? image
                self.cache.setObject(preparedImage, forKey: cacheKey, cost: self.cacheCost(for: preparedImage))
                continuation.resume(returning: preparedImage)
            }
        }
    }

    func cachedImage(for objectID: NSManagedObjectID) -> UIImage? {
        cache.object(forKey: cacheKey(for: objectID))
    }

    func removeImage(for objectID: NSManagedObjectID) {
        cache.removeObject(forKey: cacheKey(for: objectID))
    }

    func removeAllImages() {
        cache.removeAllObjects()
    }

    private func cacheKey(for objectID: NSManagedObjectID) -> NSString {
        objectID.uriRepresentation().absoluteString as NSString
    }

    private func decodeThumbnailImage(from data: Data) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: 320
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private func cacheCost(for image: UIImage) -> Int {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        return max(pixelWidth * pixelHeight * 4, 1)
    }
}
