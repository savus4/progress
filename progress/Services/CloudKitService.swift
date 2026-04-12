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
    private let cacheDirectoryURL: URL
    private let stagingDirectoryURL: URL
    private let fileManager = FileManager.default
    private let cacheIndexKey = "cachedAssetAccessDates"
    private let maxCacheSizeBytes = 512 * 1_024 * 1_024
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "CloudKitAsset")

    private init() {
        container = CKContainer.default()
        privateDatabase = container.privateCloudDatabase
        cacheDirectoryURL = Self.makeCacheDirectoryURL()
        stagingDirectoryURL = Self.makeStagingDirectoryURL()
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

    func loadAssetURL(named assetName: String) async throws -> URL {
        if let cachedURL = cachedAssetURL(named: assetName) {
            markAssetAccessed(named: assetName)
            return cachedURL
        }

        if let stagedURL = stagedAssetURL(named: assetName) {
            return stagedURL
        }

        postAssetTransferChange(kind: .download, phase: .started, assetName: assetName)
        defer {
            postAssetTransferChange(kind: .download, phase: .finished, assetName: assetName)
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
            postAssetTransferChange(kind: .download, phase: .failed, assetName: assetName)
            throw cloudKitError(for: error)
        }

        guard let asset = record[RecordKey.fileAsset] as? CKAsset,
              let stagedURL = asset.fileURL else {
            postAssetTransferChange(kind: .download, phase: .failed, assetName: assetName)
            throw CloudKitError.assetNotFound
        }

        let destinationURL = cacheFileURL(for: assetName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: stagedURL, to: destinationURL)
        markAssetAccessed(named: assetName)
        pruneCacheIfNeeded(excluding: [assetName])
        return destinationURL
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

    func cacheAssetData(_ data: Data, named assetName: String) throws -> URL {
        let fileURL = cacheFileURL(for: assetName)
        if !fileManager.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
        }
        markAssetAccessed(named: assetName)
        pruneCacheIfNeeded(excluding: [assetName])
        return fileURL
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
        let cachedURL = cacheFileURL(for: assetName)
        if fileManager.fileExists(atPath: cachedURL.path) {
            try? fileManager.removeItem(at: cachedURL)
        }
        let stagedURL = stagingFileURL(for: assetName)
        if fileManager.fileExists(atPath: stagedURL.path) {
            try? fileManager.removeItem(at: stagedURL)
        }
        removeCachedAccessDate(for: assetName)
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

    func storedPersistentAssetNames() -> Set<String> {
        let cachedNames = (try? fileManager.contentsOfDirectory(atPath: cacheDirectoryURL.path)) ?? []
        let stagedNames = (try? fileManager.contentsOfDirectory(atPath: stagingDirectoryURL.path)) ?? []
        return Set(cachedNames).union(stagedNames)
    }

    func deleteAllLocalAssets() {
        deleteContents(of: cacheDirectoryURL)
        deleteContents(of: stagingDirectoryURL)
        UserDefaults.standard.removeObject(forKey: cacheIndexKey)
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

        _ = try cacheAssetData(data, named: assetName)
    }

    private func cachedAssetURL(named assetName: String) -> URL? {
        let cachedURL = cacheFileURL(for: assetName)
        guard fileManager.fileExists(atPath: cachedURL.path) else {
            return nil
        }
        return cachedURL
    }

    private func localAssetURLForUpload(named assetName: String) -> URL? {
        if let stagedURL = stagedAssetURL(named: assetName) {
            return stagedURL
        }
        return cachedAssetURL(named: assetName)
    }

    private func cacheFileURL(for assetName: String) -> URL {
        cacheDirectoryURL.appendingPathComponent(assetName)
    }

    private func stagingFileURL(for assetName: String) -> URL {
        stagingDirectoryURL.appendingPathComponent(assetName)
    }

    private func temporaryUploadURL(for assetName: String) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension((assetName as NSString).pathExtension)
    }

    private func assetRecordName(photoID: UUID, role: PhotoAssetRole, fileExtension: String) -> String {
        "\(photoID.uuidString)_\(role.rawValue).\(fileExtension)"
    }

    private func markAssetAccessed(named assetName: String) {
        var accessDates = cachedAccessDates()
        accessDates[assetName] = Date().timeIntervalSinceReferenceDate
        UserDefaults.standard.set(accessDates, forKey: cacheIndexKey)
    }

    private func removeCachedAccessDate(for assetName: String) {
        var accessDates = cachedAccessDates()
        accessDates.removeValue(forKey: assetName)
        UserDefaults.standard.set(accessDates, forKey: cacheIndexKey)
    }

    private func cachedAccessDates() -> [String: TimeInterval] {
        let rawValues = UserDefaults.standard.dictionary(forKey: cacheIndexKey) ?? [:]
        var accessDates: [String: TimeInterval] = [:]
        for (key, value) in rawValues {
            if let number = value as? NSNumber {
                accessDates[key] = number.doubleValue
            }
        }
        return accessDates
    }

    private func pruneCacheIfNeeded(excluding protectedAssetNames: Set<String> = []) {
        guard var cachedAssetNames = try? fileManager.contentsOfDirectory(atPath: cacheDirectoryURL.path) else {
            return
        }

        var totalSize = 0
        var fileSizes: [String: Int] = [:]
        for assetName in cachedAssetNames {
            let assetURL = cacheFileURL(for: assetName)
            guard
                let attributes = try? fileManager.attributesOfItem(atPath: assetURL.path),
                let fileSize = attributes[.size] as? NSNumber
            else {
                continue
            }
            let bytes = fileSize.intValue
            totalSize += bytes
            fileSizes[assetName] = bytes
        }

        guard totalSize > maxCacheSizeBytes else { return }

        let accessDates = cachedAccessDates()
        cachedAssetNames.sort {
            let lhsDate = accessDates[$0] ?? 0
            let rhsDate = accessDates[$1] ?? 0
            if lhsDate == rhsDate {
                return $0 < $1
            }
            return lhsDate < rhsDate
        }

        for assetName in cachedAssetNames where totalSize > maxCacheSizeBytes {
            guard !protectedAssetNames.contains(assetName) else { continue }
            let assetURL = cacheFileURL(for: assetName)
            guard fileManager.fileExists(atPath: assetURL.path) else {
                removeCachedAccessDate(for: assetName)
                continue
            }
            try? fileManager.removeItem(at: assetURL)
            totalSize -= fileSizes[assetName] ?? 0
            removeCachedAccessDate(for: assetName)
        }
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

    private static func makeCacheDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "progress"
        let directoryURL = baseURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("AssetCache", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        return directoryURL
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
