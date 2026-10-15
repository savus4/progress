import Foundation

nonisolated enum PhotoOfflineSettings {
    static let keepAllKey = "keepAllPhotosOnDevice"
    static let keepHeartedKey = "keepHeartedPhotosOnDevice"
    static let cellularKey = "allowCellularOfflinePhotoDownloads"
    static let recentPhotosKey = "keepRecentPhotosOnDevice"
    static let recentLimitKey = "recentPhotoStorageLimitBytes"
    static let minimumLimitBytes: Int64 = 100_000_000
    static let defaultLimitBytes: Double = 1_000_000_000

    // Decimal GB, matching the device storage settings shown to the user.
    static let reserveBytes: Int64 = 500_000_000
    static let resumeBytes: Int64 = 550_000_000

    static func policy(in defaults: UserDefaults = .standard) -> PhotoOfflinePolicy {
        if defaults.bool(forKey: keepAllKey) { return .all }
        if defaults.bool(forKey: keepHeartedKey) { return .hearted }
        return .onDemand
    }

    static func allowsCellular(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: cellularKey)
    }

    static func keepsRecentPhotos(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: recentPhotosKey)
    }

    static func recentLimitBytes(in defaults: UserDefaults = .standard) -> Int64 {
        let value = defaults.object(forKey: recentLimitKey) == nil ? defaultLimitBytes : defaults.double(forKey: recentLimitKey)
        guard value.isFinite, value < Double(Int64.max) else { return Int64(defaultLimitBytes) }
        return max(minimumLimitBytes, Int64(max(0, value)))
    }

    static func canDownload(availableBytes: Int64, requiredBytes: Int64, wasPaused: Bool) -> Bool {
        guard requiredBytes >= 0, requiredBytes <= Int64.max / 2 else { return false }
        // Account for both the CKAsset download and an atomic persistent copy.
        let footprint = requiredBytes * 2
        return (!wasPaused || availableBytes >= resumeBytes)
            && availableBytes >= reserveBytes
            && footprint <= availableBytes - reserveBytes
    }

    static func networkPauseReason(isConnected: Bool, isExpensive: Bool, isConstrained: Bool, allowsCellular: Bool) -> String? {
        if !isConnected { return "Waiting for a network connection." }
        if isConstrained { return "Downloads paused by Low Data Mode." }
        if isExpensive && !allowsCellular { return "Waiting for Wi-Fi. You can allow cellular downloads below." }
        return nil
    }
}
