import Foundation

struct PhotoExportMetadata: Encodable {
    let id: String?
    let captureDateISO8601: String?
    let createdAtISO8601: String?
    let modifiedAtISO8601: String?
    let latitude: Double
    let longitude: Double
    let locationName: String?
    let fullImageAssetName: String?
    let livePhotoImageAssetName: String?
    let livePhotoVideoAssetName: String?
}
