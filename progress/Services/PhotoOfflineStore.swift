import Foundation

/// Contains only originals fetched from iCloud or confirmed uploaded by this device.
/// Downloading files into this store never grants local upload ownership.
actor PhotoOfflineStore {
    nonisolated let directoryURL: URL
    private var inventory: [String: PhotoAssetMetadata]?
    private var revisions: [String: Int] = [:]
    private var recentAccesses: [String: Date]?

    nonisolated static var defaultDirectoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "progress", isDirectory: true)
            .appendingPathComponent("OfflinePhotoOriginals", isDirectory: true)
    }

    init(directoryURL: URL = PhotoOfflineStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    func assetURL(named name: String) throws -> URL? {
        try loadInventory()
        let url = try fileURL(named: name)
        guard let metadata = inventory?[name],
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == metadata.byteCount else { return nil }
        return url
    }

    func assetNames() throws -> Set<String> {
        try loadInventory()
        return Set(try (inventory ?? [:]).keys.filter { try assetURL(named: $0) != nil })
    }

    func byteCount() throws -> Int64 {
        try loadInventory()
        return try (inventory ?? [:]).reduce(0) { total, entry in
            try assetURL(named: entry.key) == nil ? total : total + entry.value.byteCount
        }
    }

    func assetMetadata() throws -> [String: PhotoAssetMetadata] {
        try loadInventory()
        return try (inventory ?? [:]).filter { try assetURL(named: $0.key) != nil }
    }

    func recordAccess(to fullImageAssetName: String, at date: Date = Date()) throws {
        _ = try fileURL(named: fullImageAssetName)
        try loadRecentAccesses()
        recentAccesses?[fullImageAssetName] = date
        try persistRecentAccesses()
    }

    func accessDates() throws -> [String: Date] {
        try loadRecentAccesses()
        return recentAccesses ?? [:]
    }

    func removeAccessRecords(except names: Set<String>) throws {
        try loadRecentAccesses()
        let filtered = (recentAccesses ?? [:]).filter { names.contains($0.key) }
        guard filtered != recentAccesses else { return }
        recentAccesses = filtered
        try persistRecentAccesses()
    }

    private func loadRecentAccesses() throws {
        guard recentAccesses == nil else { return }
        try loadInventory()
        let url = directoryURL.appendingPathComponent(".recent-photos.json")
        recentAccesses = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: url)) : [:]
    }

    private func persistRecentAccesses() throws {
        let url = directoryURL.appendingPathComponent(".recent-photos.json")
        try JSONEncoder().encode(recentAccesses ?? [:]).write(to: url, options: .atomic)
    }

    func retain(from sourceURL: URL, named name: String, expected: PhotoAssetMetadata? = nil, movingOriginal: Bool = false) async throws {
        try loadInventory()
        let destination = try fileURL(named: name)
        if try assetURL(named: name) != nil { return }
        let revision = (revisions[name] ?? 0) + 1
        revisions[name] = revision
        let temporary = directoryURL.appendingPathComponent(".\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let digest: PhotoAssetFileWorker.Digest
        if movingOriginal {
            digest = try await PhotoAssetFileWorker.digestAndByteCount(at: sourceURL)
        } else {
            _ = try await PhotoAssetFileWorker.stage(file: sourceURL, at: temporary, includesInBackup: false)
            digest = try await PhotoAssetFileWorker.digestAndByteCount(at: temporary)
        }
        try Task.checkCancellation()
        guard revisions[name] == revision else { throw CancellationError() }
        if let expected,
           (expected.byteCount != digest.byteCount || (expected.checksum != nil && expected.checksum != digest.checksum)) {
            throw CocoaError(.fileReadCorruptFile)
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: movingOriginal ? sourceURL : temporary, to: destination)
        var url = destination
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        inventory?[name] = PhotoAssetMetadata(byteCount: digest.byteCount, checksum: digest.checksum)
        // If persistence fails, the complete file remains. Startup reconciliation
        // recovers it; a pending original is never deleted before this succeeds.
        try persistInventory()
    }

    func remove(named name: String) throws {
        try loadInventory()
        revisions[name, default: 0] += 1
        let url = try fileURL(named: name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        inventory?.removeValue(forKey: name)
        try persistInventory()
    }

    func removeUnselected(keeping names: Set<String>) throws {
        try loadInventory()
        let removedNames = Set((inventory ?? [:]).keys).subtracting(names)
        for name in removedNames {
            revisions[name, default: 0] += 1
            let url = try fileURL(named: name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            inventory?.removeValue(forKey: name)
        }
        for name in revisions.keys where !names.contains(name) { revisions[name, default: 0] += 1 }
        if !removedNames.isEmpty { try persistInventory() }
    }

    private func fileURL(named name: String) throws -> URL {
        guard !name.isEmpty, !name.hasPrefix("."), (name as NSString).lastPathComponent == name else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return directoryURL.appendingPathComponent(name)
    }

    private func loadInventory() throws {
        guard inventory == nil else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var directory = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let indexURL = directoryURL.appendingPathComponent(".inventory.json")
        // Fail closed on an unreadable journal: never turn it into an empty store.
        var loaded = fileManager.fileExists(atPath: indexURL.path)
            ? try JSONDecoder().decode([String: PhotoAssetMetadata].self, from: Data(contentsOf: indexURL)) : [:]
        for url in try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            if url.lastPathComponent.hasPrefix(".") {
                if url.pathExtension == "download" { try fileManager.removeItem(at: url) }
                continue
            }
            let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if resource.isRegularFile == true, loaded[url.lastPathComponent] == nil, let size = resource.fileSize {
                // Only complete files are renamed out of hidden staging paths.
                loaded[url.lastPathComponent] = PhotoAssetMetadata(byteCount: Int64(size), checksum: nil)
            }
        }
        inventory = loaded
    }

    private func persistInventory() throws {
        try JSONEncoder().encode(inventory ?? [:]).write(to: directoryURL.appendingPathComponent(".inventory.json"), options: .atomic)
    }
}
