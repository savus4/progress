import CoreData
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import progress

@MainActor
struct CameraMirroringTests {
    @Test("Pro saves the mirrored review without adding a second reflection")
    func proTakesPrecedence() {
        let off = CameraMirroring(hirsModeEnabled: false, hirsModeProEnabled: false)
        #expect(!off.savesMirrored && !off.showsMirroredPreview && !off.mirrorsPreviewOnly)
        let preview = CameraMirroring(hirsModeEnabled: true, hirsModeProEnabled: false)
        #expect(!preview.savesMirrored && preview.showsMirroredPreview && preview.mirrorsPreviewOnly)
        for hirsEnabled in [false, true] {
            let pro = CameraMirroring(hirsModeEnabled: hirsEnabled, hirsModeProEnabled: true)
            #expect(pro.savesMirrored && pro.showsMirroredPreview && !pro.mirrorsPreviewOnly)
        }
    }

    @Test("Thumbnails retain appearance and offline reference mirroring for every EXIF orientation",
          arguments: [CGImagePropertyOrientation.up, .upMirrored, .down, .downMirrored,
                      .left, .leftMirrored, .right, .rightMirrored])
    func thumbnailPreservesMirroring(orientation: CGImagePropertyOrientation) throws {
        let original = try encodedImage(orientation: orientation)
        let thumbnail = try #require(ThumbnailService.shared.generateThumbnail(from: original))
        let decoded = try #require(UIImage(data: thumbnail))
        let expected = try #require(UIImage(data: original))
        let isMirrored = [CGImagePropertyOrientation.upMirrored, .downMirrored, .leftMirrored, .rightMirrored]
            .contains(orientation)

        #expect(PhotoMirroring.sourceIsMirrored(in: thumbnail) == isMirrored)
        #expect(decoded.imageOrientation == .up)
        try expectSameAppearance(decoded, expected)

        // Recompression must retain the marker, rather than causing offline references to flip again.
        var paddedThumbnail = thumbnail
        paddedThumbnail.append(Data(repeating: 0, count: 10_000))
        let optimized = try #require(ThumbnailService.shared.optimizedThumbnailDataIfSmaller(paddedThumbnail))
        #expect(PhotoMirroring.sourceIsMirrored(in: optimized) == isMirrored)
        try expectSameAppearance(try #require(UIImage(data: optimized)), expected)
    }

    @Test("Saved mirrored originals and share files survive disabling Pro and reopening the library",
          arguments: [false, true])
    func savedCaptureSurvivesRestart(mirrored: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        try library.modeStore.set(.local)
        let original = try encodedImage(orientation: mirrored ? .upMirrored : .up)
        let image = try #require(UIImage(data: original))
        let storage = PhotoStorageService(cloudKitService: library.cloud)
        let objectID = try await storage.savePhoto(image: image, imageData: original, location: nil,
                                                  context: library.persistence.container.viewContext,
                                                  enqueuesPendingUpload: false)
        let photo = try #require(try library.persistence.container.viewContext.existingObject(with: objectID) as? DailyPhoto)
        let photoID = try #require(photo.id)
        #expect(PhotoMirroring.sourceIsMirrored(in: photo.thumbnailData) == mirrored)

        library.defaults.set(false, forKey: CameraPreferenceKey.hirsModeProEnabled)
        try await library.reopen()
        let reopened = PhotoStorageService(cloudKitService: library.cloud)
        let photos = try library.persistence.container.viewContext.fetch(DailyPhoto.fetchRequest())
        let restored = try #require(photos.first { $0.id == photoID })
        let url = try await reopened.prepareStillPhotoShareURL(for: restored)
        #expect(try Data(contentsOf: url) == original)
        #expect(PhotoMirroring.sourceIsMirrored(in: restored.thumbnailData) == mirrored)
        try expectSameAppearance(try await reopened.loadFullImage(from: restored), image)
    }

    private func encodedImage(orientation: CGImagePropertyOrientation) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600), format: format).image { context in
            for (color, rect) in [
                (UIColor.red, CGRect(x: 0, y: 0, width: 200, height: 300)),
                (.blue, CGRect(x: 200, y: 0, width: 200, height: 300)),
                (.green, CGRect(x: 0, y: 300, width: 200, height: 300)),
                (.yellow, CGRect(x: 200, y: 300, width: 200, height: 300))
            ] {
                color.setFill()
                context.fill(rect)
            }
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image.cgImage), [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 1.0
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func expectSameAppearance(_ actual: UIImage, _ expected: UIImage,
                                      sourceLocation: SourceLocation = #_sourceLocation) throws {
        let actualPixels = try samplePixels(actual)
        let expectedPixels = try samplePixels(expected)
        #expect(zip(actualPixels, expectedPixels).allSatisfy { abs(Int($0) - Int($1)) < 40 },
                "Image orientation and reflection must survive decoding and thumbnail compression.",
                sourceLocation: sourceLocation)
    }

    private func samplePixels(_ image: UIImage) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        let context = try #require(CGContext(data: &pixels, width: 4, height: 4, bitsPerComponent: 8,
                                            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try #require(upright.cgImage), in: CGRect(x: 0, y: 0, width: 4, height: 4))
        return pixels
    }
}
