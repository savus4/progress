#if DEBUG && targetEnvironment(simulator)
import CoreData
import UIKit

/// Fixed dates and locations for map UI tests, confined to the ephemeral library.
@MainActor
enum PhotoMapUITestLibrary {
    static func seedIfRequested(in context: NSManagedObjectContext) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["UI_TEST_IN_MEMORY_STORE"] == "1",
              let scenario = environment["UI_TEST_MAP_LEGEND_SCENARIO"] else { return }
        guard context.persistentStoreCoordinator?.persistentStores.first?.type == NSInMemoryStoreType else {
            throw CocoaError(.persistentStoreOperation)
        }

        let dates: [(year: Int, month: Int)]
        switch scenario {
        case "single-year": dates = [(2026, 1), (2026, 5), (2026, 10)]
        case "multiple-years": dates = [(2024, 8), (2025, 9), (2026, 10)]
        case "year-boundary": dates = [(2025, 12), (2026, 1), (2026, 2)]
        case "single-photo": dates = [(2026, 9)]
        default: throw CocoaError(.coderInvalidValue)
        }
        guard try context.count(for: DailyPhoto.fetchRequest()) == 0 else { return }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let locations = [
            (name: "Marienplatz", latitude: 48.1374, longitude: 11.5755),
            (name: "Frauenkirche", latitude: 48.1386, longitude: 11.5730),
            (name: "Viktualienmarkt", latitude: 48.1351, longitude: 11.5763)
        ]
        for (index, components) in dates.enumerated() {
            guard let date = calendar.date(from: DateComponents(
                year: components.year, month: components.month, day: 15, hour: 12
            )) else { throw CocoaError(.coderInvalidValue) }
            let imageData = try thumbnail(for: index)
            let photo = DailyPhoto(context: context)
            photo.id = UUID()
            photo.captureDate = date
            photo.createdAt = date
            photo.modifiedAt = date
            photo.thumbnailData = imageData
            photo.fullImageData = imageData
            photo.locationName = locations[index].name
            photo.latitude = locations[index].latitude
            photo.longitude = locations[index].longitude
        }
        try context.save()
    }

    private static func thumbnail(for index: Int) throws -> Data {
        let colors: [UIColor] = [.systemBlue, .systemOrange, .systemPink]
        let symbols = ["building.columns.fill", "building.2.fill", "building.fill"]
        let size = CGSize(width: 180, height: 180)
        let image = UIGraphicsImageRenderer(size: size).image { renderer in
            colors[index].setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            let symbol = UIImage(systemName: symbols[index])?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: 35, y: 35, width: 110, height: 110))
        }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
#endif
