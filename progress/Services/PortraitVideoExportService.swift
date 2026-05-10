import AVFoundation
import CoreData
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PortraitVideoExportProgress: Equatable {
    enum Phase: Equatable {
        case preparing
        case loading
        case writing
        case finishing
    }

    let completedPhotoCount: Int
    let totalPhotoCount: Int
    let phase: Phase
}

nonisolated enum PortraitVideoExportError: LocalizedError {
    case noPhotos
    case noImageAsset
    case cannotCreatePixelBuffer
    case cannotCreateImageContext
    case cannotReadImage
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPhotos:
            return "No photos match this date range."
        case .noImageAsset:
            return "One of the selected photos has no still image asset."
        case .cannotCreatePixelBuffer:
            return "Unable to create a video frame buffer."
        case .cannotCreateImageContext:
            return "Unable to create a video drawing context."
        case .cannotReadImage:
            return "Unable to read one of the still images."
        case .writerFailed(let message):
            return message
        }
    }
}

nonisolated enum PortraitVideoExportQuality: String, CaseIterable, Identifiable, Sendable {
    case compact
    case balanced
    case best

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact:
            return "Compact"
        case .balanced:
            return "Balanced"
        case .best:
            return "Best"
        }
    }

    var detail: String {
        switch self {
        case .compact:
            return "Smaller file"
        case .balanced:
            return "Recommended"
        case .best:
            return "Higher quality"
        }
    }

    var averageBitRate: Int {
        switch self {
        case .compact:
            return 2_800_000
        case .balanced:
            return 6_000_000
        case .best:
            return 12_000_000
        }
    }
}

final class PortraitVideoExportService {
    static let shared = PortraitVideoExportService()

    private let cloudKitService = CloudKitService.shared
    private let outputSize = CGSize(width: 1080, height: 1620)
    private let thumbnailMaxPixelSize = 3240

    private init() {}

    nonisolated func deleteTemporaryExports() {
        let directoryURL = temporaryExportDirectoryURL()
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in fileURLs {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    @concurrent
    nonisolated func createVideo(
        from photos: [PortraitVideoExportItem],
        picturesPerSecond: Int,
        quality: PortraitVideoExportQuality,
        includesDateBanner: Bool,
        progress: @escaping @MainActor (PortraitVideoExportProgress) -> Void
    ) async throws -> URL {
        guard !photos.isEmpty else { throw PortraitVideoExportError.noPhotos }

        let sortedPhotos = photos.sorted { lhs, rhs in
            if lhs.captureDate == rhs.captureDate {
                return lhs.objectID.uriRepresentation().absoluteString < rhs.objectID.uriRepresentation().absoluteString
            }
            return lhs.captureDate < rhs.captureDate
        }

        let outputURL = try makeOutputURL()
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: quality.averageBitRate,
                    AVVideoAllowFrameReorderingKey: false
                ]
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        guard writer.canAdd(input) else {
            throw PortraitVideoExportError.writerFailed("Unable to configure video writer.")
        }
        writer.add(input)

        await progress(
            PortraitVideoExportProgress(
                completedPhotoCount: 0,
                totalPhotoCount: sortedPhotos.count,
                phase: .preparing
            )
        )

        guard writer.startWriting() else {
            throw PortraitVideoExportError.writerFailed(writer.error?.localizedDescription ?? "Unable to start video writer.")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            for (index, photo) in sortedPhotos.enumerated() {
                try Task.checkCancellation()
                guard let assetName = photo.fullImageAssetName else {
                    throw PortraitVideoExportError.noImageAsset
                }

                await progress(
                    PortraitVideoExportProgress(
                        completedPhotoCount: index,
                        totalPhotoCount: sortedPhotos.count,
                        phase: .loading
                    )
                )

                let imageURL = try await cloudKitService.loadAssetURL(named: assetName)
                defer {
                    cloudKitService.discardTemporaryReadableAsset(named: assetName)
                }

                let image = try loadScaledImage(from: imageURL)
                try await append(
                    image,
                    dateText: includesDateBanner ? Self.dateBannerText(for: photo.captureDate) : nil,
                    atFrameIndex: index,
                    picturesPerSecond: picturesPerSecond,
                    input: input,
                    adaptor: adaptor
                )

                await progress(
                    PortraitVideoExportProgress(
                        completedPhotoCount: index + 1,
                        totalPhotoCount: sortedPhotos.count,
                        phase: .writing
                    )
                )
            }

            await progress(
                PortraitVideoExportProgress(
                    completedPhotoCount: sortedPhotos.count,
                    totalPhotoCount: sortedPhotos.count,
                    phase: .finishing
                )
            )

            input.markAsFinished()
            await finishWriting(writer)

            if writer.status == .failed || writer.status == .cancelled {
                throw PortraitVideoExportError.writerFailed(writer.error?.localizedDescription ?? "Video export failed.")
            }

            return outputURL
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    nonisolated private func append(
        _ image: CGImage,
        dateText: String?,
        atFrameIndex frameIndex: Int,
        picturesPerSecond: Int,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }

        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            throw PortraitVideoExportError.cannotCreatePixelBuffer
        }

        var pixelBuffer: CVPixelBuffer?
        let pixelBufferResult = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
        guard pixelBufferResult == kCVReturnSuccess, let pixelBuffer else {
            throw PortraitVideoExportError.cannotCreatePixelBuffer
        }

        try draw(image, dateText: dateText, into: pixelBuffer)

        let presentationTime = CMTime(
            value: CMTimeValue(frameIndex),
            timescale: CMTimeScale(max(picturesPerSecond, 1))
        )
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw PortraitVideoExportError.writerFailed("Unable to append video frame.")
        }
    }

