import SwiftUI
import UIKit
@preconcurrency import CoreData
import Combine

enum PhotoGridFilter: String, CaseIterable, Identifiable {
    case all
    case hearted
    case favoriteLivePhotos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All Photos"
        case .hearted:
            return "Hearted"
        case .favoriteLivePhotos:
            return "Favorite Live Photos"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "line.3.horizontal.decrease.circle"
        case .hearted:
            return "heart.fill"
        case .favoriteLivePhotos:
            return "livephoto"
        }
    }
}

@MainActor
final class PhotoGridDataController: NSObject, ObservableObject, NSFetchedResultsControllerDelegate {
    @Published private(set) var photoCount = 0
    @Published private(set) var totalPhotoCount = 0
    @Published private(set) var heartedPhotoCount = 0
    @Published private(set) var favoriteLivePhotoCount = 0
    @Published private(set) var isEmpty = true
    @Published private(set) var changeToken = 0

    private var fetchedResultsController: NSFetchedResultsController<DailyPhoto>?
    private weak var context: NSManagedObjectContext?
    private var filter: PhotoGridFilter = .all
    private var photosByID: [NSManagedObjectID: DailyPhoto] = [:]
    private(set) var itemsSnapshot: [UIKitPhotoGridItem] = []

    var hasAnyPhotos: Bool {
        totalPhotoCount > 0
    }

    func configureIfNeeded(context: NSManagedObjectContext, filter: PhotoGridFilter) {
        self.context = context
        self.filter = filter
        guard fetchedResultsController == nil else {
            setFilter(filter)
            return
        }

        let request = DailyPhoto.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DailyPhoto.captureDate, ascending: false)]
        request.predicate = fetchPredicate
        request.fetchBatchSize = 80

        let controller = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: context,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        controller.delegate = self
        fetchedResultsController = controller

        do {
            try controller.performFetch()
            rebuildSnapshot(from: controller.fetchedObjects ?? [])
        } catch {
            photosByID = [:]
            itemsSnapshot = []
            photoCount = 0
            isEmpty = true
            refreshCounts()
        }
    }

    func setFilter(_ filter: PhotoGridFilter) {
        guard self.filter != filter else { return }
        self.filter = filter
        fetchedResultsController?.fetchRequest.predicate = fetchPredicate

        do {
            try fetchedResultsController?.performFetch()
            rebuildSnapshot(from: fetchedResultsController?.fetchedObjects ?? [])
        } catch {
            photosByID = [:]
            itemsSnapshot = []
            photoCount = 0
            isEmpty = true
            refreshCounts()
        }
    }

    var allPhotos: [DailyPhoto] {
        fetchedResultsController?.fetchedObjects ?? []
    }

    func allStoredPhotos() -> [DailyPhoto] {
        guard let context else { return allPhotos }

        let request = DailyPhoto.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DailyPhoto.captureDate, ascending: false)]
        request.includesPendingChanges = true

        do {
            return try context.fetch(request)
        } catch {
            return allPhotos
        }
    }

    func photo(at index: Int) -> DailyPhoto? {
        let photos = allPhotos
        guard photos.indices.contains(index) else { return nil }
        return photos[index]
    }

    func photos(for objectIDs: Set<NSManagedObjectID>) -> [DailyPhoto] {
        objectIDs.compactMap { photosByID[$0] }
    }

    func shouldHeartPhotos(for objectIDs: Set<NSManagedObjectID>) -> Bool {
        let photos = photos(for: objectIDs)
        guard !photos.isEmpty else { return true }
        return photos.contains { !$0.isHearted }
    }

    func index(of objectID: NSManagedObjectID) -> Int? {
        allPhotos.firstIndex(where: { $0.objectID == objectID })
    }

    func controllerDidChangeContent(_ controller: NSFetchedResultsController<any NSFetchRequestResult>) {
        rebuildSnapshot(from: fetchedResultsController?.fetchedObjects ?? [])
    }

    private func rebuildSnapshot(from photos: [DailyPhoto]) {
        photosByID = Dictionary(uniqueKeysWithValues: photos.map { ($0.objectID, $0) })
        itemsSnapshot = photos.map(UIKitPhotoGridItem.init(photo:))
        photoCount = photos.count
        isEmpty = photos.isEmpty
        refreshCounts()
        changeToken &+= 1
    }

    private var fetchPredicate: NSPredicate? {
        switch filter {
        case .all:
            return nil
        case .hearted:
            return NSPredicate(format: "isHearted == YES")
        case .favoriteLivePhotos:
            return NSPredicate(format: "isFavoriteLivePhoto == YES")
        }
    }

    private func refreshCounts() {
        guard let context else {
            totalPhotoCount = photoCount
            heartedPhotoCount = filter == .hearted ? photoCount : 0
            favoriteLivePhotoCount = filter == .favoriteLivePhotos ? photoCount : 0
            return
        }

        totalPhotoCount = countPhotos(in: context, predicate: nil)
        heartedPhotoCount = countPhotos(
            in: context,
            predicate: NSPredicate(format: "isHearted == YES")
        )
        favoriteLivePhotoCount = countPhotos(
            in: context,
            predicate: NSPredicate(format: "isFavoriteLivePhoto == YES")
        )
    }

    private func countPhotos(in context: NSManagedObjectContext, predicate: NSPredicate?) -> Int {
        let request = NSFetchRequest<NSNumber>(entityName: "DailyPhoto")
        request.resultType = .countResultType
        request.includesPendingChanges = true
        request.predicate = predicate

        do {
            return try context.count(for: request)
        } catch {
            return 0
        }
    }
}

struct UIKitPhotoGridItem: Identifiable, Equatable {
    let objectID: NSManagedObjectID
    let captureDate: Date?
    let fullImageAssetName: String?
    let livePhotoImageAssetName: String?
    let livePhotoVideoAssetName: String?
    let locationName: String?
    let latitude: Double
    let longitude: Double
    let isHearted: Bool
    let isFavoriteLivePhoto: Bool
    let uploadState: PhotoUploadState
    let assetNames: [String]

