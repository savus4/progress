import Foundation
import CoreData

nonisolated struct PortraitVideoExportItem: Identifiable, Equatable {
    let objectID: NSManagedObjectID
    let captureDate: Date
    let locationName: String?
    let latitude: Double
    let longitude: Double
    let fullImageAssetName: String?

    var id: NSManagedObjectID { objectID }

    @MainActor
    init(photo: DailyPhoto) {
        objectID = photo.objectID
        captureDate = photo.captureDate ?? photo.createdAt ?? Date()
        locationName = photo.locationName
        latitude = photo.latitude
        longitude = photo.longitude
        fullImageAssetName = photo.fullImageAssetName ?? photo.livePhotoImageAssetName
    }
}
