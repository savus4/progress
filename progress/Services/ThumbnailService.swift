import UIKit
import CoreData
import ImageIO

class ThumbnailService {
    static let shared = ThumbnailService()

    private init() {}

    private let workerQueue = DispatchQueue(
        label: "me.riepl.progress.thumbnail-generation",
        qos: .userInitiated
    )

    /// Generate a thumbnail from an image
    /// - Parameters:
    ///   - image: Source image
    ///   - targetSize: Target size for thumbnail (default 300x300)
    /// - Returns: JPEG data of the thumbnail
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

        return thumbnail.jpegData(compressionQuality: 0.7)
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

        let image = UIImage(cgImage: cgThumbnail)
        let renderSize = CGSize(width: cgThumbnail.width, height: cgThumbnail.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        let flattenedImage = renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: renderSize))
            image.draw(in: CGRect(origin: .zero, size: renderSize))
        }
        return flattenedImage.jpegData(compressionQuality: 0.7)
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
}