    var id: NSManagedObjectID { objectID }

    init(photo: DailyPhoto) {
        objectID = photo.objectID
        captureDate = photo.captureDate
        fullImageAssetName = photo.fullImageAssetName
        livePhotoImageAssetName = photo.livePhotoImageAssetName
        livePhotoVideoAssetName = photo.livePhotoVideoAssetName
        locationName = photo.locationName
        latitude = photo.latitude
        longitude = photo.longitude
        isHearted = photo.isHearted
        isFavoriteLivePhoto = photo.isFavoriteLivePhoto
        uploadState = photo.uploadState
        assetNames = [
            fullImageAssetName,
            livePhotoImageAssetName,
            livePhotoVideoAssetName
        ].compactMap { $0 }
    }
}

struct PhotoGridCenteringRequest: Equatable {
    let objectID: NSManagedObjectID
    let token: UUID
}

struct UIKitPhotoGridView: UIViewControllerRepresentable {
    let dataController: PhotoGridDataController
    let changeToken: Int
    let centeringRequest: PhotoGridCenteringRequest?
    @Binding var isSelectionMode: Bool
    @Binding var selectedPhotoIDs: Set<NSManagedObjectID>
    let onOpenPhoto: (NSManagedObjectID, Int, CGRect) -> Void
    let onPhotoFrameChanged: (NSManagedObjectID, CGRect) -> Void
    let onPhotoCentered: (NSManagedObjectID, CGRect) -> Void
    let onFirstItemFrameChanged: (CGRect) -> Void
    let onTopVisibleDateChanged: (Date?) -> Void
    let onScrollActivityChanged: (Bool) -> Void
    let onContextMenuAction: (PhotoGridContextAction, NSManagedObjectID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> PhotoGridCollectionViewController {
        let controller = PhotoGridCollectionViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PhotoGridCollectionViewController, context: Context) {
        context.coordinator.parent = self
        uiViewController.update(
            items: dataController.itemsSnapshot,
            changeToken: changeToken,
            centeringRequest: centeringRequest,
            isSelectionMode: isSelectionMode,
            selectedPhotoIDs: selectedPhotoIDs
        )
    }

    final class Coordinator: NSObject, PhotoGridCollectionViewControllerDelegate {
        var parent: UIKitPhotoGridView

        init(_ parent: UIKitPhotoGridView) {
            self.parent = parent
        }

        func photoGridController(_ controller: PhotoGridCollectionViewController, didOpenPhotoWith objectID: NSManagedObjectID, at index: Int, frame: CGRect) {
            parent.onOpenPhoto(objectID, index, frame)
        }

        func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdatePhotoFrameFor objectID: NSManagedObjectID, frame: CGRect) {
            parent.onPhotoFrameChanged(objectID, frame)
        }

        func photoGridController(_ controller: PhotoGridCollectionViewController, didCenterPhotoWith objectID: NSManagedObjectID, frame: CGRect) {
            parent.onPhotoCentered(objectID, frame)
        }

        func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdateSelection selectedPhotoIDs: Set<NSManagedObjectID>) {
            parent.selectedPhotoIDs = selectedPhotoIDs
        }

        func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdateTopVisibleDate date: Date?) {
            parent.onTopVisibleDateChanged(date)
        }

        func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdateFirstItemFrame frame: CGRect) {
            parent.onFirstItemFrameChanged(frame)
        }

        func photoGridController(_ controller: PhotoGridCollectionViewController, didChangeScrollActivity isActive: Bool) {
            parent.onScrollActivityChanged(isActive)
        }

        func photoGridController(_ controller: PhotoGridCollectionViewController, didRequestContextAction action: PhotoGridContextAction, for objectID: NSManagedObjectID) {
            parent.onContextMenuAction(action, objectID)
        }
    }
}

private enum UIKitPhotoGridSection: Int, Hashable, Sendable {
    case main
}

enum PhotoGridContextAction {
    case share
    case save
    case copy
    case delete
}

final class PhotoThumbnailDataProvider {
    private let context = PersistenceController.shared.makeBackgroundContext()
    private var readCount = 0
    private let resetInterval = 192

    init() {
        context.undoManager = nil
        context.retainsRegisteredObjects = false
    }

    func thumbnailData(for objectID: NSManagedObjectID) async -> Data? {
        let context = context
        return await context.perform {
            autoreleasepool {
                let request = NSFetchRequest<NSDictionary>(entityName: "DailyPhoto")
                request.resultType = .dictionaryResultType
                request.fetchLimit = 1
                request.includesPendingChanges = false
                request.predicate = NSPredicate(format: "SELF == %@", objectID)
                request.propertiesToFetch = ["thumbnailData"]

                let data = (try? context.fetch(request).first?["thumbnailData"] as? Data) ?? nil

                self.readCount += 1
                if self.readCount >= self.resetInterval {
                    context.reset()
                    self.readCount = 0
                }

                return data
            }
        }
    }

    func purge() async {
        let context = context
        await context.perform {
            context.reset()
            self.readCount = 0
        }
    }
}

@MainActor
protocol PhotoGridCollectionViewControllerDelegate: AnyObject {
    func photoGridController(_ controller: PhotoGridCollectionViewController, didOpenPhotoWith objectID: NSManagedObjectID, at index: Int, frame: CGRect)
    func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdatePhotoFrameFor objectID: NSManagedObjectID, frame: CGRect)
    func photoGridController(_ controller: PhotoGridCollectionViewController, didCenterPhotoWith objectID: NSManagedObjectID, frame: CGRect)
    func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdateSelection selectedPhotoIDs: Set<NSManagedObjectID>)
    func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdateTopVisibleDate date: Date?)
    func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdateFirstItemFrame frame: CGRect)
    func photoGridController(_ controller: PhotoGridCollectionViewController, didChangeScrollActivity isActive: Bool)
    func photoGridController(_ controller: PhotoGridCollectionViewController, didRequestContextAction action: PhotoGridContextAction, for objectID: NSManagedObjectID)
}

