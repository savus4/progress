import Foundation

nonisolated struct PhotoAssetMetadata: Codable, Sendable, Equatable {
    let byteCount: Int64
    let checksum: String?
}
