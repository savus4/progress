import Foundation

nonisolated struct PhotoOfflinePhoto: Sendable {
    let id: UUID
    let createdAt: Date
    let isHearted: Bool
    let isFavoriteLivePhoto: Bool
    let fullImageAssetName: String?
    let livePhotoImageAssetName: String?
    let livePhotoVideoAssetName: String?

    var assetNames: Set<String> {
        Set([fullImageAssetName, livePhotoImageAssetName, livePhotoVideoAssetName].compactMap { $0 })
    }

    func isSelected(by policy: PhotoOfflinePolicy) -> Bool {
        policy.selects(isHearted: isHearted, isFavoriteLivePhoto: isFavoriteLivePhoto)
    }

    func isAvailable(in names: Set<String>) -> Bool {
        fullImageAssetName != nil && !assetNames.isEmpty && assetNames.isSubset(of: names)
    }
}