@MainActor
final class PhotoGridCollectionViewController: UIViewController {
    weak var delegate: PhotoGridCollectionViewControllerDelegate?

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<UIKitPhotoGridSection, NSManagedObjectID>!
    private var items: [UIKitPhotoGridItem] = []
    private var itemsByID: [NSManagedObjectID: UIKitPhotoGridItem] = [:]
    private var isSelectionMode = false
    private var selectedPhotoIDs: Set<NSManagedObjectID> = []
    private var lastAppliedSelectedPhotoIDs: Set<NSManagedObjectID> = []
    private var selectionPanRecognizer: UIPanGestureRecognizer!
    private var gridPinchRecognizer: UIPinchGestureRecognizer!
    private var selectionPanAnchorIndexPath: IndexPath?
    private var selectionPanBaseSelection: Set<NSManagedObjectID> = []
    private var selectionPanOperation: SelectionPanOperation = .select
    private var pinchStartColumnCount = 0
    private var pinchAnchor: GridPinchAnchor?
    private var thumbnailTasks: [NSManagedObjectID: ThumbnailTaskRecord] = [:]
    private var currentItemIDs: [NSManagedObjectID] = []
    private var itemIndexByID: [NSManagedObjectID: Int] = [:]
    private var currentChangeToken: Int?
    private var handledCenteringRequestToken: UUID?
    private var lastReportedTopVisibleMonth: DateComponents?
    private var isScrollMotionActive = false
    private var lastContentOffsetY: CGFloat = 0
    private var preheatDirection: ScrollPreheatDirection = .none
    private var lastTopVisibleReportUptime: TimeInterval = 0
    private var lastVisibleThumbnailKickUptime: TimeInterval = 0
    private let thumbnailDataProvider = PhotoThumbnailDataProvider()
    private let maxInflightThumbnailTasks = 48
    private let maxInflightThumbnailTasksDuringScroll = 22
    private let maxNearVisiblePrefetchPerKick = 56
    private let maxCollectionPrefetchPerPass = 24
    private let nearVisiblePreheatWindowMultiplier: CGFloat = 2.0
    private let topVisibleReportInterval: TimeInterval = 0.08
    private let visibleThumbnailKickInterval: TimeInterval = 0.04
    private let minGridColumnCount = 2
    private let maxGridColumnCount = 5
    private let gridSpacing: CGFloat = 2
    private var gridColumnCount: Int = {
        let storedValue = UserDefaults.standard.integer(forKey: GridPreferences.columnCountKey)
        guard storedValue > 0 else { return GridPreferences.defaultColumnCount }
        return min(max(storedValue, GridPreferences.minColumnCount), GridPreferences.maxColumnCount)
    }()

    private enum SelectionPanOperation {
        case select
        case deselect
    }

    private enum ScrollPreheatDirection {
        case up
        case down
        case none
    }

    private enum GridPreferences {
        static let columnCountKey = "photo-grid-column-count"
        static let minColumnCount = 2
        static let maxColumnCount = 5
        static let defaultColumnCount = 3
    }

    private enum ThumbnailLoadRole: Hashable {
        case visible
        case prefetch

        var taskPriority: TaskPriority {
            switch self {
            case .visible:
                return .userInitiated
            case .prefetch:
                return .utility
            }
        }
    }

    private struct ThumbnailTaskRecord {
        let role: ThumbnailLoadRole
        let token: UUID
        let task: Task<Void, Never>
    }

    private struct GridPinchAnchor {
        let indexPath: IndexPath
        let xRatio: CGFloat
        let yRatio: CGFloat
        let locationInBounds: CGPoint
    }

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 2
        layout.minimumInteritemSpacing = 2
        layout.sectionInset = .zero
        layout.scrollDirection = .vertical

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.allowsMultipleSelection = true
        collectionView.contentInset = UIEdgeInsets(top: 1, left: 0, bottom: 104, right: 0)
        collectionView.scrollIndicatorInsets = UIEdgeInsets(top: 1, left: 0, bottom: 104, right: 0)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.isPrefetchingEnabled = true
        lastContentOffsetY = collectionView.contentOffset.y

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        configureDataSource()

        selectionPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionPan(_:)))
        selectionPanRecognizer.cancelsTouchesInView = false
        selectionPanRecognizer.delegate = self
        collectionView.addGestureRecognizer(selectionPanRecognizer)

        gridPinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handleGridPinch(_:)))
        gridPinchRecognizer.cancelsTouchesInView = false
        gridPinchRecognizer.delegate = self
        collectionView.addGestureRecognizer(gridPinchRecognizer)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || view.window == nil else { return }

        cancelAllThumbnailTasks()
        Task {
            await thumbnailDataProvider.purge()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayoutItemSize()
        reportFirstItemFrameIfAvailable()
    }

    func update(
        items: [UIKitPhotoGridItem],
        changeToken: Int,
        centeringRequest: PhotoGridCenteringRequest?,
        isSelectionMode: Bool,
        selectedPhotoIDs: Set<NSManagedObjectID>
    ) {
        let didChangeItems = currentChangeToken != changeToken
        let didChangeSelectionMode = self.isSelectionMode != isSelectionMode

        self.isSelectionMode = isSelectionMode
        self.selectedPhotoIDs = selectedPhotoIDs

        if didChangeItems {
            currentChangeToken = changeToken
            self.items = items
            itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.objectID, $0) })
            itemIndexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.objectID, $0.offset) })

            let previousItemIDs = currentItemIDs
            let nextItemIDs = items.map(\.objectID)
            if nextItemIDs != previousItemIDs {
                currentItemIDs = nextItemIDs
                lastAppliedSelectedPhotoIDs = []
                applySnapshot(animatingDifferences: previousItemIDs.isEmpty == false && collectionView.window != nil)
            }
        }

        synchronizeSelection(animated: false)
        if didChangeItems || didChangeSelectionMode {
            refreshVisibleCells()
        }
        handleCenteringRequestIfNeeded(centeringRequest)
        reportTopVisibleDate()
        reportFirstItemFrameIfAvailable()
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<PhotoGridCollectionViewCell, NSManagedObjectID> { [weak self] cell, indexPath, objectID in
            guard let self, indexPath.item < self.items.count, let item = self.itemsByID[objectID] else { return }
            cell.configure(
                with: item,
                isSelectionMode: self.isSelectionMode,
                isSelected: self.selectedPhotoIDs.contains(objectID)
            )
            self.prepareThumbnail(for: item, in: cell)
        }

        dataSource = UICollectionViewDiffableDataSource<UIKitPhotoGridSection, NSManagedObjectID>(
            collectionView: collectionView
        ) { (collectionView: UICollectionView, indexPath: IndexPath, objectID: NSManagedObjectID) in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: objectID)
        }
    }

    private func applySnapshot(animatingDifferences: Bool = false) {
        var snapshot = NSDiffableDataSourceSnapshot<UIKitPhotoGridSection, NSManagedObjectID>()
        snapshot.appendSections([UIKitPhotoGridSection.main])
        snapshot.appendItems(items.map(\.objectID), toSection: UIKitPhotoGridSection.main)
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func synchronizeSelection(animated: Bool) {
        let idsToDeselect = lastAppliedSelectedPhotoIDs.subtracting(selectedPhotoIDs)
        let idsToSelect = selectedPhotoIDs.subtracting(lastAppliedSelectedPhotoIDs)

        for objectID in idsToDeselect {
            guard let index = itemIndexByID[objectID] else { continue }
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.deselectItem(at: indexPath, animated: animated)
            refreshVisibleCell(at: indexPath)
        }

        for objectID in idsToSelect {
            guard let index = itemIndexByID[objectID] else { continue }
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.selectItem(at: indexPath, animated: animated, scrollPosition: [])
            refreshVisibleCell(at: indexPath)
        }

        lastAppliedSelectedPhotoIDs = selectedPhotoIDs
    }

    private func refreshVisibleCell(at indexPath: IndexPath) {
        guard indexPath.item < items.count,
              let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCollectionViewCell else {
            return
        }

        let item = items[indexPath.item]
        cell.configure(
            with: item,
            isSelectionMode: isSelectionMode,
            isSelected: selectedPhotoIDs.contains(item.objectID)
        )
    }

    private func refreshVisibleCells() {
        collectionView.visibleCells.forEach { cell in
            guard let gridCell = cell as? PhotoGridCollectionViewCell,
                  let indexPath = collectionView.indexPath(for: gridCell) else {
                return
            }

            refreshVisibleCell(at: indexPath)
        }
    }

    private func updateLayoutItemSize() {
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }
        let availableWidth = collectionView.bounds.width
        guard availableWidth > 0 else { return }

        let columnCount = min(max(gridColumnCount, minGridColumnCount), maxGridColumnCount)
        let itemWidth = floor((availableWidth - CGFloat(columnCount - 1) * gridSpacing) / CGFloat(columnCount))

        let itemSize = CGSize(width: itemWidth, height: itemWidth)
        if layout.itemSize != itemSize {
            layout.itemSize = itemSize
            layout.invalidateLayout()
        }
    }

    @objc
    private func handleGridPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartColumnCount = gridColumnCount
            pinchAnchor = makePinchAnchor(at: gesture.location(in: collectionView))
        case .changed:
            guard pinchStartColumnCount > 0 else { return }
            let scaledColumnCount = CGFloat(pinchStartColumnCount) / max(gesture.scale, 0.1)
            let nextColumnCount = min(
                max(Int(round(scaledColumnCount)), minGridColumnCount),
                maxGridColumnCount
            )
            applyGridColumnCount(nextColumnCount, anchoredBy: pinchAnchor, animated: true)
        case .ended, .cancelled, .failed:
            UserDefaults.standard.set(gridColumnCount, forKey: GridPreferences.columnCountKey)
            pinchStartColumnCount = 0
            pinchAnchor = nil
            loadVisibleThumbnails()
            prefetchNearVisibleThumbnails()
        default:
            break
        }
    }

    private func applyGridColumnCount(
        _ columnCount: Int,
        anchoredBy anchor: GridPinchAnchor?,
        animated: Bool
    ) {
        guard columnCount != gridColumnCount else { return }
        gridColumnCount = columnCount

        let updates = { [self] in
            updateLayoutItemSize()
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()

            if let anchor {
                restorePinchAnchor(anchor)
            }
        }

        if animated {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction],
                animations: updates
            )
        } else {
            UIView.performWithoutAnimation(updates)
        }

        reportTopVisibleDate()
        reportFirstItemFrameIfAvailable()
    }

    private func makePinchAnchor(at location: CGPoint) -> GridPinchAnchor? {
        guard let indexPath = collectionView.indexPathForItem(at: location),
              items.indices.contains(indexPath.item),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath),
              attributes.frame.width > 0,
              attributes.frame.height > 0 else {
            return nil
        }

        return GridPinchAnchor(
            indexPath: indexPath,
            xRatio: (location.x - attributes.frame.minX) / attributes.frame.width,
            yRatio: (location.y - attributes.frame.minY) / attributes.frame.height,
            locationInBounds: location
        )
    }

    private func restorePinchAnchor(_ anchor: GridPinchAnchor) {
        guard let attributes = collectionView.layoutAttributesForItem(at: anchor.indexPath) else { return }

        let anchoredY = attributes.frame.minY + attributes.frame.height * anchor.yRatio
        let targetOffset = CGPoint(
            x: collectionView.contentOffset.x,
            y: anchoredY - anchor.locationInBounds.y
        )
        let maxOffsetY = max(
            -collectionView.adjustedContentInset.top,
            collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
        )
        let minOffsetY = -collectionView.adjustedContentInset.top
        let clampedOffsetY = min(max(targetOffset.y, minOffsetY), maxOffsetY)
        collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: clampedOffsetY)
    }

    private func prepareThumbnail(for item: UIKitPhotoGridItem, in cell: PhotoGridCollectionViewCell) {
        let objectID = item.objectID
        let wasRepresentingObject = cell.representedObjectID == objectID
        cell.representedObjectID = objectID

        if let cachedImage = DecodedThumbnailCache.shared.cachedImage(for: objectID) {
            cell.setThumbnailImage(cachedImage)
        } else if !wasRepresentingObject {
            cell.setThumbnailImage(nil)
        }
    }

    private func loadThumbnail(for item: UIKitPhotoGridItem, into cell: PhotoGridCollectionViewCell) {
        prepareThumbnail(for: item, in: cell)

        guard DecodedThumbnailCache.shared.cachedImage(for: item.objectID) == nil else { return }
        startThumbnailTask(for: item.objectID, role: .visible, cell: cell)
    }

    private func prefetchThumbnail(for item: UIKitPhotoGridItem) {
        let objectID = item.objectID
        if DecodedThumbnailCache.shared.cachedImage(for: objectID) != nil { return }
        guard thumbnailTasks[objectID] == nil else { return }
        let maxInflight = isScrollMotionActive ? maxInflightThumbnailTasksDuringScroll : maxInflightThumbnailTasks
        guard activePrefetchThumbnailTaskCount < maxInflight else { return }
        startThumbnailTask(for: objectID, role: .prefetch, cell: nil)
    }

    private var activePrefetchThumbnailTaskCount: Int {
        thumbnailTasks.values.reduce(0) { count, record in
            record.role == .prefetch ? count + 1 : count
        }
    }

    private func startThumbnailTask(
        for objectID: NSManagedObjectID,
        role: ThumbnailLoadRole,
        cell: PhotoGridCollectionViewCell?
    ) {
        if let existingRecord = thumbnailTasks[objectID] {
            switch (existingRecord.role, role) {
            case (.visible, _), (.prefetch, .prefetch):
                return
            case (.prefetch, .visible):
                existingRecord.task.cancel()
                thumbnailTasks[objectID] = nil
            }
        }

        let thumbnailDataProvider = thumbnailDataProvider
        let token = UUID()
        let task = Task.detached(priority: role.taskPriority) { [weak self, weak cell] in
            guard !Task.isCancelled else {
                await self?.finishThumbnailTask(for: objectID, token: token)
                return
            }

            let data = await thumbnailDataProvider.thumbnailData(for: objectID)
            guard !Task.isCancelled else {
                await self?.finishThumbnailTask(for: objectID, token: token)
                return
            }

            let image = await DecodedThumbnailCache.shared.image(for: objectID, data: data)
            guard !Task.isCancelled else {
                await self?.finishThumbnailTask(for: objectID, token: token)
                return
            }
            await MainActor.run { [weak self, weak cell] in
                guard let self else { return }
                guard self.thumbnailTasks[objectID]?.token == token else { return }
                if role == .visible, cell?.representedObjectID == objectID {
                    cell?.setThumbnailImage(image)
                }
                self.thumbnailTasks[objectID] = nil
            }
        }

        thumbnailTasks[objectID] = ThumbnailTaskRecord(role: role, token: token, task: task)
    }

    private func finishThumbnailTask(for objectID: NSManagedObjectID, token: UUID) {
        guard thumbnailTasks[objectID]?.token == token else {
            return
        }
        thumbnailTasks[objectID] = nil
    }

    private func cancelThumbnailTask(for objectID: NSManagedObjectID?, roles: Set<ThumbnailLoadRole>) {
        guard let objectID else { return }
        guard let record = thumbnailTasks[objectID], roles.contains(record.role) else { return }
        record.task.cancel()
        thumbnailTasks[objectID] = nil
    }

    private func cancelAllThumbnailTasks() {
        for record in thumbnailTasks.values {
            record.task.cancel()
        }
        thumbnailTasks.removeAll(keepingCapacity: false)
    }

    @objc
    private func handleMemoryWarning() {
        cancelAllThumbnailTasks()
        DecodedThumbnailCache.shared.removeAllImages()
        Task {
            await thumbnailDataProvider.purge()
        }
        collectionView.reloadData()
    }

    private func reportTopVisibleDate() {
        let indexPath = collectionView.indexPathsForVisibleItems.min()
        let date = indexPath.flatMap { $0.item < items.count ? items[$0.item].captureDate : nil }
        let month = date.map {
            Calendar.current.dateComponents([.year, .month], from: $0)
        }

        guard month != lastReportedTopVisibleMonth else { return }
        lastReportedTopVisibleMonth = month
        delegate?.photoGridController(self, didUpdateTopVisibleDate: date)
    }

    private func loadVisibleThumbnails() {
        for case let cell as PhotoGridCollectionViewCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell),
                  items.indices.contains(indexPath.item) else {
                continue
            }
            loadThumbnail(for: items[indexPath.item], into: cell)
        }
    }

    private func prefetchNearVisibleThumbnails() {
        let bounds = collectionView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let forwardMultiplier: CGFloat = isScrollMotionActive ? 3.8 : 2.8
        let backwardMultiplier: CGFloat = 1.4
        let symmetricMultiplier: CGFloat = nearVisiblePreheatWindowMultiplier

        let topExtra: CGFloat
        let bottomExtra: CGFloat
        switch preheatDirection {
        case .down:
            topExtra = bounds.height * backwardMultiplier
            bottomExtra = bounds.height * forwardMultiplier
        case .up:
            topExtra = bounds.height * forwardMultiplier
            bottomExtra = bounds.height * backwardMultiplier
        case .none:
            topExtra = bounds.height * symmetricMultiplier
            bottomExtra = bounds.height * symmetricMultiplier
        }

        let preheatRect = CGRect(
            x: bounds.minX,
            y: bounds.minY - topExtra,
            width: bounds.width,
            height: bounds.height + topExtra + bottomExtra
        )
        guard let attributes = collectionView.collectionViewLayout.layoutAttributesForElements(in: preheatRect) else {
            return
        }

        let visibleIndexPaths = Set(collectionView.indexPathsForVisibleItems)
        let candidates: [(indexPath: IndexPath, isAhead: Bool, distance: CGFloat)] = attributes.compactMap { attributes in
            guard attributes.representedElementCategory == .cell else { return nil }
            let indexPath = attributes.indexPath
            guard !visibleIndexPaths.contains(indexPath),
                  items.indices.contains(indexPath.item) else {
                return nil
            }

            let isAhead: Bool
            let distance: CGFloat
            switch preheatDirection {
            case .down:
                isAhead = attributes.center.y >= bounds.maxY
                distance = isAhead
                    ? max(0, attributes.center.y - bounds.maxY)
                    : max(0, bounds.minY - attributes.center.y)
            case .up:
                isAhead = attributes.center.y <= bounds.minY
                distance = isAhead
                    ? max(0, bounds.minY - attributes.center.y)
                    : max(0, attributes.center.y - bounds.maxY)
            case .none:
                isAhead = true
                distance = abs(attributes.center.y - bounds.midY)
            }
            return (indexPath, isAhead, distance)
        }

        for candidate in candidates
            .sorted(by: { lhs, rhs in
                if lhs.isAhead != rhs.isAhead {
                    return lhs.isAhead && !rhs.isAhead
                }
                return lhs.distance < rhs.distance
            })
            .prefix(maxNearVisiblePrefetchPerKick) {
            prefetchThumbnail(for: items[candidate.indexPath.item])
        }
    }

    private func reportFirstItemFrameIfAvailable() {
        let indexPath = IndexPath(item: 0, section: 0)
        guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let frameInCollection = attributes.frame
        let frameInView = collectionView.convert(frameInCollection, to: view.window)
        guard frameInView != .zero else { return }
        delegate?.photoGridController(self, didUpdateFirstItemFrame: frameInView)
    }

    private func handleCenteringRequestIfNeeded(_ request: PhotoGridCenteringRequest?) {
        guard let request else { return }
        guard handledCenteringRequestToken != request.token else { return }
        handledCenteringRequestToken = request.token
        centerPhoto(with: request.objectID)
    }

    private func centerPhoto(with objectID: NSManagedObjectID) {
        guard let index = itemIndexByID[objectID] else {
            delegate?.photoGridController(self, didCenterPhotoWith: objectID, frame: .zero)
            return
        }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()
            let frame = self.frameForPhoto(with: objectID)
            self.delegate?.photoGridController(self, didUpdatePhotoFrameFor: objectID, frame: frame)
            self.delegate?.photoGridController(self, didCenterPhotoWith: objectID, frame: frame)
        }
    }

    private func frameForPhoto(with objectID: NSManagedObjectID) -> CGRect {
        guard let index = itemIndexByID[objectID] else { return .zero }
        let indexPath = IndexPath(item: index, section: 0)

        if let cell = collectionView.cellForItem(at: indexPath) {
            let frame = collectionView.convert(cell.frame, to: view.window)
            return frame == .zero ? fallbackFrameForItem(at: indexPath) : frame
        }

        return fallbackFrameForItem(at: indexPath)
    }

    private func fallbackFrameForItem(at indexPath: IndexPath) -> CGRect {
        guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return .zero }
        return collectionView.convert(attributes.frame, to: view.window)
    }

    private func nearestIndexPath(to location: CGPoint) -> IndexPath? {
        if let hitIndexPath = collectionView.indexPathForItem(at: location) {
            return hitIndexPath
        }

        let attributes = collectionView.collectionViewLayout.layoutAttributesForElements(in: collectionView.bounds) ?? []
        return attributes.min(by: { lhs, rhs in
            let lhsDistance = hypot(lhs.frame.midX - location.x, lhs.frame.midY - location.y)
            let rhsDistance = hypot(rhs.frame.midX - location.x, rhs.frame.midY - location.y)
            return lhsDistance < rhsDistance
        })?.indexPath
    }

    @objc
    private func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
        guard isSelectionMode else { return }

        let location = gesture.location(in: collectionView)
        switch gesture.state {
        case .began:
            guard let indexPath = nearestIndexPath(to: location), indexPath.item < items.count else { return }
            selectionPanAnchorIndexPath = indexPath
            selectionPanBaseSelection = selectedPhotoIDs
            let objectID = items[indexPath.item].objectID
            selectionPanOperation = selectedPhotoIDs.contains(objectID) ? .deselect : .select
            applySelectionPan(to: indexPath)
        case .changed:
            guard let currentIndexPath = nearestIndexPath(to: location) else { return }
            applySelectionPan(to: currentIndexPath)
        default:
            selectionPanAnchorIndexPath = nil
            selectionPanBaseSelection = []
        }
    }

    private func applySelectionPan(to currentIndexPath: IndexPath) {
        guard let anchorIndexPath = selectionPanAnchorIndexPath,
              items.indices.contains(anchorIndexPath.item),
              items.indices.contains(currentIndexPath.item) else {
            return
        }

        let lower = min(anchorIndexPath.item, currentIndexPath.item)
        let upper = max(anchorIndexPath.item, currentIndexPath.item)
        let rangeIDs = Set(items[lower...upper].map(\.objectID))

        var updated = selectionPanBaseSelection
        switch selectionPanOperation {
        case .select:
            updated.formUnion(rangeIDs)
        case .deselect:
            updated.subtract(rangeIDs)
        }

        selectedPhotoIDs = updated
        synchronizeSelection(animated: false)
        delegate?.photoGridController(self, didUpdateSelection: updated)
    }

    private func requestContextAction(_ action: PhotoGridContextAction, for objectID: NSManagedObjectID) {
        delegate?.photoGridController(self, didRequestContextAction: action, for: objectID)
    }
}

