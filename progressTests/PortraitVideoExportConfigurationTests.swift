import Foundation
import Testing
@testable import progress

struct PortraitVideoExportConfigurationTests {
    @Test("Older paused exports retain chronological order")
    func decodesLegacyConfiguration() throws {
        let data = Data(#"""
        {
            "picturesPerSecond": 6,
            "quality": "compact",
            "includesDateBanner": true,
            "includesLocationBanner": false,
            "includesFavoriteLivePhotoVideo": true,
            "holdsHeartedPhotos": true,
            "usesAllPhotos": false,
            "startDate": 0,
            "endDate": 86400
        }
        """#.utf8)

        let configuration = try JSONDecoder().decode(PortraitVideoExportConfiguration.self, from: data)

        #expect(configuration == PortraitVideoExportConfiguration(
            picturesPerSecond: 6,
            quality: .compact,
            includesDateBanner: true,
            includesLocationBanner: false,
            includesFavoriteLivePhotoVideo: true,
            holdsHeartedPhotos: true,
            usesAllPhotos: false,
            startDate: Date(timeIntervalSinceReferenceDate: 0),
            endDate: Date(timeIntervalSinceReferenceDate: 86400),
            reversesPhotoOrder: false
        ))
    }
}
