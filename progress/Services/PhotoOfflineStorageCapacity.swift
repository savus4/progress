import Foundation

nonisolated enum PhotoOfflineStorageCapacity {
    @concurrent
    static func availableBytes() async -> Int64? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }
}
