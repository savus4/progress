@preconcurrency import AVFoundation
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Creates export derivatives only. Library assets and upload originals are never modified.
nonisolated enum PhotoExportMirroring {
    struct Resources: Sendable {
        let imageURL: URL
        let videoURL: URL?
        let temporaryDirectory: URL?

        func removeTemporaryFiles() {
            if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        }
    }

    enum Failure: LocalizedError {
        case image, video

        var errorDescription: String? {
            switch self {
            case .image: "Unable to prepare the mirrored photo export."
            case .video: "Unable to prepare the mirrored Live Photo video."
            }
        }
    }

    @concurrent
    static func prepare(imageURL: URL, videoURL: URL? = nil, mirrored: Bool) async throws -> Resources {
        guard mirrored else { return Resources(imageURL: imageURL, videoURL: videoURL, temporaryDirectory: nil) }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MirroredExport-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let outputImage = directory.appendingPathComponent(imageURL.lastPathComponent)
            try mirrorImage(from: imageURL, to: outputImage)
            let outputVideo: URL?
            if let videoURL {
                let destination = directory.appendingPathComponent(videoURL.lastPathComponent)
                try await mirrorVideo(from: videoURL, to: destination)
                outputVideo = destination
            } else { outputVideo = nil }
            try Task.checkCancellation()
            return Resources(imageURL: outputImage, videoURL: outputVideo, temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func reflected(_ orientation: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .upMirrored
        case .upMirrored: .up
        case .down: .downMirrored
        case .downMirrored: .down
        case .left: .rightMirrored
        case .rightMirrored: .left
        case .right: .leftMirrored
        case .leftMirrored: .right
        @unknown default: .upMirrored
        }
    }

    /// Reflects displayed coordinates, including photos whose pixels are rotated.
    /// UIImage's withHorizontallyFlippedOrientation instead flips the sensor axes.
    static func reflectedImage(_ image: UIImage) -> UIImage {
        guard let pixels = image.cgImage else { return image }
        let orientation: UIImage.Orientation = switch image.imageOrientation {
        case .up: .upMirrored
        case .upMirrored: .up
        case .down: .downMirrored
        case .downMirrored: .down
        case .left: .rightMirrored
        case .rightMirrored: .left
        case .right: .leftMirrored
        case .leftMirrored: .right
        @unknown default: .upMirrored
        }
        return UIImage(cgImage: pixels, scale: image.scale, orientation: orientation)
    }

    private static func mirrorImage(from sourceURL: URL, to outputURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, type, CGImageSourceGetCount(source), nil) else {
            throw Failure.image
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var orientation = CGImagePropertyOrientation(rawValue: properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1) ?? .up
        // PNG may carry an XMP orientation that UIKit ignores. Match the
        // file-based decoder used by the library instead of rotating its export.
        let ignoresEncodedOrientation = type == UTType.png.identifier as CFString
            && UIImage(contentsOfFile: sourceURL.path)?.imageOrientation == .up
        if ignoresEncodedOrientation {
            orientation = .up
        }
        // JPEG/HEIF can update orientation while keeping compressed image data,
        // color information, location, and Live Photo pairing metadata intact.
        let options = [kCGImageDestinationOrientation: reflected(orientation).rawValue] as CFDictionary
        if CGImageDestinationCopyImageSource(destination, source, options, nil) { return }

        // Formats without lossless metadata editing use a temporary derivative.
        // Each frame is handled separately; originals are always read-only.
        try? FileManager.default.removeItem(at: outputURL)
        guard let fallback = CGImageDestinationCreateWithURL(outputURL as CFURL, type, CGImageSourceGetCount(source), nil) else {
            throw Failure.image
        }
        for index in 0..<CGImageSourceGetCount(source) {
            try Task.checkCancellation()
            let frameProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let frameOrientation: CGImagePropertyOrientation = ignoresEncodedOrientation ? .up
                : CGImagePropertyOrientation(rawValue: frameProperties?[kCGImagePropertyOrientation] as? UInt32 ?? 1) ?? .up
            CGImageDestinationAddImageFromSource(fallback, source, index, [
                kCGImagePropertyOrientation: reflected(frameOrientation).rawValue,
                kCGImageDestinationPreserveGainMap: true
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(fallback) else { throw Failure.image }
    }

    private static func mirrorVideo(from sourceURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let composition = AVMutableComposition()
        let metadata = try await asset.load(.metadata)
        let tracks = try await asset.load(.tracks)
        for track in tracks {
            try Task.checkCancellation()
            guard let output = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: track.trackID) else {
                throw Failure.video
            }
            // Copy audio and timed metadata too, including Live Photo's still-image time.
            let timeRange = try await track.load(.timeRange)
            try output.insertTimeRange(timeRange, of: track, at: timeRange.start)
            if track.mediaType == .video {
                let transform = try await track.load(.preferredTransform)
                let size = try await track.load(.naturalSize)
                let bounds = CGRect(origin: .zero, size: size).applying(transform)
                let reflection = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: bounds.minX + bounds.maxX, ty: 0)
                output.preferredTransform = transform.concatenating(reflection)
            }
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.video
        }
        export.metadata = metadata
        try await export.export(to: outputURL, as: .mov)
    }
}
