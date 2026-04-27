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

final class CloudKitService {
    static let shared = CloudKitService()
    static let assetTransferDidChangeNotification = Notification.Name("CloudKitService.assetTransferDidChange")

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
    private let stagingDirectoryURL: URL
    private let temporaryReadableAssetsDirectoryURL: URL
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "CloudKitAsset")

    private init() {
        container = CKContainer.default()
        privateDatabase = container.privateCloudDatabase
        systemCloudKitCacheDirectoryURL = Self.makeSystemCloudKitCacheDirectoryURL()
        stagingDirectoryURL = Self.makeStagingDirectoryURL()
        temporaryReadableAssetsDirectoryURL = Self.makeTemporaryReadableAssetsDirectoryURL()
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
        let data = try Data(contentsOf: videoURL)
        try await saveAssetFile(
            sourceURL: videoURL,
            data: data,
            assetName: assetName,
            photoID: photoID,
            role: role,
            checksum: SHA256Hasher.hexDigest(for: data)
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
        forceRefetch: Bool = false
    ) async throws -> URL {
        if let stagedURL = stagedAssetURL(named: assetName) {
            return stableReadableURL(for: stagedURL, assetName: assetName)
        }

        if !forceRefetch, let readableURL = readableAssetURL(named: assetName) {
            return readableURL
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
        let results = try await privateDatabase.records(for: [recordID], desiredKeys: nil)
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

    func stageAssetData(_ data: Data, named assetName: String) throws -> URL {
        let fileURL = stagingFileURL(for: assetName)
        try ensureDirectoryExists(at: stagingDirectoryURL)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    func stageAssetFile(from sourceURL: URL, named assetName: String) throws -> URL {
        let destinationURL = stagingFileURL(for: assetName)
        try ensureDirectoryExists(at: stagingDirectoryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func stagedAssetURL(named assetName: String) -> URL? {
        let stagedURL = stagingFileURL(for: assetName)
        guard fileManager.fileExists(atPath: stagedURL.path) else {
            return nil
        }
        return stagedURL
    }

    func uploadStagedAsset(named assetName: String, photoID: UUID, role: PhotoAssetRole) async throws {
        guard let sourceURL = localAssetURLForUpload(named: assetName) else {
            logger.error("upload-staged-asset-missing name=\(assetName, privacy: .public) photo=\(photoID.uuidString, privacy: .public) role=\(role.rawValue, privacy: .public)")
            throw CloudKitError.assetNotFound
        }

        let data = try Data(contentsOf: sourceURL)
        logger.log("upload-staged-asset-start name=\(assetName, privacy: .public) photo=\(photoID.uuidString, privacy: .public) role=\(role.rawValue, privacy: .public) bytes=\(data.count, privacy: .public) source=\(sourceURL.path(percentEncoded: false), privacy: .public)")
        try await saveAssetFile(
            sourceURL: sourceURL,
            data: data,
            assetName: assetName,
            photoID: photoID,
            role: role,
            checksum: SHA256Hasher.hexDigest(for: data)
        )

        if sourceURL.deletingLastPathComponent() == stagingDirectoryURL {
            try? fileManager.removeItem(at: sourceURL)
        }
        logger.log("upload-staged-asset-finished name=\(assetName, privacy: .public) photo=\(photoID.uuidString, privacy: .public) role=\(role.rawValue, privacy: .public)")
    }

    func deleteAsset(named assetName: String) {
        let stagedURL = stagingFileURL(for: assetName)
        if fileManager.fileExists(atPath: stagedURL.path) {
            try? fileManager.removeItem(at: stagedURL)
        }
    }

    func deleteRemoteAsset(named assetName: String) async {
        deleteAsset(named: assetName)
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
                if let cloudKitError = normalizedError as? CloudKitError, cloudKitError == .assetNotFound {
                    return
                }
                throw normalizedError
            }
        } catch {
            let normalizedError = cloudKitError(for: error)
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

    func deleteAllLocalAssets() {
        deleteContents(of: systemCloudKitCacheDirectoryURL)
        deleteContents(of: stagingDirectoryURL)
        deleteContents(of: temporaryReadableAssetsDirectoryURL)
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
            pendingUploadBytes: usage.pendingUploadBytes
        )
    }

    func localAssetDirectoryURLs() -> (cache: URL, staging: URL) {
        (systemCloudKitCacheDirectoryURL, stagingDirectoryURL)
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
            data: data,
            assetName: assetName,
            photoID: photoID,
            role: role,
            checksum: checksum
        )
    }

    private func saveAssetFile(
        sourceURL: URL,
        data: Data,
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
        record[RecordKey.byteCount] = NSNumber(value: data.count)

        do {
            let results = try await privateDatabase.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys,
                atomically: true
            )

            if case .failure(let error) = results.saveResults[recordID] {
                logger.error("save-asset-file-result-failed name=\(assetName, privacy: .public) photo=\(photoID.uuidString, privacy: .public) role=\(role.rawValue, privacy: .public) error=\(Self.describe(error), privacy: .public)")
                throw cloudKitError(for: error)
            }
        } catch {
            logger.error("save-asset-file-threw name=\(assetName, privacy: .public) photo=\(photoID.uuidString, privacy: .public) role=\(role.rawValue, privacy: .public) error=\(Self.describe(error), privacy: .public)")
            throw cloudKitError(for: error)
        }
    }

    private func localAssetURLForUpload(named assetName: String) -> URL? {
        stagedAssetURL(named: assetName)
    }

    private func stableReadableURL(for sourceURL: URL, assetName: String) -> URL {
        let temporaryURL = temporaryReadableURL(for: assetName)
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

    private static func makeTemporaryReadableAssetsDirectoryURL() -> URL {
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

    private static func makeStagingDirectoryURL() -> URL {
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
