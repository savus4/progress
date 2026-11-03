import ImageIO
import UIKit

nonisolated enum PhotoMirroring {
    // Thumbnails have upright pixels. Keep the source's reflection separately so
    // the camera reference can match either camera's preview, even while offline.
    static let mirroredSourceComment = "me.riepl.progress.mirrored-source"

    static func sourceIsMirrored(in data: Data?) -> Bool {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else { return false }
        return sourceIsMirrored(in: source)
    }

    static func sourceIsMirrored(in source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           exif[kCGImagePropertyExifUserComment] as? String == mirroredSourceComment {
            return true
        }
        guard let rawValue = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: rawValue) else { return false }
        switch orientation {
        case .upMirrored, .downMirrored, .leftMirrored, .rightMirrored: return true
        default: return false
        }
    }

    static func isMirrored(_ orientation: UIImage.Orientation) -> Bool {
        switch orientation {
        case .upMirrored, .downMirrored, .leftMirrored, .rightMirrored: true
        default: false
        }
    }
}
