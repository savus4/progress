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
    static let limitUserDefaultsKey = "fullResolutionAssetCacheLimitBytes"
    static let bytesPerMegabyte = 1_024 * 1_024
    static let minimumLimitMegabytes = 50
    static let maximumLimitMegabytes = 10 * 1_024
    static let defaultLimitMegabytes = 512

    static var minimumLimitBytes: Int {
        minimumLimitMegabytes * bytesPerMegabyte
    }

    static var maximumLimitBytes: Int {
        maximumLimitMegabytes * bytesPerMegabyte
    }

    static var defaultLimitBytes: Int {
        defaultLimitMegabytes * bytesPerMegabyte
    }

    static var currentLimitBytes: Int {
        get {
            let storedLimit = UserDefaults.standard.integer(forKey: limitUserDefaultsKey)
            guard storedLimit > 0 else {
                return defaultLimitBytes
            }
            return normalizedLimitBytes(storedLimit)
        }
        set {
            UserDefaults.standard.set(normalizedLimitBytes(newValue), forKey: limitUserDefaultsKey)
        }
    }

    static func normalizedLimitBytes(_ bytes: Int) -> Int {
        min(max(bytes, minimumLimitBytes), maximumLimitBytes)
    }

    static func bytes(forMegabytes megabytes: Int) -> Int {
        normalizedLimitBytes(megabytes * bytesPerMegabyte)
    }

    static func megabytes(forBytes bytes: Int) -> Int {
        normalizedLimitBytes(bytes) / bytesPerMegabyte
    }

    static func formattedByteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}
