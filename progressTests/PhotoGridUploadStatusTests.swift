import CoreData
import Testing
import UIKit
@testable import progress

@MainActor
struct PhotoGridUploadStatusTests {
    @Test("Queued and retrying uploads show a steady waiting badge until connectivity returns", arguments: [
        PhotoUploadState.pending, .uploading, .failed, .paused, .uploaded
    ])
    func displaysConnectivityAwareBadge(state: PhotoUploadState) throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let photo = DailyPhoto(context: context)
        let id = UUID()
        let name = "\(id).heic"
        photo.id = id
        photo.fullImageAssetName = name
        try context.obtainPermanentIDs(for: [photo])
        let store = LocalPhotoUploadStore.shared
        try store.register(LocalPhotoUpload(photoID: id, stillAssetName: name,
                                            livePhotoImageAssetName: nil, videoAssetName: nil,
                                            createdAt: Date(), state: state))
        defer { try? store.remove(assetNames: [name]) }
        let item = UIKitPhotoGridItem(photo: photo)
        let cell = PhotoGridCollectionViewCell(frame: CGRect(x: 0, y: 0, width: 130, height: 180))
        let badge = try #require(cell.contentView.subviews.compactMap { $0 as? UILabel }
            .first { $0.accessibilityIdentifier == "photoGridUploadBadge" })

        for networkState in [PhotoNetworkState.checking, .offline, .offline, .connected] {
            cell.configure(with: item, showsUploadStatus: true, networkState: networkState,
                           isSelectionMode: false, isSelected: false)
            let expected: String?
            switch state {
            case .paused: expected = "Upload paused"
            case .uploaded: expected = nil
            case .pending, .uploading, .failed:
                expected = networkState != .connected ? "Waiting for connection"
                    : (state == .failed ? "Retrying later" : "Uploading")
            }
            #expect(cell.accessibilityValue == expected)
            #expect(badge.isHidden == (expected == nil))
            if let expected { #expect(badge.attributedText?.string.hasSuffix(expected) == true) }
        }

        cell.configure(with: item, showsUploadStatus: false, networkState: .offline,
                       isSelectionMode: false, isSelected: false)
        #expect(badge.isHidden)
        #expect(cell.accessibilityValue == nil)
    }
}
