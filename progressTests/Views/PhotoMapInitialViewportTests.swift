import CoreData
import MapKit
import SwiftUI
import Testing
@testable import progress

@MainActor
struct PhotoMapInitialViewportTests {
    private let persistence = PersistenceController(inMemory: true)
    private let now = Date(timeIntervalSince1970: 1_791_460_800) // October 8, 2026, UTC.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    @Test("Initial overview includes all photos from three calendar months, including more than thirty")
    func threeMonthsWithoutCountLimit() throws {
        let cutoff = try #require(calendar.date(byAdding: .month, value: -3, to: now))
        let photos = (0..<45).map { index in
            item(date: now.addingTimeInterval(-Double(index) * 86_400), latitude: 48 + Double(index) / 100, longitude: 11)
        }
        let atCutoff = item(date: cutoff, latitude: 50, longitude: 12)
        let beforeCutoff = item(date: cutoff.addingTimeInterval(-1), latitude: -33, longitude: 151)
        let future = item(date: now.addingTimeInterval(1), latitude: 40, longitude: -74)
        let undated = item(date: nil, latitude: 35, longitude: 139)
        let result = PhotoMapInitialViewport.coordinates(
            in: photos + [atCutoff, beforeCutoff, future, undated], now: now, calendar: calendar
        )

        #expect(result.count == 46)
        #expect(result.contains { $0.latitude == atCutoff.latitude })
        #expect(result.allSatisfy { $0.longitude == 11 || $0.longitude == 12 })
    }

    @Test("Missing and invalid locations do not affect the initial overview")
    func invalidLocations() {
        let items = [
            item(date: now, latitude: 0, longitude: 0),
            item(date: now, latitude: 91, longitude: 11),
            item(date: now, latitude: 48, longitude: .nan),
            item(date: now, latitude: 0, longitude: 11)
        ]
        let result = PhotoMapInitialViewport.coordinates(in: items, now: now, calendar: calendar)
        #expect(result.count == 1)
        #expect(result.first?.longitude == 11)
    }

    @Test("Libraries with no recent photos fall back to their latest three months")
    func olderLibrary() {
        let old = item(date: now.addingTimeInterval(-200 * 86_400), latitude: 48, longitude: 11)
        let sameTrip = item(date: now.addingTimeInterval(-220 * 86_400), latitude: 49, longitude: 12)
        let olderTrip = item(date: now.addingTimeInterval(-400 * 86_400), latitude: 35, longitude: 139)
        let undated = item(date: nil, latitude: 50, longitude: 12)
        let result = PhotoMapInitialViewport.coordinates(in: [old, sameTrip, olderTrip, undated], now: now, calendar: calendar)
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.latitude == 48 || $0.latitude == 49 })
    }

    @Test("Undated libraries still show their locations")
    func undatedLibrary() {
        let undated = item(date: nil, latitude: 50, longitude: 12)
        let result = PhotoMapInitialViewport.coordinates(in: [undated], now: now, calendar: calendar)
        #expect(result.count == 1)
        #expect(result.first?.latitude == 50)
    }

    @Test("Wide and tall routes fit clear of controls on small phones, landscape, and tablets", arguments: [
        CGSize(width: 320, height: 568),
        CGSize(width: 402, height: 874),
        CGSize(width: 874, height: 402),
        CGSize(width: 768, height: 1024),
        CGSize(width: 1024, height: 768)
    ], [
        [CLLocationCoordinate2D(latitude: 48, longitude: 2), CLLocationCoordinate2D(latitude: 49, longitude: 16)],
        [CLLocationCoordinate2D(latitude: 38, longitude: 11), CLLocationCoordinate2D(latitude: 55, longitude: 12)]
    ])
    func fitsViewport(size: CGSize, coordinates: [CLLocationCoordinate2D]) throws {
        let insets = EdgeInsets(top: 150, leading: 56, bottom: 142, trailing: 56)
        let rect = try #require(PhotoMapInitialViewport.mapRect(containing: coordinates, size: size, insets: insets))
        #expect(abs(rect.width / rect.height - size.width / size.height) < 0.000_001)
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            let x = (point.x - rect.minX) / rect.width * size.width
            let y = (point.y - rect.minY) / rect.height * size.height
            #expect(x > insets.leading)
            #expect(x < size.width - insets.trailing)
            #expect(y > min(insets.top, size.height * 0.3))
            #expect(y < size.height - min(insets.bottom, size.height * 0.3))
        }
    }

    @Test("A single photo gets neighborhood context rather than a zero-sized region")
    func singleLocation() throws {
        let rect = try #require(PhotoMapInitialViewport.mapRect(
            containing: [CLLocationCoordinate2D(latitude: 48, longitude: 11)],
            size: CGSize(width: 402, height: 874),
            insets: EdgeInsets(top: 150, leading: 56, bottom: 142, trailing: 56)
        ))
        #expect(rect.width >= 4800)
        #expect(rect.height >= 4800)
    }

    @Test("Empty data and unfinished layout do not produce a camera position")
    func emptyViewport() {
        #expect(PhotoMapInitialViewport.mapRect(containing: [], size: CGSize(width: 402, height: 874), insets: EdgeInsets()) == nil)
        #expect(PhotoMapInitialViewport.mapRect(
            containing: [CLLocationCoordinate2D(latitude: 48, longitude: 11)], size: .zero, insets: EdgeInsets()
        ) == nil)
    }

    private func item(date: Date?, latitude: Double, longitude: Double) -> PhotoRouteMapItem {
        let photo = DailyPhoto(context: persistence.container.viewContext)
        photo.captureDate = date
        photo.latitude = latitude
        photo.longitude = longitude
        return PhotoRouteMapItem(gridItem: UIKitPhotoGridItem(photo: photo))
    }
}
