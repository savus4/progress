import SwiftUI
import CoreData
import CoreLocation
import MapKit
import UIKit

struct PhotoRouteMapItem: Identifiable, Equatable {
    let objectID: NSManagedObjectID
    let fullImageAssetName: String?
    let captureDate: Date?
    let locationName: String?
    let latitude: Double
    let longitude: Double

    var id: NSManagedObjectID { objectID }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var hasLocation: Bool {
        latitude != 0 || longitude != 0
    }

    nonisolated init(gridItem: UIKitPhotoGridItem) {
        objectID = gridItem.objectID
        fullImageAssetName = gridItem.fullImageAssetName ?? gridItem.livePhotoImageAssetName
        captureDate = gridItem.captureDate
        locationName = gridItem.locationName
        latitude = gridItem.latitude
        longitude = gridItem.longitude
    }
}

struct PhotoRouteMapView: View {
    let gridItems: [UIKitPhotoGridItem]
    let changeToken: Int
    @Binding var isClusterOverlayPresented: Bool
    let onOpenPhoto: (NSManagedObjectID) -> Void

    @Namespace private var mapScope
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var didSetInitialCamera = false
    @State private var clusterPresentation: PhotoMapClusterPresentation?
    @State private var annotationAnimationToken = 0
    @State private var renderedAnnotations: [PhotoMapRenderedAnnotation] = []
    @State private var mapHeading: Double = 0
    @State private var latestMapCamera: MapCamera?
    @State private var mapItems: [PhotoRouteMapItem] = []
    @State private var didBuildMapItems = false
    @State private var renderedClusterCellMapPointSize: Double?

    private let thumbnailCellSize: CGFloat = 76
    private let clusterCellSize: CGFloat = 48
    private let maxThumbnailAnnotations = 80

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                mapContent(size: proxy.size)

                if didBuildMapItems, mapItems.isEmpty {
                    noLocationsView
                        .padding(.horizontal, 24)
                }

