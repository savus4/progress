import Foundation

nonisolated enum PhotoStorageMigrationError: LocalizedError {
    case attention(String)
    case accountChanged

    var errorDescription: String? {
        switch self {
        case .attention(let message): message
        case .accountChanged: "The iCloud account changed. Sign back in to the account used when this switch started, then retry. Your originals have been kept."
        }
    }
}
