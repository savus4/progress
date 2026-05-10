import Foundation
import CoreData

nonisolated struct PortraitVideoExportItem: Identifiable, Equatable {
    let objectID: NSManagedObjectID
    let captureDate: Date
    let fullImageAssetName: String?

    var id: NSManagedObjectID { objectID }

    @MainActor
    init(photo: DailyPhoto) {
        objectID = photo.objectID
        captureDate = photo.captureDate ?? photo.createdAt ?? Date()
        fullImageAssetName = photo.fullImageAssetName ?? photo.livePhotoImageAssetName
    }
}
