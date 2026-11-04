import AVFoundation
import CoreData
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import progress

@MainActor
struct CameraMirroringTests {
    @Test("Pro mirrors presentation while ordinary Hirs mirrors only the capture preview")
    func proTakesPrecedence() {
        let off = CameraMirroring(hirsModeEnabled: false, hirsModeProEnabled: false)
        #expect(!off.mirrorsPhotos && !off.showsMirroredPreview && !off.mirrorsPreviewOnly)
        let preview = CameraMirroring(hirsModeEnabled: true, hirsModeProEnabled: false)
        #expect(!preview.mirrorsPhotos && preview.showsMirroredPreview && preview.mirrorsPreviewOnly)
        for hirsEnabled in [false, true] {
            let pro = CameraMirroring(hirsModeEnabled: hirsEnabled, hirsModeProEnabled: true)
            #expect(pro.mirrorsPhotos && pro.showsMirroredPreview && !pro.mirrorsPreviewOnly)
        }
    }

    @Test("Canonical thumbnails retain the original appearance for every EXIF orientation",
          arguments: [CGImagePropertyOrientation.up, .upMirrored, .down, .downMirrored,
                      .left, .leftMirrored, .right, .rightMirrored])
    func thumbnailPreservesMirroring(orientation: CGImagePropertyOrientation) throws {
        let original = try encodedImage(orientation: orientation)
        let thumbnail = try #require(ThumbnailService.shared.generateThumbnail(from: original))
        let decoded = try #require(UIImage(data: thumbnail))
        let expected = try #require(UIImage(data: original))
        #expect(decoded.imageOrientation == .up)
        try expectSameAppearance(decoded, expected)

        // Optimization keeps canonical appearance without mode-specific variants.
        var paddedThumbnail = thumbnail
        paddedThumbnail.append(Data(repeating: 0, count: 10_000))
        let optimized = try #require(ThumbnailService.shared.optimizedThumbnailDataIfSmaller(paddedThumbnail))
        try expectSameAppearance(try #require(UIImage(data: optimized)), expected)
    }

    @Test("All existing photos export according to the current mode without changing originals")
    func exportsAreReversible() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        try library.modeStore.set(.local)
        let original = try encodedImage(orientation: .right)
        let image = try #require(UIImage(data: original))
        let storage = PhotoStorageService(cloudKitService: library.cloud)
        let objectID = try await storage.savePhoto(image: image, imageData: original, location: nil,
                                                  context: library.persistence.container.viewContext,
                                                  enqueuesPendingUpload: false)
        let photo = try #require(try library.persistence.container.viewContext.existingObject(with: objectID) as? DailyPhoto)
        let thumbnail = photo.thumbnailData
        for mirrored in [false, true, false] {
            let url = try await storage.prepareStillPhotoShareURL(for: photo, mirrored: mirrored)
            try expectSameAppearance(try #require(UIImage(contentsOfFile: url.path)),
                                     mirrored ? reflectedPixels(image) : image)
            let directories = try await storage.prepareExportFiles(for: [photo], mirrored: mirrored)
            defer { for directory in directories { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) } }
            let directory = try #require(directories.first)
            let asset = try #require(photo.fullImageAssetName)
            try expectSameAppearance(try #require(UIImage(contentsOfFile: directory.appendingPathComponent(asset).path)),
                                     mirrored ? reflectedPixels(image) : image)
            #expect(photo.thumbnailData == thumbnail)
            #expect(!photo.hasChanges)
        }
        let url = try await storage.prepareStillPhotoShareURL(for: photo, mirrored: false)
        #expect(try Data(contentsOf: url) == original)
        try expectSameAppearance(try await storage.loadFullImage(from: photo), image)
    }

    @Test("Export reflects displayed coordinates for all eight orientations without touching source bytes",
          arguments: [CGImagePropertyOrientation.up, .upMirrored, .down, .downMirrored,
                      .left, .leftMirrored, .right, .rightMirrored], [UTType.jpeg, .heic, .png])
    func mirroredExport(orientation: CGImagePropertyOrientation, type: UTType) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo.\(type.preferredFilenameExtension!)")
        let original = try encodedImage(orientation: orientation, type: type)
        try original.write(to: url)
        let export = try await PhotoExportMirroring.prepare(imageURL: url, mirrored: true)
        defer { export.removeTemporaryFiles() }
        #expect(export.imageURL != url)
        #expect(try Data(contentsOf: url) == original)
        // Match the file-based decoder used by the full-image cache. UIKit's
        // data-based PNG decoder does not apply its EXIF orientation.
        let originalImage = try #require(UIImage(contentsOfFile: url.path))
        let expected = reflectedPixels(originalImage)
        try expectSameAppearance(PhotoExportMirroring.reflectedImage(originalImage), expected)
        let exportedImage = try #require(UIImage(contentsOfFile: export.imageURL.path))
        try expectSameAppearance(exportedImage, expected)
        let source = try #require(CGImageSourceCreateWithURL(export.imageURL as CFURL, nil))
        let metadata = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        if type != .png {
            let gps = try #require(metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any])
            #expect(gps[kCGImagePropertyGPSLatitude as String] as? Double == 48.2)
        }
    }

    private func encodedImage(orientation: CGImagePropertyOrientation, type: UTType = .jpeg) throws -> Data {
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
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image.cgImage), [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.2, kCGImagePropertyGPSLatitudeRef: "N"]
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func reflectedPixels(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { renderer in
            renderer.cgContext.translateBy(x: image.size.width, y: 0)
            renderer.cgContext.scaleBy(x: -1, y: 1)
            image.draw(at: .zero)
        }
    }

    private func expectSameAppearance(_ actual: UIImage, _ expected: UIImage,
                                      sourceLocation: SourceLocation = #_sourceLocation) throws {
        let actualPixels = try samplePixels(actual)
        let expectedPixels = try samplePixels(expected)
        #expect(zip(actualPixels, expectedPixels).allSatisfy { abs(Int($0) - Int($1)) < 40 },
                "Displayed orientation and reflection must match.",
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
