import CoreData
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import progress

@MainActor
struct PhotoImportLibraryMetadataTests {
    @Test("Imports without EXIF retain the Photos library date and location", arguments: ImportFlow.allCases)
    func missingEXIFUsesLibraryMetadata(flow: ImportFlow) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let metadata = libraryMetadata()
        let imageData = try makeJPEG()

        let photo = try await fixture.importPhoto(imageData: imageData, metadata: metadata, flow: flow)

        #expect(photo.captureDate == metadata.creationDate)
        #expect(photo.latitude == metadata.location?.latitude)
        #expect(photo.longitude == metadata.location?.longitude)
        #expect(photo.createdAt != photo.captureDate, "The import time must remain separate from the original capture date.")
    }

    @Test("EXIF fields take precedence while missing fields fall back individually", arguments: EXIFFields.allCases)
    func partialEXIFUsesIndependentFallbacks(fields: EXIFFields) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let metadata = libraryMetadata()
        let imageData = try makeJPEG(exifDate: fields != .locationOnly, exifLocation: fields != .dateOnly)

        let photo = try await fixture.importPhoto(imageData: imageData, metadata: metadata, flow: .batch)

        #expect(photo.captureDate == (fields == .locationOnly ? metadata.creationDate : exifDate))
        #expect(photo.latitude == (fields == .dateOnly ? metadata.location?.latitude : -33.86))
        #expect(photo.longitude == (fields == .dateOnly ? metadata.location?.longitude : 151.21))
    }

    @Test("Changing library metadata does not turn the same image into a second import")
    func duplicatesKeepFirstImportMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let imageData = try makeJPEG()
        let firstMetadata = libraryMetadata()
        let secondMetadata = ImportedPhotoLibraryMetadata(creationDate: Date(timeIntervalSince1970: 1_700_000_000), location: (1, 2))

        let result = await fixture.storage.saveImportedPhotos([
            ImportedPhotoPayload(imageData: imageData, libraryMetadata: firstMetadata),
            ImportedPhotoPayload(imageData: imageData, libraryMetadata: secondMetadata)
        ], batchSize: 1, context: fixture.context, enqueuesPendingUploads: false)

        #expect(result.importedCount == 1)
        #expect(result.duplicateCount == 1)
        #expect(result.failedCount == 0)
        let photo = try #require(fixture.context.fetch(DailyPhoto.fetchRequest()).first)
        #expect(photo.captureDate == firstMetadata.creationDate)
        #expect(photo.latitude == firstMetadata.location?.latitude)
        #expect(photo.longitude == firstMetadata.location?.longitude)
    }

    @Test("An import without library or EXIF metadata still uses its import time")
    func absentMetadataKeepsExistingFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let photo = try await fixture.importPhoto(imageData: makeJPEG(), metadata: nil, flow: .still)

        #expect(photo.captureDate == photo.createdAt)
        #expect(photo.latitude == 0)
        #expect(photo.longitude == 0)
    }

    nonisolated enum ImportFlow: CaseIterable, Sendable { case batch, batchLive, still, live }
    nonisolated enum EXIFFields: CaseIterable, Sendable { case dateOnly, locationOnly, both }

    private var exifDate: Date { Date(timeIntervalSince1970: 1_451_606_400) }

    private func libraryMetadata() -> ImportedPhotoLibraryMetadata {
        ImportedPhotoLibraryMetadata(creationDate: Date(timeIntervalSince1970: 1_167_609_600), location: (48.2082, 16.3738))
    }

    private func makeJPEG(exifDate: Bool = false, exifLocation: Bool = false) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { renderer in
            UIColor.orange.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let cgImage = try #require(image.cgImage)
        let result = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if exifDate {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: "2016:01:01 00:00:00",
                "OffsetTimeOriginal" as CFString: "+00:00"
            ]
        }
        if exifLocation {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 33.86, kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 151.21, kCGImagePropertyGPSLongitudeRef: "E"
            ]
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return result as Data
    }

    private struct Fixture {
        let root: URL
        let persistence: PersistenceController
        let storage: PhotoStorageService
        var context: NSManagedObjectContext { persistence.container.viewContext }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryMetadataTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            persistence = PersistenceController(inMemory: true)
            storage = PhotoStorageService(cloudKitService: CloudKitService(
                stagingDirectoryURL: root.appendingPathComponent("Staging", isDirectory: true),
                temporaryReadableAssetsDirectoryURL: root.appendingPathComponent("Readable", isDirectory: true),
                legacyAssetDirectoryURLs: [], assetURLLoader: { _ in throw CloudKitError.assetNotFound }
            ))
        }

        func importPhoto(imageData: Data, metadata: ImportedPhotoLibraryMetadata?, flow: ImportFlow) async throws -> DailyPhoto {
            let objectID: NSManagedObjectID
            switch flow {
            case .batch, .batchLive:
                let videoURL: URL?
                if flow == .batchLive {
                    let pairedURL = root.appendingPathComponent("paired-batch.mov")
                    try Data("paired video bytes".utf8).write(to: pairedURL)
                    videoURL = pairedURL
                } else {
                    videoURL = nil
                }
                let result = await storage.saveImportedPhotos([
                    ImportedPhotoPayload(imageData: imageData, livePhotoVideoURL: videoURL, libraryMetadata: metadata)
                ], context: context, enqueuesPendingUploads: false)
                try #require(result.importedCount == 1 && result.failedCount == 0)
                return try #require(context.fetch(DailyPhoto.fetchRequest()).first)
            case .still:
                objectID = try await storage.saveImportedPhoto(imageData: imageData, libraryMetadata: metadata, context: context, enqueuesPendingUpload: false)
            case .live:
                let videoURL = root.appendingPathComponent("paired.mov")
                try Data("paired video bytes".utf8).write(to: videoURL)
                objectID = try await storage.saveImportedLivePhoto(imageData: imageData, videoURL: videoURL, libraryMetadata: metadata, context: context, enqueuesPendingUpload: false)
            }
            return try #require(context.existingObject(with: objectID) as? DailyPhoto)
        }

        func removeFiles() { try? FileManager.default.removeItem(at: root) }
    }
}
