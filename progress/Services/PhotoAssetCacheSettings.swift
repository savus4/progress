import Foundation

struct LocalPhotoAssetStorageUsage: Sendable, Equatable {
    static let empty = LocalPhotoAssetStorageUsage(
        cachedFullResolutionBytes: 0,
        pendingUploadBytes: 0
    )

    let cachedFullResolutionBytes: Int
    let pendingUploadBytes: Int

    var totalBytes: Int {
        cachedFullResolutionBytes + pendingUploadBytes
    }
}

enum PhotoAssetCacheSettings {
    static func formattedByteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}