                if let clusterPresentation {
                    PhotoMapClusterGridOverlay(
                        presentation: clusterPresentation,
                        onOpenPhoto: onOpenPhoto,
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                self.clusterPresentation = nil
                                isClusterOverlayPresented = false
                            }
                        }
                    )
                    .padding(.horizontal, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if didBuildMapItems, !mapItems.isEmpty {
                    mapControlsOverlay(topInset: proxy.safeAreaInsets.top)
                }
            }
        }
        .background(Color.black)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
    }

    @ViewBuilder
    private func mapContent(size: CGSize) -> some View {
        Map(position: $cameraPosition, interactionModes: [.pan, .zoom, .rotate, .pitch], scope: mapScope) {
            ForEach(renderedAnnotations) { renderedAnnotation in
                let annotation = renderedAnnotation.annotation
                Annotation("", coordinate: annotation.coordinate) {
                    PhotoMapAnnotationView(
                        item: annotation.primaryItem,
                        color: annotation.color,
                        aggregatePalette: annotation.aggregatePalette,
                        displayMode: annotation.displayMode,
                        count: annotation.items.count,
                        animationToken: annotationAnimationToken,
                        isVisible: renderedAnnotation.isVisible
                    )
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
                    .contentShape(Rectangle())
                    .allowsHitTesting(renderedAnnotation.isVisible)
                    .highPriorityGesture(
                        TapGesture().onEnded {
                            handleAnnotationTap(annotation)
                        }
                    )
                    .accessibilityLabel(annotationAccessibilityLabel(for: annotation))
                }
            }
        }
        .mapScope(mapScope)
        .mapStyle(.standard(elevation: .realistic))
        .mapControlVisibility(.hidden)
        .onMapCameraChange(frequency: .continuous) { context in
            updateMapHeading(context.camera.heading)
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            updateMapHeading(context.camera.heading)
            latestMapCamera = context.camera
            let nextClusterCellSize = clusterCellMapPointSize(region: context.region, viewSize: size)
            let shouldAnimateClusterChange = renderedClusterCellMapPointSize.map {
                abs(log2(nextClusterCellSize / max($0, 1))) > 0.001
            } ?? false
            renderedClusterCellMapPointSize = nextClusterCellSize
            updateRenderedAnnotations(size: size, region: context.region, animated: shouldAnimateClusterChange)
        }
        .onAppear {
            rebuildMapItemsIfNeeded()
            setInitialCameraIfNeeded(size: size)
        }
        .onChange(of: changeToken) { _, _ in
            rebuildMapItems()
            didSetInitialCamera = false
            clusterPresentation = nil
            isClusterOverlayPresented = false
            setInitialCameraIfNeeded(size: size)
        }
    }

    private func mapControlsOverlay(topInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ageLegend
            if shouldShowCompass {
                PhotoMapHeadingCompass(
                    heading: mapHeading,
                    onReset: resetMapHeading
                )
                .transition(.scale(scale: 0.82).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: shouldShowCompass)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, topInset + 62)
        .padding(.leading, 16)
    }

    private var shouldShowCompass: Bool {
        abs(normalizedHeading(mapHeading)) > 1
    }

    private var ageLegend: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: Self.timelineColorStops.map { Color(uiColor: $0) },
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 104, height: 8)

            HStack(spacing: 0) {
                ForEach(Array(legendYearLabels.enumerated()), id: \.offset) { _, year in
                    Text(year)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        .frame(width: 126)
        .accessibilityLabel("Photo age legend")
    }

    private var noLocationsView: some View {
        VStack(spacing: 14) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("No locations for this filter.")
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier("routeMapNoLocations")
    }

    private func annotationItems(size: CGSize, region activeRegionOverride: MKCoordinateRegion? = nil) -> [PhotoMapAnnotationItem] {
        guard !mapItems.isEmpty else { return [] }

        let activeRegion = activeRegionOverride ?? visibleRegion ?? initialCameraRegion()
        let visibleItems = activeRegion.map { region in
            mapItems.filter { region.contains($0.coordinate, latitudePadding: 0.18, longitudePadding: 0.18) }
        } ?? mapItems
        let indexByObjectID = Dictionary(uniqueKeysWithValues: mapItems.enumerated().map { ($0.element.objectID, $0.offset) })

        guard size.width > 0,
              size.height > 0,
              let region = activeRegion,
              region.span.latitudeDelta > 0,
              region.span.longitudeDelta > 0 else {
            return visibleItems.map { item in
                let index = indexByObjectID[item.objectID] ?? 0
                return PhotoMapAnnotationItem(
                    items: [item],
                    itemIndex: index,
                    coordinate: item.coordinate,
                    color: routeColor(forPhotoAt: index),
                    aggregatePalette: .empty,
                    displayMode: .dot,
                    screenPoint: .zero
                )
            }
        }

        var clustersByCell: [PhotoMapCellKey: [PhotoRouteMapItem]] = [:]
        let cellMapPointSize = clusterCellMapPointSize(region: region, viewSize: size)
        for item in visibleItems {
            let mapPoint = MKMapPoint(item.coordinate)
            let cell = PhotoMapCellKey(
                x: Int((mapPoint.x / cellMapPointSize).rounded(.down)),
                y: Int((mapPoint.y / cellMapPointSize).rounded(.down))
            )
            clustersByCell[cell, default: []].append(item)
        }

        var annotations = clustersByCell.values.map { clusterItems in
            annotation(for: clusterItems, indexByObjectID: indexByObjectID, region: region, size: size)
        }

        let singleAnnotationIDs = Set(annotations.filter { $0.items.count == 1 }.map(\.id))
        var thumbnailAnnotationIDs: Set<String> = []

        for annotation in annotations
            .filter({ $0.items.count == 1 })
            .sorted(by: { lhs, rhs in
                switch (lhs.primaryItem.captureDate, rhs.primaryItem.captureDate) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate > rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.primaryItem.objectID.uriRepresentation().absoluteString > rhs.primaryItem.objectID.uriRepresentation().absoluteString
                }
            }) {
            guard thumbnailAnnotationIDs.count < maxThumbnailAnnotations else { break }
            let hasNearbyAnnotation = annotations.contains { other in
                guard other.id != annotation.id else { return false }
                let minimumDistance = singleAnnotationIDs.contains(other.id) ? thumbnailCellSize : thumbnailCellSize * 0.82
                return annotation.screenPoint.distance(to: other.screenPoint) < minimumDistance
            }
            guard !hasNearbyAnnotation else { continue }
            thumbnailAnnotationIDs.insert(annotation.id)
        }

        annotations = annotations.map { annotation in
            guard annotation.items.count == 1,
                  thumbnailAnnotationIDs.contains(annotation.id) else {
                return annotation
            }
            return annotation.withDisplayMode(.thumbnail)
        }

        return annotations.sorted { lhs, rhs in
            if lhs.items.count != rhs.items.count {
                return lhs.items.count < rhs.items.count
            }
            return lhs.itemIndex < rhs.itemIndex
        }
    }

    private func annotation(
        for items: [PhotoRouteMapItem],
        indexByObjectID: [NSManagedObjectID: Int],
        region: MKCoordinateRegion,
        size: CGSize
    ) -> PhotoMapAnnotationItem {
        let primaryItem = items.max { lhs, rhs in
            switch (lhs.captureDate, rhs.captureDate) {
            case let (lhsDate?, rhsDate?):
                return lhsDate < rhsDate
            case (nil, _?):
                return true
            case (_?, nil):
                return false
            case (nil, nil):
                return lhs.objectID.uriRepresentation().absoluteString < rhs.objectID.uriRepresentation().absoluteString
            }
        } ?? items[0]
        let averageLatitude = items.reduce(0) { $0 + $1.latitude } / Double(items.count)
        let averageLongitude = items.reduce(0) { $0 + $1.longitude } / Double(items.count)
        let averageIndex = Int(
            (items.reduce(0) { partialResult, item in
                partialResult + (indexByObjectID[item.objectID] ?? 0)
            } / max(items.count, 1))
        )
        let coordinate = items.count == 1
            ? primaryItem.coordinate
            : CLLocationCoordinate2D(latitude: averageLatitude, longitude: averageLongitude)

        return PhotoMapAnnotationItem(
            items: items,
            itemIndex: averageIndex,
            coordinate: coordinate,
            color: routeColor(forPhotoAt: averageIndex),
            aggregatePalette: aggregatePalette(for: items, indexByObjectID: indexByObjectID),
            displayMode: items.count > 1 ? .aggregate : .dot,
            screenPoint: screenPoint(for: coordinate, in: region, size: size)
        )
    }

    private func screenPoint(
        for coordinate: CLLocationCoordinate2D,
        in region: MKCoordinateRegion,
        size: CGSize
    ) -> CGPoint {
        let topLatitude = region.center.latitude + (region.span.latitudeDelta / 2)
        let leftLongitude = region.center.longitude - (region.span.longitudeDelta / 2)
        return CGPoint(
            x: ((coordinate.longitude - leftLongitude) / region.span.longitudeDelta) * size.width,
            y: ((topLatitude - coordinate.latitude) / region.span.latitudeDelta) * size.height
        )
    }

    private func handleAnnotationTap(_ annotation: PhotoMapAnnotationItem) {
        if annotation.items.count == 1 {
            onOpenPhoto(annotation.primaryItem.objectID)
        } else if shouldOpenClusterGrid(annotation) {
            showClusterGrid(for: annotation)
        } else {
            let region = zoomRegion(for: annotation)
            withAnimation(.easeInOut(duration: 0.28)) {
                cameraPosition = .camera(camera(for: region, heading: mapHeading))
            }
            visibleRegion = region
        }
    }

    private func shouldOpenClusterGrid(_ annotation: PhotoMapAnnotationItem) -> Bool {
        guard annotation.items.count > 1 else { return false }
        guard !annotation.hasSingleCoordinate else { return true }
        guard let visibleRegion else { return false }

        let targetRegion = zoomRegion(for: annotation)
        let latitudeReduction = targetRegion.span.latitudeDelta / max(visibleRegion.span.latitudeDelta, 0.000_001)
        let longitudeReduction = targetRegion.span.longitudeDelta / max(visibleRegion.span.longitudeDelta, 0.000_001)
        return max(latitudeReduction, longitudeReduction) > 0.72
    }

    private func showClusterGrid(for annotation: PhotoMapAnnotationItem) {
        let items = annotation.items
            .sorted { lhs, rhs in
                switch (lhs.captureDate, rhs.captureDate) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate > rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.objectID.uriRepresentation().absoluteString > rhs.objectID.uriRepresentation().absoluteString
                }
            }
            .map { item in
                PhotoMapClusterGridItem(
                    item: item,
                    color: routeColor(forPhotoAt: mapItems.firstIndex(where: { $0.objectID == item.objectID }) ?? 0)
                )
            }

        withAnimation(.easeInOut(duration: 0.18)) {
            clusterPresentation = PhotoMapClusterPresentation(items: items)
            isClusterOverlayPresented = true
        }
    }

    private func clusterCellMapPointSize(region: MKCoordinateRegion, viewSize: CGSize) -> Double {
        let normalizedLongitudeDelta = min(max(region.span.longitudeDelta, 0.000_001), 360)
        let visibleMapPointWidth = MKMapSize.world.width * (normalizedLongitudeDelta / 360)
        let rawCellMapPointSize = visibleMapPointWidth / max(viewSize.width, 1) * clusterCellSize
        let quantizedExponent = (log2(max(rawCellMapPointSize, 1)) * 4).rounded(.down) / 4
        return max(pow(2, quantizedExponent), 1)
    }

    private func mapRect(for region: MKCoordinateRegion) -> MKMapRect {
        let northWest = CLLocationCoordinate2D(
            latitude: region.center.latitude + (region.span.latitudeDelta / 2),
            longitude: region.center.longitude - (region.span.longitudeDelta / 2)
        )
        let southEast = CLLocationCoordinate2D(
            latitude: region.center.latitude - (region.span.latitudeDelta / 2),
            longitude: region.center.longitude + (region.span.longitudeDelta / 2)
        )
        let pointA = MKMapPoint(northWest)
        let pointB = MKMapPoint(southEast)

        return MKMapRect(
            x: min(pointA.x, pointB.x),
            y: min(pointA.y, pointB.y),
            width: max(abs(pointA.x - pointB.x), 1),
            height: max(abs(pointA.y - pointB.y), 1)
        )
    }

    private func aggregateRegionPadding(for count: Int) -> Double {
        min(max(Double(count).squareRoot() * 0.018, 0.08), 0.22)
    }

    private func zoomRegion(for annotation: PhotoMapAnnotationItem) -> MKCoordinateRegion {
        let padding = aggregateRegionPadding(for: annotation.items.count)
        return region(
            containing: annotation.items.map(\.coordinate),
            paddingFraction: padding,
            minimumMapPointPadding: 1800
        )
    }

    private func annotationAccessibilityLabel(for annotation: PhotoMapAnnotationItem) -> String {
        if annotation.items.count > 1 {
            return "\(annotation.items.count) photos"
        }
        guard let date = annotation.primaryItem.captureDate else { return "Photo location" }
        return "Photo from \(Self.accessibilityDateFormatter.string(from: date))"
    }

    private func region(
        containing coordinates: [CLLocationCoordinate2D],
        paddingFraction: Double = 0.22,
        minimumMapPointPadding: Double = 2400
    ) -> MKCoordinateRegion {
        guard let firstCoordinate = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 120)
            )
        }

        var mapRect = MKMapRect(origin: MKMapPoint(firstCoordinate), size: MKMapSize(width: 1, height: 1))
        for coordinate in coordinates.dropFirst() {
            mapRect = mapRect.union(
                MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 1, height: 1))
            )
        }

        let paddedMapRect = mapRect.insetBy(
            dx: -max(mapRect.width * paddingFraction, minimumMapPointPadding),
            dy: -max(mapRect.height * paddingFraction, minimumMapPointPadding)
        )
        return MKCoordinateRegion(paddedMapRect)
    }

    private func routeColor(forPhotoAt index: Int) -> Color {
        let progress = Double(index) / Double(max(mapItems.count - 1, 1))
        return Self.timelineColorStops.interpolatedColor(at: progress)
    }

    private func rebuildMapItemsIfNeeded() {
        guard !didBuildMapItems else { return }
        rebuildMapItems()
    }

    private func rebuildMapItems() {
        didBuildMapItems = true
        mapItems = gridItems
            .map(PhotoRouteMapItem.init(gridItem:))
            .filter(\.hasLocation)
            .sorted { lhs, rhs in
                switch (lhs.captureDate, rhs.captureDate) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate < rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.objectID.uriRepresentation().absoluteString < rhs.objectID.uriRepresentation().absoluteString
                }
            }
    }

    private func updateMapHeading(_ heading: Double) {
        let normalizedNewHeading = normalizedHeading(heading)
        guard abs(normalizedHeading(mapHeading) - normalizedNewHeading) > 0.5 else { return }
        mapHeading = heading
    }

    private func aggregatePalette(
        for items: [PhotoRouteMapItem],
        indexByObjectID: [NSManagedObjectID: Int]
    ) -> PhotoMapAggregatePalette {
        guard items.count > 1 else {
            return .empty
        }

        var oldWeight = 0.0
        var middleWeight = 0.0
        var newWeight = 0.0
        for item in items {
            let index = indexByObjectID[item.objectID] ?? 0
            let progress = Double(index) / Double(max(mapItems.count - 1, 1))
            switch progress {
            case ..<0.34:
                oldWeight += 1
            case ..<0.67:
                middleWeight += 1
            default:
                newWeight += 1
            }
        }

        let total = max(oldWeight + middleWeight + newWeight, 1)
        return PhotoMapAggregatePalette(
            old: oldWeight / total,
            middle: middleWeight / total,
            new: newWeight / total
        )
    }

    private func camera(for region: MKCoordinateRegion, heading: Double) -> MapCamera {
        let latitudeMeters = region.span.latitudeDelta * 111_000
        let longitudeMeters = region.span.longitudeDelta *
            111_000 *
            max(cos(region.center.latitude * .pi / 180), 0.2)
        let distance = max(max(latitudeMeters, longitudeMeters) * 1.25, 500)

        return MapCamera(
            centerCoordinate: region.center,
            distance: distance,
            heading: heading,
            pitch: latestMapCamera?.pitch ?? 0
        )
    }

    private func resetMapHeading() {
        let camera = latestMapCamera ?? MapCamera(
            centerCoordinate: visibleRegion?.center ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
            distance: 1_000,
            heading: mapHeading,
            pitch: 0
        )
        withAnimation(.easeInOut(duration: 0.24)) {
            cameraPosition = .camera(
                MapCamera(
                    centerCoordinate: camera.centerCoordinate,
                    distance: camera.distance,
                    heading: 0,
                    pitch: camera.pitch
                )
            )
            mapHeading = 0
        }
    }

    private func normalizedHeading(_ heading: Double) -> Double {
        let normalized = heading.truncatingRemainder(dividingBy: 360)
        if normalized > 180 {
            return normalized - 360
        }
        if normalized < -180 {
            return normalized + 360
        }
        return normalized
    }

    private var legendYearLabels: [String] {
        let datedItems = mapItems.filter { $0.captureDate != nil }
        guard !datedItems.isEmpty else { return ["--", "--", "--"] }

        let indices = [
            0,
            max((datedItems.count - 1) / 2, 0),
            max(datedItems.count - 1, 0)
        ]
        return indices.map { index in
            guard datedItems.indices.contains(index),
                  let date = datedItems[index].captureDate else {
                return "--"
            }
            return Self.twoDigitYearFormatter.string(from: date)
        }
    }

    private static let timelineAgeStops: [(label: String, color: UIColor)] = [
        ("Old", UIColor(red: 0.10, green: 0.43, blue: 0.95, alpha: 1.00)),
        ("Mid", UIColor(red: 0.96, green: 0.68, blue: 0.12, alpha: 1.00)),
        ("New", UIColor(red: 0.93, green: 0.16, blue: 0.36, alpha: 1.00))
    ]

    private static var timelineColorStops: [UIColor] {
        timelineAgeStops.map(\.color)
    }

    private func setInitialCameraIfNeeded(size: CGSize) {
        guard !didSetInitialCamera else { return }
        guard !mapItems.isEmpty else {
            cameraPosition = .automatic
            visibleRegion = nil
            renderedAnnotations = []
            renderedClusterCellMapPointSize = nil
            return
        }

        didSetInitialCamera = true
        guard let region = initialCameraRegion() else { return }
        visibleRegion = region
        renderedClusterCellMapPointSize = clusterCellMapPointSize(region: region, viewSize: size)
        cameraPosition = .camera(camera(for: region, heading: mapHeading))
        updateRenderedAnnotations(size: size, region: region, animated: false)
    }

    private func updateRenderedAnnotations(size: CGSize, region: MKCoordinateRegion?, animated: Bool) {
        let nextAnnotations = annotationItems(size: size, region: region)
        let nextIDs = Set(nextAnnotations.map(\.id))
        let previousExitingAnnotations = renderedAnnotations.filter { renderedAnnotation in
            !nextIDs.contains(renderedAnnotation.id) && renderedAnnotation.isVisible
        }
        let nextRenderedAnnotations = nextAnnotations.map {
            PhotoMapRenderedAnnotation(annotation: $0, isVisible: true)
        }
        let exitingRenderedAnnotations = animated
            ? previousExitingAnnotations.map {
                PhotoMapRenderedAnnotation(annotation: $0.annotation, isVisible: false)
            }
            : []

        let applyUpdate = {
            renderedAnnotations = nextRenderedAnnotations + exitingRenderedAnnotations
            if animated {
                annotationAnimationToken += 1
            }
        }

        if animated {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                applyUpdate()
            }

            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                let visibleIDs = Set(renderedAnnotations.filter(\.isVisible).map(\.id))
                renderedAnnotations.removeAll { renderedAnnotation in
                    !renderedAnnotation.isVisible && !visibleIDs.contains(renderedAnnotation.id)
                }
            }
        } else {
            applyUpdate()
        }
    }

    private func initialCameraRegion() -> MKCoordinateRegion? {
        let recentItems = mapItems
            .sorted { lhs, rhs in
                switch (lhs.captureDate, rhs.captureDate) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate > rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.objectID.uriRepresentation().absoluteString > rhs.objectID.uriRepresentation().absoluteString
                }
            }
            .prefix(30)
        guard !recentItems.isEmpty else { return nil }
        return region(containing: recentItems.map(\.coordinate))
    }

    private static let accessibilityDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let twoDigitYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yy"
        return formatter
    }()
}