extension PhotoGridCollectionViewController: UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < items.count else { return }
        let objectID = items[indexPath.item].objectID

        if isSelectionMode {
            selectedPhotoIDs.insert(objectID)
            delegate?.photoGridController(self, didUpdateSelection: selectedPhotoIDs)
            if let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCollectionViewCell {
                cell.configure(
                    with: items[indexPath.item],
                    isSelectionMode: true,
                    isSelected: true
                )
            }
        } else {
            collectionView.deselectItem(at: indexPath, animated: false)
            let frame = frameForPhoto(with: objectID)
            delegate?.photoGridController(self, didUpdatePhotoFrameFor: objectID, frame: frame)
            delegate?.photoGridController(self, didOpenPhotoWith: objectID, at: indexPath.item, frame: frame)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        guard isSelectionMode, indexPath.item < items.count else { return }
        let objectID = items[indexPath.item].objectID
        selectedPhotoIDs.remove(objectID)
        delegate?.photoGridController(self, didUpdateSelection: selectedPhotoIDs)
        if let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCollectionViewCell {
            cell.configure(
                with: items[indexPath.item],
                isSelectionMode: true,
                isSelected: false
            )
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard items.indices.contains(indexPath.item) else { return nil }
        let objectID = items[indexPath.item].objectID

        return UIContextMenuConfiguration(identifier: objectID.uriRepresentation() as NSURL) { nil } actionProvider: { [weak self] _ in
            guard let self else { return nil }

            let shareAction = UIAction(
                title: "Share",
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in
                self?.requestContextAction(.share, for: objectID)
            }

            let saveAction = UIAction(
                title: "Save to Photos",
                image: UIImage(systemName: "square.and.arrow.down")
            ) { [weak self] _ in
                self?.requestContextAction(.save, for: objectID)
            }

            let copyAction = UIAction(
                title: "Copy",
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                self?.requestContextAction(.copy, for: objectID)
            }

            let deleteAction = UIAction(
                title: "Delete",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.presentContextDeleteConfirmation(for: objectID)
            }

            return UIMenu(children: [shareAction, saveAction, copyAction, deleteAction])
        }
    }

    private func presentContextDeleteConfirmation(for objectID: NSManagedObjectID) {
        guard presentedViewController == nil else { return }

        let alert = UIAlertController(
            title: "Delete photo?",
            message: "This action cannot be undone.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Delete Photo", style: .destructive) { [weak self] _ in
            self?.requestContextAction(.delete, for: objectID)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = collectionView
            popover.sourceRect = contextMenuSourceRect(for: objectID)
        }

        present(alert, animated: true)
    }

    private func contextMenuSourceRect(for objectID: NSManagedObjectID) -> CGRect {
        guard let itemIndex = items.firstIndex(where: { $0.objectID == objectID }) else {
            return CGRect(
                x: collectionView.bounds.midX,
                y: collectionView.bounds.midY,
                width: 1,
                height: 1
            )
        }

        let indexPath = IndexPath(item: itemIndex, section: 0)
        if let cell = collectionView.cellForItem(at: indexPath) {
            return cell.frame
        }

        return collectionView.layoutAttributesForItem(at: indexPath)?.frame ?? CGRect(
            x: collectionView.bounds.midX,
            y: collectionView.bounds.midY,
            width: 1,
            height: 1
        )
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths.prefix(maxCollectionPrefetchPerPass) where indexPath.item < items.count {
            prefetchThumbnail(for: items[indexPath.item])
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths where indexPath.item < items.count {
            cancelThumbnailTask(for: items[indexPath.item].objectID, roles: [.prefetch])
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard indexPath.item < items.count,
              let gridCell = cell as? PhotoGridCollectionViewCell else {
            return
        }

        let item = items[indexPath.item]
        gridCell.configure(
            with: item,
            isSelectionMode: isSelectionMode,
            isSelected: selectedPhotoIDs.contains(item.objectID)
        )
        loadThumbnail(for: item, into: gridCell)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Let visible loads finish into the shared cache. Rubber-band scrolling can briefly
        // end-display cells that immediately reappear; canceling here causes visible flicker.
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let delta = scrollView.contentOffset.y - lastContentOffsetY
        if delta > 0.5 {
            preheatDirection = .down
        } else if delta < -0.5 {
            preheatDirection = .up
        }
        lastContentOffsetY = scrollView.contentOffset.y

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTopVisibleReportUptime >= topVisibleReportInterval {
            lastTopVisibleReportUptime = now
            reportTopVisibleDate()
        }

        if isScrollMotionActive,
           now - lastVisibleThumbnailKickUptime >= visibleThumbnailKickInterval {
            lastVisibleThumbnailKickUptime = now
            loadVisibleThumbnails()
            prefetchNearVisibleThumbnails()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isScrollMotionActive = true
        let velocityY = collectionView.panGestureRecognizer.velocity(in: collectionView).y
        if velocityY < 0 {
            preheatDirection = .down
        } else if velocityY > 0 {
            preheatDirection = .up
        }
        loadVisibleThumbnails()
        prefetchNearVisibleThumbnails()
        delegate?.photoGridController(self, didChangeScrollActivity: true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            isScrollMotionActive = false
            preheatDirection = .none
            loadVisibleThumbnails()
            prefetchNearVisibleThumbnails()
            delegate?.photoGridController(self, didChangeScrollActivity: false)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isScrollMotionActive = false
        preheatDirection = .none
        loadVisibleThumbnails()
        prefetchNearVisibleThumbnails()
        delegate?.photoGridController(self, didChangeScrollActivity: false)
    }
}

extension PhotoGridCollectionViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === selectionPanRecognizer,
              let panGesture = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }

        let velocity = panGesture.velocity(in: collectionView)
        return isSelectionMode && abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === gridPinchRecognizer || otherGestureRecognizer === gridPinchRecognizer
    }
}

final class PhotoGridCollectionViewCell: UICollectionViewCell {
    var representedObjectID: NSManagedObjectID?
    private let imageView = UIImageView()
    private let placeholderView = UIView()
    private let selectionBadgeImageView = UIImageView()
    private let heartBadgeImageView = UIImageView()
    private let livePhotoFavoriteBadgeImageView = UIImageView()
    private let statusLabel = PaddingLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedObjectID = nil
        imageView.image = nil
        statusLabel.isHidden = true
        selectionBadgeImageView.isHidden = true
        heartBadgeImageView.isHidden = true
        livePhotoFavoriteBadgeImageView.isHidden = true
    }

    func configure(
        with item: UIKitPhotoGridItem,
        isSelectionMode: Bool,
        isSelected: Bool
    ) {
        isAccessibilityElement = true
        accessibilityIdentifier = "photoGridItem"
        accessibilityValue = accessibilityValue(for: item)

        selectionBadgeImageView.isHidden = !isSelectionMode
        if isSelectionMode {
            selectionBadgeImageView.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            selectionBadgeImageView.tintColor = isSelected ? .systemBlue : UIColor.white.withAlphaComponent(0.85)
        }

        heartBadgeImageView.isHidden = !item.isHearted
        livePhotoFavoriteBadgeImageView.isHidden = !item.isFavoriteLivePhoto

        let badge: (text: String, systemName: String, backgroundColor: UIColor, foregroundColor: UIColor)?
        switch item.uploadState {
        case .pending, .uploading:
            badge = ("Uploading", "icloud.and.arrow.up", UIColor.black.withAlphaComponent(0.62), .white)
        case .failed:
            badge = ("Retrying later", "exclamationmark.icloud", UIColor.systemOrange.withAlphaComponent(0.9), .black)
        case .paused:
            badge = ("Upload paused", "pause.circle", UIColor.systemRed.withAlphaComponent(0.9), .white)
        case .uploaded:
            badge = nil
        }

        if let badge {
            let configuration = UIImage.SymbolConfiguration(font: .preferredFont(forTextStyle: .caption2), scale: .small)
            let image = UIImage(systemName: badge.systemName, withConfiguration: configuration)
            let attachment = NSTextAttachment(image: image ?? UIImage())
            let attributed = NSMutableAttributedString(attachment: attachment)
            attributed.append(NSAttributedString(string: " \(badge.text)"))
            statusLabel.attributedText = attributed
            statusLabel.backgroundColor = badge.backgroundColor
            statusLabel.textColor = badge.foregroundColor
            statusLabel.isHidden = false
        } else {
            statusLabel.isHidden = true
        }
    }

    func setThumbnailImage(_ image: UIImage?) {
        imageView.image = image
    }

    private func configureViews() {
        clipsToBounds = true
        contentView.clipsToBounds = true

        placeholderView.backgroundColor = UIColor.systemGray5.withAlphaComponent(0.65)
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(placeholderView)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        selectionBadgeImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(selectionBadgeImageView)

        heartBadgeImageView.image = UIImage(systemName: "heart.fill")
        heartBadgeImageView.tintColor = .white
        heartBadgeImageView.contentMode = .center
        heartBadgeImageView.isHidden = true
        heartBadgeImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(heartBadgeImageView)

        livePhotoFavoriteBadgeImageView.image = Self.favoriteLivePhotoBadgeImage()
        livePhotoFavoriteBadgeImageView.tintColor = .white
        livePhotoFavoriteBadgeImageView.contentMode = .center
        livePhotoFavoriteBadgeImageView.isHidden = true
        livePhotoFavoriteBadgeImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(livePhotoFavoriteBadgeImageView)

        statusLabel.font = .preferredFont(forTextStyle: .caption2).bold()
        statusLabel.accessibilityIdentifier = "photoGridUploadBadge"
        statusLabel.layer.cornerRadius = 12
        statusLabel.layer.masksToBounds = true
        statusLabel.numberOfLines = 1
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            placeholderView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            placeholderView.topAnchor.constraint(equalTo: contentView.topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            selectionBadgeImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            selectionBadgeImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),

            heartBadgeImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 7),
            heartBadgeImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7),
            heartBadgeImageView.widthAnchor.constraint(equalToConstant: 22),
            heartBadgeImageView.heightAnchor.constraint(equalToConstant: 22),

            livePhotoFavoriteBadgeImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -7),
            livePhotoFavoriteBadgeImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7),
            livePhotoFavoriteBadgeImageView.widthAnchor.constraint(equalToConstant: 22),
            livePhotoFavoriteBadgeImageView.heightAnchor.constraint(equalToConstant: 22),

            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            statusLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8)
        ])
    }

    private func accessibilityValue(for item: UIKitPhotoGridItem) -> String? {
        var values: [String] = []
        if item.isHearted {
            values.append("Favorite")
        }
        if item.isFavoriteLivePhoto {
            values.append("Favorite Live Photo")
        }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private static func favoriteLivePhotoBadgeImage() -> UIImage? {
        let livePhotoConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let heartConfiguration = UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        guard let livePhoto = UIImage(systemName: "livephoto", withConfiguration: livePhotoConfiguration),
              let heart = UIImage(systemName: "heart.fill", withConfiguration: heartConfiguration) else {
            return UIImage(systemName: "livephoto")
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22))
        let image = renderer.image { _ in
            UIColor.white.set()
            livePhoto.draw(in: CGRect(x: 1, y: 1, width: 17, height: 17))
            heart.draw(in: CGRect(x: 12, y: 11, width: 9, height: 9))
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

private final class PaddingLabel: UILabel {
    var insets = UIEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }
}

private extension UIFont {
    func bold() -> UIFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
