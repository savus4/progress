import AVFoundation
import CoreData
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import MapKit
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

nonisolated struct PortraitVideoExportFailedPhoto: Identifiable, Equatable, Sendable {
    let id: String
    let captureDate: Date
    let assetName: String?
    let reason: String

    init(photo: PortraitVideoExportItem, reason: String) {
        id = photo.objectID.uriRepresentation().absoluteString
        captureDate = photo.captureDate
        assetName = photo.fullImageAssetName
        self.reason = reason
    }
}

nonisolated struct PortraitVideoExportResult: Sendable {
    let videoURL: URL
    let failedPhotos: [PortraitVideoExportFailedPhoto]
}

nonisolated private struct PortraitVideoBannerText: Sendable {
    let primary: String
    let secondary: String?

    var hasSecondary: Bool {
        secondary != nil
    }
}

nonisolated enum PortraitVideoExportError: LocalizedError {
    case noPhotos
    case noImageAsset
    case cannotCreatePixelBuffer
    case cannotCreateImageContext
    case cannotReadImage
    case noFramesWritten([PortraitVideoExportFailedPhoto])
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
        case .noFramesWritten:
            return "No photos could be written to the video."
        case .writerFailed(let message):
            return message
        }
    }
}

nonisolated enum PortraitVideoExportQuality: String, CaseIterable, Identifiable, Sendable {
    case compact
    case best

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact:
            return "Compact"
        case .best:
            return "Best"
        }
    }

    var detail: String {
        switch self {
        case .compact:
            return "Smaller file"
        case .best:
            return "Higher quality"
        }
    }

    var averageBitRate: Int {
        switch self {
        case .compact:
            return 2_800_000
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
    private let maximumPhotoAttempts = 3

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
        includesLocationBanner: Bool,
        progress: @escaping @MainActor (PortraitVideoExportProgress) -> Void
    ) async throws -> PortraitVideoExportResult {
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
            var failedPhotos: [PortraitVideoExportFailedPhoto] = []
            var writtenFrameCount = 0

            for (index, photo) in sortedPhotos.enumerated() {
                try Task.checkCancellation()

                await progress(
                    PortraitVideoExportProgress(
                        completedPhotoCount: index,
                        totalPhotoCount: sortedPhotos.count,
                        phase: .loading
                    )
                )

                do {
                    guard let assetName = photo.fullImageAssetName else {
                        throw PortraitVideoExportError.noImageAsset
                    }

                    let image = try await loadImageWithRetries(named: assetName)
                    try await retryPhotoOperation {
                        try await append(
                            image,
                            bannerText: await Self.makeBannerText(
                                for: photo,
                                includesDate: includesDateBanner,
                                includesLocation: includesLocationBanner
                            ),
                            atFrameIndex: writtenFrameCount,
                            picturesPerSecond: picturesPerSecond,
                            input: input,
                            adaptor: adaptor
                        )
                    }
                    writtenFrameCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failedPhotos.append(
                        PortraitVideoExportFailedPhoto(
                            photo: photo,
                            reason: failureReason(for: error)
                        )
                    )

                    if writer.status == .failed || writer.status == .cancelled {
                        throw PortraitVideoExportError.writerFailed(writer.error?.localizedDescription ?? "Video export failed.")
                    }
                }

                await progress(
                    PortraitVideoExportProgress(
                        completedPhotoCount: index + 1,
                        totalPhotoCount: sortedPhotos.count,
                        phase: .writing
                    )
                )
            }

            guard writtenFrameCount > 0 else {
                throw PortraitVideoExportError.noFramesWritten(failedPhotos)
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

            return PortraitVideoExportResult(videoURL: outputURL, failedPhotos: failedPhotos)
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    nonisolated private func loadImageWithRetries(named assetName: String) async throws -> CGImage {
        try await retryPhotoOperation {
            let imageURL = try await cloudKitService.loadAssetURL(named: assetName)
            defer {
                cloudKitService.discardTemporaryReadableAsset(named: assetName)
            }

            return try loadScaledImage(from: imageURL)
        }
    }

    nonisolated private func retryPhotoOperation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?

        for attempt in 1...maximumPhotoAttempts {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error

                if attempt < maximumPhotoAttempts {
                    try await Task.sleep(for: .milliseconds(250 * attempt))
                }
            }
        }

        throw lastError ?? PortraitVideoExportError.cannotReadImage
    }

    nonisolated private func append(
        _ image: CGImage,
        bannerText: PortraitVideoBannerText?,
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

        try draw(image, bannerText: bannerText, into: pixelBuffer)

        let presentationTime = CMTime(
            value: CMTimeValue(frameIndex),
            timescale: CMTimeScale(max(picturesPerSecond, 1))
        )
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw PortraitVideoExportError.writerFailed("Unable to append video frame.")
        }
    }

    nonisolated private func draw(_ image: CGImage, bannerText: PortraitVideoBannerText?, into pixelBuffer: CVPixelBuffer) throws {
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

        if let bannerText {
            drawBanner(bannerText, in: context, frame: frame)
        }
    }

    nonisolated private func drawBanner(_ text: PortraitVideoBannerText, in context: CGContext, frame: CGRect) {
        let widestTextCount = max(text.primary.count, text.secondary?.count ?? 0)
        let bannerWidth = min(frame.width - 96, text.hasSecondary || widestTextCount > 16 ? 880 : 620)
        let bannerHeight: CGFloat = text.hasSecondary ? 126 : 82
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

        if let secondary = text.secondary {
            drawBannerLine(
                text.primary,
                fontSize: 36,
                alpha: 0.98,
                centerY: bannerRect.midY + 22,
                in: context,
                bannerRect: bannerRect
            )
            drawBannerLine(
                secondary,
                fontSize: secondary.count > 28 ? 28 : 30,
                alpha: 0.86,
                centerY: bannerRect.midY - 24,
                in: context,
                bannerRect: bannerRect
            )
        } else {
            drawBannerLine(
                text.primary,
                fontSize: text.primary.count > 28 ? 32 : 36,
                alpha: 0.96,
                centerY: bannerRect.midY,
                in: context,
                bannerRect: bannerRect
            )
        }
    }

    nonisolated private func drawBannerLine(
        _ text: String,
        fontSize: CGFloat,
        alpha: CGFloat,
        centerY: CGFloat,
        in context: CGContext,
        bannerRect: CGRect
    ) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: alpha),
            kCTKernAttributeName: 0.4
        ]

        guard let attributedText = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            return
        }

        let fullLine = CTLineCreateWithAttributedString(attributedText)
        let line = CTLineCreateTruncatedLine(
            fullLine,
            Double(max(bannerRect.width - 56, 1)),
            .end,
            nil
        ) ?? fullLine
        let lineBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let textX = bannerRect.midX - lineBounds.width / 2 - lineBounds.minX
        let textY = centerY - lineBounds.height / 2 - lineBounds.minY

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
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    nonisolated private static func makeBannerText(
        for photo: PortraitVideoExportItem,
        includesDate: Bool,
        includesLocation: Bool
    ) async -> PortraitVideoBannerText? {
        let dateText = includesDate ? dateBannerText(for: photo.captureDate) : nil
        let locationText = includesLocation ? await locationBannerText(for: photo) : nil

        if let dateText {
            return PortraitVideoBannerText(primary: dateText, secondary: locationText)
        }

        if let locationText {
            return PortraitVideoBannerText(primary: locationText, secondary: nil)
        }

        return nil
    }

    nonisolated private static func locationBannerText(for photo: PortraitVideoExportItem) async -> String? {
        if let locationName = photo.locationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !locationName.isEmpty {
            return locationName
        }

        guard photo.latitude != 0 || photo.longitude != 0 else {
            return nil
        }

        if let cachedLocationName = await LocationNameCacheService.shared.cachedName(
            for: photo.latitude,
            longitude: photo.longitude
        ) {
            return cachedLocationName
        }

        let fallbackText = coordinateBannerText(latitude: photo.latitude, longitude: photo.longitude)
        let location = CLLocation(latitude: photo.latitude, longitude: photo.longitude)

        do {
            let resolvedName = try await resolveLocationName(for: location)
            await LocationNameCacheService.shared.setCachedName(
                resolvedName,
                for: photo.latitude,
                longitude: photo.longitude
            )
            return resolvedName
        } catch {
            return fallbackText
        }
    }

    nonisolated private static func coordinateBannerText(latitude: Double, longitude: Double) -> String {
        return String(format: "%.4f, %.4f", latitude, longitude)
    }

    nonisolated private static func resolveLocationName(for location: CLLocation) async throws -> String {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return "Pinned location"
        }

        return try await withCheckedThrowingContinuation { continuation in
            request.getMapItems { mapItems, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let resolvedName = mapItems?
                    .compactMap { mapItem in
                        [
                            mapItem.addressRepresentations?.cityWithContext(.short),
                            mapItem.addressRepresentations?.cityName,
                            mapItem.address?.shortAddress,
                            mapItem.name,
                            mapItem.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
                        ].compactMap { $0 }
                            .first(where: { !$0.isEmpty })
                    }
                    .first ?? "Pinned location"

                continuation.resume(returning: resolvedName)
            }
        }
    }

    nonisolated private func failureReason(for error: Error) -> String {
        if case PortraitVideoExportError.noImageAsset = error {
            return "No still image asset."
        }

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "Failed after \(maximumPhotoAttempts) attempts: \(message)"
    }
}
