import Foundation

/// A device-only, atomic checkpoint. Read failures stop cloud writes rather than
/// silently uploading a library whose privacy preference could not be read.
nonisolated final class PhotoStorageModeStore: @unchecked Sendable {
    static let shared: PhotoStorageModeStore = {
        guard StorageTestConfiguration.usesEphemeralLibrary else { return PhotoStorageModeStore() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StorageTestMode-\(UUID())/mode.json")
        let store = PhotoStorageModeStore(storageURL: url)
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["UI_TEST_STORAGE_MODE"] == "local" { try? store.set(.local) }
        #endif
        return store
    }()
    static let didChangeNotification = Notification.Name("PhotoStorageModeStore.didChange")

    private struct Checkpoint: Codable {
        var mode: PhotoStorageMode
        var downloadAccountID: String?
        var storeFilename: String?
        var deletionPlan: PhotoCloudDeletionPlan?
    }

    private let lock = NSLock()
    private let storageURL: URL
    private var checkpoint: Checkpoint?
    private var loadError: Error?

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoStoragePreference", isDirectory: true)
            .appendingPathComponent("mode.json")
    }

    var mode: PhotoStorageMode { lock.withLock { load(); return checkpoint?.mode ?? .local } }
    var downloadAccountID: String? { lock.withLock { load(); return checkpoint?.downloadAccountID } }
    var storeFilename: String? { lock.withLock { load(); return checkpoint?.storeFilename } }
    var deletionPlan: PhotoCloudDeletionPlan? { lock.withLock { load(); return checkpoint?.deletionPlan } }

    func checkReadable() throws {
        try lock.withLock { load(); if let loadError { throw loadError } }
    }

    func set(_ mode: PhotoStorageMode, downloadAccountID: String? = nil, storeFilename: String? = nil,
             deletionPlan: PhotoCloudDeletionPlan? = nil) throws {
        try lock.withLock {
            load()
            if let loadError { throw loadError }
            let updated = Checkpoint(mode: mode, downloadAccountID: downloadAccountID,
                                     storeFilename: storeFilename ?? checkpoint?.storeFilename, deletionPlan: deletionPlan)
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            try JSONEncoder().encode(updated).write(to: storageURL, options: .atomic)
            checkpoint = updated
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func load() {
        guard checkpoint == nil, loadError == nil else { return }
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            // Preserve the behavior of every existing installation.
            checkpoint = Checkpoint(mode: .iCloud)
            return
        }
        do { checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: storageURL)) }
        catch { loadError = error }
    }
}
