import Foundation
import CloudKit
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import CryptoKit
import os

enum PhotoAssetRole: String, Sendable {
    case still
    case livePhotoImage
    case livePhotoVideo
}

enum CloudKitConfiguration {
    static let containerIdentifier = "iCloud.me.riepl.progress"
}

final class CloudKitService {
    static let shared = CloudKitService()
    static let assetTransferDidChangeNotification = Notification.Name("CloudKitService.assetTransferDidChange")
    static let photoAccessDidChangeNotification = Notification.Name("CloudKitService.photoAccessDidChange")

    enum AssetTransferKind: String {
        case download
    }

    enum AssetTransferPhase: String {
        case started
        case finished
        case failed
    }

    private enum RecordKey {
        static let fileAsset = "fileAsset"
        static let photoID = "photoID"
        static let role = "role"
        static let checksum = "checksum"
        static let byteCount = "byteCount"
    }

    private enum RecordType {
        static let photoAsset = "PhotoAsset"
    }

    private let container: CKContainer
    private let privateDatabase: CKDatabase
    private let systemCloudKitCacheDirectoryURL: URL
    nonisolated private let stagingDirectoryURL: URL
    nonisolated private let temporaryReadableAssetsDirectoryURL: URL
    private let legacyAssetDirectoryURLs: [URL]
    private let assetURLLoader: (@MainActor @Sendable (String) async throws -> URL)?
    private let assetUploader: (@MainActor @Sendable (String, UUID, PhotoAssetRole) async throws -> Void)?
    private let remoteAssetExistenceChecker: (@MainActor @Sendable (String) async throws -> Bool)?
    private let assetMetadataLoader: (@MainActor @Sendable (String) async throws -> PhotoAssetMetadata)?
    private let network: PhotoNetworkMonitor?
    nonisolated let offlineStore: PhotoOfflineStore
    let offlineSettingsDefaults: UserDefaults
    private var offlineDeletionTasks: [String: Task<Void, Never>] = [:]
    private var deletedAssetNames: Set<String> = []
    private var activeAssetUploads: [String: Int] = [:]
    private var assetUploadWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    let uploadStateStore: LocalPhotoUploadStore
    let pendingUploadManifestService: PendingUploadManifestService
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "CloudKitAsset")

    init(
        stagingDirectoryURL: URL? = nil,
        temporaryReadableAssetsDirectoryURL: URL? = nil,
        legacyAssetDirectoryURLs: [URL]? = nil,
        uploadStateStore: LocalPhotoUploadStore? = nil,
        assetURLLoader: (@MainActor @Sendable (String) async throws -> URL)? = nil,
        assetUploader: (@MainActor @Sendable (String, UUID, PhotoAssetRole) async throws -> Void)? = nil,
        remoteAssetExistenceChecker: (@MainActor @Sendable (String) async throws -> Bool)? = nil,
        offlineStore: PhotoOfflineStore? = nil,
        offlineSettingsDefaults: UserDefaults = .standard,
        assetMetadataLoader: (@MainActor @Sendable (String) async throws -> PhotoAssetMetadata)? = nil,
        networkMonitor: PhotoNetworkMonitor? = nil
    ) {
        container = CKContainer(identifier: CloudKitConfiguration.containerIdentifier)
        privateDatabase = container.privateCloudDatabase
        systemCloudKitCacheDirectoryURL = Self.makeSystemCloudKitCacheDirectoryURL()
        self.stagingDirectoryURL = stagingDirectoryURL ?? Self.makeStagingDirectoryURL()
        self.temporaryReadableAssetsDirectoryURL = temporaryReadableAssetsDirectoryURL ?? Self.makeTemporaryReadableAssetsDirectoryURL()
        self.legacyAssetDirectoryURLs = legacyAssetDirectoryURLs ?? Self.makeLegacyAssetDirectoryURLs()
        self.uploadStateStore = uploadStateStore ?? (stagingDirectoryURL.map {
            LocalPhotoUploadStore(storageURL: $0.deletingLastPathComponent().appendingPathComponent("local-uploads.json"))
        } ?? .shared)
        pendingUploadManifestService = stagingDirectoryURL.map {
            PendingUploadManifestService(storageURL: $0.deletingLastPathComponent().appendingPathComponent("pending-uploads.json"))
        } ?? .shared
        self.assetURLLoader = assetURLLoader
        self.assetUploader = assetUploader
        self.remoteAssetExistenceChecker = remoteAssetExistenceChecker
        self.assetMetadataLoader = assetMetadataLoader
        network = networkMonitor ?? (assetURLLoader == nil ? .shared : nil)
        self.offlineSettingsDefaults = offlineSettingsDefaults
        self.offlineStore = offlineStore ?? PhotoOfflineStore(directoryURL: stagingDirectoryURL.map {
            $0.deletingLastPathComponent().appendingPathComponent("OfflinePhotoOriginals", isDirectory: true)
        } ?? PhotoOfflineStore.defaultDirectoryURL)
    }

    func saveImageAsset(_ image: UIImage) async throws -> String {
        let imageData = autoreleasepool {
            heifData(from: image, compressionQuality: 0.9)
        }
        guard let imageData else {
            throw CloudKitError.invalidImageData
        }
        return try await saveImageDataAsset(imageData, fileExtension: "heic")
    }

    func saveImageDataAsset(_ data: Data, fileExtension: String = "heic") async throws -> String {
        try await saveImageDataAsset(
            data,
            fileExtension: fileExtension,
            photoID: UUID(),
            role: .still
        )
    }

    func saveImageDataAsset(
        _ data: Data,
        fileExtension: String = "heic",
        photoID: UUID,
        role: PhotoAssetRole
    ) async throws -> String {
        let assetName = assetRecordName(photoID: photoID, role: role, fileExtension: fileExtension)
        try await saveAssetData(
            data,
            assetName: assetName,
            photoID: photoID,
            role: role,
            checksum: SHA256Hasher.hexDigest(for: data)
        )
        return assetName
    }

    func saveVideoAsset(from videoURL: URL) async throws -> String {
        try await saveVideoAsset(from: videoURL, photoID: UUID(), role: .livePhotoVideo)
    }

    func saveVideoAsset(
        from videoURL: URL,
        photoID: UUID,
        role: PhotoAssetRole
    ) async throws -> String {
        let sourceExtension = videoURL.pathExtension
        let fileExtension = sourceExtension.isEmpty ? "mov" : sourceExtension
        let assetName = assetRecordName(photoID: photoID, role: role, fileExtension: fileExtension)
        let digest = try await PhotoAssetFileWorker.digestAndByteCount(at: videoURL)
        try await saveAssetFile(
            sourceURL: videoURL,
            byteCount: digest.byteCount,
            assetName: assetName,
            photoID: photoID,
            role: role,
            checksum: digest.checksum
        )
        return assetName
    }

    func makeAssetName(photoID: UUID, role: PhotoAssetRole, fileExtension: String) -> String {
        assetRecordName(photoID: photoID, role: role, fileExtension: fileExtension)
    }

    func loadImageAsset(named assetName: String) async throws -> UIImage {
        let fileURL = try await loadAssetURL(named: assetName)
        guard let image = UIImage(contentsOfFile: fileURL.path) else {
            throw CloudKitError.assetNotFound
        }
        return image
    }

    func loadVideoAsset(named assetName: String) async throws -> URL {
        try await loadAssetURL(named: assetName)
    }

    func loadAssetURL(
        named assetName: String,
        reportsTransferEvents: Bool = true,
        forceRefetch: Bool = false,
        allowsCellularAccess: Bool = true
    ) async throws -> URL {
        try Task.checkCancellation()
        guard !deletedAssetNames.contains(assetName) else { throw CloudKitError.assetNotFound }
        if let stagedURL = stagedAssetURL(named: assetName) {
            return stableReadableURL(for: stagedURL, assetName: assetName)
        }

        if !forceRefetch, let offlineURL = try await offlineStore.assetURL(named: assetName) {
            return stableReadableURL(for: offlineURL, assetName: assetName)
        }

        if let legacyURL = legacyAssetURL(named: assetName) {
            do {
                let staged = try await stageAssetFileAsync(from: legacyURL, named: assetName, includesInBackup: true)
                return stableReadableURL(for: staged, assetName: assetName)
            } catch {
                logger.error("legacy-asset-staging: \(error.localizedDescription, privacy: .public)")
                return stableReadableURL(for: legacyURL, assetName: assetName)
            }
        }

        if !forceRefetch, let readableURL = readableAssetURL(named: assetName) {
            return readableURL
        }

        if self === Self.shared {
            try await PhotoStorageService.shared.recoverLegacyAssetIfNeeded(named: assetName)
            if let stagedURL = stagedAssetURL(named: assetName) {
                return stableReadableURL(for: stagedURL, assetName: assetName)
            }
        }

        if let assetURLLoader {
            let sourceURL: URL = try await PhotoAssetDownload.run(network: network) { request in
                let work = Task {
                    do { request.finish(.success(try await assetURLLoader(assetName))) }
                    catch { request.finish(.failure(error)) }
                }
                return { work.cancel() }
            }
            try Task.checkCancellation()
            return stableReadableURL(for: sourceURL, assetName: assetName)
        }

        if reportsTransferEvents {
            postAssetTransferChange(kind: .download, phase: .started, assetName: assetName)
        }
        defer {
            if reportsTransferEvents {
                postAssetTransferChange(kind: .download, phase: .finished, assetName: assetName)
            }
        }

        let recordID = CKRecord.ID(recordName: assetName)
        let results: [CKRecord.ID: Result<CKRecord, Error>]
        do {
            let record = try await fetchAssetRecord(named: assetName, desiredKeys: nil, allowsCellularAccess: allowsCellularAccess)
            results = [recordID: .success(record)]
        } catch {
            if reportsTransferEvents {
                postAssetTransferChange(kind: .download, phase: .failed, assetName: assetName)
            }
            await MainActor.run {
                ICloudAvailabilityMonitor.shared.recordCloudKitError(error)
            }
            throw cloudKitError(for: error)
        }
        guard let result = results[recordID] else {
            postAssetTransferChange(kind: .download, phase: .failed, assetName: assetName)
            throw CloudKitError.assetNotFound
        }

        let record: CKRecord
        switch result {
        case .success(let fetchedRecord):
            record = fetchedRecord
        case .failure(let error):
            if reportsTransferEvents {
                postAssetTransferChange(kind: .download, phase: .failed, assetName: assetName)
            }
            await MainActor.run {
                ICloudAvailabilityMonitor.shared.recordCloudKitError(error)
            }
            throw cloudKitError(for: error)
        }

        guard let asset = record[RecordKey.fileAsset] as? CKAsset,
              let stagedURL = asset.fileURL else {
            if reportsTransferEvents {
                postAssetTransferChange(kind: .download, phase: .failed, assetName: assetName)
            }
            throw CloudKitError.assetNotFound
        }

        return stableReadableURL(for: stagedURL, assetName: assetName)
    }

    func offlineAssetMetadata(named assetName: String, allowsCellularAccess: Bool) async throws -> PhotoAssetMetadata {
        if let assetMetadataLoader {
            return try await PhotoAssetDownload.run(network: network) { request in
                let work = Task {
                    do { request.finish(.success(try await assetMetadataLoader(assetName))) }
                    catch { request.finish(.failure(error)) }
                }
                return { work.cancel() }
            }
        }
        let record = try await fetchAssetRecord(
            named: assetName, desiredKeys: [RecordKey.byteCount, RecordKey.checksum],
            allowsCellularAccess: allowsCellularAccess
        )
        guard let count = record[RecordKey.byteCount] as? NSNumber, count.int64Value >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return PhotoAssetMetadata(byteCount: count.int64Value, checksum: record[RecordKey.checksum] as? String)
    }

    func offlineAssetMetadata(named assetNames: [String], allowsCellularAccess: Bool) async throws -> [String: Result<PhotoAssetMetadata, any Error>] {
        if assetMetadataLoader != nil {
            var results: [String: Result<PhotoAssetMetadata, any Error>] = [:]
            for name in assetNames {
                try Task.checkCancellation()
                do { results[name] = .success(try await offlineAssetMetadata(named: name, allowsCellularAccess: allowsCellularAccess)) }
                catch { results[name] = .failure(error) }
            }
            return results
        }
        let operation = CKFetchRecordsOperation(recordIDs: assetNames.map { CKRecord.ID(recordName: $0) })
        operation.desiredKeys = [RecordKey.byteCount, RecordKey.checksum]
        operation.configuration.allowsCellularAccess = allowsCellularAccess
        operation.configuration.qualityOfService = .utility
        operation.configuration.timeoutIntervalForRequest = 15
        operation.configuration.timeoutIntervalForResource = 30
        return try await PhotoAssetDownload.run(network: network) { request in
            let completion = CloudKitAssetMetadataFetchOperation(request)
            operation.perRecordResultBlock = { id, result in completion.record(id.recordName, result: result) }
            operation.fetchRecordsResultBlock = { result in completion.finish(result) }
            privateDatabase.add(operation)
            return { operation.cancel() }
        }
    }

    private func fetchAssetRecord(named assetName: String, desiredKeys: [String]?, allowsCellularAccess: Bool) async throws -> CKRecord {
        let operation = CKFetchRecordsOperation(recordIDs: [CKRecord.ID(recordName: assetName)])
        operation.desiredKeys = desiredKeys
        operation.configuration.allowsCellularAccess = allowsCellularAccess
        operation.configuration.timeoutIntervalForRequest = 15
        operation.configuration.timeoutIntervalForResource = 30
        return try await PhotoAssetDownload.run(network: network) { request in
            operation.perRecordResultBlock = { _, result in request.finish(result) }
            operation.fetchRecordsResultBlock = { result in
                if case .failure(let error) = result { request.finish(.failure(error)) }
            }
            privateDatabase.add(operation)
            return { operation.cancel() }
        }
    }

    func finishUploadedOriginals(assetNames: Set<String>, retaining: Bool) async throws {
        for name in assetNames {
            guard !deletedAssetNames.contains(name), let source = stagedAssetURL(named: name) else { continue }
            if retaining {
                try await offlineStore.retain(from: source, named: name, movingOriginal: true)
            }
            removeStagedAsset(named: name)
        }
    }

    func recordPhotoAccess(named fullImageAssetName: String) async {
        guard PhotoOfflineSettings.keepsRecentPhotos(in: offlineSettingsDefaults) else { return }
        do {
            try await offlineStore.recordAccess(to: fullImageAssetName)
            NotificationCenter.default.post(name: Self.photoAccessDidChangeNotification, object: self)
        } catch {
            logger.error("recent-photo-access: \(error.localizedDescription, privacy: .public)")
        }
    }

    func localAssetMetadata(named names: Set<String>) async throws -> [String: PhotoAssetMetadata] {
        var metadata = try await offlineStore.assetMetadata()
        let urls = names.subtracting(metadata.keys).reduce(into: [String: URL]()) { result, name in
            result[name] = stagedAssetURL(named: name) ?? readableAssetURL(named: name)
        }
        metadata.merge(await PhotoLocalAssetMetadata.read(from: urls)) { stored, _ in stored }
        return metadata
    }

    func releaseOfflineCopies(except names: Set<String>) async throws {
        let removed = try await offlineStore.assetNames().subtracting(names)
        try await offlineStore.removeUnselected(keeping: names)
        // Readable URLs can be hard links to persistent originals. Remove both
        // links when evicting so the storage is actually reclaimed.
        for name in removed { try? fileManager.removeItem(at: temporaryReadableURL(for: name)) }
    }

    private func postAssetTransferChange(kind: AssetTransferKind, phase: AssetTransferPhase, assetName: String) {
        NotificationCenter.default.post(
            name: Self.assetTransferDidChangeNotification,
            object: nil,
            userInfo: [
                "kind": kind.rawValue,
                "phase": phase.rawValue,
                "assetName": assetName
            ]
        )
    }

    func stageAssetData(_ data: Data, named assetName: String, includesInBackup: Bool = false) throws -> URL {
        deletedAssetNames.remove(assetName)
        let fileURL = stagingFileURL(for: assetName)
        try ensureDirectoryExists(at: stagingDirectoryURL)
        try data.write(to: fileURL, options: .atomic)
        if includesInBackup {
            try markIncludedInBackup(fileURL)
        }
        return fileURL
    }

    func stageAssetFile(from sourceURL: URL, named assetName: String, includesInBackup: Bool = false) throws -> URL {
        deletedAssetNames.remove(assetName)
        let destinationURL = stagingFileURL(for: assetName)
        try ensureDirectoryExists(at: stagingDirectoryURL)
        if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
            let temporaryURL = stagingDirectoryURL.appendingPathComponent(".\(UUID().uuidString).staging")
            defer { try? fileManager.removeItem(at: temporaryURL) }
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        }
        if includesInBackup {
            try markIncludedInBackup(destinationURL)
        }
        return destinationURL
    }

    func stageAssetDataAsync(
        _ data: Data,
        named assetName: String,
        includesInBackup: Bool = false
    ) async throws -> URL {
        deletedAssetNames.remove(assetName)
        return try await PhotoAssetFileWorker.stage(
            data: data,
            at: stagingFileURL(for: assetName),
            includesInBackup: includesInBackup
        )
    }

    func stageAssetFileAsync(
        from sourceURL: URL,
        named assetName: String,
        includesInBackup: Bool = false
    ) async throws -> URL {
        deletedAssetNames.remove(assetName)
        return try await PhotoAssetFileWorker.stage(
            file: sourceURL,
            at: stagingFileURL(for: assetName),
            includesInBackup: includesInBackup
        )
    }

    func stagedAssetURL(named assetName: String) -> URL? {
        let stagedURL = stagingFileURL(for: assetName)
        guard fileManager.fileExists(atPath: stagedURL.path) else {
            return nil
        }
        return stagedURL
    }

    func restoreStagedUploadAsset(named assetName: String, photoID: UUID) async throws -> Bool {
        guard !deletedAssetNames.contains(assetName),
              let entry = uploadStateStore.entry(for: photoID), entry.state != .uploaded,
              entry.assetNames.contains(assetName) else { return false }
        if stagedAssetURL(named: assetName) != nil { return true }

        let offlineURL = try await offlineStore.assetURL(named: assetName)
        guard let source = offlineURL ?? readableAssetURL(named: assetName) ?? legacyAssetURL(named: assetName) else {
            return false
        }
        try Task.checkCancellation()
        _ = try await PhotoAssetFileWorker.stage(
            file: source, at: stagingFileURL(for: assetName), includesInBackup: true
        )
        guard !deletedAssetNames.contains(assetName),
              let current = uploadStateStore.entry(for: photoID), current.state != .uploaded,
              current.assetNames.contains(assetName) else {
            removeStagedAsset(named: assetName)
            throw CancellationError()
        }
        logger.log("upload-asset-restored photo=\(photoID.uuidString, privacy: .public) name=\(assetName, privacy: .public)")
        return true
    }

    nonisolated func isAssetAvailableForImmediateRead(named assetName: String) -> Bool {
        let fileManager = FileManager.default
        let stagedURL = stagingDirectoryURL.appendingPathComponent(assetName)
        let readableURL = temporaryReadableAssetsDirectoryURL.appendingPathComponent(assetName)
        let offlineURL = offlineStore.directoryURL.appendingPathComponent(assetName)
        return fileManager.fileExists(atPath: stagedURL.path) || fileManager.fileExists(atPath: readableURL.path)
            || fileManager.fileExists(atPath: offlineURL.path)
    }

    func uploadStagedAsset(named assetName: String, photoID: UUID, role: PhotoAssetRole, retainsStagedOriginal: Bool = false) async throws {
        try Task.checkCancellation()
        guard !deletedAssetNames.contains(assetName) else { throw CancellationError() }
        activeAssetUploads[assetName, default: 0] += 1
        defer {
            activeAssetUploads[assetName, default: 0] -= 1
            if activeAssetUploads[assetName] == 0 {
                activeAssetUploads.removeValue(forKey: assetName)
                if deletedAssetNames.contains(assetName) { removeStagedAsset(named: assetName) }
                for waiter in assetUploadWaiters.removeValue(forKey: assetName) ?? [] { waiter.resume() }
            }
        }
        guard let sourceURL = localAssetURLForUpload(named: assetName) else {
            logger.error("upload-staged-asset-missing name=\(assetName, privacy: .public) photo=\(photoID.uuidString, privacy: .public) role=\(role.rawValue, privacy: .public)")
            throw CloudKitError.assetNotFound
        }

        let digest = try await PhotoAssetFileWorker.digestAndByteCount(at: sourceURL)
        try Task.checkCancellation()
        guard !deletedAssetNames.contains(assetName) else { throw CancellationError() }
        logger.log("upload-staged-asset-start name=\(assetName, privacy: .public) photo=\(photoID.uuidString, privacy: .public) role=\(role.rawValue, privacy: .public) bytes=\(digest.byteCount, privacy: .public) source=\(sourceURL.path(percentEncoded: false), privacy: .public)")
        if let assetUploader {
            try await assetUploader(assetName, photoID, role)
        } else {
            try await saveAssetFile(
                sourceURL: sourceURL,
                byteCount: digest.byteCount,
                assetName: assetName,
                photoID: photoID,
                role: role,
                checksum: digest.checksum
            )
        }

        if !retainsStagedOriginal, sourceURL.deletingLastPathComponent() == stagingDirectoryURL {
            try? fileManager.removeItem(at: sourceURL)
        }
        logger.log("upload-staged-asset-finished name=\(assetName, privacy: .public) photo=\(photoID.uuidString, privacy: .public) role=\(role.rawValue, privacy: .public)")
    }

    func remoteAssetExists(named assetName: String) async throws -> Bool {
        if let remoteAssetExistenceChecker {
            return try await remoteAssetExistenceChecker(assetName)
        }
        let recordID = CKRecord.ID(recordName: assetName)

        do {
            let results = try await privateDatabase.records(for: [recordID], desiredKeys: [RecordKey.photoID])
            guard let result = results[recordID] else {
                return false
            }

            switch result {
            case .success:
                return true
            case .failure(let error):
                let normalizedError = cloudKitError(for: error)
                await MainActor.run {
                    ICloudAvailabilityMonitor.shared.recordCloudKitError(error)
                }
                if let cloudKitError = normalizedError as? CloudKitError, cloudKitError == .assetNotFound {
                    return false
                }
                throw normalizedError
            }
        } catch {
            let normalizedError = cloudKitError(for: error)
            await MainActor.run {
                ICloudAvailabilityMonitor.shared.recordCloudKitError(error)
            }
            if let cloudKitError = normalizedError as? CloudKitError, cloudKitError == .assetNotFound {
                return false
            }
            throw normalizedError
        }
    }

    func deleteAsset(named assetName: String) {
        deletedAssetNames.insert(assetName)
        let store = offlineStore
        offlineDeletionTasks[assetName] = Task {
            do { try await store.remove(named: assetName) }
            catch { logger.error("offline-asset-delete: \(error.localizedDescription, privacy: .public)") }
        }
        try? uploadStateStore.remove(assetNames: [assetName])
        for directory in legacyAssetDirectoryURLs {
            try? fileManager.removeItem(at: directory.appendingPathComponent(assetName))
        }
        if activeAssetUploads[assetName] == nil { removeStagedAsset(named: assetName) }

        let readableURL = temporaryReadableURL(for: assetName)
        if fileManager.fileExists(atPath: readableURL.path) {
            try? fileManager.removeItem(at: readableURL)
        }
    }

    func deleteAssetAndWait(named assetName: String) async {
        deleteAsset(named: assetName)
        await offlineDeletionTasks[assetName]?.value
        offlineDeletionTasks.removeValue(forKey: assetName)
        if activeAssetUploads[assetName] != nil {
            await withCheckedContinuation { continuation in
                assetUploadWaiters[assetName, default: []].append(continuation)
            }
        }
    }

    func removeStagedAsset(named assetName: String) {
        let stagedURL = stagingFileURL(for: assetName)
        if fileManager.fileExists(atPath: stagedURL.path) {
            try? fileManager.removeItem(at: stagedURL)
        }
    }

    func legacyAssetURL(named assetName: String) -> URL? {
        legacyAssetDirectoryURLs.lazy.map { $0.appendingPathComponent(assetName) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    var legacyAssetDirectoryURLsSnapshot: [URL] { legacyAssetDirectoryURLs }

    private static func makeLegacyAssetDirectoryURLs() -> [URL] {
        let bundle = Bundle.main.bundleIdentifier ?? "progress"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return [
            support.appendingPathComponent(bundle).appendingPathComponent("Assets", isDirectory: true),
            caches.appendingPathComponent(bundle).appendingPathComponent("AssetCache", isDirectory: true),
            FileManager.default.temporaryDirectory
        ]
    }

    func deleteRemoteAsset(named assetName: String) async {
        await deleteAssetAndWait(named: assetName)
        try? await deleteRemoteAssetRecord(named: assetName)
    }

    func deleteRemoteAssetRecord(named assetName: String) async throws {
        let recordID = CKRecord.ID(recordName: assetName)
        do {
            let results = try await privateDatabase.modifyRecords(
                saving: [],
                deleting: [recordID],
                savePolicy: .changedKeys,
                atomically: false
            )

            if case .failure(let error) = results.deleteResults[recordID] {
                let normalizedError = cloudKitError(for: error)
                await MainActor.run {
                    ICloudAvailabilityMonitor.shared.recordCloudKitError(error)
                }
                if let cloudKitError = normalizedError as? CloudKitError, cloudKitError == .assetNotFound {
                    return
                }
                throw normalizedError
            }
        } catch {
            let normalizedError = cloudKitError(for: error)
            await MainActor.run {
                ICloudAvailabilityMonitor.shared.recordCloudKitError(error)
            }
            if let cloudKitError = normalizedError as? CloudKitError, cloudKitError == .assetNotFound {
                return
            }
            throw normalizedError
        }
    }

    func deleteRemoteAssetRecords(named assetNames: [String]) async -> [String: RemoteAssetDeletionOutcome] {
        let orderedAssetNames = Self.uniqueAssetNames(from: assetNames)
        guard !orderedAssetNames.isEmpty else { return [:] }

        let recordIDsByAssetName = Dictionary(
            uniqueKeysWithValues: orderedAssetNames.map { ($0, CKRecord.ID(recordName: $0)) }
        )
        let recordIDs = orderedAssetNames.compactMap { recordIDsByAssetName[$0] }

        do {
            let results = try await privateDatabase.modifyRecords(
                saving: [],
                deleting: recordIDs,
                savePolicy: .changedKeys,
                atomically: false
            )

            var outcomes: [String: RemoteAssetDeletionOutcome] = [:]
            for assetName in orderedAssetNames {
                guard let recordID = recordIDsByAssetName[assetName] else {
                    outcomes[assetName] = .failure(
                        RemoteAssetDeletionFailure(
                            ckErrorCodeRawValue: nil,
                            retryAfterSeconds: nil,
                            description: "Missing CloudKit record identifier for remote asset deletion."
                        )
                    )
                    continue
                }

                guard let result = results.deleteResults[recordID] else {
                    outcomes[assetName] = .failure(
                        RemoteAssetDeletionFailure(
                            ckErrorCodeRawValue: nil,
                            retryAfterSeconds: nil,
                            description: "CloudKit did not report a deletion result for this asset."
                        )
                    )
                    continue
                }

                switch result {
                case .success:
                    outcomes[assetName] = .success
                case .failure(let error):
                    outcomes[assetName] = deletionOutcome(for: error)
                }
            }

            return outcomes
        } catch {
            let normalizedError = cloudKitError(for: error)
            await MainActor.run {
                ICloudAvailabilityMonitor.shared.recordCloudKitError(error)
            }

            if let ckError = normalizedError as? CKError,
               let partialErrors = ckError.partialErrorsByItemID {
                var outcomes: [String: RemoteAssetDeletionOutcome] = [:]

                for assetName in orderedAssetNames {
                    guard let recordID = recordIDsByAssetName[assetName] else {
                        outcomes[assetName] = .failure(
                            RemoteAssetDeletionFailure(
                                ckErrorCodeRawValue: nil,
                                retryAfterSeconds: nil,
                                description: "Missing CloudKit record identifier for remote asset deletion."
                            )
                        )
                        continue
                    }

                    if let partialError = partialErrors[recordID] {
                        outcomes[assetName] = deletionOutcome(for: partialError)
                    } else {
                        outcomes[assetName] = .success
                    }
                }

                return outcomes
            }

            let failure = RemoteAssetDeletionFailure(
                ckErrorCodeRawValue: (normalizedError as? CKError)?.code.rawValue,
                retryAfterSeconds: (normalizedError as? CKError)?.retryAfterSeconds,
                description: Self.describe(normalizedError)
            )

            return Dictionary(
                uniqueKeysWithValues: orderedAssetNames.map { ($0, .failure(failure)) }
            )
        }
    }

    func storedPersistentAssetNames() -> Set<String> {
        let stagedNames = (try? fileManager.contentsOfDirectory(atPath: stagingDirectoryURL.path)) ?? []
        return Set(stagedNames)
    }

    func markStagedAssetsIncludedInBackup() {
        do {
            try ensureDirectoryExists(at: stagingDirectoryURL)
            var directoryURL = stagingDirectoryURL
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = false
            try directoryURL.setResourceValues(directoryValues)

            let stagedURLs = try fileManager.contentsOfDirectory(
                at: stagingDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            for stagedURL in stagedURLs {
                let values = try? stagedURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                try markIncludedInBackup(stagedURL)
            }
        } catch {
            logger.error("mark-staged-assets-backup-included-failed \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteAllLocalAssets() async {
        try? await offlineStore.removeUnselected(keeping: [])
        try? await offlineStore.removeAccessRecords(except: [])
        deleteContents(of: systemCloudKitCacheDirectoryURL)
        deleteContents(of: stagingDirectoryURL)
        deleteContents(of: temporaryReadableAssetsDirectoryURL)
    }

    nonisolated func discardTemporaryReadableAsset(named assetName: String) {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKitReadableAssets", isDirectory: true)
            .appendingPathComponent(assetName)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try? fileManager.removeItem(at: temporaryURL)
        }
    }

    func localAssetStorageUsage() async -> LocalPhotoAssetStorageUsage {
        let cacheDirectoryURL = systemCloudKitCacheDirectoryURL
        let stagingDirectoryURL = stagingDirectoryURL

        let usage = await Task.detached(priority: .utility) {
            (
                cachedFullResolutionBytes: Self.allocatedSizeOfContents(at: cacheDirectoryURL),
                pendingUploadBytes: Self.allocatedSizeOfContents(at: stagingDirectoryURL)
            )
        }.value

        return LocalPhotoAssetStorageUsage(
            cachedFullResolutionBytes: usage.cachedFullResolutionBytes,
            pendingUploadBytes: usage.pendingUploadBytes,
            offlineOriginalBytes: Int((try? await offlineStore.byteCount()) ?? 0)
        )
    }

    func localAssetDirectoryURLs() -> (cache: URL, staging: URL, offline: URL) {
        (systemCloudKitCacheDirectoryURL, stagingDirectoryURL, offlineStore.directoryURL)
    }

    private func saveAssetData(
        _ data: Data,
        assetName: String,
        photoID: UUID,
        role: PhotoAssetRole,
        checksum: String
    ) async throws {
        let temporaryURL = temporaryUploadURL(for: assetName)
        try data.write(to: temporaryURL, options: .atomic)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try await saveAssetFile(
            sourceURL: temporaryURL,
            byteCount: Int64(data.count),
            assetName: assetName,
            photoID: photoID,
            role: role,
            checksum: checksum
        )
    }

    private func saveAssetFile(
        sourceURL: URL,
        byteCount: Int64,
        assetName: String,
        photoID: UUID,
        role: PhotoAssetRole,
        checksum: String
    ) async throws {
        let recordID = CKRecord.ID(recordName: assetName)
        let record = CKRecord(recordType: RecordType.photoAsset, recordID: recordID)
        record[RecordKey.fileAsset] = CKAsset(fileURL: sourceURL)
        record[RecordKey.photoID] = photoID.uuidString as CKRecordValue
        record[RecordKey.role] = role.rawValue as CKRecordValue
        record[RecordKey.checksum] = checksum as CKRecordValue
        record[RecordKey.byteCount] = NSNumber(value: byteCount)

        do {
            let results = try await privateDatabase.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys,
                atomically: true
            )

            try Self.validateAssetSaveResult(results.saveResults[recordID])
        } catch {
            logger.error("save-asset-file-threw name=\(assetName, privacy: .public) photo=\(photoID.uuidString, privacy: .public) role=\(role.rawValue, privacy: .public) error=\(Self.describe(error), privacy: .public)")
            await MainActor.run {
                ICloudAvailabilityMonitor.shared.recordCloudKitError(error)
            }
            throw cloudKitError(for: error)
        }
    }

    static func validateAssetSaveResult(_ result: Result<CKRecord, any Error>?) throws {
        guard let result else { throw CloudKitError.uploadFailed }
        _ = try result.get()
    }

    private func localAssetURLForUpload(named assetName: String) -> URL? {
        stagedAssetURL(named: assetName)
    }

    private func stableReadableURL(for sourceURL: URL, assetName: String) -> URL {
        let temporaryURL = temporaryReadableURL(for: assetName)
        guard sourceURL.standardizedFileURL != temporaryURL.standardizedFileURL else { return sourceURL }
        do {
            try ensureDirectoryExists(at: temporaryURL.deletingLastPathComponent())
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }

            do {
                try fileManager.linkItem(at: sourceURL, to: temporaryURL)
            } catch {
                try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            }

            return temporaryURL
        } catch {
            logger.error("stable-staged-asset-copy-failed name=\(assetName, privacy: .public) source=\(sourceURL.path(percentEncoded: false), privacy: .public) error=\(Self.describe(error), privacy: .public)")
            return sourceURL
        }
    }

    private func stagingFileURL(for assetName: String) -> URL {
        stagingDirectoryURL.appendingPathComponent(assetName)
    }

    private func temporaryUploadURL(for assetName: String) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension((assetName as NSString).pathExtension)
    }

    private func temporaryReadableURL(for assetName: String) -> URL {
        temporaryReadableAssetsDirectoryURL
            .appendingPathComponent(assetName)
    }

    private func readableAssetURL(named assetName: String) -> URL? {
        let readableURL = temporaryReadableURL(for: assetName)
        guard fileManager.fileExists(atPath: readableURL.path) else {
            return nil
        }
        return readableURL
    }

    private func assetRecordName(photoID: UUID, role: PhotoAssetRole, fileExtension: String) -> String {
        "\(photoID.uuidString)_\(role.rawValue).\(fileExtension)"
    }

    private func deleteContents(of directoryURL: URL) {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in fileURLs {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func heifData(from image: UIImage, compressionQuality: CGFloat) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality,
            kCGImagePropertyOrientation: image.imageOrientation.cgImagePropertyOrientation.rawValue
        ] as CFDictionary

        if let cgImage = image.cgImage {
            CGImageDestinationAddImage(destination, cgImage, options)
        } else if let ciImage = image.ciImage {
            let context = CIContext(options: nil)
            guard let rendered = context.createCGImage(ciImage, from: ciImage.extent) else {
                return nil
            }
            CGImageDestinationAddImage(destination, rendered, options)
        } else {
            return nil
        }

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return mutableData as Data
    }

    private func cloudKitError(for error: Error) -> Error {
        guard let ckError = error as? CKError else {
            return error
        }

        switch ckError.code {
        case .unknownItem:
            return CloudKitError.assetNotFound
        default:
            return ckError
        }
    }

    private static func makeSystemCloudKitCacheDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("CloudKit", isDirectory: true)
    }

    nonisolated private static func makeTemporaryReadableAssetsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKitReadableAssets", isDirectory: true)
    }

    nonisolated private static func allocatedSizeOfContents(at directoryURL: URL) -> Int {
        guard let fileURLs = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalBytes = 0
        for case let fileURL as URL in fileURLs {
            totalBytes += allocatedSize(of: fileURL)
        }
        return totalBytes
    }

    nonisolated private static func allocatedSize(of fileURL: URL) -> Int {
        guard
            let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey
            ]),
            values.isRegularFile == true
        else {
            return 0
        }

        return values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
    }

    nonisolated private static func makeStagingDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "progress"
        let directoryURL = baseURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("PendingAssetUploads", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        return directoryURL
    }

    private static func describe(_ error: Error) -> String {
        if let ckError = error as? CKError {
            return "CKError(\(ckError.code.rawValue)): \(ckError.localizedDescription)"
        }
        return String(describing: error)
    }

    private func deletionOutcome(for error: Error) -> RemoteAssetDeletionOutcome {
        let normalizedError = cloudKitError(for: error)
        if let cloudKitError = normalizedError as? CloudKitError, cloudKitError == .assetNotFound {
            return .success
        }

        return .failure(
            RemoteAssetDeletionFailure(
                ckErrorCodeRawValue: (normalizedError as? CKError)?.code.rawValue,
                retryAfterSeconds: (normalizedError as? CKError)?.retryAfterSeconds,
                description: Self.describe(normalizedError)
            )
        )
    }

    private static func uniqueAssetNames(from assetNames: [String]) -> [String] {
        var seenAssetNames = Set<String>()
        var orderedAssetNames: [String] = []

        for assetName in assetNames {
            if seenAssetNames.insert(assetName).inserted {
                orderedAssetNames.append(assetName)
            }
        }

        return orderedAssetNames
    }

    private func ensureDirectoryExists(at directoryURL: URL) throws {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private func markIncludedInBackup(_ fileURL: URL) throws {
        var directoryURL = fileURL.deletingLastPathComponent()
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = false
        try directoryURL.setResourceValues(directoryValues)

        var fileURL = fileURL
        var fileValues = URLResourceValues()
        fileValues.isExcludedFromBackup = false
        try fileURL.setResourceValues(fileValues)
    }
}

private enum SHA256Hasher {
    static func hexDigest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum RemoteAssetDeletionOutcome: Sendable {
    case success
    case failure(RemoteAssetDeletionFailure)
}

struct RemoteAssetDeletionFailure: Sendable {
    let ckErrorCodeRawValue: Int?
    let retryAfterSeconds: Double?
    let description: String
}

private extension UIImage.Orientation {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

enum CloudKitError: LocalizedError {
    case invalidImageData
    case assetNotFound
    case uploadFailed
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Failed to convert image to data"
        case .assetNotFound:
            return "Asset file not found"
        case .uploadFailed:
            return "Failed to upload to CloudKit"
        case .downloadFailed:
            return "Failed to download from CloudKit"
        }
    }
}
