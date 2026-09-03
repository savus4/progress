import CoreData
import Foundation

nonisolated extension DailyPhoto {
    @nonobjc class func fetchRequest() -> NSFetchRequest<DailyPhoto> {
        NSFetchRequest<DailyPhoto>(entityName: "DailyPhoto")
    }

    @NSManaged var id: UUID?
    @NSManaged var captureDate: Date?
    @NSManaged var thumbnailData: Data?
    @NSManaged var fullImageAssetName: String?
    @NSManaged var fullImageData: Data?
    @NSManaged var livePhotoImageAssetName: String?
    @NSManaged var livePhotoImageData: Data?
    @NSManaged var livePhotoVideoAssetName: String?
    @NSManaged var livePhotoVideoData: Data?
    @NSManaged var latitude: Double
    @NSManaged var longitude: Double
    @NSManaged var locationName: String?
    @NSManaged var createdAt: Date?
    @NSManaged var modifiedAt: Date?
    @NSManaged var importFingerprint: String?
    @NSManaged var isHearted: Bool
    @NSManaged var isFavoriteLivePhoto: Bool
    @NSManaged var uploadAttemptCount: Int16
    @NSManaged var uploadErrorMessage: String?
    @NSManaged var uploadRetryAfter: Date?
    @NSManaged var uploadStateRaw: String?
}

extension DailyPhoto: Identifiable {}
