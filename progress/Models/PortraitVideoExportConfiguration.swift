import Foundation

nonisolated struct PortraitVideoExportConfiguration: Equatable, Codable, Sendable {
    let picturesPerSecond: Int
    let quality: PortraitVideoExportQuality
    let includesDateBanner: Bool
    let includesLocationBanner: Bool
    let includesFavoriteLivePhotoVideo: Bool
    let holdsHeartedPhotos: Bool
    let usesAllPhotos: Bool
    let startDate: Date
    let endDate: Date
    let reversesPhotoOrder: Bool

    init(
        picturesPerSecond: Int,
        quality: PortraitVideoExportQuality,
        includesDateBanner: Bool,
        includesLocationBanner: Bool,
        includesFavoriteLivePhotoVideo: Bool,
        holdsHeartedPhotos: Bool,
        usesAllPhotos: Bool,
        startDate: Date,
        endDate: Date,
        reversesPhotoOrder: Bool = false
    ) {
        self.picturesPerSecond = picturesPerSecond
        self.quality = quality
        self.includesDateBanner = includesDateBanner
        self.includesLocationBanner = includesLocationBanner
        self.includesFavoriteLivePhotoVideo = includesFavoriteLivePhotoVideo
        self.holdsHeartedPhotos = holdsHeartedPhotos
        self.usesAllPhotos = usesAllPhotos
        self.startDate = startDate
        self.endDate = endDate
        self.reversesPhotoOrder = reversesPhotoOrder
    }

    private enum CodingKeys: String, CodingKey {
        case picturesPerSecond, quality, includesDateBanner, includesLocationBanner
        case includesFavoriteLivePhotoVideo, holdsHeartedPhotos, usesAllPhotos
        case startDate, endDate, reversesPhotoOrder
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        picturesPerSecond = try values.decode(Int.self, forKey: .picturesPerSecond)
        quality = try values.decode(PortraitVideoExportQuality.self, forKey: .quality)
        includesDateBanner = try values.decode(Bool.self, forKey: .includesDateBanner)
        includesLocationBanner = try values.decode(Bool.self, forKey: .includesLocationBanner)
        includesFavoriteLivePhotoVideo = try values.decode(Bool.self, forKey: .includesFavoriteLivePhotoVideo)
        holdsHeartedPhotos = try values.decode(Bool.self, forKey: .holdsHeartedPhotos)
        usesAllPhotos = try values.decode(Bool.self, forKey: .usesAllPhotos)
        startDate = try values.decode(Date.self, forKey: .startDate)
        endDate = try values.decode(Date.self, forKey: .endDate)
        // Exports paused before Reverse Mode was added keep chronological order.
        reversesPhotoOrder = try values.decodeIfPresent(Bool.self, forKey: .reversesPhotoOrder) ?? false
    }
}
