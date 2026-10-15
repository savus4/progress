import Foundation

nonisolated enum PhotoOfflinePolicy: Sendable {
    case onDemand
    case hearted
    case all

    func selects(isHearted: Bool, isFavoriteLivePhoto: Bool) -> Bool {
        switch self {
        case .onDemand: false
        case .hearted: isHearted || isFavoriteLivePhoto
        case .all: true
        }
    }
}