    nonisolated private func draw(_ image: CGImage, dateText: String?, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw PortraitVideoExportError.cannotCreatePixelBuffer
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw PortraitVideoExportError.cannotCreateImageContext
        }

        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(frame)
        context.interpolationQuality = .high
        context.draw(image, in: aspectFillRect(for: image, in: frame))

        if let dateText {
            drawDateBanner(dateText, in: context, frame: frame)
        }
    }

    nonisolated private func drawDateBanner(_ text: String, in context: CGContext, frame: CGRect) {
        let bannerWidth = min(frame.width - 96, 620)
        let bannerHeight: CGFloat = 82
        let bannerRect = CGRect(
            x: (frame.width - bannerWidth) / 2,
            y: frame.height - bannerHeight - 78,
            width: bannerWidth,
            height: bannerHeight
        )
        let cornerRadius: CGFloat = 32

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: CGColor(gray: 0, alpha: 0.28))
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 0.68))
        context.addPath(roundedRectPath(bannerRect, cornerRadius: cornerRadius))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        context.setLineWidth(1)
        context.addPath(roundedRectPath(bannerRect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: cornerRadius))
        context.strokePath()
        context.restoreGState()

        let font = CTFontCreateWithName("AvenirNext-DemiBold" as CFString, 36, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 0.96),
            kCTKernAttributeName: 0.4
        ]
        guard let attributedText = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            return
        }
        let line = CTLineCreateWithAttributedString(attributedText)
        let lineBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let textX = bannerRect.midX - lineBounds.width / 2 - lineBounds.minX
        let textY = bannerRect.midY - lineBounds.height / 2 - lineBounds.minY

        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: textX, y: textY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    nonisolated private func roundedRectPath(_ rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
    }

    nonisolated private func aspectFillRect(for image: CGImage, in frame: CGRect) -> CGRect {
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = max(frame.width / imageSize.width, frame.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        return CGRect(
            x: (frame.width - scaledSize.width) / 2,
            y: (frame.height - scaledSize.height) / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )
    }

    nonisolated private func loadScaledImage(from url: URL) throws -> CGImage {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            throw PortraitVideoExportError.cannotReadImage
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw PortraitVideoExportError.cannotReadImage
        }

        return image
    }

    nonisolated private func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    nonisolated private func makeOutputURL() throws -> URL {
        let directoryURL = temporaryExportDirectoryURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let dateText = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let outputURL = directoryURL
            .appendingPathComponent("work_in_progress_\(dateText)")
            .appendingPathExtension("mp4")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        return outputURL
    }

    nonisolated private func temporaryExportDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("portrait_video_exports", isDirectory: true)
    }

    nonisolated private static func dateBannerText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
