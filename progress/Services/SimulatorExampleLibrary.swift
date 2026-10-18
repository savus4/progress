#if DEBUG && targetEnvironment(simulator)
@preconcurrency import CoreData
import CryptoKit
import Foundation
import ImageIO

/// Local development fixtures. This entire type is absent from device and Release builds.
nonisolated enum SimulatorExampleLibrary {
    private static let assetPrefix = "simulator-example-"
    static let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("SimulatorExamplePhotos", isDirectory: true)

    static let isEnabled: Bool = {
        let process = ProcessInfo.processInfo
        let environment = process.environment
        guard environment["SIMULATOR_EXAMPLE_PHOTOS"] != "0",
              environment["UI_TEST_IN_MEMORY_STORE"] != "1",
              !process.arguments.contains("UI_TEST_IN_MEMORY_STORE"),
              environment["XCTestConfigurationFilePath"] == nil,
              environment["XCTestBundlePath"] == nil,
              let resourceURL else { return false }
        return FileManager.default.fileExists(atPath: resourceURL.path)
    }()

    private static let assetURLs: [String: URL] = {
        guard isEnabled, let resourceURL,
              let files = FileManager.default.enumerator(at: resourceURL, includingPropertiesForKeys: nil) else { return [:] }
        var result: [String: URL] = [:]
        for case let url as URL in files where ["heic", "jpg", "jpeg", "mov"].contains(url.pathExtension.lowercased()) {
            result[assetName(for: url)] = url
        }
        return result
    }()

    static func assetURL(named name: String?) -> URL? {
        guard let name else { return nil }
        return assetURLs[name]
    }

    static func assetName(for url: URL) -> String {
        assetPrefix + url.lastPathComponent
    }

    /// A stable namespace keeps fixture IDs separate from the exported photos' real IDs.
    static func photoID(for url: URL) -> UUID {
        let digest = SHA256.hash(data: Data((assetPrefix + url.lastPathComponent).utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    @concurrent
    static func seed(in context: NSManagedObjectContext, from root: URL) async throws {
        let existingIDs = try await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.includesPropertyValues = true
            return Set(try context.fetch(request).compactMap(\.id))
        }
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let stills = files.compactMap { $0 as? URL }.filter {
            ["heic", "jpg", "jpeg"].contains($0.pathExtension.lowercased())
        }.sorted { $0.path < $1.path }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.dateFormat = "d.M.yyyy_H:mm:ss"
        // Exported folder dates use the developer's local time zone.

        for still in stills {
            try Task.checkCancellation()
            let id = photoID(for: still)
            guard !existingIDs.contains(id) else { continue }
            let data = try Data(contentsOf: still)
            guard let thumbnail = ThumbnailService.shared.generateThumbnail(from: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let parts = still.deletingLastPathComponent().lastPathComponent.components(separatedBy: "_")
            guard parts.count >= 4, let date = dateFormatter.date(from: parts[1] + "_" + parts[2]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let sourceID = String(still.lastPathComponent.prefix(36))
            let video = still.deletingLastPathComponent().appendingPathComponent(sourceID + "_livePhotoVideo.mov")
            let videoName = FileManager.default.fileExists(atPath: video.path) ? assetName(for: video) : nil
            let imageName = assetName(for: still)
            let source = CGImageSourceCreateWithData(data as CFData, nil)
            let metadata = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            let gps = metadata?[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            let latitude = (gps?[kCGImagePropertyGPSLatitude] as? Double ?? 0) * ((gps?[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -1 : 1)
            let longitude = (gps?[kCGImagePropertyGPSLongitude] as? Double ?? 0) * ((gps?[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -1 : 1)

            await context.perform {
                let photo = DailyPhoto(context: context)
                photo.id = id
                photo.captureDate = date
                photo.createdAt = date
                photo.modifiedAt = date
                photo.thumbnailData = thumbnail
                photo.fullImageAssetName = imageName
                photo.livePhotoImageAssetName = videoName == nil ? nil : imageName
                photo.livePhotoVideoAssetName = videoName
                photo.latitude = latitude
                photo.longitude = longitude
            }
        }
        try await context.perform {
            if context.hasChanges { try context.save() }
        }
    }
}
#endif