private struct PhotoMapAnnotationItem: Identifiable {
    let items: [PhotoRouteMapItem]
    let itemIndex: Int
    let coordinate: CLLocationCoordinate2D
    let color: Color
    let aggregatePalette: PhotoMapAggregatePalette
    let displayMode: PhotoMapAnnotationDisplayMode
    let screenPoint: CGPoint

    var id: String {
        "\(primaryItem.objectID.uriRepresentation().absoluteString)-\(items.count)-\(displayMode.rawValue)"
    }

    var primaryItem: PhotoRouteMapItem {
        items.max { lhs, rhs in
            switch (lhs.captureDate, rhs.captureDate) {
            case let (lhsDate?, rhsDate?):
                return lhsDate < rhsDate
            case (nil, _?):
                return true
            case (_?, nil):
                return false
            case (nil, nil):
                return lhs.objectID.uriRepresentation().absoluteString < rhs.objectID.uriRepresentation().absoluteString
            }
        } ?? items[0]
    }

    var hasSingleCoordinate: Bool {
        guard let firstCoordinate = items.first?.coordinate else { return true }
        return items.allSatisfy { item in
            abs(item.latitude - firstCoordinate.latitude) < 0.000_001 &&
                abs(item.longitude - firstCoordinate.longitude) < 0.000_001
        }
    }

