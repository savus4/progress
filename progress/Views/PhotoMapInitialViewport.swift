import MapKit
import SwiftUI

enum PhotoMapInitialViewport {
    static func coordinates(
        in items: [PhotoRouteMapItem],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [CLLocationCoordinate2D] {
        let locatedItems = items.filter(\.hasLocation)
        let cutoff = calendar.date(byAdding: .month, value: -3, to: now) ?? now
        let recentItems = locatedItems.filter { item in
            guard let date = item.captureDate else { return false }
            return date >= cutoff && date <= now
        }
        if !recentItems.isEmpty { return recentItems.map(\.coordinate) }

        // With an older library, use its latest three months rather than
        // zooming out to every trip in the entire photo history.
        guard let latestDate = locatedItems.compactMap(\.captureDate).filter({ $0 <= now }).max() else {
            return locatedItems.map(\.coordinate)
        }
        let latestCutoff = calendar.date(byAdding: .month, value: -3, to: latestDate) ?? latestDate
        return locatedItems.filter { item in
            guard let date = item.captureDate else { return false }
            return date >= latestCutoff && date <= latestDate
        }.map(\.coordinate)
    }

    static func mapRect(
        containing coordinates: [CLLocationCoordinate2D],
        size: CGSize,
        insets: EdgeInsets
    ) -> MKMapRect? {
        guard size.width > 0, size.height > 0,
              let first = coordinates.first else { return nil }

        var bounds = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 1, height: 1))
        for coordinate in coordinates.dropFirst() {
            bounds = bounds.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 1, height: 1)))
        }
        bounds = bounds.insetBy(
            dx: -max(bounds.width * 0.12, 2400),
            dy: -max(bounds.height * 0.12, 2400)
        )

        // Keep useful map space even in short landscape or split-screen layouts.
        let top = min(insets.top, size.height * 0.3)
        let bottom = min(insets.bottom, size.height * 0.3)
        let leading = min(insets.leading, size.width * 0.2)
        let trailing = min(insets.trailing, size.width * 0.2)
        let availableWidth = size.width - leading - trailing
        let availableHeight = size.height - top - bottom
        let scale = max(bounds.width / availableWidth, bounds.height / availableHeight)

        // Match the actual viewport aspect ratio and center photos in its unobscured area.
        return MKMapRect(
            x: bounds.midX - (leading + availableWidth / 2) * scale,
            y: bounds.midY - (top + availableHeight / 2) * scale,
            width: size.width * scale,
            height: size.height * scale
        )
    }
}
