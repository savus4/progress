import UIKit
import CoreData

class ThumbnailService {
    static let shared = ThumbnailService()
    
    private init() {}
    
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
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let thumbnail = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        
        return thumbnail.jpegData(compressionQuality: 0.7)
    }
}
