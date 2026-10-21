import Foundation

nonisolated enum PhotoStorageMode: String, Codable, Sendable {
    case iCloud
    case downloading
    case local
    case deletingCloudCopies
    case preparingUpload

    var allowsCloudWrites: Bool { self == .iCloud }
    var keepsAllOriginals: Bool { self != .iCloud }
    var isMigrating: Bool { self == .downloading || self == .preparingUpload || self == .deletingCloudCopies }
}
