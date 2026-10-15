import Foundation

nonisolated enum PhotoLocalAssetMetadata {
    @concurrent
    static func read(from urls: [String: URL]) async -> [String: PhotoAssetMetadata] {
        urls.reduce(into: [:]) { result, entry in
            guard let size = try? entry.value.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
            result[entry.key] = PhotoAssetMetadata(byteCount: Int64(size), checksum: nil)
        }
    }
}