    func withDisplayMode(_ displayMode: PhotoMapAnnotationDisplayMode) -> PhotoMapAnnotationItem {
        PhotoMapAnnotationItem(
            items: items,
            itemIndex: itemIndex,
            coordinate: coordinate,
            color: color,
            aggregatePalette: aggregatePalette,
            displayMode: displayMode,
            screenPoint: screenPoint
        )
    }
}

private struct PhotoMapAggregatePalette {
    let old: Double
    let middle: Double
    let new: Double

    static var empty: PhotoMapAggregatePalette {
        PhotoMapAggregatePalette(old: 0, middle: 0, new: 0)
    }

    var blendedColor: Color {
        let total = max(old + middle + new, 0.000_001)
        let oldShare = old / total
        let middleShare = middle / total
        let newShare = new / total

        return Color(
            red: (0.10 * oldShare) + (0.96 * middleShare) + (0.93 * newShare),
            green: (0.43 * oldShare) + (0.68 * middleShare) + (0.16 * newShare),
            blue: (0.95 * oldShare) + (0.12 * middleShare) + (0.36 * newShare)
        )
    }

    var angularGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: angularStops),
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }

    private var angularStops: [Gradient.Stop] {
        let components = [
            (share: old, color: Self.oldColor),
            (share: middle, color: Self.middleColor),
            (share: new, color: Self.newColor)
        ].filter { $0.share > 0.000_001 }

        guard let first = components.first else {
            return [
                Gradient.Stop(color: Self.oldColor, location: 0),
                Gradient.Stop(color: Self.oldColor, location: 1)
            ]
        }

        guard components.count > 1 else {
            return [
                Gradient.Stop(color: first.color, location: 0),
                Gradient.Stop(color: first.color, location: 1)
            ]
        }

        let total = components.reduce(0) { $0 + $1.share }
        let minimumShare = components.map { $0.share / total }.min() ?? 1
        let blendWidth = min(0.10, minimumShare * 0.70)

        var stops = [Gradient.Stop(color: first.color, location: 0)]
        var cursor = 0.0
        for index in components.indices {
            let component = components[index]
            let nextColor = components[(index + 1) % components.count].color
            cursor += component.share / total

            if index == components.indices.last {
                stops.append(Gradient.Stop(color: component.color, location: max(1 - blendWidth, 0)))
                stops.append(Gradient.Stop(color: first.color, location: 1))
            } else {
                stops.append(Gradient.Stop(color: component.color, location: max(cursor - blendWidth, 0)))
                stops.append(Gradient.Stop(color: nextColor, location: min(cursor + blendWidth, 1)))
            }
        }

        return stops.sorted { $0.location < $1.location }
    }

    private static let oldColor = Color(red: 0.10, green: 0.43, blue: 0.95)
    private static let middleColor = Color(red: 0.96, green: 0.68, blue: 0.12)
    private static let newColor = Color(red: 0.93, green: 0.16, blue: 0.36)
}

