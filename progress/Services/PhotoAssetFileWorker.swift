import CryptoKit
import Foundation

enum PhotoAssetFileWorker {
    struct Digest: Sendable {
        let checksum: String
        let byteCount: Int64
    }

    @concurrent
    nonisolated static func stage(
        data: Data,
        at destinationURL: URL,
        includesInBackup: Bool
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destinationURL, options: .atomic)
        if includesInBackup {
            try markIncludedInBackup(destinationURL)
        }
        return destinationURL
    }

    @concurrent
    nonisolated static func stage(
        file sourceURL: URL,
        at destinationURL: URL,
        includesInBackup: Bool
    ) async throws -> URL {
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let temporaryURL = directoryURL.appendingPathComponent(".\(UUID().uuidString).staging")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }

        if includesInBackup {
            try markIncludedInBackup(destinationURL)
        }
        return destinationURL
    }

    @concurrent
    nonisolated static func copyReplacingItem(from sourceURL: URL, to destinationURL: URL) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    @concurrent
    nonisolated static func fingerprint(imageData: Data, videoURL: URL?) async throws -> String {
        let imageDigest = hexDigest(SHA256.hash(data: imageData))
        guard let videoURL else { return imageDigest }
        let videoDigest = try digestAndByteCountSync(at: videoURL).checksum
        return "\(imageDigest):\(videoDigest)"
    }

    @concurrent
    nonisolated static func digestAndByteCount(at fileURL: URL) async throws -> Digest {
        try digestAndByteCountSync(at: fileURL)
    }

    nonisolated private static func digestAndByteCountSync(at fileURL: URL) throws -> Digest {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
            byteCount += Int64(chunk.count)
        }
        return Digest(checksum: hexDigest(hasher.finalize()), byteCount: byteCount)
    }

    nonisolated private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func markIncludedInBackup(_ fileURL: URL) throws {
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
