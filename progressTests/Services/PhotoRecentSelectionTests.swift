import Foundation
import Testing
@testable import progress

@MainActor
struct PhotoRecentSelectionTests {
    @Test("Opening an older photo makes it most recent; creation date does not determine eviction")
    func leastRecentlyOpenedEviction() {
        let a = photo("a", createdAt: 300)
        let b = photo("b", createdAt: 200)
        let c = photo("c", createdAt: 100)
        let metadata = ["a": size(4), "b": size(4), "c": size(4)]
        var accesses = ["a": date(1), "b": date(2), "c": date(3)]
        let original = selection([a, b, c], accesses, metadata, limit: 8)
        #expect(original.photos.map(\.fullImageAssetName) == ["c", "b"])
        accesses["a"] = date(4)
        let reopened = selection([a, b, c], accesses, metadata, limit: 8)
        #expect(reopened.photos.map(\.fullImageAssetName) == ["a", "c"])
        #expect(reopened.retainedAccessNames == ["a", "c"])
    }

    @Test("Live Photo resources are budgeted and evicted together, with shared still assets counted once")
    func wholeLivePhotoBudget() {
        let live = photo("live", liveImage: "live", video: "motion")
        let still = photo("still")
        let metadata = ["live": size(6), "motion": size(4), "still": size(1)]
        let accesses = ["live": date(2), "still": date(1)]
        let fits = selection([live, still], accesses, metadata, limit: 10)
        #expect(fits.photos.map(\.fullImageAssetName) == ["live"])
        #expect(fits.byteCount == 10)
        let tooSmall = selection([live, still], accesses, metadata, limit: 9)
        #expect(!tooSmall.photos.contains { $0.id == live.id })
        #expect(tooSmall.byteCount <= 9)
    }

    @Test("Explicitly kept hearts are protected outside the recent-photo budget")
    func heartedProtection() {
        let hearted = photo("hearted", video: "hearted-motion")
        let recent = photo("recent")
        let result = selection([hearted, recent], ["hearted": date(1), "recent": date(2)], ["recent": size(10)], limit: 10, protectedNames: hearted.assetNames)
        #expect(result.photos.count == 2)
        #expect(result.byteCount == 10)
        #expect(!result.hasUnknownSizes)
    }

    @Test("Unknown sizes remain eligible for retry; overflow cannot exceed the budget")
    func unknownSizesAndOverflow() {
        let unknown = photo("unknown")
        let enormous = photo("large", video: "motion")
        let result = selection([unknown, enormous], ["unknown": date(2), "large": date(1)], ["large": size(Int64.max), "motion": size(1)], limit: 100)
        #expect(result.photos.isEmpty)
        #expect(result.hasUnknownSizes)
        #expect(result.retainedAccessNames == ["unknown"])
        #expect(result.byteCount == 0)
        let partial = photo("partial", video: "not-yet-synced")
        let retained = selection([partial], ["partial": date(1)], ["partial": size(4)], limit: 5)
        #expect(retained.photos.map(\.fullImageAssetName) == ["partial"])
        #expect(retained.byteCount == 4)
        #expect(retained.hasUnknownSizes)
    }

    private func photo(_ name: String, createdAt: TimeInterval = 0, liveImage: String? = nil, video: String? = nil) -> PhotoOfflinePhoto {
        PhotoOfflinePhoto(id: UUID(), createdAt: date(createdAt), isHearted: false, isFavoriteLivePhoto: false, fullImageAssetName: name, livePhotoImageAssetName: liveImage, livePhotoVideoAssetName: video)
    }
    private func date(_ value: TimeInterval) -> Date { Date(timeIntervalSince1970: value) }
    private func size(_ bytes: Int64) -> PhotoAssetMetadata { PhotoAssetMetadata(byteCount: bytes, checksum: nil) }
    private func selection(_ photos: [PhotoOfflinePhoto], _ dates: [String: Date], _ metadata: [String: PhotoAssetMetadata], limit: Int64, protectedNames: Set<String> = []) -> PhotoRecentSelection {
        PhotoRecentSelection(photos: photos, accessDates: dates, metadata: metadata, limitBytes: limit, protectedNames: protectedNames)
    }
}