private struct PhotoMapRenderedAnnotation: Identifiable {
    let annotation: PhotoMapAnnotationItem
    let isVisible: Bool

    var id: String {
        annotation.id
    }
}

private enum PhotoMapAnnotationDisplayMode: String {
    case dot
    case thumbnail
    case aggregate
}

private struct PhotoMapCellKey: Hashable {
    let x: Int
    let y: Int
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

private extension Array where Element == UIColor {
    func interpolatedColor(at progress: Double) -> Color {
        guard let first else { return .blue }
        guard count > 1 else { return Color(uiColor: first) }

        let clampedProgress = Swift.min(Swift.max(progress, 0), 1)
        let scaledProgress = clampedProgress * Double(count - 1)
        let lowerIndex = Swift.min(Swift.max(Int(floor(scaledProgress)), 0), count - 2)
        let upperIndex = lowerIndex + 1
        let localProgress = CGFloat(scaledProgress - Double(lowerIndex))

        return Color(uiColor: self[lowerIndex].interpolated(to: self[upperIndex], progress: localProgress))
    }
}

private extension UIColor {
    func interpolated(to endColor: UIColor, progress: CGFloat) -> UIColor {
        var startRed: CGFloat = 0
        var startGreen: CGFloat = 0
        var startBlue: CGFloat = 0
        var startAlpha: CGFloat = 0
        var endRed: CGFloat = 0
        var endGreen: CGFloat = 0
        var endBlue: CGFloat = 0
        var endAlpha: CGFloat = 0

        getRed(&startRed, green: &startGreen, blue: &startBlue, alpha: &startAlpha)
        endColor.getRed(&endRed, green: &endGreen, blue: &endBlue, alpha: &endAlpha)

        return UIColor(
            red: startRed + ((endRed - startRed) * progress),
            green: startGreen + ((endGreen - startGreen) * progress),
            blue: startBlue + ((endBlue - startBlue) * progress),
            alpha: startAlpha + ((endAlpha - startAlpha) * progress)
        )
    }
}

private extension Set where Element == PhotoMapCellKey {
    func containsNeighbor(of cell: PhotoMapCellKey) -> Bool {
        for x in (cell.x - 1)...(cell.x + 1) {
            for y in (cell.y - 1)...(cell.y + 1) {
                if contains(PhotoMapCellKey(x: x, y: y)) {
                    return true
                }
            }
        }
        return false
    }
}

private struct PhotoMapClusterPresentation: Identifiable {
    let id = UUID()
    let items: [PhotoMapClusterGridItem]
}

private struct PhotoMapClusterGridItem: Identifiable {
    let item: PhotoRouteMapItem
    let color: Color

