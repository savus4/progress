import Foundation

/// Upload attempts belong to the device holding the originals, not to mirrored Core Data metadata.
nonisolated struct LocalPhotoUpload: Codable, Equatable, Sendable {
    let photoID: UUID
    let stillAssetName: String
    let livePhotoImageAssetName: String?
    let videoAssetName: String?
    let createdAt: Date
    var state: PhotoUploadState = .pending
    var attemptCount: Int = 0
    var errorMessage: String?
    var retryAfter: Date?

    var assetNames: Set<String> {
        Set([stillAssetName, livePhotoImageAssetName, videoAssetName].compactMap { $0 })
    }
}

nonisolated final class LocalPhotoUploadStore: @unchecked Sendable {
    static let shared = LocalPhotoUploadStore()
    static let didChangeNotification = Notification.Name("LocalPhotoUploadStore.didChange")

    private let storageURL: URL
    private let lock = NSLock()
    private var entries: [UUID: LocalPhotoUpload]?
    private var loadError: Error?

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
    }

    func entry(for photoID: UUID) -> LocalPhotoUpload? {
        lock.withLock { loadIfNeeded(); return entries?[photoID] }
    }

    func allEntries() -> [LocalPhotoUpload] {
        lock.withLock { loadIfNeeded(); return Array((entries ?? [:]).values) }
    }

    /// Call only after all required originals have been copied to staging.
    func register(_ entry: LocalPhotoUpload) throws {
        try mutate { entries in
            if let existing = entries[entry.photoID], existing.assetNames == entry.assetNames {
                return
            }
            entries[entry.photoID] = entry
        }
    }

    func update(photoID: UUID, _ change: (inout LocalPhotoUpload) -> Void) throws {
        try mutate { entries in
            guard var entry = entries[photoID] else { return }
            change(&entry)
            entries[photoID] = entry
        }
    }

    func remove(assetNames: Set<String>) throws {
        try mutate { entries in
            entries = entries.filter { $0.value.assetNames.isDisjoint(with: assetNames) }
        }
    }

    private func mutate(_ change: (inout [UUID: LocalPhotoUpload]) -> Void) throws {
        let didChange = try lock.withLock {
            loadIfNeeded()
            if let loadError { throw loadError }
            var updated = entries ?? [:]
            change(&updated)
            guard updated != entries else { return false }
            let data = try JSONEncoder().encode(Array(updated.values))
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storageURL, options: .atomic)
            entries = updated
            return true
        }
        if didChange { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
    }

    private func loadIfNeeded() {
        guard entries == nil, loadError == nil else { return }
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            entries = [:]
            return
        }
        do {
            let stored = try JSONDecoder().decode([LocalPhotoUpload].self, from: Data(contentsOf: storageURL))
            entries = Dictionary(stored.map { ($0.photoID, $0) }, uniquingKeysWith: { _, latest in latest })
        } catch {
            // Never overwrite an unreadable retry journal or discard the staged originals.
            loadError = error
        }
    }

    private static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "progress", isDirectory: true)
            .appendingPathComponent("LocalPhotoUploads", isDirectory: true)
            .appendingPathComponent("uploads.json")
    }
}
