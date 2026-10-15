import CloudKit
import Foundation
import Synchronization

nonisolated final class CloudKitAssetMetadataFetchOperation: Sendable {
    private let results = Mutex<[String: Result<PhotoAssetMetadata, any Error>]>([:])
    private let request: PhotoAssetRequest<[String: Result<PhotoAssetMetadata, any Error>]>

    init(_ request: PhotoAssetRequest<[String: Result<PhotoAssetMetadata, any Error>]>) {
        self.request = request
    }

    func record(_ name: String, result: Result<CKRecord, any Error>) {
        let metadata = result.flatMap { record -> Result<PhotoAssetMetadata, any Error> in
            guard let count = record["byteCount"] as? NSNumber, count.int64Value >= 0 else {
                return .failure(CocoaError(.fileReadUnknown))
            }
            return .success(PhotoAssetMetadata(byteCount: count.int64Value, checksum: record["checksum"] as? String))
        }
        results.withLock { $0[name] = metadata }
    }

    func finish(_ result: Result<Void, any Error>) {
        let collected = results.withLock { $0 }
        if case .failure(let error) = result, collected.isEmpty {
            request.finish(.failure(error))
        } else {
            // A missing original must not hide other successful record headers.
            request.finish(.success(collected))
        }
    }
}