    var id: NSManagedObjectID {
        item.objectID
    }
}

private struct PhotoMapClusterGridOverlay: View {
    let presentation: PhotoMapClusterPresentation
    let onOpenPhoto: (NSManagedObjectID) -> Void
    let onDismiss: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 84, maximum: 96), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("\(presentation.items.count) Photos")
                    .font(.headline.weight(.semibold))

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Photo Cluster")
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(presentation.items) { gridItem in
                        PhotoMapClusterGridCell(gridItem: gridItem)
                            .onTapGesture {
                                onDismiss()
                                onOpenPhoto(gridItem.item.objectID)
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 430)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 10)
        .frame(maxWidth: 580)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }
}

private struct PhotoMapClusterGridCell: View {
    let gridItem: PhotoMapClusterGridItem

    @State private var thumbnailImage: UIImage?

    private static let thumbnailDataProvider = PhotoThumbnailDataProvider()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.black.opacity(0.18))

            if let thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .frame(width: 80, height: 80)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(gridItem.color, lineWidth: 3)
        }
        .padding(2)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: gridItem.id) {
            await loadThumbnail()
        }
    }

    @MainActor
    private func loadThumbnail() async {
        if let cachedImage = DecodedThumbnailCache.shared.cachedImage(for: gridItem.item.objectID) {
            thumbnailImage = cachedImage
            return
        }

        let thumbnailData = await Self.thumbnailDataProvider.thumbnailData(for: gridItem.item.objectID)
        guard !Task.isCancelled else { return }
        thumbnailImage = await DecodedThumbnailCache.shared.image(for: gridItem.item.objectID, data: thumbnailData)
    }
}

private struct PhotoMapHeadingCompass: View {
    let heading: Double
    let onReset: () -> Void

    var body: some View {
        Button(action: onReset) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.24), .white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .stroke(.white.opacity(0.34), lineWidth: 1)

                Circle()
                    .stroke(.black.opacity(0.08), lineWidth: 0.5)
                    .padding(5)

                Image(systemName: "location.north.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.red, Color(red: 0.86, green: 0.05, blue: 0.16)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .rotationEffect(.degrees(-heading))

                Text("N")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                    .offset(y: -16)
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .accessibilityLabel("Map compass")
        .accessibilityValue("\(Int(heading.rounded())) degrees")
        .accessibilityHint("Resets map rotation to north")
    }
}

private struct PhotoMapAnnotationView: View {
    let item: PhotoRouteMapItem
    let color: Color
    let aggregatePalette: PhotoMapAggregatePalette
    let displayMode: PhotoMapAnnotationDisplayMode
    let count: Int
    let animationToken: Int
    let isVisible: Bool

    @State private var thumbnailImage: UIImage?
    @State private var hasAppeared = false

    private static let thumbnailDataProvider = PhotoThumbnailDataProvider()

    var body: some View {
        Group {
            switch displayMode {
            case .dot:
                dotView
            case .thumbnail:
                thumbnailView
            case .aggregate:
                aggregateView
            }
        }
        .scaleEffect(hasAppeared && isVisible ? 1 : 0.72)
        .opacity(hasAppeared && isVisible ? 1 : 0)
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: hasAppeared)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isVisible)
        .onAppear {
            hasAppeared = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(18))
                hasAppeared = true
            }
        }
        .onChange(of: displayMode) { _, _ in
            bounceIn()
        }
        .onChange(of: count) { _, _ in
            bounceIn()
        }
        .onChange(of: animationToken) { _, _ in
            bounceIn()
        }
        .task(id: displayMode == .thumbnail ? item.objectID : nil) {
            await loadThumbnailIfNeeded()
        }
    }

    private func bounceIn() {
        hasAppeared = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(18))
            hasAppeared = true
        }
    }

    private var dotView: some View {
        Circle()
            .fill(color)
            .frame(width: 16, height: 16)
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.95), lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
            .frame(width: 44, height: 44)
    }

    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.regularMaterial)

            if let thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
            }
        }
        .frame(width: 62, height: 62)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(color, lineWidth: 3)
        }
        .shadow(color: .black.opacity(0.25), radius: 7, y: 3)
    }

    private var aggregateView: some View {
        let diameter = min(24 + (log(Double(max(count, 1))) * 9), 66)

        return ZStack {
            Circle()
                .fill(aggregatePalette.angularGradient)

            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: diameter * 0.44, height: diameter * 0.44)
                .offset(x: -diameter * 0.12, y: -diameter * 0.16)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(.white.opacity(0.95), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
        .frame(width: max(diameter, 48), height: max(diameter, 48))
    }

    @MainActor
    private func loadThumbnailIfNeeded() async {
        guard displayMode == .thumbnail else {
            thumbnailImage = nil
            return
        }

        if let cachedImage = DecodedThumbnailCache.shared.cachedImage(for: item.objectID) {
            thumbnailImage = cachedImage
            return
        }

        let thumbnailData = await Self.thumbnailDataProvider.thumbnailData(for: item.objectID)
        guard !Task.isCancelled else { return }
        thumbnailImage = await DecodedThumbnailCache.shared.image(for: item.objectID, data: thumbnailData)
    }
}

private extension MKCoordinateRegion {
    func contains(
        _ coordinate: CLLocationCoordinate2D,
        latitudePadding: Double = 0,
        longitudePadding: Double = 0
    ) -> Bool {
        let halfLatitudeDelta = span.latitudeDelta * (0.5 + latitudePadding)
        let halfLongitudeDelta = span.longitudeDelta * (0.5 + longitudePadding)
        return coordinate.latitude >= center.latitude - halfLatitudeDelta &&
            coordinate.latitude <= center.latitude + halfLatitudeDelta &&
            coordinate.longitude >= center.longitude - halfLongitudeDelta &&
            coordinate.longitude <= center.longitude + halfLongitudeDelta
    }
}
